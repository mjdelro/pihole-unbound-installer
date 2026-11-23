#!/usr/bin/env bash
# Shared core library for the Pi-hole v6 + Unbound installers.
# Distribution-specific scripts define:
#   - detect_os()
#   - install_detection_dependencies()
#   - install_docker()
#   - DISTRO_REMOVE_DOCKER_CMD

readonly INSTALL_DIR="/opt/pihole-unbound"
readonly BACKUP_ROOT="/root"
readonly ROLLBACK_UNIT="pihole-network-rollback-$$"
readonly ROOT_HINTS_URL="https://www.internic.net/domain/named.root"
readonly UNBOUND_BASE_IMAGE="debian:trixie-slim"
readonly UNBOUND_LOCAL_IMAGE="local/pihole-unbound:trixie"
readonly ROLLBACK_KEEP_COUNT=3

TMP_FILES=()
NETWORK_BACKEND=""
PRIMARY_IFACE=""
CURRENT_CIDR=""
CURRENT_IP=""
PREFIX=""
GATEWAY=""
LAN_CIDR=""
DNS_SERVERS=""
LINK_KIND="ethernet"
STATIC_IP=""
WEB_PORT="8080"
CLI_WEB_PORT=""
TIMEZONE="UTC"
BACKUP_DIR=""
DOCKER_INSTALLED_BY_SCRIPT=0
RESOLVED_CHANGED=0
IPV6_ENABLED=0
UPDATES_ENABLED=0
WEB_PASSWORD=""
DOCKER_SUBNET=""

log()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

dc() {
  docker compose -f "$INSTALL_DIR/compose.yaml" --env-file "$INSTALL_DIR/.env" "$@"
}

