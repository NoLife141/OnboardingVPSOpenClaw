#!/usr/bin/env bash
set -euo pipefail

log_info() { printf '[INFO] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log_error "Missing required variable: ${name}"
    exit 1
  fi
}

write_wireguard_config() {
  local wg_conf_path="/etc/wireguard/${WG_INTERFACE}.conf"
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "[Interface]"
    echo "Address = ${WG_VPS_IP}"
    echo "PrivateKey = ${WG_VPS_PRIVKEY}"
    echo "Table = auto"
    echo "FwMark = ${WG_FWMARK}"
    if [[ -n "${WG_DNS:-}" ]]; then
      echo "DNS = ${WG_DNS}"
    fi
    echo
    echo "[Peer]"
    echo "PublicKey = ${WG_HOME_PUBKEY}"
    if [[ -n "${WG_HOME_PRESHARED_KEY:-}" ]]; then
      echo "PresharedKey = ${WG_HOME_PRESHARED_KEY}"
    fi
    echo "Endpoint = ${WG_HOME_ENDPOINT}"
    echo "AllowedIPs = ${WG_ALLOWED_IPS}"
    echo "PersistentKeepalive = ${WG_PERSISTENT_KEEPALIVE}"
  } > "$tmp_file"

  install -m 0600 "$tmp_file" "$wg_conf_path"
  rm -f "$tmp_file"
}

configure_sysctl() {
  local sysctl_file="/etc/sysctl.d/99-openclaw-wireguard.conf"
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "net.ipv4.ip_forward=1"
    echo "net.ipv4.conf.all.src_valid_mark=1"
  } > "$tmp_file"

  install -m 0644 "$tmp_file" "$sysctl_file"
  rm -f "$tmp_file"
  sysctl --system >/dev/null
}

validate_policy_routing() {
  local fwmark
  fwmark="$(wg show "$WG_INTERFACE" fwmark || true)"

  if [[ -z "$fwmark" || "$fwmark" == "off" ]]; then
    log_error "WireGuard fwmark is not configured. Refusing to continue."
    exit 1
  fi

  if ! ip rule show | grep -Eq 'fwmark .* lookup'; then
    log_error "wg-quick policy routing rule with fwmark was not detected."
    exit 1
  fi

  if ! wg show "$WG_INTERFACE" allowed-ips | grep -q '0.0.0.0/0'; then
    log_error "AllowedIPs does not include 0.0.0.0/0; private egress requirement is not met."
    exit 1
  fi
}

if [[ $EUID -ne 0 ]]; then
  log_error "This module must run as root."
  exit 1
fi

CONFIG_FILE="${1:-}"
if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
  log_error "Usage: $0 /absolute/path/to/config.env"
  exit 1
fi

set -a
# shellcheck source=/dev/null
source "$CONFIG_FILE"
set +a

WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0}"
WG_PERSISTENT_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE:-25}"
WG_FWMARK="${WG_FWMARK:-51820}"

require_var WG_INTERFACE
require_var WG_VPS_IP
require_var WG_HOME_ENDPOINT
require_var WG_HOME_PUBKEY
require_var WG_VPS_PRIVKEY
require_var WG_ALLOWED_IPS
require_var WG_PERSISTENT_KEEPALIVE
require_var WG_FWMARK

log_info "Installing WireGuard packages."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

configure_sysctl
write_wireguard_config

log_info "Starting and enabling wg-quick@${WG_INTERFACE}."
systemctl enable "wg-quick@${WG_INTERFACE}"
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
  systemctl restart "wg-quick@${WG_INTERFACE}"
else
  systemctl start "wg-quick@${WG_INTERFACE}"
fi

validate_policy_routing
log_info "WireGuard private egress configuration completed."

