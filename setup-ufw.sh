
#!/bin/bash

# ============================================================
# Production UFW Firewall Setup
#
# Policy:
#   Incoming traffic : DENY
#   Outgoing traffic : ALLOW
#   SSH               : ALLOW from trusted CIDRs only
#
# Run:
#   sudo bash setup-ufw.sh
#
# IMPORTANT:
#   Run this from an active SSH session.
#   The script allows SSH BEFORE enabling UFW.
# ============================================================

set -Eeuo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

# Ports allowed only from trusted IPs and networks.
RESTRICTED_INCOMING_RULES=(
    "22/tcp"                  # SSH
    # "26657/tcp"               # Tendermint RPC
)

# Incoming rules to remove from UFW on every normal script run.
remove_INCOMING_RULES=(
   "8545/tcp"
   "26657/tcp"
   "888/tcp"
)

# Services exposed publicly.
PUBLIC_INCOMING_RULES=(
    "80/tcp"                  # HTTP
    "443/tcp"                 # HTTPS
    # "8545/tcp"  
    # "26657/tcp"               # Tendermint RPC
)

# Trusted IP addresses and networks allowed to access restricted ports.
TRUSTED_CIDRS=(
    "14.99.117.194/32"
    "125.21.216.158/32"
    # "112.196.25.234/32"

)

# Trusted IPs allowed to access all incoming ports.
# Do not add these IPs to TRUSTED_CIDRS as well.
TRUSTED_ALL_CIDRS=(
    "125.21.216.158/32"
    "14.99.117.194/32"
    "112.196.81.250/32"
    "112.196.25.234/32"
)

# Previously configured trusted networks that should no longer have rules.
REMOVE_TRUSTED_CIDRS=(
    # "112.196.119.50/31"
)

# Wazuh agent -> manager traffic. These rules allow outbound traffic only.
# OUTGOING_RULES=(
#     "1514/tcp|Wazuh agent -> manager"
#     "55000/tcp|Wazuh API"
# )

LOG_FILE="/var/log/ufw-firewall-setup.log"

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

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
# Allow SSH BEFORE enabling UFW.
# This prevents accidental SSH lockout.
# ------------------------------------------------------------

echo
echo "Removing unrestricted restricted-port rules, if present..."

for RULE in "${RESTRICTED_INCOMING_RULES[@]}"; do
    ufw delete allow "$RULE" >/dev/null 2>&1 || true
done

echo "Removing configured incoming rules..."

for RULE in "${remove_INCOMING_RULES[@]}"; do
    echo "  DELETE IN -> $RULE"
    ufw delete allow "$RULE" >/dev/null 2>&1 || true
done

echo "Removing previously configured trusted IP rules..."

for CIDR in "${REMOVE_TRUSTED_CIDRS[@]}"; do
    echo "  DELETE TRUSTED -> $CIDR"

    for RULE in "${RESTRICTED_INCOMING_RULES[@]}"; do
        PORT="${RULE%/*}"
        PROTO="${RULE#*/}"
        ufw delete allow from "$CIDR" to any port "$PORT" proto "$PROTO" >/dev/null 2>&1 || true
    done

    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true
done

echo "Removing broad trusted rules for active IPs..."

for CIDR in "${TRUSTED_CIDRS[@]}"; do
    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true
done

echo "Removing old all-port rules for configured IPs..."

for CIDR in "${TRUSTED_ALL_CIDRS[@]}"; do
    ufw delete allow from "$CIDR" >/dev/null 2>&1 || true
done

echo "Allowing all incoming ports for configured IPs..."

for CIDR in "${TRUSTED_ALL_CIDRS[@]}"; do
    echo "  ALLOW ALL -> $CIDR"
    ufw allow from "$CIDR" comment "Trusted all ports"
done

echo "Allowing restricted ports only from trusted IPs and networks..."

for CIDR in "${TRUSTED_CIDRS[@]}"; do
    for RULE in "${RESTRICTED_INCOMING_RULES[@]}"; do
        PORT="${RULE%/*}"
        PROTO="${RULE#*/}"
        echo "  ALLOW $RULE -> $CIDR"
        ufw allow from "$CIDR" to any port "$PORT" proto "$PROTO" comment "Trusted network"
    done
done

echo
echo "Allowing configured public services..."

for RULE in "${PUBLIC_INCOMING_RULES[@]}"; do
    echo "  ALLOW PUBLIC -> $RULE"
    ufw allow "$RULE"
done

# ------------------------------------------------------------
# Configure default policy
# ------------------------------------------------------------

echo
echo "Configuring default UFW policy..."

ufw default deny incoming
ufw default allow outgoing

# ------------------------------------------------------------
# Configure managed outbound rules
# ------------------------------------------------------------

# echo
# echo "Allowing configured outbound services..."
#
# for RULE in "${OUTGOING_RULES[@]}"; do
#     PORT="${RULE%%|*}"
#     COMMENT="${RULE#*|}"
#     echo "  ALLOW OUT -> $PORT ($COMMENT)"
#     ufw allow out "$PORT" comment "$COMMENT"
# done

# ------------------------------------------------------------
# Display rules BEFORE enabling
# ------------------------------------------------------------

echo
echo "============================================================"
echo " UFW RULES BEFORE ENABLE"
echo "============================================================"

ufw show added

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
echo "Restricted ports : ${#RESTRICTED_INCOMING_RULES[@]}"
echo "Public ports     : ${#PUBLIC_INCOMING_RULES[@]}"
echo "Trusted networks: ${#TRUSTED_CIDRS[@]}"
# echo "Outbound rules   : ${#OUTGOING_RULES[@]}"
echo
echo "Log file:"
echo "  $LOG_FILE"
echo
echo "IMPORTANT:"
echo "  Keep your current SSH session open."
echo "  Open a SECOND SSH session and verify access before"
echo "  closing this session."
echo
echo "Completed: $(date)"
echo "============================================================"
