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

# ==================== Ensure SSHD Installed ====================
ensure_sshd() {
    if command -v sshd &>/dev/null && systemctl is-active --quiet ssh 2>/dev/null; then
        return 0
    fi

    warn "OpenSSH Server is not installed or not running."
    info "Installing openssh-server..."
    apt-get update -y
    apt-get install -y openssh-server
    systemctl enable ssh
    systemctl start ssh

    if systemctl is-active --quiet ssh 2>/dev/null; then
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
    echo -e "${BOLD}║  2) Disable Password Auth (After Key Upload) ║${NC}"
    echo -e "${BOLD}║  3) Server Security Hardening                ║${NC}"
    echo -e "${BOLD}║  0) Exit                                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
}

#============================================================================
# Option 1: SSH Security Initialization
#   - Create sudo user
#   - Reset root password
#   - Disable root SSH login
#   - Change SSH port
#============================================================================
ssh_security_init() {
    section "Option 1: SSH Security Initialization"
    ensure_sshd

    # ---------- Create sudo user ----------
    info "Step 1: Create a new sudo user"
    read -rp "Enter new username: " NEW_USER

    if [[ -z "$NEW_USER" ]]; then
        error "Username cannot be empty."
        return 1
    fi

    if id "$NEW_USER" &>/dev/null; then
        warn "User '$NEW_USER' already exists, skipping creation."
    else
        # Read password with confirmation
        while true; do
            read -srp "Enter password for '$NEW_USER': " USER_PASS
            echo
            read -srp "Confirm password: " USER_PASS_CONFIRM
            echo
            if [[ "$USER_PASS" == "$USER_PASS_CONFIRM" ]]; then
                break
            else
                warn "Passwords do not match. Please try again."
            fi
        done

        adduser --gecos "" --disabled-password "$NEW_USER"
        echo "${NEW_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$NEW_USER"
        info "User '$NEW_USER' created and added to sudo group."
    fi

    # Create .ssh directory for the new user
    NEW_USER_HOME=$(eval echo "~$NEW_USER")
    mkdir -p "${NEW_USER_HOME}/.ssh"
    chmod 700 "${NEW_USER_HOME}/.ssh"
    touch "${NEW_USER_HOME}/.ssh/authorized_keys"
    chmod 600 "${NEW_USER_HOME}/.ssh/authorized_keys"
    chown -R "${NEW_USER}:${NEW_USER}" "${NEW_USER_HOME}/.ssh"
    info "Created ~/.ssh/authorized_keys for '$NEW_USER'."

    # ---------- Reset root password ----------
    info "Step 2: Reset root password"
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
    info "Root password has been changed."

    # ---------- Change SSH port ----------
    info "Step 3: Change SSH port"
    read -rp "Enter new SSH port (default 22, recommended 10000-65535): " NEW_SSH_PORT
    NEW_SSH_PORT=${NEW_SSH_PORT:-22}

    # Validate port number
    if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT < 1 || NEW_SSH_PORT > 65535 )); then
        error "Invalid port number: $NEW_SSH_PORT"
        return 1
    fi

    # ---------- Disable root login & apply SSH port ----------
    info "Step 4: Configure SSH daemon"
    SSHD_CONFIG="/etc/ssh/sshd_config"
    backup_file "$SSHD_CONFIG"

    # Use a temporary file for safe editing
    SSHD_TMP=$(mktemp)
    cp "$SSHD_CONFIG" "$SSHD_TMP"

    # Function to set or add an SSH config directive
    set_sshd_option() {
        local key="$1"
        local value="$2"
        local file="$3"
        # Remove all existing lines (including commented ones) for this key
        sed -i "/^[#[:space:]]*${key}[[:space:]]/d" "$file"
        # Append the new value
        echo "${key} ${value}" >> "$file"
    }

    set_sshd_option "Port"                  "$NEW_SSH_PORT" "$SSHD_TMP"
    set_sshd_option "PermitRootLogin"       "no"            "$SSHD_TMP"
    set_sshd_option "MaxAuthTries"          "5"             "$SSHD_TMP"
    set_sshd_option "LoginGraceTime"        "60"            "$SSHD_TMP"
    set_sshd_option "ClientAliveInterval"   "300"           "$SSHD_TMP"
    set_sshd_option "ClientAliveCountMax"   "3"             "$SSHD_TMP"
    set_sshd_option "X11Forwarding"         "no"            "$SSHD_TMP"
    set_sshd_option "AllowUsers"            "$NEW_USER"     "$SSHD_TMP"

    # Validate the new config before applying
    cp "$SSHD_TMP" "$SSHD_CONFIG"
    if sshd -t 2>/dev/null; then
        info "SSH config validation passed."
    else
        error "SSH config validation failed! Restoring backup..."
        cp "${SSHD_CONFIG}.bak."* "$SSHD_CONFIG" 2>/dev/null
        rm -f "$SSHD_TMP"
        return 1
    fi
    rm -f "$SSHD_TMP"

    # Restart SSH service
    systemctl restart sshd
    info "SSH service restarted."

    # ---------- Summary ----------
    section "SSH Security Init Complete"
    echo -e "  ${GREEN}✓${NC} New user:          ${BOLD}${NEW_USER}${NC}"
    echo -e "  ${GREEN}✓${NC} Root password:     changed"
    echo -e "  ${GREEN}✓${NC} Root SSH login:    ${RED}disabled${NC}"
    echo -e "  ${GREEN}✓${NC} SSH port:          ${BOLD}${NEW_SSH_PORT}${NC}"
    echo -e "  ${GREEN}✓${NC} Allowed SSH users: ${BOLD}${NEW_USER}${NC}"
    echo ""
    warn "IMPORTANT: Do NOT close this session!"
    warn "Open a NEW terminal and test SSH login before disconnecting:"
    echo -e "    ${CYAN}ssh -p ${NEW_SSH_PORT} ${NEW_USER}@<your-server-ip>${NC}"
    echo ""
    warn "After logging in, upload your public key with:"
    echo -e "    ${CYAN}ssh-copy-id -p ${NEW_SSH_PORT} ${NEW_USER}@<your-server-ip>${NC}"
    echo -e "    or manually paste your key into: ${CYAN}~/.ssh/authorized_keys${NC}"
    echo ""
}