cleanup() {
  local file
  (( ${#TMP_FILES[@]} > 0 )) || return 0
  for file in "${TMP_FILES[@]}"; do
    [[ -e "$file" ]] && rm -f -- "$file" || :
  done
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-unknown} command=${BASH_COMMAND:-unknown}
  printf '\n\033[1;31mInstallation failed (exit %d) at line %s.\033[0m\nCommand: %s\n' \
    "$rc" "$line" "$command" >&2
  if [[ -n "${BACKUP_DIR:-}" ]]; then
    printf 'Network backup: %s\n' "$BACKUP_DIR" >&2
  fi
  exit "$rc"
}

trap cleanup EXIT
trap on_error ERR

usage() {
  cat <<'EOF'
Usage: install-pihole-unbound.sh [OPTIONS]

Options:
  --web-port PORT   TCP port for the Pi-hole web UI (default: 8080, range: 1-65535)
  -h, --help        Show this help message and exit
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --web-port)
        [[ $# -ge 2 ]] || die "--web-port requires a port number."
        validate_port "$2" || die "Invalid --web-port value: $2 (must be 1-65535 and not 53)."
        CLI_WEB_PORT=$2
        shift 2
        ;;
      --web-port=*)
        local val=${1#*=}
        validate_port "$val" || die "Invalid --web-port value: $val (must be 1-65535 and not 53)."
        CLI_WEB_PORT=$val
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1 (use --help for usage)"
        ;;
    esac
  done
}

validate_port() {
  local port=$1
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 && port != 53 ))
}

require_root() {
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "Run this installer as root (sudo is not installed)."
    exec sudo --preserve-env=SSH_CONNECTION,SSH_CLIENT,SSH_TTY bash "$0" "$@"
  fi
}

confirm() {
  local prompt=$1 reply
  read -r -p "$prompt" reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_commands_for_detection() {
  command -v ip >/dev/null 2>&1 || die "The iproute2 package is required."
  command -v awk >/dev/null 2>&1 || die "awk is required."
  command -v python3 >/dev/null 2>&1 || die "python3 is required for safe IP validation."
  command -v dig >/dev/null 2>&1 || die "dig (dnsutils/bind-utils) is required for DNS verification."
}

detect_primary_interface() {
  local route
  route=$(ip -4 route show default | awk 'NR==1 {print}')
  [[ -n "$route" ]] || die "No IPv4 default route was found."
  PRIMARY_IFACE=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' <<<"$route")
  GATEWAY=$(awk '{for (i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' <<<"$route")
  [[ -n "$PRIMARY_IFACE" && -n "$GATEWAY" ]] || die "Could not parse the primary interface and gateway."
  CURRENT_CIDR=$(ip -o -4 addr show dev "$PRIMARY_IFACE" scope global | awk 'NR==1 {print $4}')
  [[ -n "$CURRENT_CIDR" ]] || die "No global IPv4 address is assigned to $PRIMARY_IFACE."
  CURRENT_IP=${CURRENT_CIDR%/*}
  PREFIX=${CURRENT_CIDR#*/}
  [[ -d "/sys/class/net/$PRIMARY_IFACE/wireless" ]] && LINK_KIND="wifi"
  if command -v resolvectl >/dev/null 2>&1; then
    DNS_SERVERS=$(resolvectl dns "$PRIMARY_IFACE" 2>/dev/null | awk -F': ' 'NR==1 {gsub(/ /, ",", $2); print $2}' || :)
  fi
  if [[ -z "$DNS_SERVERS" ]] && command -v nmcli >/dev/null 2>&1; then
    DNS_SERVERS=$(nmcli -g IP4.DNS device show "$PRIMARY_IFACE" 2>/dev/null | paste -sd, - || :)
  fi
  if [[ -z "$DNS_SERVERS" ]]; then
    DNS_SERVERS=$(awk '/^nameserver[[:space:]]+/ && $2 !~ /^127\./ {print $2}' /etc/resolv.conf | paste -sd, -)
  fi
  # The gateway is a better persistence fallback than writing a local stub
  # address (127.0.0.53) into interface configuration.
  [[ -n "$DNS_SERVERS" ]] || DNS_SERVERS="$GATEWAY"
}

detect_network_backend() {
  local nm_state="" networkd_state=""
  if command -v nmcli >/dev/null 2>&1; then
    nm_state=$(nmcli -t -f GENERAL.STATE device show "$PRIMARY_IFACE" 2>/dev/null | cut -d: -f2- || :)
  fi
  if [[ "$nm_state" == 100* || "$nm_state" == *connected* ]]; then
    NETWORK_BACKEND="NetworkManager"
  elif compgen -G '/etc/netplan/*.yaml' >/dev/null || compgen -G '/etc/netplan/*.yml' >/dev/null; then
    NETWORK_BACKEND="netplan"
  else
    networkd_state=$(systemctl is-active systemd-networkd 2>/dev/null || :)
    if [[ "$networkd_state" == "active" ]] && networkctl status "$PRIMARY_IFACE" >/dev/null 2>&1; then
      NETWORK_BACKEND="systemd-networkd"
    elif [[ -f /etc/network/interfaces ]]; then
      NETWORK_BACKEND="ifupdown"
    else
      die "No supported network manager controls $PRIMARY_IFACE. Configure a static address manually, then rerun."
    fi
  fi
}

detect_network_configuration() {
  detect_primary_interface
  detect_network_backend
  if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && [[ $(</proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] && ip -6 addr show scope global | grep -q 'inet6'; then
    IPV6_ENABLED=1
  fi
  printf '\nDetected network configuration\n'
  printf '  Interface:       %s (%s)\n' "$PRIMARY_IFACE" "$LINK_KIND"
  printf '  Address:         %s\n' "$CURRENT_CIDR"
  printf '  Default gateway: %s\n' "$GATEWAY"
  printf '  DNS servers:     %s\n' "$DNS_SERVERS"
  printf '  Network backend: %s\n\n' "$NETWORK_BACKEND"
}

validate_static_ip() {
  local candidate=$1 result
  result=$(python3 - "$candidate" "$PREFIX" "$GATEWAY" <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.IPv4Address(sys.argv[1])
    prefix = int(sys.argv[2])
    gateway = ipaddress.IPv4Address(sys.argv[3])
    net = ipaddress.IPv4Network(f"{ip}/{prefix}", strict=False)
    current_net = ipaddress.IPv4Network(f"{gateway}/{prefix}", strict=False)
    if ip not in current_net: raise ValueError("address is not in the gateway's subnet")
    if ip in (net.network_address, net.broadcast_address): raise ValueError("address is the network or broadcast address")
    if ip == gateway: raise ValueError("address is the default gateway")
    if ip.is_unspecified or ip.is_loopback or ip.is_multicast or ip.is_link_local or ip.is_reserved:
        raise ValueError("address is reserved or link-local")
    # A LAN DNS service must not become an Internet-facing open resolver. Use
    # RFC1918 explicitly because ipaddress.is_private also includes documentation ranges.
    rfc1918 = [ipaddress.IPv4Network(x) for x in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    if not any(ip in block for block in rfc1918):
        raise ValueError("address is not RFC1918 private; this installer will not expose DNS on a public address")
    print(net)
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
PY
  ) || return 1
  LAN_CIDR=$result
}

ask_static_ip() {
  local candidate
  while :; do
    read -r -p "Desired static address [$CURRENT_IP]: " candidate
    candidate=${candidate:-$CURRENT_IP}
    if validate_static_ip "$candidate"; then
      STATIC_IP=$candidate
      break
    fi
    warn "Invalid static address. It must be a usable private address in $GATEWAY/$PREFIX."
  done
}

check_duplicate_ip() {
  local conflict=0
  if [[ "$STATIC_IP" == "$CURRENT_IP" ]]; then
    log "$STATIC_IP is already assigned to this interface; duplicate probes are not meaningful."
    return
  fi
  log "Checking whether $STATIC_IP appears to be in use (no probe can guarantee an unused address)."
  ip neigh show to "$STATIC_IP" | grep -Eq 'lladdr .* (REACHABLE|STALE|DELAY|PROBE|PERMANENT)' && conflict=1
  if command -v arping >/dev/null 2>&1; then
    if ! arping -D -c 3 -w 4 -I "$PRIMARY_IFACE" "$STATIC_IP" >/dev/null 2>&1; then
      conflict=1
    fi
  fi
  if ping -4 -c 2 -W 1 "$STATIC_IP" >/dev/null 2>&1; then conflict=1; fi
  (( conflict == 0 )) || die "$STATIC_IP responded on the LAN. Choose another address or verify the owner first."
  warn "No conflict was detected, but silent or sleeping devices may not respond."
}

backup_network_config() {
  local stamp path
  stamp=$(date +%Y%m%d-%H%M%S)
  BACKUP_DIR="$BACKUP_ROOT/network-backup-$stamp"
  install -d -m 700 "$BACKUP_DIR"
  for path in /etc/netplan /etc/systemd/network /etc/NetworkManager/system-connections /etc/network/interfaces /etc/network/interfaces.d /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d /etc/resolv.conf; do
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a --parents "$path" "$BACKUP_DIR"
    fi
  done
  printf '%s\n' "$NETWORK_BACKEND" >"$BACKUP_DIR/backend"
  chmod 600 "$BACKUP_DIR/backend"
  log "Network configuration backed up to $BACKUP_DIR"
}

create_rollback_script() {
  local script="$BACKUP_DIR/rollback-network.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
backup=$(printf '%q' "$BACKUP_DIR")
for rel in etc/netplan etc/systemd/network etc/NetworkManager/system-connections etc/network/interfaces etc/network/interfaces.d etc/systemd/resolved.conf etc/systemd/resolved.conf.d etc/resolv.conf; do
  if [[ -e "\$backup/\$rel" || -L "\$backup/\$rel" ]]; then
    rm -rf -- "/\$rel"
    cp -a "\$backup/\$rel" "/\$rel"
  fi
done
case $(printf '%q' "$NETWORK_BACKEND") in
  NetworkManager) systemctl reload NetworkManager; nmcli connection reload ;;
  netplan) netplan generate; netplan apply ;;
  systemd-networkd) systemctl restart systemd-networkd ;;
  ifupdown) ifdown --force $(printf '%q' "$PRIMARY_IFACE") || :; ifup $(printf '%q' "$PRIMARY_IFACE") ;;
esac
systemctl restart systemd-resolved 2>/dev/null || :
EOF
  chmod 700 "$script"
  systemd-run --unit="$ROLLBACK_UNIT" --on-active=3m "$script" >/dev/null
  warn "A three-minute automatic rollback has been armed. It will be cancelled only after connectivity checks pass."
}

configure_networkmanager() {
  local connection dns_list
  connection=$(nmcli -g GENERAL.CONNECTION device show "$PRIMARY_IFACE")
  [[ -n "$connection" && "$connection" != "--" ]] || die "No active NetworkManager connection was found."
  dns_list=$DNS_SERVERS
  nmcli connection modify "$connection" ipv4.method manual \
    ipv4.addresses "$STATIC_IP/$PREFIX" ipv4.gateway "$GATEWAY" \
    ipv4.dns "$dns_list" ipv4.never-default no
  nmcli connection up "$connection"
}

configure_netplan() {
  local type="ethernets"
  [[ "$LINK_KIND" == "wifi" ]] && type="wifis"
  install -d -m 755 /etc/netplan
  cat >/etc/netplan/99-pihole-static.yaml <<EOF
# Generated by install-pihole-unbound.sh. A late filename ensures these scalar
# settings override DHCP settings from vendor/cloud-init netplan definitions.
network:
  version: 2
  ${type}:
    ${PRIMARY_IFACE}:
      dhcp4: false
      addresses: [${STATIC_IP}/${PREFIX}]
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVERS//,/, }]
EOF
  chmod 600 /etc/netplan/99-pihole-static.yaml
  netplan generate
  netplan apply
}

configure_networkd() {
  local dns_lines="" server
  local -a servers
  IFS=',' read -ra servers <<<"$DNS_SERVERS"
  for server in "${servers[@]}"; do
    [[ "$server" != "not detected" && -n "$server" ]] && dns_lines+="DNS=$server"$'\n'
  done
  install -d -m 755 /etc/systemd/network
  cat >/etc/systemd/network/00-pihole-static.network <<EOF
# Generated by install-pihole-unbound.sh. networkd uses the first matching file.
[Match]
Name=$PRIMARY_IFACE

[Network]
DHCP=no
Address=$STATIC_IP/$PREFIX
Gateway=$GATEWAY
${dns_lines}
EOF
  systemctl restart systemd-networkd
}

configure_ifupdown() {
  local dns_space=${DNS_SERVERS//,/ }
  grep -Eq "^[[:space:]]*iface[[:space:]]+$PRIMARY_IFACE[[:space:]]+inet[[:space:]]" /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null && \
    die "An existing ifupdown stanza controls $PRIMARY_IFACE. Automatic editing is unsafe; configure it statically and rerun. Backup: $BACKUP_DIR"
  install -d -m 755 /etc/network/interfaces.d
  grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces.d' /etc/network/interfaces || \
    printf '\nsource /etc/network/interfaces.d/*\n' >>/etc/network/interfaces
  cat >/etc/network/interfaces.d/pihole-static <<EOF
# Generated by install-pihole-unbound.sh
auto $PRIMARY_IFACE
iface $PRIMARY_IFACE inet static
    address $STATIC_IP/$PREFIX
    gateway $GATEWAY
    dns-nameservers $dns_space
EOF
  ifdown --force "$PRIMARY_IFACE" || :
  ifup "$PRIMARY_IFACE"
}

configure_static_ip() {
  printf '\nIMPORTANT:\n  Reserve %s for this machine in your router DHCP configuration,\n  or place it outside the router DHCP allocation pool.\n\n' "$STATIC_IP"
  if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]]; then
    warn "SSH SESSION DETECTED: changing this address can disconnect this session."
  fi
  confirm "Apply the static network configuration now? [y/N]: " || die "Network configuration cancelled by user."
  backup_network_config
  create_rollback_script
  case "$NETWORK_BACKEND" in
    NetworkManager) configure_networkmanager ;;
    netplan) configure_netplan ;;
    systemd-networkd) configure_networkd ;;
    ifupdown) configure_ifupdown ;;
  esac
  verify_network
  systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || :
  systemctl reset-failed "$ROLLBACK_UNIT.service" 2>/dev/null || :
  log "Connectivity verified; automatic rollback cancelled."
}

network_is_already_static() {
  [[ "$STATIC_IP" == "$CURRENT_IP" ]] || return 1
  case "$NETWORK_BACKEND" in
    NetworkManager)
      local connection
      connection=$(nmcli -g GENERAL.CONNECTION device show "$PRIMARY_IFACE")
      [[ $(nmcli -g ipv4.method connection show "$connection") == manual ]]
      ;;
    netplan) [[ -f /etc/netplan/99-pihole-static.yaml ]] ;;
    systemd-networkd) [[ -f /etc/systemd/network/00-pihole-static.network ]] ;;
    ifupdown) [[ -f /etc/network/interfaces.d/pihole-static ]] ;;
  esac
}

verify_network() {
  ip -4 addr show dev "$PRIMARY_IFACE"
  ip -4 route show
  ip -4 addr show dev "$PRIMARY_IFACE" | grep -q "inet $STATIC_IP/$PREFIX"
  ping -4 -c 3 -W 2 "$GATEWAY" >/dev/null || die "The default gateway is unreachable; rollback remains armed."
  ping -4 -c 3 -W 2 1.1.1.1 >/dev/null || ping -4 -c 3 -W 2 9.9.9.9 >/dev/null || \
    die "Public IPv4 connectivity failed; rollback remains armed."
}

docker_is_working() {
  command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

port53_listeners() {
  ss -H -lntp '( sport = :53 )' 2>/dev/null || :
  ss -H -lnup '( sport = :53 )' 2>/dev/null || :
}

handle_systemd_resolved() {
  local listeners=$1
  if grep -vE '127\.0\.0\.(53|54)(%[^:]*)?:53' <<<"$listeners" | grep -q ':53'; then
    return 1
  fi
  # Docker publishes on SERVER_IP, not 0.0.0.0, so the loopback stub is not a
  # socket conflict. Leaving resolved intact is the safest way to preserve host DNS.
  log "systemd-resolved uses only a loopback stub; exact-address Docker binding can coexist, so it is unchanged."
  return 0
}

check_port_53() {
  local listeners non_stub other
  listeners=$(port53_listeners)
  [[ -z "$listeners" ]] && return
  if grep -q 'systemd-resolve' <<<"$listeners" && handle_systemd_resolved "$listeners"; then
    return
  fi
  non_stub=$(grep -vE '127\.0\.0\.(53|54)(%[^:]*)?:53' <<<"$listeners" || :)
  if [[ -f "$INSTALL_DIR/compose.yaml" ]]; then
    other=$(grep -vE 'docker-proxy|pihole' <<<"$non_stub" || :)
    if [[ -z "$other" ]] && dc ps -q pihole 2>/dev/null | grep -q .; then
      log "Port 53 is owned by the existing Pi-hole installation."
      return
    fi
  fi
  printf '%s\n' "$non_stub" >&2
  die "Port 53 is already occupied on a non-stub address. No service was stopped automatically."
}

select_and_check_web_port() {
  local existing_port="" listeners candidate
  if [[ -n "$CLI_WEB_PORT" ]]; then
    WEB_PORT=$CLI_WEB_PORT
  elif [[ -f "$INSTALL_DIR/.env" ]]; then
    existing_port=$(sed -n 's/^WEB_PORT=//p' "$INSTALL_DIR/.env" | head -1)
    if [[ -n "$existing_port" ]] && validate_port "$existing_port"; then
      WEB_PORT=$existing_port
    fi
  fi

  while :; do
    listeners=$(ss -H -lntp "( sport = :$WEB_PORT )" 2>/dev/null || :)
    if [[ -z "$listeners" ]]; then
      return
    fi
    if [[ -f "$INSTALL_DIR/compose.yaml" ]] && dc ps -q pihole 2>/dev/null | grep -q .; then
      log "TCP port $WEB_PORT is owned by the existing Pi-hole installation."
      return
    fi
    warn "TCP port $WEB_PORT is already occupied:"
    printf '%s\n' "$listeners" >&2
    read -r -p "Choose another TCP port for the Pi-hole web UI (e.g. 8081): " candidate
    if validate_port "$candidate"; then
      WEB_PORT=$candidate
    else
      warn "Invalid port number. Enter a value from 1 to 65535 (excluding 53)."
    fi
  done
}

detect_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    TIMEZONE=$(timedatectl show -p Timezone --value 2>/dev/null || printf UTC)
  elif [[ -r /etc/timezone ]]; then
    TIMEZONE=$(</etc/timezone)
  fi
  [[ -n "$TIMEZONE" ]] || TIMEZONE="UTC"
}

select_docker_subnet() {
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    DOCKER_SUBNET=$(sed -n 's/^DOCKER_SUBNET=//p' "$INSTALL_DIR/.env" | head -1)
    if [[ -n "$DOCKER_SUBNET" ]]; then
      log "Reusing existing Docker subnet $DOCKER_SUBNET."
      return
    fi
  fi
  DOCKER_SUBNET=$(python3 - <<'PY'
import ipaddress, subprocess
routes = []
for line in subprocess.check_output(["ip", "-4", "route", "show"], text=True).splitlines():
    field = line.split()[0]
    if field == "default":
        continue
    try:
        routes.append(ipaddress.IPv4Network(field, strict=False))
    except ValueError:
        pass
for text in ("172.31.53.0/24", "172.30.53.0/24", "10.255.53.0/24", "172.29.53.0/24"):
    candidate = ipaddress.IPv4Network(text)
    if not any(candidate.overlaps(route) for route in routes):
        print(candidate)
        break
else:
    raise SystemExit("No conflict-free Docker subnet candidate was found")
PY
  ) || die "Could not select a conflict-free private Docker subnet."
}

generate_password() {
  local supplied="" confirmation=""
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    WEB_PASSWORD=$(sed -n 's/^WEB_PASSWORD=//p' "$INSTALL_DIR/.env" | head -1)
  fi
  [[ -n "$WEB_PASSWORD" ]] && return
  while :; do
    read -r -s -p "Pi-hole web password (leave blank to generate one): " supplied
    printf '\n'
    if [[ -z "$supplied" ]]; then
      WEB_PASSWORD=$(openssl rand -base64 30 | tr -d '\n' | tr '/+' '_-')
      return
    fi
    if (( ${#supplied} < 12 )) || [[ ! "$supplied" =~ ^[A-Za-z0-9._@%+=:-]+$ ]]; then
      warn "Use at least 12 characters from: letters, digits, . _ @ % + = : -"
      continue
    fi
    read -r -s -p "Confirm Pi-hole web password: " confirmation
    printf '\n'
    if [[ "$supplied" == "$confirmation" ]]; then
      WEB_PASSWORD=$supplied
      return
    fi
    warn "Passwords did not match; try again."
  done
}

backup_existing_file() {
  local path=$1 stamp
  [[ -e "$path" ]] || return
  stamp=$(date +%Y%m%d-%H%M%S)
  cp -a "$path" "$path.bak-$stamp"
}

selinux_mount_opts() {
  if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null || :) == Enforcing ]]; then
    printf 'Z'
  fi
}

create_compose_files() {
  local previous_backup="" previous_docker="" previous_resolved="" tmp_root_hints=""
  local selinux_flag ro_opt rw_opt
  if [[ -f "$INSTALL_DIR/.env" ]]; then
    previous_backup=$(sed -n 's/^NETWORK_BACKUP_DIR=//p' "$INSTALL_DIR/.env" | head -1)
    previous_docker=$(sed -n 's/^DOCKER_INSTALLED_BY_SCRIPT=//p' "$INSTALL_DIR/.env" | head -1)
    previous_resolved=$(sed -n 's/^RESOLVED_CHANGED=//p' "$INSTALL_DIR/.env" | head -1)
  fi
  [[ -n "$BACKUP_DIR" ]] || BACKUP_DIR=$previous_backup
  [[ "$previous_docker" == 1 ]] && DOCKER_INSTALLED_BY_SCRIPT=1
  [[ "$previous_resolved" == 1 ]] && RESOLVED_CHANGED=1
  detect_timezone
  select_docker_subnet
  generate_password
  install -d -m 755 "$INSTALL_DIR" "$INSTALL_DIR/etc-pihole" "$INSTALL_DIR/unbound"
  backup_existing_file "$INSTALL_DIR/.env"
  backup_existing_file "$INSTALL_DIR/compose.yaml"
  backup_existing_file "$INSTALL_DIR/unbound/Dockerfile"
  backup_existing_file "$INSTALL_DIR/unbound/unbound.conf"
  backup_existing_file "$INSTALL_DIR/unbound/root.hints"

  selinux_flag=$(selinux_mount_opts)
  if [[ -n "$selinux_flag" ]]; then
    ro_opt=":ro,Z"
    rw_opt=":Z"
    log "SELinux is enforcing; applying :Z relabeling options to Docker bind mounts."
  else
    ro_opt=":ro"
    rw_opt=""
  fi

  cat >"$INSTALL_DIR/.env" <<EOF
SERVER_IP=$STATIC_IP
WEB_PORT=$WEB_PORT
TZ=$TIMEZONE
WEB_PASSWORD=$WEB_PASSWORD
LAN_CIDR=$LAN_CIDR
DOCKER_SUBNET=$DOCKER_SUBNET
DOCKER_INSTALLED_BY_SCRIPT=$DOCKER_INSTALLED_BY_SCRIPT
NETWORK_BACKUP_DIR=$BACKUP_DIR
NETWORK_BACKEND=$NETWORK_BACKEND
RESOLVED_CHANGED=$RESOLVED_CHANGED
EOF
  chmod 600 "$INSTALL_DIR/.env"

  cat >"$INSTALL_DIR/compose.yaml" <<EOF
name: pihole-unbound
services:
  unbound:
    build:
      context: ./unbound
    image: ${UNBOUND_LOCAL_IMAGE}
    restart: unless-stopped
    networks:
      - dns-backend
    volumes:
      - ./unbound/unbound.conf:/etc/unbound/unbound.conf${ro_opt}
      - ./unbound/root.hints:/var/lib/unbound/root.hints${ro_opt}
    healthcheck:
      test: ["CMD-SHELL", "dig @127.0.0.1 -p 5335 dnssec.works A +dnssec +time=3 +tries=1 | grep -q 'status: NOERROR'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 20s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - SETGID
      - SETUID
      - DAC_OVERRIDE

  pihole:
    image: pihole/pihole:latest
    restart: unless-stopped
    depends_on:
      unbound:
        condition: service_healthy
    networks:
      - dns-backend
    ports:
      # Binding to the selected LAN address avoids publishing DNS on every host interface.
      - "\${SERVER_IP}:53:53/tcp"
      - "\${SERVER_IP}:53:53/udp"
      - "\${SERVER_IP}:\${WEB_PORT}:80/tcp"
    environment:
      TZ: "\${TZ}"
      FTLCONF_dns_upstreams: "unbound#5335"
      FTLCONF_dns_listeningMode: "ALL"
      FTLCONF_webserver_api_password: "\${WEB_PASSWORD}"
    volumes:
      - ./etc-pihole:/etc/pihole${rw_opt}
    healthcheck:
      test: ["CMD-SHELL", "dig @127.0.0.1 pi.hole A +time=3 +tries=1 | grep -q 'status: NOERROR'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      - no-new-privileges:true

networks:
  dns-backend:
    driver: bridge
    internal: false
    ipam:
      config:
        - subnet: "\${DOCKER_SUBNET}"
EOF

  cat >"$INSTALL_DIR/unbound/Dockerfile" <<EOF
# Debian is used instead of an opaque third-party DNS image. The image is tiny,
# auditable, and obtains Unbound security updates from Debian's official archive.
FROM ${UNBOUND_BASE_IMAGE}
RUN apt-get update \\
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends unbound dnsutils dns-root-data ca-certificates \\
 && install -d -o unbound -g unbound /var/lib/unbound \\
 && install -o unbound -g unbound -m 0644 /usr/share/dns/root.key /var/lib/unbound/root.key \\
 && rm -rf /var/lib/apt/lists/*
EXPOSE 5335/tcp 5335/udp
CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
EOF

  cat >"$INSTALL_DIR/unbound/unbound.conf" <<EOF
server:
  verbosity: 1
  num-threads: 1
  interface: 0.0.0.0@5335
  # Only the dedicated Compose subnet can query Unbound. Its port is never published.
  access-control: 0.0.0.0/0 refuse
  access-control: $DOCKER_SUBNET allow
  root-hints: "/var/lib/unbound/root.hints"
  auto-trust-anchor-file: "/var/lib/unbound/root.key"
  module-config: "validator iterator"
  val-permissive-mode: no
  username: "unbound"
  directory: "/etc/unbound"
  chroot: ""
  pidfile: ""
  do-ip4: yes
  do-udp: yes
  do-tcp: yes
  do-ip6: no
  hide-identity: yes
  hide-version: yes
  minimal-responses: yes
  qname-minimisation: yes
  harden-glue: yes
  harden-dnssec-stripped: yes
  harden-below-nxdomain: yes
  aggressive-nsec: yes
  use-caps-for-id: no
  prefetch: yes
  prefetch-key: yes
  serve-expired: yes
  serve-expired-ttl: 86400
  rrset-cache-size: 100m
  msg-cache-size: 50m
  so-rcvbuf: 1m
  so-sndbuf: 1m
  cache-min-ttl: 300
  cache-max-ttl: 86400
  unwanted-reply-threshold: 10000000
  edns-buffer-size: 1232
  val-clean-additional: yes
  # Protect against DNS rebinding attacks returning private addresses for public names.
  private-address: 192.168.0.0/16
  private-address: 169.254.0.0/16
  private-address: 172.16.0.0/12
  private-address: 10.0.0.0/8
  private-address: fd00::/8
  private-address: fe80::/10
EOF
  tmp_root_hints=$(mktemp "$INSTALL_DIR/unbound/.root.hints.XXXXXX")
  TMP_FILES+=("$tmp_root_hints")
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 "$ROOT_HINTS_URL" -o "$tmp_root_hints"
  grep -q '^\.[[:space:]].*IN[[:space:]]\+NS' "$tmp_root_hints" || die "Downloaded root hints failed validation."
  mv "$tmp_root_hints" "$INSTALL_DIR/unbound/root.hints"
  chmod 644 "$INSTALL_DIR/unbound/root.hints" "$INSTALL_DIR/unbound/unbound.conf"
}

configure_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    log "Adding LAN-scoped UFW rules (Docker's own rules still apply; ports bind only to $STATIC_IP)."
    ufw allow from "$LAN_CIDR" to "$STATIC_IP" port 53 proto tcp
    ufw allow from "$LAN_CIDR" to "$STATIC_IP" port 53 proto udp
    ufw allow from "$LAN_CIDR" to "$STATIC_IP" port "$WEB_PORT" proto tcp
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    local zone=""
    zone=$(firewall-cmd --get-zone-of-interface="$PRIMARY_IFACE" 2>/dev/null || :)
    if [[ -z "$zone" || "$zone" == "no zone" ]]; then
      zone=$(firewall-cmd --get-default-zone)
    fi
    firewall-cmd --permanent --zone="$zone" --add-service=dns
    firewall-cmd --permanent --zone="$zone" --add-port="$WEB_PORT/tcp"
    firewall-cmd --reload
    warn "firewalld rules were added to zone $zone; confirm that zone contains only trusted LAN interfaces."
  elif command -v nft >/dev/null 2>&1 && systemctl is-active nftables >/dev/null 2>&1; then
    warn "nftables is active. Existing rules were not flushed or rewritten. Ensure $LAN_CIDR can reach TCP/UDP 53 and TCP $WEB_PORT on $STATIC_IP."
  fi
}

wait_for_healthy() {
  local service=$1 timeout=${2:-180} id status started
  id=$(dc ps -q "$service")
  [[ -n "$id" ]] || return 1
  started=$SECONDS
  while (( SECONDS - started < timeout )); do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")
    [[ "$status" == healthy ]] && return 0
    [[ "$status" == unhealthy || "$status" == exited || "$status" == dead ]] && return 1
    sleep 3
  done
  return 1
}

show_diagnostics() {
  dc ps || :
  dc logs --tail=100 pihole || :
  dc logs --tail=100 unbound || :
}

start_stack() {
  (cd "$INSTALL_DIR" && docker compose build --pull unbound && docker compose pull pihole && docker compose up -d --remove-orphans)
  if ! wait_for_healthy unbound 180 || ! wait_for_healthy pihole 240; then
    show_diagnostics
    die "One or more DNS containers did not become healthy."
  fi
}

verify_unbound() {
  dc exec -T unbound \
    dig @127.0.0.1 -p 5335 example.com A +short +time=5 +tries=2 | grep -qE '^[0-9]+\.'
}

verify_pihole() {
  dc exec -T pihole \
    dig @unbound -p 5335 example.com A +short +time=5 +tries=2 | grep -qE '^[0-9]+\.'
  dig "@$STATIC_IP" example.com A +short +time=5 +tries=2 | grep -qE '^[0-9]+\.'
  # A blocklist target may intentionally return NOERROR, NXDOMAIN, or NODATA;
  # receiving a syntactically valid response verifies Pi-hole answered it.
  dig "@$STATIC_IP" doubleclick.net A +time=5 +tries=2 | grep -qE 'status: (NOERROR|NXDOMAIN)'
}

verify_dnssec() {
  dig "@$STATIC_IP" dnssec.works A +dnssec +time=5 +tries=2 | grep -q 'status: NOERROR'
  dig "@$STATIC_IP" fail01.dnssec.works A +dnssec +time=5 +tries=2 | grep -q 'status: SERVFAIL'
}

verify_installation() {
  dc ps
  if ! verify_unbound || ! verify_pihole || ! verify_dnssec; then
    show_diagnostics
    die "DNS verification failed."
  fi
  log "Unbound, Pi-hole, LAN-address DNS, and DNSSEC verification passed."
}

create_update_script() {
  cat >"$INSTALL_DIR/update.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=\$'\n\t'
cd /opt/pihole-unbound
exec 9>/run/lock/pihole-unbound-update.lock
flock -n 9 || { echo "Another Pi-hole update is already running; exiting."; exit 0; }
fail() {
  echo "Update verification failed; old images were retained."
  docker compose ps || :
  docker compose logs --tail=100 pihole unbound || :
  exit 1
}
mapfile -t old_images < <(docker compose images -q | sort -u)
# Retag current images before pulling. This keeps a known-good local rollback
# target even after a mutable upstream tag moves to a newer image.
stamp=\$(date +%Y%m%d-%H%M%S)
for image in "\${old_images[@]}"; do
  short=\$(printf '%s' "\$image" | cut -c8-19)
  docker image tag "\$image" "local/pihole-unbound-rollback:\${stamp}-\${short}"
done
# Pull/build first: a registry outage therefore leaves running DNS untouched.
docker compose pull pihole
tmp_hints=\$(mktemp)
trap 'rm -f "\$tmp_hints"' EXIT
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 https://www.internic.net/domain/named.root -o "\$tmp_hints"
grep -q '^\.[[:space:]].*IN[[:space:]]\+NS' "\$tmp_hints"
install -m 644 "\$tmp_hints" unbound/root.hints
docker compose build --pull unbound
docker compose up -d --remove-orphans
for service in unbound pihole; do
  id=\$(docker compose ps -q "\$service")
  [[ -n "\$id" ]] || fail
  state=""
  for _ in \$(seq 1 80); do
    state=\$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "\$id")
    [[ "\$state" == healthy ]] && break
    [[ "\$state" == unhealthy || "\$state" == exited || "\$state" == dead ]] && fail
    sleep 3
  done
  [[ "\$state" == healthy ]] || fail
done
server_ip=\$(sed -n 's/^SERVER_IP=//p' .env)
docker compose exec -T unbound dig @127.0.0.1 -p 5335 example.com +short +time=5 +tries=2 | grep -qE '^[0-9]+\.' || fail
dig "@\$server_ip" example.com +short +time=5 +tries=2 | grep -qE '^[0-9]+\.' || fail
echo "Update healthy. Previous image IDs retained for manual rollback:"
printf '%s\n' "\${old_images[@]}"

# Retain only the most recent ${ROLLBACK_KEEP_COUNT} rollback timestamps to bound disk usage.
mapfile -t rollback_stamps < <(
  docker image ls --format '{{.Tag}}' local/pihole-unbound-rollback 2>/dev/null \\
    | sed -n 's/^\([0-9]\{8\}-[0-9]\{6\}\)-.*/\1/p' | sort -ru
)
if (( \${#rollback_stamps[@]} > ${ROLLBACK_KEEP_COUNT} )); then
  for old_stamp in "\${rollback_stamps[@]:${ROLLBACK_KEEP_COUNT}}"; do
    while IFS= read -r tag; do
      [[ -n "\$tag" ]] && docker image rm "local/pihole-unbound-rollback:\$tag" >/dev/null 2>&1 || :
    done < <(docker image ls --format '{{.Tag}}' local/pihole-unbound-rollback | grep "^\${old_stamp}-" || :)
  done
fi

# Conservative dangling-image cleanup only. Retained rollback tags stay intact.
docker image prune -f --filter dangling=true
EOF
  chmod 750 "$INSTALL_DIR/update.sh"
}

create_update_service() {
  cat >/etc/systemd/system/pihole-unbound-update.service <<'EOF'
[Unit]
Description=Update and verify Pi-hole and Unbound containers
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/pihole-unbound/update.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/opt/pihole-unbound /run/lock /var/lib/docker
NoNewPrivileges=true
EOF
}

create_configure_updater() {
  cat >"$INSTALL_DIR/configure-updater.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || exec sudo bash "$0" "$@"
valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
while :; do
  printf 'How often should updates be checked?\n  1) Daily\n  2) Weekly\n  3) Monthly\n'
  read -r -p 'Selection [1-3]: ' frequency
  [[ "$frequency" =~ ^[123]$ ]] && break
done
case "$frequency" in
  1)
    while read -r -p 'What time should updates run each day? [HH:MM]: ' time; do valid_time "$time" && break; done
    calendar="*-*-* $time:00"; description="Daily at $time" ;;
  2)
    while :; do
      printf 'Day: 1) Monday  2) Tuesday  3) Wednesday  4) Thursday  5) Friday  6) Saturday  7) Sunday\n'
      read -r -p 'Selection [1-7]: ' day
      [[ "$day" =~ ^[1-7]$ ]] && break
    done
    days=(unused Mon Tue Wed Thu Fri Sat Sun)
    while read -r -p 'What time should updates run? [HH:MM]: ' time; do valid_time "$time" && break; done
    calendar="${days[$day]} *-*-* $time:00"; description="Weekly - ${days[$day]} at $time" ;;
  3)
    while read -r -p 'What day of the month should updates run? [1-28]: ' day; do
      [[ "$day" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] && break
    done
    while read -r -p 'What time should updates run? [HH:MM]: ' time; do valid_time "$time" && break; done
    calendar="*-*-$day $time:00"; description="Monthly - day $day at $time" ;;
esac
cat >/etc/systemd/system/pihole-unbound-update.timer <<TIMER
[Unit]
Description=Scheduled Pi-hole and Unbound container update
[Timer]
OnCalendar=$calendar
Persistent=true
RandomizedDelaySec=15m
Unit=pihole-unbound-update.service
[Install]
WantedBy=timers.target
TIMER
printf '%s\n' "$description" >/opt/pihole-unbound/.update-schedule
systemctl daemon-reload
systemctl enable pihole-unbound-update.timer >/dev/null
systemctl restart pihole-unbound-update.timer
systemctl list-timers pihole-unbound-update.timer --no-pager
EOF
  chmod 750 "$INSTALL_DIR/configure-updater.sh"
}

configure_update_schedule() {
  "$INSTALL_DIR/configure-updater.sh"
}

verify_updater_timer() {
  systemctl status pihole-unbound-update.timer --no-pager
  systemctl list-timers pihole-unbound-update.timer --no-pager
}

create_uninstall_script() {
  cat >"$INSTALL_DIR/uninstall.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || exec sudo bash "\$0" "\$@"
cd /opt/pihole-unbound
installed=\$(sed -n 's/^DOCKER_INSTALLED_BY_SCRIPT=//p' .env 2>/dev/null || printf 0)
echo "This removes containers; persistent Pi-hole files are preserved by default."
read -r -p 'Stop and remove the Pi-hole/Unbound containers? [y/N]: ' answer
if [[ "\$answer" =~ ^[Yy]\$ ]]; then
  docker compose down
  read -r -p 'Also remove the Pi-hole and locally built Unbound images? [y/N]: ' answer
  if [[ "\$answer" =~ ^[Yy]\$ ]]; then
    docker image rm pihole/pihole:latest ${UNBOUND_LOCAL_IMAGE} local/pihole-unbound:bookworm 2>/dev/null || :
    echo 'Images were requested for removal; persistent bind-mounted data was not touched.'
  fi
fi
systemctl disable --now pihole-unbound-update.timer 2>/dev/null || :
rm -f /etc/systemd/system/pihole-unbound-update.timer /etc/systemd/system/pihole-unbound-update.service
systemctl daemon-reload
backup=\$(sed -n 's/^NETWORK_BACKUP_DIR=//p' .env 2>/dev/null || :)
if [[ -n "\$backup" && -x "\$backup/rollback-network.sh" ]]; then
  read -r -p "Restore original network configuration from \$backup? [y/N]: " answer
  [[ "\$answer" =~ ^[Yy]\$ ]] && "\$backup/rollback-network.sh"
fi
read -r -p 'Delete persistent Pi-hole data and all installer files? Type DELETE to confirm: ' answer
if [[ "\$answer" == DELETE ]]; then
  rm -rf -- /opt/pihole-unbound/etc-pihole /opt/pihole-unbound/unbound
  rm -f -- /opt/pihole-unbound/compose.yaml /opt/pihole-unbound/.env /opt/pihole-unbound/.update-schedule /opt/pihole-unbound/update.sh /opt/pihole-unbound/configure-updater.sh /opt/pihole-unbound/uninstall.sh
fi
if [[ "\$installed" == 1 ]]; then
  read -r -p 'Docker was installed by this script. Remove Docker packages too? [y/N]: ' answer
  if [[ "\$answer" =~ ^[Yy]\$ ]]; then
    ${DISTRO_REMOVE_DOCKER_CMD}
    echo 'Docker data under /var/lib/docker was NOT deleted.'
  fi
fi
echo 'Uninstall actions complete. Tagged images and persistent data not explicitly confirmed remain.'
EOF
  chmod 750 "$INSTALL_DIR/uninstall.sh"
}

ask_install_updater() {
  if systemctl is-enabled pihole-unbound-update.timer >/dev/null 2>&1; then
    create_update_script
    create_update_service
    create_configure_updater
    systemctl daemon-reload
    printf '\nAn updater timer already exists.\n  1) Keep its schedule\n  2) Change its schedule\n  3) Disable it\n'
    local choice
    while read -r -p 'Selection [1-3]: ' choice; do [[ "$choice" =~ ^[123]$ ]] && break; done
    case "$choice" in
      1) UPDATES_ENABLED=1 ;;
      2) configure_update_schedule; UPDATES_ENABLED=1 ;;
      3) systemctl disable --now pihole-unbound-update.timer; UPDATES_ENABLED=0 ;;
    esac
    return
  fi
  if confirm "Would you like to install an automatic Pi-hole + Unbound updater? [y/N]: "; then
    create_update_script
    create_update_service
    create_configure_updater
    configure_update_schedule
    verify_updater_timer
    UPDATES_ENABLED=1
  else
    UPDATES_ENABLED=0
  fi
}

