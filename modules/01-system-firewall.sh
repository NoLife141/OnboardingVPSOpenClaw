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

collect_managed_ssh_keys() {
  local var_name
  local key_names=()

  while IFS= read -r var_name; do
    key_names+=("$var_name")
  done < <(compgen -A variable | grep -E '^SSH_AUTHORIZED_KEY_[0-9]+$' | sort -V || true)

  if (( ${#key_names[@]} == 0 )); then
    return 1
  fi

  local found=0
  for var_name in "${key_names[@]}"; do
    if [[ -n "${!var_name:-}" ]]; then
      found=1
      printf '%s\n' "${!var_name}"
    fi
  done

  (( found == 1 ))
}

ensure_login_user_exists() {
  if ! getent passwd "$SSH_LOGIN_USER" >/dev/null; then
    log_error "SSH_LOGIN_USER does not exist: ${SSH_LOGIN_USER}"
    exit 1
  fi

  SSH_LOGIN_HOME="$(getent passwd "$SSH_LOGIN_USER" | cut -d: -f6)"
  if [[ -z "$SSH_LOGIN_HOME" || ! -d "$SSH_LOGIN_HOME" ]]; then
    log_error "Home directory for ${SSH_LOGIN_USER} is missing: ${SSH_LOGIN_HOME:-<empty>}"
    exit 1
  fi
}

ensure_authorized_keys_managed() {
  local ssh_dir="${SSH_LOGIN_HOME}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"
  local tmp_keys
  local tmp_auth
  local begin_marker="# BEGIN OnboardingVPSOpenClaw managed keys"
  local end_marker="# END OnboardingVPSOpenClaw managed keys"

  tmp_keys="$(mktemp)"
  if ! collect_managed_ssh_keys > "$tmp_keys"; then
    rm -f "$tmp_keys"
    log_error "No SSH_AUTHORIZED_KEY_* entries defined. Refusing to disable password auth without managed keys."
    exit 1
  fi

  install -d -m 0700 -o "$SSH_LOGIN_USER" -g "$SSH_LOGIN_USER" "$ssh_dir"
  if [[ ! -f "$auth_keys" ]]; then
    install -m 0600 -o "$SSH_LOGIN_USER" -g "$SSH_LOGIN_USER" /dev/null "$auth_keys"
  fi

  tmp_auth="$(mktemp)"
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$auth_keys" > "$tmp_auth"

  {
    cat "$tmp_auth"
    if [[ -s "$tmp_auth" ]] && [[ "$(tail -c1 "$tmp_auth" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '%s\n' "$begin_marker"
    cat "$tmp_keys"
    printf '%s\n' "$end_marker"
  } > "${tmp_auth}.new"

  install -m 0600 -o "$SSH_LOGIN_USER" -g "$SSH_LOGIN_USER" "${tmp_auth}.new" "$auth_keys"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_keys"

  if ! awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0 }
    in_block && NF { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$auth_keys"; then
    rm -f "$tmp_keys" "$tmp_auth" "${tmp_auth}.new"
    log_error "Managed authorized_keys block is empty after update."
    exit 1
  fi

  rm -f "$tmp_keys" "$tmp_auth" "${tmp_auth}.new"
  log_info "Managed authorized_keys for ${SSH_LOGIN_USER}"
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

discover_sshd_binary() {
  if command -v sshd >/dev/null 2>&1; then
    SSHD_BIN="$(command -v sshd)"
  elif [[ -x /usr/sbin/sshd ]]; then
    SSHD_BIN="/usr/sbin/sshd"
  else
    SSHD_BIN=""
  fi
}

discover_ssh_service_unit() {
  SSH_SERVICE_UNIT=""

  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE_UNIT="ssh.service"
  elif systemctl cat sshd.service >/dev/null 2>&1; then
    SSH_SERVICE_UNIT="sshd.service"
  fi
}

preflight_existing_ssh_stack() {
  discover_sshd_binary
  discover_ssh_service_unit

  SSH_STACK_READY="false"
  if [[ -n "${SSHD_BIN:-}" && -n "${SSH_SERVICE_UNIT:-}" ]]; then
    SSH_STACK_READY="true"
    if ss -lntp | grep -q sshd; then
      log_info "Detected existing SSH listener and service (${SSH_SERVICE_UNIT})."
    else
      log_info "Detected existing SSH service (${SSH_SERVICE_UNIT}) with no current listener check hit."
    fi
  fi
}

ensure_ssh_stack_ready() {
  preflight_existing_ssh_stack
  if [[ "${SSH_STACK_READY}" == "true" ]]; then
    return
  fi

  log_warn "No usable SSH stack detected. Installing openssh-server."
  install_packages_if_missing openssh-server
  preflight_existing_ssh_stack

  if [[ "${SSH_STACK_READY}" != "true" ]]; then
    log_error "Unable to detect a usable SSH daemon/service after installing openssh-server."
    exit 1
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

ensure_sshd_config_includes_dropins() {
  local target="/etc/ssh/sshd_config"
  local include_line="Include /etc/ssh/sshd_config.d/*.conf"

  if grep -Fqx "$include_line" "$target"; then
    return
  fi

  printf '\n%s\n' "$include_line" >> "$target"
}

write_sshd_port_block() {
  local target="/etc/ssh/sshd_config"
  local tmp_file
  local begin_marker="# BEGIN OnboardingVPSOpenClaw managed ports"
  local end_marker="# END OnboardingVPSOpenClaw managed ports"

  tmp_file="$(mktemp)"

  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$target" > "$tmp_file"

  {
    cat "$tmp_file"
    if [[ -s "$tmp_file" ]] && [[ "$(tail -c1 "$tmp_file" 2>/dev/null || true)" != $'\n' ]]; then
      printf '\n'
    fi
    printf '%s\n' "$begin_marker"
    printf 'Port %s\n' "$SSH_PORT"
    if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "true" ]] \
      && [[ -n "${CURRENT_SSH_PORT:-}" ]] \
      && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
      printf 'Port %s\n' "$CURRENT_SSH_PORT"
    fi
    printf '%s\n' "$end_marker"
  } > "${tmp_file}.new"

  install -m 0644 "${tmp_file}.new" "$target"
  rm -f "$tmp_file" "${tmp_file}.new"
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
  } > "$tmp_file"

  install -m 0644 "$tmp_file" "$target"
  rm -f "$tmp_file"
}

validate_effective_sshd_port_config() {
  local effective_ports

  effective_ports="$("$SSHD_BIN" -T 2>/dev/null | awk '/^port / {print $2}')"
  if ! grep -qx "$SSH_PORT" <<<"$effective_ports"; then
    log_error "Effective sshd config does not include target SSH port ${SSH_PORT}."
    exit 1
  fi
}

write_ssh_boot_guard_unit() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  cat > /etc/systemd/system/openclaw-ssh-boot-guard.service <<'EOF'
[Unit]
Description=Ensure SSH daemon is started after boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl start ssh.service >/dev/null 2>&1 || systemctl start sshd.service >/dev/null 2>&1'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 /etc/systemd/system/openclaw-ssh-boot-guard.service
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ! systemctl enable openclaw-ssh-boot-guard.service >/dev/null 2>&1; then
    log_error "Unable to enable openclaw-ssh-boot-guard.service."
    exit 1
  fi
}

ensure_ssh_service_enabled() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl unmask ssh.service >/dev/null 2>&1 || true
  systemctl unmask sshd.service >/dev/null 2>&1 || true

  if [[ -z "$SSH_SERVICE_UNIT" ]]; then
    log_error "Unable to detect a usable SSH service unit (ssh.service or sshd.service)."
    exit 1
  fi

  if ! systemctl enable "$SSH_SERVICE_UNIT" >/dev/null 2>&1; then
    log_warn "Could not enable ${SSH_SERVICE_UNIT} directly; relying on boot-guard unit for reboot safety."
  fi
}

validate_ssh_boot_guard_enabled() {
  local state=""

  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  state="$(systemctl is-enabled openclaw-ssh-boot-guard.service 2>/dev/null || true)"
  case "$state" in
    enabled|enabled-runtime|static|alias|indirect|generated|linked|linked-runtime)
      return
      ;;
  esac

  log_error "openclaw-ssh-boot-guard.service is not enabled for boot."
  exit 1
}

validate_ssh_service_enabled() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return
  fi

  if [[ -n "${SSH_SERVICE_UNIT:-}" ]]; then
    if ! systemctl is-active --quiet "${SSH_SERVICE_UNIT}"; then
      log_error "${SSH_SERVICE_UNIT} is not active."
      exit 1
    fi
  fi

  validate_ssh_boot_guard_enabled
}

