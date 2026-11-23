#!/usr/bin/env bash
# Debian/Ubuntu installer for Pi-hole v6 and a recursive Unbound resolver.
# Package management and Docker repository trust setup stay explicit in this
# file so they can be audited independently; shared runtime logic lives in lib/common.sh.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
readonly DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
readonly DISTRO_REMOVE_DOCKER_CMD="apt-get remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

OS_ID=""
OS_CODENAME=""

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:11*|debian:12*|debian:13*|debian:14*) ;;
    ubuntu:22.04*|ubuntu:24.04*|ubuntu:26.04*) ;;
    *) die "Unsupported system: ${PRETTY_NAME:-unknown}. Supported: Debian 11-14, Ubuntu 22.04/24.04/26.04 LTS." ;;
  esac
  OS_ID=$ID
  OS_CODENAME=${VERSION_CODENAME:-}
  [[ -n "$OS_CODENAME" ]] || die "Could not determine the distribution codename."
  log "Supported operating system detected: ${PRETTY_NAME}"
}

install_detection_dependencies() {
  # Install all required host tools once before Docker setup and network mutation.
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iproute2 iputils-ping iputils-arping python3 ca-certificates curl openssl util-linux dnsutils
}

install_docker() {
  if docker_is_working; then
    log "Docker Engine and Compose v2 are already working; leaving them unchanged."
    systemctl enable --now docker
    return
  fi
  log "Installing Docker Engine from Docker's official apt repository."
  local package
  local conflicts=()
  for package in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
      conflicts+=("$package")
    fi
  done
  if (( ${#conflicts[@]} > 0 )); then
    warn "Docker's official packages conflict with installed distribution packages: ${conflicts[*]}"
    confirm "Remove those conflicting packages (Docker data is retained)? [y/N]: " || \
      die "Cannot install official Docker packages while conflicts remain."
    apt-get remove -y "${conflicts[@]}"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 30 \
    "https://download.docker.com/linux/$OS_ID/gpg" -o "$DOCKER_KEYRING"
  chmod a+r "$DOCKER_KEYRING"
  local arch
  arch=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$DOCKER_KEYRING" "$OS_ID" "$OS_CODENAME" >"$DOCKER_LIST"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker version
  docker compose version
  DOCKER_INSTALLED_BY_SCRIPT=1
}

run_installer "$@"
