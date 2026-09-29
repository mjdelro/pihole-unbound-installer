#!/usr/bin/env bash
# Compatibility dispatcher. Each distribution family has an explicit installer
# so its package management and Docker trust setup can be reviewed independently.

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

[[ -r /etc/os-release ]] || {
  printf 'ERROR: /etc/os-release is missing.\n' >&2
  exit 1
}

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian|ubuntu)
    installer="$SCRIPT_DIR/install-pihole-unbound-debian-ubuntu.sh"
    ;;
  fedora)
    installer="$SCRIPT_DIR/install-pihole-unbound-fedora.sh"
    ;;
  arch)
    installer="$SCRIPT_DIR/install-pihole-unbound-arch.sh"
    ;;
  *)
    printf 'ERROR: Unsupported distribution: %s.\n' "${PRETTY_NAME:-unknown}" >&2
    printf 'Supported families: Debian/Ubuntu, Fedora, and Arch Linux.\n' >&2
    exit 1
    ;;
esac

[[ -x "$installer" ]] || {
  printf 'ERROR: Required installer is missing or not executable: %s\n' "$installer" >&2
  printf 'Clone or download the complete repository, not only this dispatcher.\n' >&2
  exit 1
}

exec "$installer" "$@"
