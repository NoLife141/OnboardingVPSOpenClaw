# Bash Coding Standards

To ensure the scripts are robust and production-ready, apply the following rules to all generated `.sh` files:

1. **Strict Mode:** Every script must start with:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
Root Check: The master script must check if it is running as root (if [[ $EUID -ne 0 ]]) and exit with a helpful error if not.

Idempotency Check: Before appending lines to files (like sshd_config), check if the line already exists using grep.

Logging: Include a simple logging function (e.g., log_info(), log_error()) to provide clear visual feedback in the terminal.

Safe Restarts: When restarting the SSH daemon after changes, test the config first (sshd -t) to prevent locking the user out.

Secret Handling: Do not echo private keys or passwords to the terminal output during execution.