print_summary() {
  cat <<EOF

============================================================
              PI-HOLE + UNBOUND INSTALLED
============================================================

Pi-hole address:
    $STATIC_IP

DNS SERVER TO CONFIGURE ON YOUR ROUTER:
    $STATIC_IP

Pi-hole web interface:
    http://$STATIC_IP:$WEB_PORT/admin/

Web password (shown once; also stored in $INSTALL_DIR/.env):
    $WEB_PASSWORD

DNS path:
    LAN -> Pi-hole -> Unbound -> authoritative DNS

Pi-hole:    healthy
Unbound:    healthy
DNS test:   passed
DNSSEC:     passed

IMPORTANT:
    Set your router's LAN DHCP DNS server to $STATIC_IP.
    Do not add a public secondary DNS unless intentional bypass is desired.
    Reserve $STATIC_IP in DHCP or keep it outside the DHCP allocation pool.
    If the router redirects DNS, exempt this DNS server to avoid a loop.

Management:
    cd $INSTALL_DIR
    docker compose ps
    docker compose logs -f
    docker compose pull pihole
    docker compose build --pull unbound
    docker compose up -d
    docker compose restart

Uninstall:       $INSTALL_DIR/uninstall.sh
EOF
  if (( IPV6_ENABLED == 1 )); then
    cat <<'EOF'

IPv6 WARNING:
    IPv6 is enabled. Clients may bypass Pi-hole if the router advertises a
    separate IPv6 DNS resolver. Point router RDNSS/IPv6 DNS advertisements to
    Pi-hole as well; IPv6 was not disabled by this installer.
EOF
  fi
  printf '\n============================================================\n'
}

