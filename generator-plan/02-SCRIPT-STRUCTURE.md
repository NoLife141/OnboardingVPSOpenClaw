# Required File Structure

Generate the following files exactly.

`config.env.example`
A template file containing all necessary variables. Examples:
- SSH_PORT=2222
- WG_VPS_IP=10.50.0.2/24
- WG_HOME_ENDPOINT=home.example.com:51820
- WG_HOME_PUBKEY=...
- WG_VPS_PRIVKEY=...
- OPENCLAW_PORT=3000
- ENABLE_SSH_MFA=false

`install.sh`
The master orchestrator script. It checks if `config.env` exists, sources it, and calls the modules in sequence.

`modules/01-system-firewall.sh`
Updates packages, installs UFW, configures the firewall rules, and hardens SSH (including optional MFA setup).

`modules/02-wireguard.sh`
Installs WireGuard, writes `/etc/wireguard/wg0.conf` using the config variables, enables IP forwarding if necessary, and starts `wg-quick@wg0`.

`modules/03-openclaw-docker.sh`
Installs Docker (if missing), creates a directory for OpenClaw, generates the `docker-compose.yml` binding to the WG IP, and starts the container.

`README.md`
Instructions for the human operator on how to copy the repository to the VPS, fill out `config.env`, and run `./install.sh`.
