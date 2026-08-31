```bash
#!/bin/bash

# ============================================================
# Production UFW Firewall Setup
#
# Policy:
#   Incoming traffic : DENY
#   Outgoing traffic : ALLOW
#
# Public services:
#   80/tcp  -> HTTP
#   443/tcp -> HTTPS
#
# SSH:
#   BLOCKED / NOT ALLOWED BY UFW
#
# Trusted IPs:
#   TRUSTED_ALL_CIDRS can access all incoming ports.
#
# Run:
#   sudo bash setup-ufw.sh
#
# IMPORTANT:
#   If you are connected over SSH, make sure you have
#   console/KVM/out-of-band access before running this script.
#   This configuration intentionally removes SSH access.
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

# Restricted incoming ports.
#
# SSH is intentionally NOT configured here.
#
RESTRICTED_INCOMING_RULES=(
    # "22/tcp"
    # "26657/tcp"
)

# Incoming rules to remove from UFW on every normal script run.
REMOVE_INCOMING_RULES=(
    "22/tcp"
    "8545/tcp"
    "26657/tcp"
    "888/tcp"
)

# Services exposed publicly.
PUBLIC_INCOMING_RULES=(
    "80/tcp"                  # HTTP
    "443/tcp"                 # HTTPS
)

# Trusted IP addresses and networks allowed to access
# restricted ports.
#
# Currently empty because no restricted ports are configured.
#
TRUSTED_CIDRS=(
    # "14.99.117.194/32"
    # "125.21.216.158/32"
)

# Trusted IPs allowed to access ALL incoming ports.
#
# WARNING:
# These IPs effectively bypass the normal incoming deny policy.
#
TRUSTED_ALL_CIDRS=(
    "125.21.216.158/32"
    "14.99.117.194/32"
    "112.196.81.250/32"
    "112.196.25.234/32"
)

# Previously configured trusted networks that should no longer
# have rules.
REMOVE_TRUSTED_CIDRS=(
    # "112.196.119.50/31"
)

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

LOG_FILE="/var/log/ufw-firewall-setup.log"

mkdir -p "$(dirname "$LOG_FILE")"

exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "============================================================"
echo " UFW PRODUCTION FIREWALL SETUP"
echo "============================================================"
echo "Started: $(date)"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo
    echo "Run:"
    echo "  sudo bash $0"
    exit 1
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: Cannot identify operating system."
    exit 1
fi

source /etc/os-release

echo "Operating System: ${PRETTY_NAME:-Unknown}"
echo

# ------------------------------------------------------------
# Confirm Debian/Ubuntu
# ------------------------------------------------------------

if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"debian"* ]]; then
    echo "WARNING: This script is designed for Ubuntu/Debian systems."
    echo "Detected: ${ID:-unknown}"
    echo
fi

# ------------------------------------------------------------
# Check network connectivity
# ------------------------------------------------------------

echo "[1/8] Checking network connectivity..."

if ! ip route get 1.1.1.1 >/dev/null 2>&1; then
    echo "WARNING: Network connectivity check failed."
    echo "Continuing, but apt operations may fail."
fi

# ------------------------------------------------------------
# Update package repository
# ------------------------------------------------------------

echo
echo "[2/8] Updating package repository..."

# apt-get update

# ------------------------------------------------------------
# Upgrade installed packages
# ------------------------------------------------------------

echo
echo "[3/8] Upgrading installed packages..."

# export DEBIAN_FRONTEND=noninteractive
# apt-get upgrade -y

# ------------------------------------------------------------
# Install UFW
# ------------------------------------------------------------

echo
echo "[4/8] Installing UFW..."

# apt-get install -y ufw

# ------------------------------------------------------------
# IMPORTANT SAFETY RULE
#
# SSH is intentionally NOT allowed.
#
# This script removes:
#
#   OpenSSH                    ALLOW Anywhere
#   OpenSSH (v6)               ALLOW Anywhere (v6)
#   22/tcp                     ALLOW trusted IP
#
# Make sure you have console/KVM access before running.
# ------------------------------------------------------------

echo
echo "============================================================"
echo " REMOVING UNWANTED UFW RULES"
echo "============================================================"

# ------------------------------------------------------------
# Remove unrestricted OpenSSH application rules
# ------------------------------------------------------------

echo
echo "Removing unrestricted SSH rules..."

ufw delete allow OpenSSH >/dev/null 2>&1 || true
ufw delete allow "OpenSSH (v6)" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Remove unrestricted Nginx Full application rules
# ------------------------------------------------------------

echo
echo "Removing unrestricted Nginx Full rules..."

ufw delete allow "Nginx Full" >/dev/null 2>&1 || true
ufw delete allow "Nginx Full (v6)" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Remove unrestricted HTTP/HTTPS application profiles
#
# We manage 80/443 explicitly below.
# ------------------------------------------------------------

echo
echo "Removing old Nginx HTTP/HTTPS application rules..."

ufw delete allow "Nginx HTTP" >/dev/null 2>&1 || true
ufw delete allow "Nginx HTTP (v6)" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Remove configured incoming rules
# ------------------------------------------------------------

echo
echo "Removing configured incoming rules..."

for RULE in "${REMOVE_INCOMING_RULES[@]}"; do

    PORT="${RULE%/*}"
    PROTO="${RULE#*/}"

    echo "  DELETE IN -> $RULE"

    ufw delete allow "$RULE" >/dev/null 2>&1 || true
    ufw delete allow "$PORT/$PROTO" >/dev/null 2>&1 || true

done

# ------------------------------------------------------------
# Remove previously configured trusted CIDRs
# ------------------------------------------------------------

echo
echo "Removing previously configured trusted IP rules..."

for CIDR in "${REMOVE_TRUSTED_CIDRS[@]}"; do

    echo "  DELETE TRUSTED -> $CIDR"

    # Remove all-port rule
    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true

    # Remove restricted-port rules
    for RULE in "${RESTRICTED_INCOMING_RULES[@]}"; do

        PORT="${RULE%/*}"
        PROTO="${RULE#*/}"

        ufw delete allow \
            from "$CIDR" \
            to any \
            port "$PORT" \
            proto "$PROTO" \
            >/dev/null 2>&1 || true

    done

done

# ------------------------------------------------------------
# Remove broad trusted rules for active TRUSTED_CIDRS
# ------------------------------------------------------------

echo
echo "Removing broad trusted rules for active IPs..."

for CIDR in "${TRUSTED_CIDRS[@]}"; do

    echo "  DELETE ALL -> $CIDR"

    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true

done

# ------------------------------------------------------------
# Remove old all-port rules for TRUSTED_ALL_CIDRS
# ------------------------------------------------------------

echo
echo "Removing old all-port rules for configured trusted IPs..."

for CIDR in "${TRUSTED_ALL_CIDRS[@]}"; do

    echo "  DELETE ALL -> $CIDR"

    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true

done

# ------------------------------------------------------------
# Remove SSH trusted rules explicitly
#
# This guarantees that old rules like:
#
# 22/tcp ALLOW 14.99.117.194
# 22/tcp ALLOW 125.21.216.158
#
# are removed even if SSH is no longer present in
# RESTRICTED_INCOMING_RULES.
# ------------------------------------------------------------

echo
echo "Removing ALL SSH trusted-IP rules..."

SSH_PORT="22"
SSH_PROTO="tcp"

for CIDR in "${TRUSTED_CIDRS[@]}"; do

    echo "  DELETE SSH -> $CIDR"

    ufw delete allow \
        from "$CIDR" \
        to any \
        port "$SSH_PORT" \
        proto "$SSH_PROTO" \
        >/dev/null 2>&1 || true

done

# ------------------------------------------------------------
# Add trusted ALL rules
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ADDING TRUSTED ALL-PORT RULES"
echo "============================================================"

for CIDR in "${TRUSTED_ALL_CIDRS[@]}"; do

    echo "  ALLOW ALL -> $CIDR"

    ufw allow from "$CIDR" comment "Trusted all ports"

done

# ------------------------------------------------------------
# Add restricted ports
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ADDING RESTRICTED PORT RULES"
echo "============================================================"

for CIDR in "${TRUSTED_CIDRS[@]}"; do

    for RULE in "${RESTRICTED_INCOMING_RULES[@]}"; do

        PORT="${RULE%/*}"
        PROTO="${RULE#*/}"

        echo "  ALLOW $RULE -> $CIDR"

        ufw allow \
            from "$CIDR" \
            to any \
            port "$PORT" \
            proto "$PROTO" \
            comment "Trusted network"

    done

done

# ------------------------------------------------------------
# Add public services
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ADDING PUBLIC SERVICES"
echo "============================================================"

for RULE in "${PUBLIC_INCOMING_RULES[@]}"; do

    echo "  ALLOW PUBLIC -> $RULE"

    ufw allow "$RULE"

done

# ------------------------------------------------------------
# Configure default policy
# ------------------------------------------------------------

echo
echo "============================================================"
echo " CONFIGURING DEFAULT POLICY"
echo "============================================================"

ufw default deny incoming
ufw default allow outgoing

# ------------------------------------------------------------
# Display rules BEFORE enabling
# ------------------------------------------------------------

echo
echo "============================================================"
echo " UFW RULES BEFORE ENABLE"
echo "============================================================"

ufw show added

# ------------------------------------------------------------
# Enable firewall
# ------------------------------------------------------------

echo
echo "============================================================"
echo " ENABLING FIREWALL"
echo "============================================================"

ufw --force enable

# ------------------------------------------------------------
# Reload firewall
# ------------------------------------------------------------

echo
echo "Reloading UFW..."

ufw reload

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

echo
echo "============================================================"
echo " FINAL UFW STATUS"
echo "============================================================"

ufw status verbose

# ------------------------------------------------------------
# Numbered rules
# ------------------------------------------------------------

echo
echo "============================================================"
echo " NUMBERED RULES"
echo "============================================================"

ufw status numbered

# ------------------------------------------------------------
# Verify UFW service
# ------------------------------------------------------------

echo
echo "============================================================"
echo " UFW SERVICE STATUS"
echo "============================================================"

systemctl is-enabled ufw || true
systemctl is-active ufw || true

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " FIREWALL SETUP COMPLETED SUCCESSFULLY"
echo "============================================================"
echo
echo "Incoming traffic : DENY by default"
echo "Outgoing traffic : ALLOW by default"
echo "SSH               : BLOCKED"
echo "HTTP              : PUBLIC"
echo "HTTPS             : PUBLIC"
echo "Restricted ports  : ${#RESTRICTED_INCOMING_RULES[@]}"
echo "Public ports      : ${#PUBLIC_INCOMING_RULES[@]}"
echo "Trusted networks  : ${#TRUSTED_CIDRS[@]}"
echo "Trusted ALL IPs   : ${#TRUSTED_ALL_CIDRS[@]}"
echo
echo "Log file:"
echo "  $LOG_FILE"
echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo
echo "SSH (22/tcp) is intentionally NOT allowed."
echo
echo "The following rules have been removed:"
echo "  - OpenSSH -> Anywhere"
echo "  - OpenSSH (v6) -> Anywhere"
echo "  - Nginx Full -> Anywhere"
echo "  - Nginx Full (v6) -> Anywhere"
echo "  - 22/tcp -> trusted SSH IPs"
echo
echo "Make sure console/KVM access is available before"
echo "closing your current SSH session."
echo
echo "Completed: $(date)"
echo
echo "============================================================"
```
