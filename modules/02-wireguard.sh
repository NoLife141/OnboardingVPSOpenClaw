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

require_bool() {
  local name="$1"
  local value="${!name:-}"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    log_error "${name} must be true or false."
    exit 1
  fi
}

wg_conf_value() {
  local section="$1"
  local key="$2"
  local file="$3"

  awk -v section="$section" -v key="$key" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }
    BEGIN { in_section = 0 }
    {
      line = $0
      gsub(/\r/, "", line)
      sub(/[[:space:]]*[#;].*$/, "", line)
      line = trim(line)
      if (line == "") next

      if (line ~ /^\[[^]]+\]$/) {
        in_section = (tolower(line) == "[" tolower(section) "]")
        next
      }

      if (in_section && index(line, "=") > 0) {
        k = trim(substr(line, 1, index(line, "=") - 1))
        v = trim(substr(line, index(line, "=") + 1))
        if (tolower(k) == tolower(key)) {
          print v
          exit
        }
      }
    }
  ' "$file"
}

import_wireguard_client_config_if_set() {
  local cfg="${WG_CLIENT_CONFIG_FILE:-}"
  if [[ -z "$cfg" ]]; then
    return
  fi

  if [[ ! -f "$cfg" ]]; then
    log_error "WG_CLIENT_CONFIG_FILE not found: ${cfg}"
    exit 1
  fi

  local v
  v="$(wg_conf_value Interface Address "$cfg")"
  WG_VPS_IP="$v"

  v="$(wg_conf_value Interface PrivateKey "$cfg")"
  WG_VPS_PRIVKEY="$v"
  if [[ -n "$v" ]]; then
    WG_VPS_PRIVKEY="$v"
    WG_AUTO_GENERATE_VPS_KEY="false"
  fi

  v="$(wg_conf_value Interface DNS "$cfg")"
  WG_DNS="$v"

  v="$(wg_conf_value Peer PublicKey "$cfg")"
  WG_HOME_PUBKEY="$v"

  v="$(wg_conf_value Peer Endpoint "$cfg")"
  WG_HOME_ENDPOINT="$v"

  v="$(wg_conf_value Peer AllowedIPs "$cfg")"
  WG_ALLOWED_IPS="$v"

  v="$(wg_conf_value Peer PresharedKey "$cfg")"
  WG_HOME_PRESHARED_KEY="$v"

  v="$(wg_conf_value Peer PersistentKeepalive "$cfg")"
  if [[ -n "$v" ]]; then
    WG_PERSISTENT_KEEPALIVE="$v"
  fi

  log_info "Imported WireGuard client settings from ${cfg}."
}

validate_private_key_format() {
  local key="$1"
  if [[ ! "$key" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    log_error "WireGuard private key format appears invalid."
    exit 1
  fi
}

resolve_wireguard_private_key() {
  local key_file="${WG_VPS_PRIVKEY_FILE}"
  local key_value="${WG_VPS_PRIVKEY:-}"

  if [[ -n "$key_value" ]]; then
    validate_private_key_format "$key_value"
    WG_VPS_PRIVATE_KEY_EFFECTIVE="$key_value"
    return
  fi

  if [[ -s "$key_file" ]]; then
    WG_VPS_PRIVATE_KEY_EFFECTIVE="$(head -n 1 "$key_file" | tr -d '[:space:]')"
    if [[ -z "$WG_VPS_PRIVATE_KEY_EFFECTIVE" ]]; then
      log_error "Private key file exists but is empty: ${key_file}"
      exit 1
    fi
    validate_private_key_format "$WG_VPS_PRIVATE_KEY_EFFECTIVE"
    log_info "Using existing WireGuard private key file: ${key_file}"
    return
  fi

  if [[ "${WG_AUTO_GENERATE_VPS_KEY}" != "true" ]]; then
    log_error "WG_VPS_PRIVKEY is empty and key file is missing; auto-generation is disabled."
    exit 1
  fi

  WG_VPS_PRIVATE_KEY_EFFECTIVE="$(wg genkey)"
  validate_private_key_format "$WG_VPS_PRIVATE_KEY_EFFECTIVE"

  install -d -m 0700 "$(dirname "$key_file")"
  umask 077
  printf '%s\n' "$WG_VPS_PRIVATE_KEY_EFFECTIVE" > "$key_file"
  chmod 600 "$key_file"
  printf '%s\n' "$WG_VPS_PRIVATE_KEY_EFFECTIVE" | wg pubkey > "${key_file}.pub"
  chmod 644 "${key_file}.pub"

  log_warn "Generated a new WireGuard private key and stored it at ${key_file}."
  log_info "WireGuard public key saved at ${key_file}.pub (add it to your home server peer config)."
}

configure_apt_ipv4_fallback() {
  local apt_cfg="/etc/apt/apt.conf.d/99-openclaw-force-ipv4"

  # If tunnel policy is IPv4-only, apt may stall on unreachable IPv6 endpoints.
  if [[ "${WG_ALLOWED_IPS}" != *"::/0"* ]]; then
    cat > "$apt_cfg" <<'EOF'
Acquire::ForceIPv4 "true";
EOF
    chmod 0644 "$apt_cfg"
    log_info "Enabled APT IPv4 fallback at ${apt_cfg} (WG_ALLOWED_IPS is IPv4-only)."
  else
    if [[ -f "$apt_cfg" ]]; then
      rm -f "$apt_cfg"
      log_info "Removed APT IPv4 fallback because WG_ALLOWED_IPS includes IPv6."
    fi
  fi
}

write_wireguard_config() {
  local wg_conf_path="/etc/wireguard/${WG_INTERFACE}.conf"
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "[Interface]"
    echo "Address = ${WG_VPS_IP}"
    echo "PrivateKey = ${WG_VPS_PRIVATE_KEY_EFFECTIVE}"
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
WG_AUTO_GENERATE_VPS_KEY="${WG_AUTO_GENERATE_VPS_KEY:-true}"
WG_VPS_PRIVKEY_FILE="${WG_VPS_PRIVKEY_FILE:-/etc/wireguard/${WG_INTERFACE}.privatekey}"
WG_CLIENT_CONFIG_FILE="${WG_CLIENT_CONFIG_FILE:-}"
WG_VPS_PRIVATE_KEY_EFFECTIVE=""

import_wireguard_client_config_if_set

require_var WG_INTERFACE
require_var WG_VPS_IP
require_var WG_HOME_ENDPOINT
require_var WG_HOME_PUBKEY
require_var WG_ALLOWED_IPS
require_var WG_PERSISTENT_KEEPALIVE
require_var WG_FWMARK
require_var WG_AUTO_GENERATE_VPS_KEY
require_var WG_VPS_PRIVKEY_FILE
require_bool WG_AUTO_GENERATE_VPS_KEY

log_info "Installing WireGuard packages."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

configure_sysctl
resolve_wireguard_private_key
write_wireguard_config

log_info "Starting and enabling wg-quick@${WG_INTERFACE}."
systemctl enable "wg-quick@${WG_INTERFACE}"
if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
  systemctl restart "wg-quick@${WG_INTERFACE}"
else
  systemctl start "wg-quick@${WG_INTERFACE}"
fi

validate_policy_routing
configure_apt_ipv4_fallback
log_info "WireGuard private egress configuration completed."
