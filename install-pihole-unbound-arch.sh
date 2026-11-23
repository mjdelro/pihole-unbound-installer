#!/usr/bin/env bash
# Arch Linux installer for Pi-hole v6 and a recursive Unbound resolver.
# Package management and Docker repository trust setup stay explicit in this
# file so they can be audited independently; shared runtime logic lives in lib/common.sh.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

readonly DISTRO_REMOVE_DOCKER_CMD="pacman -Rns --noconfirm docker docker-compose docker-buildx"

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == arch ]] || die "Unsupported system: ${PRETTY_NAME:-unknown}. This installer supports Arch Linux itself, not untested derivatives."
  log "Supported operating system detected: ${PRETTY_NAME}"
}

install_detection_dependencies() {
  # Install all required host tools once with a synchronized Arch upgrade.
  warn "Arch Linux does not support partial upgrades; required packages will be installed with a full system upgrade."
  confirm "Run pacman -Syu before installation? [y/N]: " || die "A synchronized Arch upgrade is required."
  pacman -Syu --needed --noconfirm iproute2 iputils python ca-certificates curl openssl util-linux bind
}

install_docker() {
  if docker_is_working; then
    log "Docker Engine and Compose v2 are already working; leaving them unchanged."
    systemctl enable --now docker
    return
  fi
  log "Installing Docker Engine, Buildx, and Compose v2 from Arch's official repositories."
  if pacman -Q podman-docker >/dev/null 2>&1; then
    warn "podman-docker conflicts with the Docker CLI package."
    confirm "Remove podman-docker (container storage is retained)? [y/N]: " || \
      die "Cannot install Docker while podman-docker owns the Docker CLI."
    pacman -Rns --noconfirm podman-docker
  fi
  pacman -S --needed --noconfirm docker docker-compose docker-buildx
  systemctl enable --now docker
  docker version
  docker compose version
  DOCKER_INSTALLED_BY_SCRIPT=1
}

run_installer "$@"
