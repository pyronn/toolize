# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal collection of tools and scripts. Currently contains bash scripts for VPS/server administration targeting Ubuntu.

## Repository Structure

```
docs/
  vps-init.md                # vps-init.sh 详细使用文档
  add-socks5-static-ip.md    # add-socks5-static-ip.sh 详细使用文档
scripts/
  bash/
    vps-init/
      vps-init.sh            # Interactive VPS initialization script for Ubuntu
    proxy/
      add-socks5-static-ip.sh # sing-box SOCKS5 链式代理配置生成脚本
```

## Running Scripts

Scripts are designed to run on a remote Ubuntu VPS, not the local Windows machine.

```bash
# On the target Ubuntu VPS (requires root):
sudo bash scripts/bash/vps-init/vps-init.sh
```

There are no build steps, linters, or test suites configured.

## vps-init.sh Architecture

Interactive menu-driven script with three main options:

1. **SSH Security Init** (`ssh_security_init`) — creates a sudo user, resets root password, changes SSH port, disables root login, writes `AllowUsers`
2. **Disable Password Auth** (`disable_password_auth`) — verifies a public key exists then disables password/PAM auth in `sshd_config`
3. **Server Security Hardening** (`server_security_hardening`) — sub-menu selecting any combination of: system update, UFW firewall, fail2ban, unattended-upgrades, sysctl network hardening, timezone/NTP, disable unused services

**Key patterns used throughout:**
- `ensure_sshd` — called at the start of every option to guarantee `openssh-server` is installed and active before touching SSH config
- `backup_file` — timestamps and copies any config before modification (`file.bak.YYYYMMDDHHMMSS`)
- `set_sshd_option` — deletes all existing lines (including commented ones) for a given `sshd_config` key, then appends the new value; defined locally inside each function that uses it
- Every `sshd_config` change is validated with `sshd -t` before `systemctl restart sshd`; on failure the backup is restored

## Conventions

- All scripts use `set -euo pipefail`
- Use the shared color/helper functions (`info`, `warn`, `error`, `section`, `confirm`) defined at the top of each script
- New scripts under `scripts/bash/<category>/` follow the same interactive pattern with pre-flight root and OS checks

## Documentation Requirement

Every script must have a corresponding documentation file in the `docs/` directory. Documentation file name should match the script name (e.g. `vps-init.sh` → `docs/vps-init.md`).

**When adding a new script:**
- Create a documentation file in `docs/<script-name>.md`
- Include: basic info (path, environment, dependencies), usage examples, detailed parameter/option descriptions, execution flow, and any rollback/uninstall instructions
- Update the Repository Structure section above

**When modifying an existing script:**
- Update the corresponding documentation to reflect the changes
- If new options, parameters, or behavior are added, document them

## Security — Never Commit Sensitive Information

**Strictly prohibited from being committed to this repository:**

- Passwords, passphrases, or any credentials
- SSH private keys (`id_rsa`, `id_ed25519`, `*.pem`, `*.key`)
- API keys, tokens, or secrets (cloud providers, services, etc.)
- IP addresses, hostnames, or server identifiers specific to personal infrastructure
- Proxy credentials (usernames, passwords, server addresses)
- Any configuration files containing the above (e.g. generated `socks-chain.json` with real credentials)

**Scripts must obtain all sensitive values at runtime** (via `read`, environment variables, or command-line arguments) — never hardcode them.

Before committing, verify with `git diff --staged` that no secrets are included.