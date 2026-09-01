#!/bin/bash

set -e

echo "========================================="
echo " Autheo Nginx Reverse Proxy Setup"
echo " Ubuntu 22.04"
echo "========================================="

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run this script as root."
    echo "Example: sudo bash install-autheo-nginx.sh"
    exit 1
fi

echo ""
echo "[1/7] Updating package list..."
apt-get update -y

echo ""
echo "[2/7] Installing Nginx..."
apt-get install -y nginx

echo ""
echo "[3/7] Creating Autheo Nginx configuration..."

cat > /etc/nginx/sites-available/autheo.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    # =========================================================
    # EVM RPC
    #
    # Public:
    #   /evm/
    #
    # Internal:
    #   127.0.0.1:8545/
    #
    # The trailing "/" on proxy_pass removes /evm/ from the
    # request before sending it to the EVM service.
    # =========================================================

    location = /evm {
        return 301 /evm/;
    }

    location /evm/ {
        proxy_pass http://127.0.0.1:8545/;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }


    # =========================================================
    # Tendermint / Autheo API
    #
    # Everything else goes to port 26657.
    #
    # Examples:
    #   /status
    #   /health
    #   /net_info
    #   /block
    #   /blockchain
    #   /commit
    #   /validators
    #   /tx
    # =========================================================

    location / {
        proxy_pass http://127.0.0.1:26657;

        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

echo ""
echo "[4/7] Enabling Autheo configuration..."

ln -sf /etc/nginx/sites-available/autheo.conf \
       /etc/nginx/sites-enabled/autheo.conf

echo ""
echo "[5/7] Removing default Nginx site..."

rm -f /etc/nginx/sites-enabled/default

echo ""
echo "[6/7] Testing Nginx configuration..."

nginx -t

echo ""
echo "[7/7] Starting and enabling Nginx..."

systemctl daemon-reload
systemctl enable nginx
systemctl restart nginx

echo ""
echo "========================================="
echo " Nginx Setup Completed Successfully"
echo "========================================="

echo ""
echo "Nginx service status:"
systemctl --no-pager --full status nginx

echo ""
echo "Enabled configuration:"
ls -la /etc/nginx/sites-enabled/

echo ""
echo "Listening ports:"
ss -lntp | grep ':80' || true

echo ""
echo "========================================="
echo " Endpoints"
echo "========================================="
echo "EVM RPC      : http://SERVER-IP/evm/"
echo "Autheo API   : http://SERVER-IP/status"
echo "Health       : http://SERVER-IP/health"
echo "========================================="
