# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal collection of tools and scripts. Currently contains bash scripts for VPS/server administration targeting Ubuntu.

## Repository Structure

```
scripts/
  bash/
    vps-init/
      vps-init.sh   # Interactive VPS initialization script for Ubuntu
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