#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Autheo Mainnet Full Node Installation + State Sync Script
#
# OS:           Linux x86_64
# Components:   Go 1.23.1, Autheo Chain Core, systemd
# User/Group:   autheo:autheo
# Storage:      Pruned (keep-recent=100) + State Sync enabled
###############################################################################

############################
# Configuration
############################

GO_VERSION="1.23.1"
GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"
GO_SHA256_URL="https://dl.google.com/go/${GO_ARCHIVE}.sha256"

AUTHEO_USER="autheo"
AUTHEO_GROUP="autheo"

AUTHEO_REPO="https://github.com/autheo-blockchain/autheo-chain-core.git"
NETWORK_REPO="https://github.com/autheo-blockchain/networks.git"

AUTHEO_HOME="/data/.autheo"
AUTHEO_ROOT_LINK="/root/.autheo"

CHAIN_ID="autheo_2127-1"
NODE_NAME="autheo$(head -c 500 /dev/urandom | tr -dc '0-9' | cut -c1-5)"

AUTHEO_BINARY="/usr/local/bin/autheod"
SERVICE_FILE="/etc/systemd/system/autheod.service"

BUILD_DIR="/tmp/autheo-chain-core"
NETWORK_DIR="/tmp/autheo-networks"

MINIMUM_GAS_PRICES="2500aauth"
JSON_RPC_ADDRESS="0.0.0.0:8545"

# State Sync Target RPC Node
STATE_SYNC_RPC="https://aqil-autheo.instanodes.io"

############################
# Logging & Utilities
############################

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

############################
# Root check
############################

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root."
fi

export HOME="${HOME:-/root}"
export GOPATH="${HOME}/go"
export GOMODCACHE="${GOPATH}/pkg/mod"

############################
# OS / Architecture check
############################

ARCH="$(uname -m)"
if [[ "${ARCH}" != "x86_64" ]]; then
    die "Unsupported architecture: ${ARCH}. This script requires x86_64."
fi

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

log "Detected architecture: ${ARCH}"

############################
# Create System User & Group
############################

log "Setting up system group and user..."

if ! getent group "${AUTHEO_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${AUTHEO_GROUP}"
    log "Created group: ${AUTHEO_GROUP}"
fi

if ! id -u "${AUTHEO_USER}" >/dev/null 2>&1; then
    useradd --system \
        --gid "${AUTHEO_GROUP}" \
        --create-home \
        --home-dir "/home/${AUTHEO_USER}" \
        --shell /bin/false \
        "${AUTHEO_USER}"
    log "Created user: ${AUTHEO_USER}"
fi

AUTHEO_USER_HOME="/home/${AUTHEO_USER}"
AUTHEO_USER_LINK="${AUTHEO_USER_HOME}/.autheo"

############################
# Required packages
############################

log "Installing required packages..."
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    git \
    make \
    build-essential \
    tar \
    gzip \
    python3 \
    jq

############################
# Install Go
############################

install_go() {
    if command -v go >/dev/null 2>&1; then
        CURRENT_GO="$(go version | awk '{print $3}' | sed 's/^go//')"
        if [[ "${CURRENT_GO}" == "${GO_VERSION}" ]]; then
            log "Go ${GO_VERSION} is already installed."
            return
        fi
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'cd /root && rm -rf "${TMP_DIR}"' RETURN
    cd "${TMP_DIR}"

    log "Downloading Go ${GO_VERSION}..."
    curl -fL --retry 3 --retry-delay 2 -o "${GO_ARCHIVE}" "${GO_URL}"
    curl -fL --retry 3 --retry-delay 2 -o "${GO_ARCHIVE}.sha256" "${GO_SHA256_URL}"

    ACTUAL_HASH="$(sha256sum "${GO_ARCHIVE}" | awk '{print $1}')"
    EXPECTED_HASH="$(tr -d ' \n\r' < "${GO_ARCHIVE}.sha256")"

    if [[ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]]; then
        die "Go Checksum mismatch!"
    fi

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${GO_ARCHIVE}"
}

install_go
export PATH="/usr/local/go/bin:${PATH}"

