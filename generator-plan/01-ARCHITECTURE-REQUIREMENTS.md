# Architecture & Network Requirements

The generated scripts must configure the VPS to achieve the following state:

## 1. Network & WireGuard (The "Private Egress" Model)
- The VPS acts as a WireGuard client connecting to a remote home server.
- The VPS must route ALL outbound internet traffic through the WireGuard tunnel (`AllowedIPs = 0.0.0.0/0`).
- **Critical Requirement:** The script must ensure `wg-quick` policy routing (`fwmark`) is properly configured so that inbound SSH connections on the VPS's public IP return via the public interface, preventing asymmetric routing lockouts.

## 2. Firewall Posture (UFW)
- Default incoming: DENY
- Default outgoing: ALLOW
- Allow inbound TCP on the SSH port defined in the config file (on the public interface).
- Allow inbound TCP on the OpenClaw port defined in the config file, BUT strictly limited to the `wg0` interface.

## 3. SSH Hardening
- Disable `PasswordAuthentication`.
- Ensure `PubkeyAuthentication` is enabled.
- Add an optional flag in the config to install and configure Google Authenticator PAM for MFA (`AuthenticationMethods publickey,keyboard-interactive`).

## 4. OpenClaw Host Preparation
- Do not install or run OpenClaw in these scripts.
- Prepare the VPS for a future manual host install (system packages, optional Node.js 22+, optional pnpm, dedicated directory/user).
- Keep network exposure aligned with UFW/WireGuard constraints so the later OpenClaw process can bind to the WireGuard IP (e.g., `10.x.x.x:3000`).
