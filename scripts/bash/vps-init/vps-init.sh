#!/usr/bin/env bash
#============================================================================
# VPS Server Initialization Script for Ubuntu
# Usage: sudo bash vps_init.sh
#============================================================================

set -euo pipefail

# ==================== Color & Helpers ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  $*${NC}"; echo -e "${CYAN}${BOLD}══════════════════════════════════════════${NC}\n"; }

confirm() {
    local prompt="${1:-Continue?} [y/N]: "
    read -rp "$prompt" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ==================== Pre-flight Checks ====================
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use: sudo bash $0)"
    exit 1
fi

if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Detected a different OS."
    confirm "Continue anyway?" || exit 1
fi

# ==================== Backup Utility ====================
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
        info "Backed up: $file"
    fi
}

# ==================== Global SSH Config Helper ====================
# Removes all existing lines (including commented) for a key, then appends the new value.
# Also purges the same key from /etc/ssh/sshd_config.d/*.conf drop-in files so that
# the value set here is not overridden (Ubuntu 24.04+ uses Include with first-match wins).
set_sshd_option() {
    local key="$1"
    local value="$2"
    local file="$3"
    sed -i "/^[#[:space:]]*${key}[[:space:]]/d" "$file"
    # Remove the same key from drop-in config files to avoid first-match override
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        local dropin
        for dropin in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$dropin" ]] || continue
            if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$dropin" 2>/dev/null; then
                sed -i "/^[#[:space:]]*${key}[[:space:]]/d" "$dropin"
                info "Removed conflicting '${key}' from drop-in: ${dropin}"
            fi
        done
    fi
    echo "${key} ${value}" >> "$file"
}

# ==================== Restart SSH Service (sshd or ssh) ====================
restart_ssh_service() {
    if systemctl cat sshd &>/dev/null; then
        systemctl restart sshd
        info "SSH service (sshd) restarted."
    elif systemctl cat ssh &>/dev/null; then
        systemctl restart ssh
        info "SSH service (ssh) restarted."
    else
        error "Could not find sshd or ssh service to restart."
        return 1
    fi
}

# ==================== Ensure SSHD Installed ====================
ensure_sshd() {
    if command -v sshd &>/dev/null && (systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null); then
        return 0
    fi

    warn "OpenSSH Server is not installed or not running."
    info "Installing openssh-server..."
    apt-get update -y
    apt-get install -y openssh-server
    # Enable whichever service unit exists (ssh on Ubuntu, sshd on some variants)
    if systemctl cat ssh &>/dev/null; then
        systemctl enable ssh
        systemctl start ssh
    elif systemctl cat sshd &>/dev/null; then
        systemctl enable sshd
        systemctl start sshd
    fi

    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        info "OpenSSH Server installed and running."
    else
        error "Failed to start SSH service. Please check manually."
        exit 1
    fi
}

# ==================== Main Menu ====================
show_menu() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║       VPS Server Initialization Script       ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${BOLD}║  1) SSH Security Init (Create User + SSH)    ║${NC}"
    echo -e "${BOLD}║  2) Add Public Key to authorized_keys        ║${NC}"
    echo -e "${BOLD}║  3) Disable Password Auth (After Key Upload) ║${NC}"
    echo -e "${BOLD}║  4) Server Security Hardening                ║${NC}"
    echo -e "${BOLD}║  0) Exit                                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

#============================================================================
# Option 1: SSH Security Initialization
#   Steps can be run individually or all in sequence.
#============================================================================

# Shared state between steps (populated by step 1, consumed by step 3)
_SSH_INIT_USER=""