############################
# Prepare Autheo Directories & Links
############################

log "Preparing Autheo home directory..."
mkdir -p "${AUTHEO_HOME}"

if [[ ! -L "${AUTHEO_USER_LINK}" ]] && [[ ! -e "${AUTHEO_USER_LINK}" ]]; then
    ln -s "${AUTHEO_HOME}" "${AUTHEO_USER_LINK}"
    chown -h "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_USER_LINK}"
fi

if [[ ! -L "${AUTHEO_ROOT_LINK}" ]] && [[ ! -e "${AUTHEO_ROOT_LINK}" ]]; then
    ln -s "${AUTHEO_HOME}" "${AUTHEO_ROOT_LINK}"
fi

############################
# Build autheod
############################

log "Building autheod binary..."
rm -rf "${BUILD_DIR}"
git clone --depth 1 "${AUTHEO_REPO}" "${BUILD_DIR}"
cd "${BUILD_DIR}"

HOME="/root" GOPATH="/root/go" GOMODCACHE="/root/go/pkg/mod" make build

install -o root -g root -m 0755 "${BUILD_DIR}/build/autheod" "${AUTHEO_BINARY}"

log "Installed binary: $("${AUTHEO_BINARY}" version)"

############################
# Initialize Node
############################

log "Initializing node configuration..."
if [[ ! -f "${AUTHEO_HOME}/config/config.toml" ]]; then
    su -s /bin/bash "${AUTHEO_USER}" -c "${AUTHEO_BINARY} init '${NODE_NAME}' --chain-id='${CHAIN_ID}' --home '${AUTHEO_HOME}'"
fi

############################
# Download Network Configuration
############################

log "Downloading genesis & peers..."
rm -rf "${NETWORK_DIR}"
git clone --depth 1 "${NETWORK_REPO}" "${NETWORK_DIR}"

install -o "${AUTHEO_USER}" -g "${AUTHEO_GROUP}" -m 0644 \
    "${NETWORK_DIR}/mainnet/genesis.json" \
    "${AUTHEO_HOME}/config/genesis.json"

PERSISTENT_PEERS="$(tr '\n' ',' < "${NETWORK_DIR}/mainnet/persistent_peers.txt" | sed 's/,$//')"

############################
# Apply Pruning (keep-recent = 100)
############################

CONFIG_TOML="${AUTHEO_HOME}/config/config.toml"
APP_TOML="${AUTHEO_HOME}/config/app.toml"

log "Configuring app.toml with gas prices, JSON-RPC, and pruning..."

MINIMUM_GAS_PRICES="${MINIMUM_GAS_PRICES}" \
JSON_RPC_ADDRESS="${JSON_RPC_ADDRESS}" \
python3 <<'PY'
from pathlib import Path
import os

path = Path("/data/.autheo/config/app.toml")
minimum_gas = os.environ["MINIMUM_GAS_PRICES"]
rpc_address = os.environ["JSON_RPC_ADDRESS"]

lines = path.read_text().splitlines()
in_json_rpc = False

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        in_json_rpc = stripped == "[json-rpc]"
        continue

    if "=" in line:
        key = stripped.split("=")[0].strip()
        prefix = line[:len(line) - len(line.lstrip())]

        if key == "minimum-gas-prices":
            lines[i] = f'{prefix}minimum-gas-prices = "{minimum_gas}"'
        elif in_json_rpc and key == "address":
            lines[i] = f'{prefix}address = "{rpc_address}"'
        elif key == "pruning":
            lines[i] = f'{prefix}pruning = "custom"'
        elif key == "pruning-keep-recent":
            lines[i] = f'{prefix}pruning-keep-recent = "100"'
        elif key == "pruning-keep-every":
            lines[i] = f'{prefix}pruning-keep-every = "0"'
        elif key == "pruning-interval":
            lines[i] = f'{prefix}pruning-interval = "10"'

path.write_text("\n".join(lines) + "\n")
PY

############################
# Perform State Sync Setup
############################

log "Fetching live state sync metadata from ${STATE_SYNC_RPC}..."

