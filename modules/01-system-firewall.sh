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

package_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

install_packages_if_missing() {
  local missing=()
  local pkg

  for pkg in "$@"; do
    if ! package_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    log_info "Required packages already installed: $*"
    return
  fi

  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

detect_public_interface() {
  ip -o route show default | awk '{print $5; exit}'
}

detect_current_ssh_port() {
  local current_port=""
  if [[ -n "${SSH_CURRENT_PORT_OVERRIDE:-}" ]]; then
    current_port="${SSH_CURRENT_PORT_OVERRIDE}"
  fi

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current_port="$(awk '{print $4}' <<<"${SSH_CONNECTION}")"
  fi

  if [[ -z "$current_port" ]] && command -v sshd >/dev/null 2>&1; then
    current_port="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
  fi

  if [[ "$current_port" =~ ^[0-9]+$ ]]; then
    printf '%s' "$current_port"
  fi
}

ensure_pam_google_authenticator() {
  local pam_file="/etc/pam.d/sshd"
  local pam_line="auth required pam_google_authenticator.so nullok"

  if [[ "$ENABLE_SSH_MFA" == "true" ]]; then
    if ! grep -Eq '^\s*auth\s+required\s+pam_google_authenticator\.so(\s+nullok)?\s*$' "$pam_file"; then
      printf '\n# OpenClaw managed MFA\n%s\n' "$pam_line" >> "$pam_file"
      log_info "Added PAM MFA rule to ${pam_file}"
    fi
  else
    if grep -Eq 'pam_google_authenticator\.so' "$pam_file"; then
      sed -i '/pam_google_authenticator\.so/d' "$pam_file"
      log_info "Removed PAM MFA rule from ${pam_file}"
    fi
  fi
}

write_sshd_hardening_config() {
  local target="/etc/ssh/sshd_config.d/99-openclaw-hardening.conf"
  local tmp_file
  tmp_file="$(mktemp)"

  {
    echo "# Managed by OnboardingVPSOpenClaw"
    echo "PasswordAuthentication no"
    echo "PubkeyAuthentication yes"
    if [[ "$ENABLE_SSH_MFA" == "true" ]]; then
      echo "KbdInteractiveAuthentication yes"
      echo "ChallengeResponseAuthentication yes"
      echo "AuthenticationMethods publickey,keyboard-interactive"
    else
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    fi

    echo "Port ${SSH_PORT}"
    if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "true" ]] \
      && [[ -n "${CURRENT_SSH_PORT:-}" ]] \
      && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
      echo "Port ${CURRENT_SSH_PORT}"
    fi
  } > "$tmp_file"

  install -m 0644 "$tmp_file" "$target"
  rm -f "$tmp_file"
}