reload_ssh_safely() {
  local restart_required="false"
  local found="false"
  local _i

  if [[ -z "${SSHD_BIN:-}" ]]; then
    log_error "Unable to locate sshd binary."
    exit 1
  fi

  if ! "$SSHD_BIN" -t; then
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
        systemctl daemon-reload >/dev/null 2>&1 || true
        restart_required="true"
      fi
    fi
  fi

  ensure_ssh_service_enabled
  write_ssh_boot_guard_unit

  if command -v systemctl >/dev/null 2>&1; then
    if [[ "$restart_required" == "true" ]]; then
      if [[ -n "${SSH_SERVICE_UNIT:-}" ]] && systemctl restart "${SSH_SERVICE_UNIT}" >/dev/null 2>&1; then
        :
      elif [[ -n "${SSH_SERVICE_UNIT:-}" ]] && systemctl start "${SSH_SERVICE_UNIT}" >/dev/null 2>&1; then
        :
      else
        log_error "Unable to restart SSH after disabling ssh.socket."
        exit 1
      fi
    elif [[ -n "${SSH_SERVICE_UNIT:-}" ]] && systemctl reload "${SSH_SERVICE_UNIT}" >/dev/null 2>&1; then
      :
    elif [[ -n "${SSH_SERVICE_UNIT:-}" ]] && systemctl restart "${SSH_SERVICE_UNIT}" >/dev/null 2>&1; then
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

  for _i in $(seq 1 20); do
    if ss -lntH "( sport = :${SSH_PORT} )" | grep -q '.'; then
      found="true"
      break
    fi
    sleep 0.25
  done

  if [[ "$found" != "true" ]] && command -v systemctl >/dev/null 2>&1 && [[ -n "${SSH_SERVICE_UNIT:-}" ]]; then
    log_warn "SSH reload did not open port ${SSH_PORT}. Trying a full service restart."
    if ! systemctl restart "${SSH_SERVICE_UNIT}" >/dev/null 2>&1; then
      log_error "Unable to restart SSH service ${SSH_SERVICE_UNIT} after reload failed to apply new port."
      exit 1
    fi

    for _i in $(seq 1 20); do
      if ss -lntH "( sport = :${SSH_PORT} )" | grep -q '.'; then
        found="true"
        break
      fi
      sleep 0.25
    done
  fi

  if [[ "$found" != "true" ]]; then
    log_error "SSH daemon is not listening on new port ${SSH_PORT} after reload."
    exit 1
  fi

  validate_ssh_service_enabled
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
require_var SSH_LOGIN_USER
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
ensure_ssh_stack_ready
install_packages_if_missing ufw

if [[ "$ENABLE_SSH_MFA" == "true" ]]; then
  install_packages_if_missing libpam-google-authenticator
fi

ensure_login_user_exists
ensure_authorized_keys_managed
ensure_pam_google_authenticator
ensure_sshd_config_includes_dropins
write_sshd_port_block
write_sshd_hardening_config
validate_effective_sshd_port_config
reload_ssh_safely

log_info "Allowing SSH on ${PUBLIC_INTERFACE}:${SSH_PORT}"
ufw allow in on "$PUBLIC_INTERFACE" proto tcp to any port "$SSH_PORT" comment 'OpenClaw SSH'
log_info "Allowing SSH on ${WG_INTERFACE}:${SSH_PORT}"
ufw allow in on "$WG_INTERFACE" proto tcp to any port "$SSH_PORT" comment 'OpenClaw SSH WireGuard'

if [[ "${SSH_KEEP_CURRENT_PORT:-true}" == "true" ]] \
  && [[ -n "$CURRENT_SSH_PORT" ]] \
  && [[ "$CURRENT_SSH_PORT" != "$SSH_PORT" ]]; then
  log_warn "Keeping current SSH port ${CURRENT_SSH_PORT} open to avoid lockout."
  ufw allow in on "$PUBLIC_INTERFACE" proto tcp to any port "$CURRENT_SSH_PORT" comment 'OpenClaw SSH legacy'
  ufw allow in on "$WG_INTERFACE" proto tcp to any port "$CURRENT_SSH_PORT" comment 'OpenClaw SSH legacy WireGuard'
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