# ---------- Step 1: Create sudo user ----------
ssh_step_create_user() {
    section "SSH Init — Step 1: Create Sudo User"
    ensure_sshd

    read -rp "Enter new username: " _SSH_INIT_USER

    if [[ -z "$_SSH_INIT_USER" ]]; then
        error "Username cannot be empty."
        return 1
    fi

    if id "$_SSH_INIT_USER" &>/dev/null; then
        warn "User '$_SSH_INIT_USER' already exists, skipping creation."
    else
        while true; do
            read -srp "Enter password for '$_SSH_INIT_USER': " USER_PASS
            echo
            read -srp "Confirm password: " USER_PASS_CONFIRM
            echo
            if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]]; then
                break
            else
                warn "Passwords do not match. Please try again."
            fi
        done

        adduser --gecos "" --disabled-password "$_SSH_INIT_USER"
        echo "${_SSH_INIT_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$_SSH_INIT_USER"
        info "User '$_SSH_INIT_USER' created and added to sudo group."
    fi

    local user_home
    user_home=$(eval echo "~$_SSH_INIT_USER")
    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh"
    touch "${user_home}/.ssh/authorized_keys"
    chmod 600 "${user_home}/.ssh/authorized_keys"
    chown -R "${_SSH_INIT_USER}:${_SSH_INIT_USER}" "${user_home}/.ssh"

    echo ""
    echo -e "  ${GREEN}✓${NC} User:     ${BOLD}${_SSH_INIT_USER}${NC} (sudo group)"
    echo -e "  ${GREEN}✓${NC} SSH dir:  ${CYAN}${user_home}/.ssh/authorized_keys${NC} ready"
}

# ---------- Step 2: Reset root password ----------
ssh_step_reset_root_password() {
    section "SSH Init — Step 2: Reset Root Password"

    while true; do
        read -srp "Enter new root password: " ROOT_PASS
        echo
        read -srp "Confirm new root password: " ROOT_PASS_CONFIRM
        echo
        if [[ "$ROOT_PASS" == "$ROOT_PASS_CONFIRM" ]]; then
            break
        else
            warn "Passwords do not match. Please try again."
        fi
    done
    echo "root:${ROOT_PASS}" | chpasswd

    echo ""
    echo -e "  ${GREEN}✓${NC} Root password: changed"
}

# ---------- Step 3: Configure SSH daemon ----------
ssh_step_configure_daemon() {
    section "SSH Init — Step 3: Configure SSH Daemon"
    ensure_sshd

    # If step 1 was skipped, ask for the username to add to AllowUsers
    local allow_user="$_SSH_INIT_USER"
    if [[ -z "$allow_user" ]]; then
        read -rp "Enter username to allow SSH (AllowUsers): " allow_user
        if [[ -z "$allow_user" ]]; then
            error "Username cannot be empty."
            return 1
        fi
        if ! id "$allow_user" &>/dev/null; then
            warn "User '$allow_user' does not exist on this system."
            confirm "Continue anyway?" || return 1
        fi
    fi

    # Detect current port as default
    local current_port
    current_port=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    current_port=${current_port:-22}

    read -rp "Enter new SSH port (current: ${current_port}, press Enter to keep): " NEW_SSH_PORT
    NEW_SSH_PORT=${NEW_SSH_PORT:-$current_port}

    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT < 1 || NEW_SSH_PORT > 65535 )); then
        error "Invalid port number: $NEW_SSH_PORT"
        return 1
    fi

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    backup_file "$SSHD_CONFIG"

    local SSHD_TMP
    SSHD_TMP=$(mktemp)
    cp "$SSHD_CONFIG" "$SSHD_TMP"

    set_sshd_option "Port"                  "$NEW_SSH_PORT" "$SSHD_TMP"
    set_sshd_option "PermitRootLogin"       "no"            "$SSHD_TMP"
    set_sshd_option "MaxAuthTries"          "5"             "$SSHD_TMP"
    set_sshd_option "LoginGraceTime"        "60"            "$SSHD_TMP"
    set_sshd_option "ClientAliveInterval"   "300"           "$SSHD_TMP"
    set_sshd_option "ClientAliveCountMax"   "3"             "$SSHD_TMP"
    set_sshd_option "X11Forwarding"         "no"            "$SSHD_TMP"
    set_sshd_option "AllowUsers"            "$allow_user"   "$SSHD_TMP"

    cp "$SSHD_TMP" "$SSHD_CONFIG"
    if sshd -t 2>/dev/null; then
        info "SSH config validation passed."
    else
        error "SSH config validation failed! Restoring backup..."
        local latest_bak
        latest_bak=$(ls -t "${SSHD_CONFIG}.bak."* 2>/dev/null | head -1)
        [[ -n "$latest_bak" ]] && cp "$latest_bak" "$SSHD_CONFIG"
        rm -f "$SSHD_TMP"
        return 1
    fi
    rm -f "$SSHD_TMP"

    restart_ssh_service

    echo ""
    echo -e "  ${GREEN}✓${NC} Root SSH login:    ${RED}disabled${NC}"
    echo -e "  ${GREEN}✓${NC} SSH port:          ${BOLD}${NEW_SSH_PORT}${NC}"
    echo -e "  ${GREEN}✓${NC} Allowed SSH users: ${BOLD}${allow_user}${NC}"
    echo ""
    warn "IMPORTANT: Do NOT close this session!"
    warn "Open a NEW terminal and test SSH login before disconnecting:"
    echo -e "    ${CYAN}ssh -p ${NEW_SSH_PORT} ${allow_user}@<your-server-ip>${NC}"
    echo ""
    warn "After logging in, upload your public key with:"
    echo -e "    ${CYAN}ssh-copy-id -p ${NEW_SSH_PORT} ${allow_user}@<your-server-ip>${NC}"
    echo -e "    or manually paste your key into: ${CYAN}~/.ssh/authorized_keys${NC}"
}

