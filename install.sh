#!/usr/bin/env bash
set -euo pipefail

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "Missing required variable: ${name}"
    exit 1
  fi
}

require_port() {
  local name="$1"
  local value="${!name:-}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    log_error "Invalid port in ${name}: ${value}"
    exit 1
  fi
}

if [[ $EUID -ne 0 ]]; then
  log_error "This installer must run as root. Use: sudo ./install.sh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Missing ${CONFIG_FILE}."
  log_info "Copy ${SCRIPT_DIR}/config.env.example to ${CONFIG_FILE} and edit it first."
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

require_var SSH_PORT
require_var WG_VPS_IP
require_var WG_HOME_ENDPOINT
require_var WG_HOME_PUBKEY
require_var WG_VPS_PRIVKEY
require_var OPENCLAW_PORT
require_var ENABLE_SSH_MFA
require_port SSH_PORT
require_port OPENCLAW_PORT

if [[ "$ENABLE_SSH_MFA" != "true" && "$ENABLE_SSH_MFA" != "false" ]]; then
  log_error "ENABLE_SSH_MFA must be true or false."
  exit 1
fi

if [[ "${SSH_KEEP_CURRENT_PORT:-true}" != "true" && "${SSH_KEEP_CURRENT_PORT:-true}" != "false" ]]; then
  log_error "SSH_KEEP_CURRENT_PORT must be true or false."
  exit 1
fi

MODULES=(
  "${SCRIPT_DIR}/modules/01-system-firewall.sh"
  "${SCRIPT_DIR}/modules/02-wireguard.sh"
  "${SCRIPT_DIR}/modules/03-openclaw-host-prep.sh"
)

for module in "${MODULES[@]}"; do
  if [[ ! -f "$module" ]]; then
    log_error "Missing module: $module"
    exit 1
  fi
done

log_info "Starting OpenClaw private VPS host-preparation setup."
log_warn "Keep your current SSH session open until you confirm login on the new port."

for module in "${MODULES[@]}"; do
  log_info "Running $(basename "$module")"
  bash "$module" "$CONFIG_FILE"
done

log_info "Setup complete."
log_info "OpenClaw application was not installed. The VPS is now prepared for manual host install."
log_info "If SSH_KEEP_CURRENT_PORT=true, verify login on SSH_PORT then set SSH_KEEP_CURRENT_PORT=false and rerun to close legacy SSH port."
