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
- `SSH_LOGIN_USER`: single non-root SSH admin account; root SSH is disabled
- `SSH_CREATE_LOGIN_USER`: create `SSH_LOGIN_USER` if missing
- `SSH_LOGIN_USER_SUDO`: add `SSH_LOGIN_USER` to sudo group
- `SSH_LOGIN_USER_SHELL`: login shell used when creating `SSH_LOGIN_USER`
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

If another package job is running (for example unattended upgrades), the modules wait for APT locks and retry instead of failing immediately.

## SSH Key Management

Module 1 manages a dedicated block in `${HOME}/.ssh/authorized_keys` for `SSH_LOGIN_USER`.

- `SSH_LOGIN_USER` is the only SSH login account allowed by the managed SSH policy.
- Root SSH is explicitly disabled (`PermitRootLogin no`).
- If `SSH_CREATE_LOGIN_USER=true`, module 1 creates the SSH admin user before installing keys.
- If `SSH_LOGIN_USER_SUDO=true`, module 1 adds that user to the `sudo` group.
- Keys come from `SSH_AUTHORIZED_KEY_1`, `SSH_AUTHORIZED_KEY_2`, and so on.
- At least one non-empty `SSH_AUTHORIZED_KEY_*` entry is required before password auth is disabled.
- Existing unmanaged keys outside the managed block are preserved.
- Managed block markers are:
  - `# BEGIN OnboardingVPSOpenClaw managed keys`
  - `# END OnboardingVPSOpenClaw managed keys`

Before any SSH mutation, module 1 preflights the existing SSH stack:

- it reuses the SSH server already present on the VPS when a usable `sshd` binary and service unit are detected
- it installs `openssh-server` only if no usable SSH stack is found
- it refuses to change ports, MFA, keys, sockets, or firewall state until that preflight succeeds

## Cloud-Init Interplay

On Ubuntu 24.04-style cloud images, cloud-init can override SSH password settings during provisioning.

When cloud-init is present, module 1 writes:

- `/etc/cloud/cloud.cfg.d/99-openclaw-ssh-hardening.cfg`

with:

- `ssh_pwauth: false`
- `disable_root: true`

The scripts do not edit `50-cloud-init.conf`. OpenSSH hardening remains authoritative through the managed `99-*` SSH drop-in and effective-config validation.

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

1. SSH ports are managed directly in `/etc/ssh/sshd_config` with a dedicated managed block.
2. SSH auth hardening is written to `/etc/ssh/sshd_config.d/99-openclaw-hardening.conf`.
3. The script ensures `/etc/ssh/sshd_config` includes `sshd_config.d/*.conf`.
4. Root SSH is disabled and `AllowUsers` is restricted to `SSH_LOGIN_USER`.
5. `sshd -t` is executed before reload.
6. `sshd -T` is checked to confirm the target SSH port and effective auth policy are correct.
7. When present, cloud-init is told not to re-enable SSH password auth or root login.
8. `ssh.socket` is disabled and masked if present, and `ssh.service` is explicitly enabled for boot.
9. SSH daemon is reloaded or restarted safely depending on socket activation state.
10. A systemd boot-guard unit is installed to start SSH after boot if the image has unusual SSH unit wiring.
11. Script verifies SSH is listening on `SSH_PORT`.
12. If `SSH_KEEP_CURRENT_PORT=true`, script also keeps current SSH port open in SSH and UFW.
13. SSH is allowed on both the public interface and `wg0`.

Recommended migration procedure:

1. Run installer with `SSH_KEEP_CURRENT_PORT=true`.
2. Open a second terminal and verify login works on new `SSH_PORT`.
3. Set `SSH_KEEP_CURRENT_PORT=false` in `config.env`.
4. Run installer again to remove legacy SSH port rule.

Admin workflow after hardening:

```bash
ssh -p <SSH_PORT> <SSH_LOGIN_USER>@your-vps
sudo -i
```

Important:

- The script does not set or print a password for `SSH_LOGIN_USER`.
- SSH access is expected to work with your managed SSH key(s), not a password.
- If `SSH_LOGIN_USER_SUDO=true`, set a password manually after first login if your sudo policy requires one:

```bash
sudo passwd <SSH_LOGIN_USER>
```

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
sudo cloud-init status || true
sudo sshd -T | egrep 'passwordauthentication|permitrootlogin|allowusers|authenticationmethods|kbdinteractiveauthentication'
sudo systemctl status ssh --no-pager
sudo systemctl status ssh.socket --no-pager
sudo ss -lntp | grep sshd
ip -4 rule show
```

Expected state:

- `ssh.service` enabled and active
- `ssh.socket` masked or inactive
- `passwordauthentication no`
- `permitrootlogin no`
- `allowusers` set to your `SSH_LOGIN_USER`
- `sshd` listening on your configured SSH port
- public SSH return-path rule present when full-tunnel WireGuard is enabled