#============================================================================
# Option 2: Disable Password Authentication
#   - Verify public key exists
#   - Disable password auth in sshd_config
#============================================================================
disable_password_auth() {
    section "Option 2: Disable Password Authentication"
    ensure_sshd

    warn "This will disable password login for ALL users."
    warn "Make sure you have uploaded your SSH public key and tested key-based login."
    echo ""

    # Try to detect which user to check
    read -rp "Enter the username whose key should be verified: " CHECK_USER

    if [[ -z "$CHECK_USER" ]]; then
        error "Username cannot be empty."
        return 1
    fi

    CHECK_HOME=$(eval echo "~$CHECK_USER")
    AUTH_KEYS="${CHECK_HOME}/.ssh/authorized_keys"

    if [[ ! -f "$AUTH_KEYS" ]] || [[ ! -s "$AUTH_KEYS" ]]; then
        error "No public key found in $AUTH_KEYS"
        error "Please upload your public key first, then run this option again."
        echo ""
        info "You can upload with:"
        echo -e "    ${CYAN}ssh-copy-id -p <port> ${CHECK_USER}@<server-ip>${NC}"
        return 1
    fi

    KEY_COUNT=$(grep -c '^ssh-' "$AUTH_KEYS" 2>/dev/null || echo 0)
    info "Found $KEY_COUNT public key(s) in $AUTH_KEYS"
    echo ""

    warn "Please confirm: Have you tested logging in with your SSH key? (in a separate session)"
    confirm "Proceed to disable password authentication?" || return 0

    SSHD_CONFIG="/etc/ssh/sshd_config"
    backup_file "$SSHD_CONFIG"

    set_sshd_option() {
        local key="$1"
        local value="$2"
        local file="$3"
        sed -i "/^[#[:space:]]*${key}[[:space:]]/d" "$file"
        echo "${key} ${value}" >> "$file"
    }

    set_sshd_option "PasswordAuthentication"        "no"  "$SSHD_CONFIG"
    set_sshd_option "ChallengeResponseAuthentication" "no"  "$SSHD_CONFIG"
    set_sshd_option "UsePAM"                         "no"  "$SSHD_CONFIG"
    set_sshd_option "PubkeyAuthentication"           "yes" "$SSHD_CONFIG"

    if sshd -t 2>/dev/null; then
        systemctl restart sshd
        info "SSH config validation passed, service restarted."
    else
        error "SSH config validation failed! Restoring backup..."
        LATEST_BACKUP=$(ls -t "${SSHD_CONFIG}.bak."* 2>/dev/null | head -1)
        if [[ -n "$LATEST_BACKUP" ]]; then
            cp "$LATEST_BACKUP" "$SSHD_CONFIG"
            systemctl restart sshd
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
server_security_hardening() {
    section "Option 3: Server Security Hardening"
    ensure_sshd

    # Detect current SSH port from sshd_config
    CURRENT_SSH_PORT=$(grep -E "^Port\s+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
    info "Detected current SSH port: $CURRENT_SSH_PORT"
    echo ""

    # ---------- 3.1 System Update ----------
    info "Updating system packages..."
    apt-get update -y && apt-get upgrade -y
    info "System updated."

    # ---------- 3.2 Install Common Tools ----------
    info "Installing common tools..."
    apt-get install -y \
        curl wget vim htop iotop net-tools \
        unzip zip git tmux lsof tree jq \
        software-properties-common apt-transport-https \
        ca-certificates gnupg
    info "Common tools installed."

    # ---------- 3.3 UFW Firewall ----------
    section "Configuring UFW Firewall"
    apt-get install -y ufw

    # Reset UFW to defaults
    ufw --force reset

    # Default policies
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH port
    ufw allow "${CURRENT_SSH_PORT}/tcp" comment "SSH"

    # Ask about common ports
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
            port=$(echo "$port" | xargs)  # trim whitespace
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
    echo ""

    # ---------- 3.4 Fail2ban ----------
    section "Configuring Fail2ban"
    apt-get install -y fail2ban

    # Create local jail config (overrides default safely)
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
    echo ""

    # ---------- 3.5 Unattended Upgrades ----------
    section "Configuring Automatic Security Updates"
    apt-get install -y unattended-upgrades apt-listchanges

    # Enable automatic security updates
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE_EOF

    # Configure unattended-upgrades to only apply security patches
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
    echo ""

    # ---------- 3.6 Kernel Network Hardening (sysctl) ----------
    section "Kernel Network Parameter Hardening"

    SYSCTL_FILE="/etc/sysctl.d/99-security.conf"
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
    echo ""

    # ---------- 3.7 Timezone & NTP ----------
    section "Timezone & NTP Configuration"

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

    # Configure NTP
    apt-get install -y systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl restart systemd-timesyncd
    timedatectl set-ntp true
    info "NTP time synchronization enabled."
    timedatectl status
    echo ""

    # ---------- 3.8 Disable Unused Services ----------
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
    echo ""

    # ---------- Summary ----------
    section "Server Security Hardening Complete"
    echo -e "  ${GREEN}✓${NC} System packages updated"
    echo -e "  ${GREEN}✓${NC} Common tools installed"
    echo -e "  ${GREEN}✓${NC} UFW firewall enabled (SSH port: ${CURRENT_SSH_PORT})"
    echo -e "  ${GREEN}✓${NC} Fail2ban active (SSH protection)"
    echo -e "  ${GREEN}✓${NC} Automatic security updates enabled"
    echo -e "  ${GREEN}✓${NC} Kernel network parameters hardened"
    echo -e "  ${GREEN}✓${NC} Timezone & NTP configured"
    echo -e "  ${GREEN}✓${NC} Unused services disabled"
    echo ""
}

#============================================================================
# Main Loop
#============================================================================
main() {
    while true; do
        show_menu
        read -rp "Select an option [0-3]: " choice
        case "$choice" in
            1) ssh_security_init ;;
            2) disable_password_auth ;;
            3) server_security_hardening ;;
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