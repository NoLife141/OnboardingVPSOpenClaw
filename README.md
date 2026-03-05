# OpenClaw Private VPS Bootstrap (Host-Install Ready)

This repository provides idempotent Bash scripts to prepare a fresh Ubuntu VPS for a private OpenClaw host install.

The scripts configure:

- WireGuard client egress (`AllowedIPs=0.0.0.0/0`)
- UFW default deny inbound posture
- SSH hardening with lockout-safe migration flow (optional MFA)
- Host prerequisites for OpenClaw (without installing OpenClaw itself)

## Important Scope

- These scripts **do not install OpenClaw**.
- These scripts **do not deploy Docker for OpenClaw**.
- After VPS prep, install OpenClaw yourself following the official docs:
  - [Getting Started](https://docs.openclaw.ai/start/getting-started)
  - [Setup](https://docs.openclaw.ai/start/setup)

## File Layout

- `config.env.example`: template for all variables
- `install.sh`: master orchestrator
- `modules/01-system-firewall.sh`: SSH hardening + UFW
- `modules/02-wireguard.sh`: WireGuard setup + policy routing validation
- `modules/03-openclaw-host-prep.sh`: host preparation for manual OpenClaw install

## 1. Clone repository on VPS

Connect to your VPS:

```bash
ssh -p <current-ssh-port> user@your-vps
```

Clone and enter the project:

```bash
git clone https://github.com/NoLife141/OnboardingVPSOpenClaw.git
cd OnboardingVPSOpenClaw
```

## 2. Create config.env

```bash
cp config.env.example config.env
```

Edit `config.env` and fill values:

- `SSH_PORT`: target SSH port
- `SSH_LOGIN_USER`: Linux user whose `authorized_keys` will be managed
- `SSH_KEEP_CURRENT_PORT`: keep currently used SSH port open for safe migration (`true` recommended on first run)
- `SSH_CURRENT_PORT_OVERRIDE`: optional manual current SSH port fallback for migration safety
- `SSH_AUTHORIZED_KEY_1`, `SSH_AUTHORIZED_KEY_2`, ...: inline public keys to install for `SSH_LOGIN_USER`
- `ENABLE_SSH_MFA`: `true` or `false`
- `WG_VPS_IP`: VPS WireGuard address in CIDR
- `WG_HOME_ENDPOINT`: home server endpoint (`host:port`)
- `WG_HOME_PUBKEY`: home server public key
- `WG_CLIENT_CONFIG_FILE`: optional path to UniFi-exported WireGuard client config
- `WG_VPS_PRIVKEY`: optional VPS private key (leave empty to auto-generate)
- `WG_AUTO_GENERATE_VPS_KEY`: when `true`, generate key if missing
- `WG_VPS_PRIVKEY_FILE`: secure path used to persist auto-generated key
- `WG_PRESERVE_PUBLIC_SSH_ROUTE`: keep SSH public-IP return path out of tunnel
- `WG_PUBLIC_SSH_SOURCE_IP`: optional source IP override for SSH return-path rule
- `OPENCLAW_PORT`: future host port for OpenClaw gateway
- `OPENCLAW_SETUP_DIR`: directory prepared for later OpenClaw install
- `OPENCLAW_SETUP_USER`: owner for prepared directory
- `INSTALL_NODEJS`: install Node runtime for OpenClaw prerequisites
- `NODEJS_MAJOR_VERSION`: minimum Node major version (default `25`)
- `INSTALL_PNPM`: optional pnpm install

## 3. Run installer

```bash
sudo ./install.sh
```

Installer execution order is:
1. `01-system-firewall.sh`
2. `03-openclaw-host-prep.sh`
3. `02-wireguard.sh`

This order ensures host package setup happens before full-tunnel WireGuard routing is enabled.

## SSH Key Management

Module 1 manages a dedicated block in `${HOME}/.ssh/authorized_keys` for `SSH_LOGIN_USER`.

- Keys come from `SSH_AUTHORIZED_KEY_1`, `SSH_AUTHORIZED_KEY_2`, and so on.
- At least one non-empty `SSH_AUTHORIZED_KEY_*` entry is required before password auth is disabled.
- Existing unmanaged keys outside the managed block are preserved.
- Managed block markers are:
  - `# BEGIN OnboardingVPSOpenClaw managed keys`
  - `# END OnboardingVPSOpenClaw managed keys`

## WireGuard Key Handling

You can optionally set:

- `WG_CLIENT_CONFIG_FILE=/absolute/path/to/client.conf`

When set, module 2 imports values from the client config (`Address`, `PrivateKey`, `DNS`, `PublicKey`, `Endpoint`, `AllowedIPs`, optional `PresharedKey` and `PersistentKeepalive`) and uses them as source of truth.

If `WG_VPS_PRIVKEY` is empty, module 2 will:

1. Reuse `WG_VPS_PRIVKEY_FILE` if it already exists.
2. Otherwise generate a new private key (when `WG_AUTO_GENERATE_VPS_KEY=true`).
3. Save the matching public key to `${WG_VPS_PRIVKEY_FILE}.pub`.

Private keys are never printed in logs.

## Post-WireGuard APT Behavior

If `WG_ALLOWED_IPS` is IPv4-only (for example `0.0.0.0/0`), module 2 writes:

- `/etc/apt/apt.conf.d/99-openclaw-force-ipv4`

This avoids `apt` stalls on unreachable IPv6 endpoints after the full-tunnel route is enabled.

## Public SSH Return-Path Protection

With `AllowedIPs=0.0.0.0/0`, module 2 adds a policy rule that keeps traffic sourced from your public SSH IP on the main routing table (outside `wg0`).  
This prevents asymmetric routing lockouts when WireGuard full tunnel is enabled.

## SSH Lockout Safety Model

The scripts are designed to reduce lockout risk:

1. SSH config is written to `/etc/ssh/sshd_config.d/99-openclaw-hardening.conf`.
2. `sshd -t` is executed before reload.
3. `ssh.socket` is disabled and masked if present, and `ssh.service` is explicitly enabled for boot.
4. SSH daemon is reloaded or restarted safely depending on socket activation state.
5. Script verifies SSH is listening on `SSH_PORT`.
6. If `SSH_KEEP_CURRENT_PORT=true`, script also keeps current SSH port open in SSH and UFW.
7. SSH is allowed on both the public interface and `wg0`.

Recommended migration procedure:

1. Run installer with `SSH_KEEP_CURRENT_PORT=true`.
2. Open a second terminal and verify login works on new `SSH_PORT`.
3. Set `SSH_KEEP_CURRENT_PORT=false` in `config.env`.
4. Run installer again to remove legacy SSH port rule.

## What Module 03 Does Now

`modules/03-openclaw-host-prep.sh` prepares the host only:

- installs baseline packages (`curl`, `git`, etc.)
- optionally installs Node (`NODEJS_MAJOR_VERSION`, default `25`)
- optionally installs pnpm
- creates prep directory and optional service user
- writes `${OPENCLAW_SETUP_DIR}/openclaw-host-setup.env` with bind/port hints

It does not install or run OpenClaw.

## MFA Notes

If `ENABLE_SSH_MFA=true`, the script configures PAM Google Authenticator with `nullok` for safer rollout.
Users can enroll with:

```bash
google-authenticator
```

After all required users are enrolled, you can harden further by removing `nullok` manually from `/etc/pam.d/sshd`.

## Reboot Verification

After a reboot, verify:

```bash
sudo systemctl status ssh --no-pager
sudo systemctl status ssh.socket --no-pager
sudo ss -lntp | grep sshd
ip -4 rule show
```

Expected state:

- `ssh.service` enabled and active
- `ssh.socket` masked or inactive
- `sshd` listening on your configured SSH port
- public SSH return-path rule present when full-tunnel WireGuard is enabled
