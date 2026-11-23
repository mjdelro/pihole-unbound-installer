#!/usr/bin/env bash
# Fedora installer for Pi-hole v6 and a recursive Unbound resolver.
# Package management and Docker repository trust setup stay explicit in this
# file so they can be audited independently; shared runtime logic lives in lib/common.sh.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly DOCKER_REPO_URL="https://download.docker.com/linux/fedora/docker-ce.repo"
readonly DISTRO_REMOVE_DOCKER_CMD="dnf -y remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    fedora:42|fedora:43|fedora:44|fedora:45) ;;
    *) die "Unsupported system: ${PRETTY_NAME:-unknown}. Supported: maintained Fedora 42-45 releases." ;;
  esac
  log "Supported operating system detected: ${PRETTY_NAME}"
}

install_detection_dependencies() {
  # Install all required host tools once before Docker setup and network mutation.
  dnf -y install iproute iputils python3 ca-certificates curl openssl util-linux bind-utils
}

install_docker() {
  if docker_is_working; then
    log "Docker Engine and Compose v2 are already working; leaving them unchanged."
    systemctl enable --now docker
    return
  fi
  log "Installing Docker Engine from Docker's official Fedora RPM repository."
  local package
  local conflicts=()
  for package in docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine podman-docker; do
    if rpm -q "$package" >/dev/null 2>&1; then
      conflicts+=("$package")
    fi
  done
  if (( ${#conflicts[@]} > 0 )); then
    warn "Docker's official packages conflict with installed distribution packages: ${conflicts[*]}"
    confirm "Remove those conflicting packages (Docker data is retained)? [y/N]: " || \
      die "Cannot install official Docker packages while conflicts remain."
    dnf -y remove "${conflicts[@]}"
  fi
  dnf -y install dnf5-plugins
  if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
    dnf config-manager addrepo --from-repofile "$DOCKER_REPO_URL"
  fi
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  docker version
  docker compose version
  DOCKER_INSTALLED_BY_SCRIPT=1
}

run_installer "$@"