# ==================== Option 1 Sub-menu ====================
ssh_security_init() {
    local items=(
        "Create Sudo User"
        "Reset Root Password"
        "Configure SSH Daemon (Port + Security)"
    )
    local funcs=(
        ssh_step_create_user
        ssh_step_reset_root_password
        ssh_step_configure_daemon
    )

    while true; do
        _SSH_INIT_USER=""   # reset shared state on each menu visit

        echo ""
        echo -e "${BOLD}┌──────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}│       SSH Security Initialization Steps      │${NC}"
        echo -e "${BOLD}├──────────────────────────────────────────────┤${NC}"
        for i in "${!items[@]}"; do
            local idx=$((i + 1))
            printf "${BOLD}│  %d) %-42s│${NC}\n" "$idx" "${items[$i]}"
        done
        echo -e "${BOLD}├──────────────────────────────────────────────┤${NC}"
        echo -e "${BOLD}│  a) Run all steps in sequence                │${NC}"
        echo -e "${BOLD}│  0) Back to main menu                        │${NC}"
        echo -e "${BOLD}└──────────────────────────────────────────────┘${NC}"
        echo ""
        read -rp "Select steps to execute (e.g. 1,3 or 'a' for all): " selection

        if [[ "$selection" == "0" ]]; then
            return 0
        fi

        local selected=()
        if [[ "$selection" =~ ^[Aa]$ ]]; then
            for i in "${!funcs[@]}"; do
                selected+=("$i")
            done
        else
            IFS=',' read -ra choices <<< "$selection"
            for choice in "${choices[@]}"; do
                choice=$(echo "$choice" | xargs)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
                    selected+=("$((choice - 1))")
                else
                    warn "Skipping invalid choice: $choice"
                fi
            done
        fi

        if [[ ${#selected[@]} -eq 0 ]]; then
            warn "No valid steps selected."
            continue
        fi

        echo ""
        info "You selected:"
        for idx in "${selected[@]}"; do
            echo -e "  ${CYAN}→${NC} ${items[$idx]}"
        done
        echo ""
        confirm "Proceed?" || continue

        local completed=()
        for idx in "${selected[@]}"; do
            "${funcs[$idx]}"
            completed+=("${items[$idx]}")
            echo ""
        done

        section "SSH Security Init — Done"
        for item in "${completed[@]}"; do
            echo -e "  ${GREEN}✓${NC} ${item}"
        done
        echo ""
        return 0
    done
}

#============================================================================
# Option 2: Add Public Key to authorized_keys
#============================================================================
add_public_key() {
    section "Option 2: Add Public Key to authorized_keys"

    read -rp "Enter the username to add the public key for: " TARGET_USER

    if [[ -z "$TARGET_USER" ]]; then
        error "Username cannot be empty."
        return 1
    fi

    if ! id "$TARGET_USER" &>/dev/null; then
        error "User '$TARGET_USER' does not exist on this system."
        return 1
    fi

    local user_home
    user_home=$(eval echo "~$TARGET_USER")
    local auth_keys="${user_home}/.ssh/authorized_keys"

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh"
    touch "$auth_keys"
    chmod 600 "$auth_keys"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${user_home}/.ssh"

    echo ""
    info "Paste the public key below, then press Enter followed by Ctrl+D:"
    echo ""
    local pubkey
    pubkey=$(cat)

    if [[ -z "$pubkey" ]]; then
        error "No public key entered. Aborting."
        return 1
    fi

    if ! echo "$pubkey" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256) '; then
        warn "Input does not look like a valid SSH public key."
        confirm "Add it anyway?" || return 1
    fi

    # Check for duplicate
    if grep -qF "$pubkey" "$auth_keys" 2>/dev/null; then
        warn "This public key already exists in $auth_keys. Skipping."
        return 0
    fi

    echo "$pubkey" >> "$auth_keys"
    chown "${TARGET_USER}:${TARGET_USER}" "$auth_keys"

    local key_count
    key_count=$(grep -c '^ssh-\|^ecdsa-\|^sk-' "$auth_keys" 2>/dev/null || echo 0)

    echo ""
    echo -e "  ${GREEN}✓${NC} Public key added to: ${CYAN}${auth_keys}${NC}"
    echo -e "  ${GREEN}✓${NC} Total keys in file:  ${BOLD}${key_count}${NC}"
}

#============================================================================
# Option 3: Disable Password Authentication
#   - Verify public key exists
#   - Disable password auth in sshd_config
#============================================================================
disable_password_auth() {
    section "Option 3: Disable Password Authentication"
    ensure_sshd

    warn "This will disable password login for ALL users."
    warn "Make sure you have uploaded your SSH public key and tested key-based login."
    echo ""

    read -rp "Enter the username whose key should be verified: " CHECK_USER

    if [[ -z "$CHECK_USER" ]]; then
        error "Username cannot be empty."
        return 1
    fi

    local CHECK_HOME
    CHECK_HOME=$(eval echo "~$CHECK_USER")
    local AUTH_KEYS="${CHECK_HOME}/.ssh/authorized_keys"

    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        error "No public key found in $AUTH_KEYS"
        error "Please upload your public key first, then run this option again."
        echo ""
        info "You can upload with:"
        echo -e "    ${CYAN}ssh-copy-id -p <port> ${CHECK_USER}@<server-ip>${NC}"
        return 1
    fi

    local KEY_COUNT
    KEY_COUNT=$(grep -c '^ssh-' "$AUTH_KEYS" 2>/dev/null || echo 0)
    info "Found $KEY_COUNT public key(s) in $AUTH_KEYS"
    echo ""

    warn "Please confirm: Have you tested logging in with your SSH key? (in a separate session)"
    confirm "Proceed to disable password authentication?" || return 0

    local SSHD_CONFIG="/etc/ssh/sshd_config"
    backup_file "$SSHD_CONFIG"

    set_sshd_option "PasswordAuthentication"          "no"  "$SSHD_CONFIG"
    set_sshd_option "KbdInteractiveAuthentication" "no"  "$SSHD_CONFIG"
    set_sshd_option "UsePAM"                          "no"  "$SSHD_CONFIG"
    set_sshd_option "PubkeyAuthentication"            "yes" "$SSHD_CONFIG"

    if sshd -t 2>/dev/null; then
        restart_ssh_service
        info "SSH config validation passed."
    else
        error "SSH config validation failed! Restoring backup..."
        local latest_bak
        latest_bak=$(ls -t "${SSHD_CONFIG}.bak."* 2>/dev/null | head -1)
        if [[ -n "$latest_bak" ]]; then
            cp "$latest_bak" "$SSHD_CONFIG"
            restart_ssh_service
        fi
        return 1
    fi

    section "Password Auth Disabled"
    echo -e "  ${GREEN}✓${NC} Password authentication:  ${RED}disabled${NC}"
    echo -e "  ${GREEN}✓${NC} Public key authentication: ${GREEN}enabled${NC}"
    echo ""
    warn "IMPORTANT: Do NOT close this session!"
    warn "Open a NEW terminal and verify key-based login works."
    echo ""
}

#============================================================================
# Option 3: Server Security Hardening
#   - UFW firewall
#   - Fail2ban
#   - Unattended upgrades
#   - Kernel network hardening (sysctl)
#   - Timezone & NTP
#   - Common tools
#============================================================================

# Detect current SSH port (used by multiple sub-options)
detect_ssh_port() {
    CURRENT_SSH_PORT=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
}

hardening_system_update() {
    section "System Update & Common Tools"
    info "Updating system packages..."
    apt-get update -y && apt-get upgrade -y
    info "System updated."
    echo ""
    info "Installing common tools..."
    apt-get install -y \
        curl wget vim htop iotop net-tools \
        unzip zip git tmux lsof tree jq \
        software-properties-common ca-certificates gnupg
    info "Common tools installed."
}

hardening_ufw() {
    section "Configuring UFW Firewall"
    detect_ssh_port
    info "Detected current SSH port: $CURRENT_SSH_PORT"
    apt-get install -y ufw

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${CURRENT_SSH_PORT}/tcp" comment "SSH"

    echo ""
    if confirm "Allow HTTP (80)?"; then
        ufw allow 80/tcp comment "HTTP"
    fi
    if confirm "Allow HTTPS (443)?"; then
        ufw allow 443/tcp comment "HTTPS"
    fi

    read -rp "Any additional ports to open? (comma-separated, e.g. 8080,3306 or press Enter to skip): " EXTRA_PORTS
    if [[ -n "$EXTRA_PORTS" ]]; then
        IFS=',' read -ra PORT_ARRAY <<< "$EXTRA_PORTS"
        for port in "${PORT_ARRAY[@]}"; do
            port=$(echo "$port" | xargs)
            if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
                ufw allow "${port}/tcp" comment "Custom"
                info "Allowed port $port/tcp"
            else
                warn "Skipping invalid port: $port"
            fi
        done
    fi

    ufw --force enable
    info "UFW firewall enabled."
    ufw status verbose
}

hardening_fail2ban() {
    section "Configuring Fail2ban"
    detect_ssh_port
    info "Detected current SSH port: $CURRENT_SSH_PORT"
    apt-get install -y fail2ban

    cat > /etc/fail2ban/jail.local << FAIL2BAN_EOF
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
banaction = ufw

[sshd]
enabled  = true
port     = ${CURRENT_SSH_PORT}
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 7200
FAIL2BAN_EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    info "Fail2ban configured and started."
    fail2ban-client status sshd 2>/dev/null || true
}

hardening_auto_updates() {
    section "Configuring Automatic Security Updates"
    apt-get install -y unattended-upgrades apt-listchanges

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE_EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UNATTENDED_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
UNATTENDED_EOF

    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
    info "Automatic security updates enabled."
}

hardening_sysctl() {
    section "Kernel Network Parameter Hardening"

    local SYSCTL_FILE="/etc/sysctl.d/99-security.conf"
    cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
# ===== Network Security Hardening =====

# Disable IP forwarding
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Disable ICMP redirects (prevent MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Enable reverse path filtering (anti-spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log suspicious packets (martians)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Protect against TIME_WAIT assassination
net.ipv4.tcp_rfc1337 = 1
SYSCTL_EOF

    sysctl -p "$SYSCTL_FILE"
    info "Kernel network parameters hardened."
}

hardening_timezone_ntp() {
    section "Timezone & NTP Configuration"

    local CURRENT_TZ
    CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "unknown")
    echo -e "  Current timezone: ${BOLD}${CURRENT_TZ}${NC}"
    echo ""
    echo "  1) Keep current timezone ($CURRENT_TZ)"
    echo "  2) Set to Asia/Shanghai (UTC+8)"
    echo ""
    read -rp "Select timezone option [1/2]: " TZ_CHOICE

    case "$TZ_CHOICE" in
        2)
            timedatectl set-timezone Asia/Shanghai
            info "Timezone set to Asia/Shanghai."
            ;;
        *)
            info "Keeping current timezone: $CURRENT_TZ"
            ;;
    esac

    apt-get install -y systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    timedatectl set-ntp true
    info "NTP time synchronization enabled."
    timedatectl status
}

hardening_disable_services() {
    section "Disabling Unused Services"
    local services_to_disable=("snapd" "cups" "avahi-daemon" "bluetooth")
    for svc in "${services_to_disable[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc"
            systemctl disable "$svc"
            info "Disabled: $svc"
        else
            info "Not active, skipping: $svc"
        fi
    done
}

# ==================== Option 3: Server Security Hardening ====================
server_security_hardening() {
    section "Option 4: Server Security Hardening"
    ensure_sshd

    local items=(
        "System Update & Install Common Tools"
        "UFW Firewall"
        "Fail2ban (Anti Brute-force)"
        "Automatic Security Updates"
        "Kernel Network Hardening (sysctl)"
        "Timezone & NTP Sync"
        "Disable Unused Services"
    )
    local funcs=(
        hardening_system_update
        hardening_ufw
        hardening_fail2ban
        hardening_auto_updates
        hardening_sysctl
        hardening_timezone_ntp
        hardening_disable_services
    )
    local selected=()

    while true; do
        echo ""
        echo -e "${BOLD}┌──────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}│       Server Security Hardening Items        │${NC}"
        echo -e "${BOLD}├──────────────────────────────────────────────┤${NC}"
        for i in "${!items[@]}"; do
            local idx=$((i + 1))
            printf "${BOLD}│  %d) %-42s│${NC}\n" "$idx" "${items[$i]}"
        done
        echo -e "${BOLD}├──────────────────────────────────────────────┤${NC}"
        echo -e "${BOLD}│  a) Select ALL                               │${NC}"
        echo -e "${BOLD}│  0) Back to main menu                        │${NC}"
        echo -e "${BOLD}└──────────────────────────────────────────────┘${NC}"
        echo ""
        read -rp "Select items to execute (e.g. 1,3,5 or 'a' for all): " selection

        if [[ "$selection" == "0" ]]; then
            return 0
        fi

        selected=()
        if [[ "$selection" =~ ^[Aa]$ ]]; then
            for i in "${!funcs[@]}"; do
                selected+=("$i")
            done
        else
            IFS=',' read -ra choices <<< "$selection"
            for choice in "${choices[@]}"; do
                choice=$(echo "$choice" | xargs)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
                    selected+=("$((choice - 1))")
                else
                    warn "Skipping invalid choice: $choice"
                fi
            done
        fi

        if [[ ${#selected[@]} -eq 0 ]]; then
            warn "No valid items selected."
            continue
        fi

        echo ""
        info "You selected:"
        for idx in "${selected[@]}"; do
            echo -e "  ${CYAN}→${NC} ${items[$idx]}"
        done
        echo ""
        confirm "Proceed with these items?" || continue

        local completed=()
        for idx in "${selected[@]}"; do
            ${funcs[$idx]}
            completed+=("${items[$idx]}")
            echo ""
        done

        section "Hardening Complete"
        for item in "${completed[@]}"; do
            echo -e "  ${GREEN}✓${NC} ${item}"
        done
        echo ""
        return 0
    done
}

#============================================================================
# Main Loop
#============================================================================
main() {
    while true; do
        show_menu
        read -rp "Select an option [0-4]: " choice
        case "$choice" in
            1) ssh_security_init ;;
            2) add_public_key ;;
            3) disable_password_auth ;;
            4) server_security_hardening ;;
            0)
                info "Goodbye!"
                exit 0
                ;;
            *)
                warn "Invalid option. Please choose 0-3."
                ;;
        esac
    done
}

main "$@"