print_updater_summary() {
  local schedule next
  if (( UPDATES_ENABLED == 1 )); then
    schedule=$(cat "$INSTALL_DIR/.update-schedule" 2>/dev/null || printf Enabled)
    next=$(systemctl list-timers pihole-unbound-update.timer --no-legend 2>/dev/null | awk '{$1=$1; print}' || printf unavailable)
    printf '\nAutomatic updates: Enabled\nSchedule: %s\nNext run: %s\nUpdater logs: journalctl -u pihole-unbound-update.service\nChange schedule: %s/configure-updater.sh\n' \
      "$schedule" "$next" "$INSTALL_DIR"
  else
    cat <<EOF

Automatic updates: Disabled
Manual update:
    cd $INSTALL_DIR
    docker compose pull pihole
    docker compose build --pull unbound
    docker compose up -d --remove-orphans
    # Only after health verification: docker image prune -f --filter dangling=true
EOF
  fi
}

run_installer() {
  parse_args "$@"
  require_root "$@"
  detect_os
  install_detection_dependencies
  require_commands_for_detection
  detect_network_configuration
  ask_static_ip
  check_duplicate_ip
  if network_is_already_static; then
    log "$STATIC_IP is already configured statically by this backend; no network files were changed."
  else
    configure_static_ip
  fi
  install_docker
  check_port_53
  select_and_check_web_port
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "Existing installation detected. Persistent data will be retained and generated configs backed up."
  fi
  create_compose_files
  create_uninstall_script
  configure_firewall
  start_stack
  verify_installation
  # The requested main summary precedes the optional updater prompt.
  UPDATES_ENABLED=0
  print_summary
  ask_install_updater
  print_updater_summary
}