reload_ssh_safely() {
  local sshd_bin
  local restart_required="false"
  sshd_bin="$(command -v sshd || true)"
  if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then
    sshd_bin="/usr/sbin/sshd"
  fi

  if [[ -z "$sshd_bin" ]]; then
    log_error "Unable to locate sshd binary."
    exit 1
  fi

  if ! "$sshd_bin" -t; then
    log_error "sshd -t failed. Refusing to reload SSH."
    exit 1
  fi

  # Ubuntu/Debian may enable ssh.socket (socket activation) on port 22.
  # In that case, sshd Port directives are ignored until the socket is disabled.
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^ssh\.socket'; then
      if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
        log_warn "Detected active ssh.socket. Disabling socket activation so SSH can bind configured ports."
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl stop ssh.socket >/dev/null 2>&1 || true
        systemctl mask ssh.socket >/dev/null 2>&1 || true
        restart_required="true"
      fi
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if [[ "$restart_required" == "true" ]]; then
      if systemctl restart ssh >/dev/null 2>&1; then
        :
      elif systemctl restart ssh.service >/dev/null 2>&1; then
        :
      elif systemctl restart sshd >/dev/null 2>&1; then
        :
      elif systemctl restart sshd.service >/dev/null 2>&1; then
        :
      else
        log_error "Unable to restart SSH after disabling ssh.socket."
        exit 1
      fi
    elif systemctl reload ssh >/dev/null 2>&1; then
      :
    elif systemctl reload ssh.service >/dev/null 2>&1; then
      :
    elif systemctl reload sshd >/dev/null 2>&1; then
      :
    elif systemctl reload sshd.service >/dev/null 2>&1; then
      :
    else
      log_error "Unable to reload SSH via systemctl (tried ssh/sshd service names)."
      exit 1
    fi
  elif command -v service >/dev/null 2>&1; then
    if service ssh reload >/dev/null 2>&1; then
      :
    elif service sshd reload >/dev/null 2>&1; then
      :
    else
      log_error "Unable to reload SSH via service command (tried ssh/sshd)."
      exit 1
    fi
  else
    log_error "No supported service manager found to reload SSH."
    exit 1
  fi

  local found="false"
  local _i
  for _i in $(seq 1 20); do
    if ss -lntH "( sport = :${SSH_PORT} )" | grep -q '.'; then
      found="true"
      break
    fi
    sleep 0.25
  done

  if [[ "$found" != "true" ]]; then
    log_error "SSH daemon is not listening on new port ${SSH_PORT} after reload."
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

require_var SSH_PORT
require_var OPENCLAW_PORT
require_var ENABLE_SSH_MFA
require_port SSH_PORT
require_port OPENCLAW_PORT
if [[ -n "${SSH_CURRENT_PORT_OVERRIDE:-}" ]]; then
  require_port SSH_CURRENT_PORT_OVERRIDE
fi
if [[ "${SSH_KEEP_CURRENT_PORT:-true}" != "true" && "${SSH_KEEP_CURRENT_PORT:-true}" != "false" ]]; then
  log_error "SSH_KEEP_CURRENT_PORT must be true or false."
  exit 1
fi
if [[ "${ENABLE_SSH_MFA}" != "true" && "${ENABLE_SSH_MFA}" != "false" ]]; then
  log_error "ENABLE_SSH_MFA must be true or false."
  exit 1
fi

WG_INTERFACE="${WG_INTERFACE:-wg0}"
PUBLIC_INTERFACE="$(detect_public_interface)"
if [[ -z "$PUBLIC_INTERFACE" ]]; then
  log_error "Unable to detect public network interface."
  exit 1
fi

CURRENT_SSH_PORT="$(detect_current_ssh_port || true)"
if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "true" ]] && [[ -z "$CURRENT_SSH_PORT" ]]; then
  log_warn "Current SSH port could not be detected automatically."
  log_warn "Set SSH_CURRENT_PORT_OVERRIDE in config.env for maximum migration safety."
fi

log_info "Installing required packages for firewall and SSH hardening."
install_packages_if_missing ufw openssh-server

if [[ "$ENABLE_SSH_MFA" == "true" ]]; then
  install_packages_if_missing libpam-google-authenticator
fi

ensure_pam_google_authenticator
write_sshd_hardening_config
reload_ssh_safely

log_info "Allowing SSH on ${PUBLIC_INTERFACE}:${SSH_PORT}"
ufw allow in on "$PUBLIC_INTERFACE" proto tcp to any port "$SSH_PORT" comment 'OpenClaw SSH'

if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "true" ]] \
  && [[ -n "$CURRENT_SSH_PORT" ]] \
  && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
  log_warn "Keeping current SSH port ${CURRENT_SSH_PORT} open to avoid lockout."
  ufw allow in on "$PUBLIC_INTERFACE" proto tcp to any port "$CURRENT_SSH_PORT" comment 'OpenClaw SSH legacy'
fi

log_info "Allowing OpenClaw only on ${WG_INTERFACE}:${OPENCLAW_PORT}"
ufw allow in on "$WG_INTERFACE" proto tcp to any port "$OPENCLAW_PORT" comment 'OpenClaw over WireGuard'

log_info "Blocking OpenClaw port on public interface ${PUBLIC_INTERFACE}"
ufw deny in on "$PUBLIC_INTERFACE" proto tcp to any port "$OPENCLAW_PORT" comment 'Block OpenClaw public'

log_info "Configuring UFW defaults."
ufw --force default deny incoming
ufw --force default allow outgoing

ufw --force enable

if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "false" ]] \
  && [[ -n "$CURRENT_SSH_PORT" ]] \
  && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
  log_info "Attempting to remove legacy SSH allow rule for port ${CURRENT_SSH_PORT}"
  ufw --force delete allow in on "$PUBLIC_INTERFACE" proto tcp to any port "$CURRENT_SSH_PORT" || true
fi

log_info "Firewall and SSH hardening completed safely."