STATUS_JSON=$(curl -s --max-time 10 "${STATE_SYNC_RPC}/status" || die "Unable to reach RPC at ${STATE_SYNC_RPC}")
LATEST_HEIGHT=$(echo "${STATUS_JSON}" | jq -r '.result.sync_info.latest_block_height // .sync_info.latest_block_height')

if [[ -z "${LATEST_HEIGHT}" || "${LATEST_HEIGHT}" == "null" ]]; then
    die "Failed to parse latest block height from RPC status."
fi

# Calculate Trust Height with 1000 block offset
TRUST_HEIGHT=$((LATEST_HEIGHT - 1000))
BLOCK_JSON=$(curl -s --max-time 10 "${STATE_SYNC_RPC}/block?height=${TRUST_HEIGHT}")
TRUST_HASH=$(echo "${BLOCK_JSON}" | jq -r '.result.block_id.hash // .block_id.hash')

log "State Sync Parameters -> Trust Height: ${TRUST_HEIGHT} | Trust Hash: ${TRUST_HASH}"

# Ensure autheo user owns configuration before running database commands
chown -R "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_HOME}"
chmod -R 755 "${AUTHEO_HOME}"

log "Cleaning light client database and resetting database for State Sync initialization..."
rm -rf "${AUTHEO_HOME}/data/light-client*"
su -s /bin/bash "${AUTHEO_USER}" -c "${AUTHEO_BINARY} comet unsafe-reset-all --home '${AUTHEO_HOME}' --keep-addr-book"

log "Writing State Sync & Persistent Peers to config.toml..."
PERSISTENT_PEERS="${PERSISTENT_PEERS}" \
STATE_SYNC_RPC="${STATE_SYNC_RPC}" \
TRUST_HEIGHT="${TRUST_HEIGHT}" \
TRUST_HASH="${TRUST_HASH}" \
python3 <<'PY'
from pathlib import Path
import os
import re

path = Path("/data/.autheo/config/config.toml")
peers = os.environ["PERSISTENT_PEERS"]
rpc = os.environ["STATE_SYNC_RPC"]
height = os.environ["TRUST_HEIGHT"]
hash_val = os.environ["TRUST_HASH"]

text = path.read_text()

# Inject Persistent Peers
text = re.sub(r'(?m)^\s*persistent_peers\s*=\s*".*"\s*$', f'persistent_peers = "{peers}"', text, count=1)

# Enable State Sync with duplicated dual-RPC configuration for single RPC endpoints
text = re.sub(r'(?m)^\s*enable\s*=\s*(false|true)\s*$', 'enable = true', text, count=1)
text = re.sub(r'(?m)^\s*rpc_servers\s*=\s*".*"\s*$', f'rpc_servers = "{rpc},{rpc}"', text, count=1)
text = re.sub(r'(?m)^\s*trust_height\s*=\s*.*$', f'trust_height = {height}', text, count=1)
text = re.sub(r'(?m)^\s*trust_hash\s*=\s*".*"\s*$', f'trust_hash = "{hash_val}"', text, count=1)
text = re.sub(r'(?m)^\s*trust_period\s*=\s*".*"\s*$', 'trust_period = "168h0m0s"', text, count=1)

path.write_text(text)
PY

############################
# Strict Permission Enforcement
############################

log "Enforcing autheo:autheo ownership and 700 permissions..."
chown -R "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_HOME}"
chmod -R 700 "${AUTHEO_HOME}"

############################
# Systemd Service Creation & Startup
############################

log "Creating systemd unit..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Autheo Mainnet Full Node
After=network-online.target
Wants=network-online.target

[Service]
User=${AUTHEO_USER}
Group=${AUTHEO_GROUP}
ExecStart=${AUTHEO_BINARY} start --home "${AUTHEO_HOME}"
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE_FILE}"
systemctl daemon-reload
systemctl enable autheod.service

log "Starting autheod.service for the first time..."
systemctl restart autheod.service

sleep 2

log "Service started successfully. Streaming live logs (Press Ctrl+C to stop viewing logs)..."
# journalctl -u autheod.service -f -o cat
