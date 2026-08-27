#!/usr/bin/env bash

# Load environment variables from .env file
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Error: .env file not found. Please create one with CF_API_TOKEN and ZONE_ID."
    exit 1
fi

# Validate credentials are present
if [ -z "$CF_API_TOKEN" ] || [ -z "$ZONE_ID" ]; then
    echo "Error: CF_API_TOKEN or ZONE_ID missing in .env file."
    exit 1
fi

# Prompt for interactive inputs
read -p "Enter Domain or Subdomain (e.g., node1.instanodes.io): " DOMAIN_NAME
read -p "Enter Server IP Address: " SERVER_IP

# Validate prompt inputs
if [ -z "$DOMAIN_NAME" ] || [ -z "$SERVER_IP" ]; then
    echo "Error: Both Domain Name and Server IP are required."
    exit 1
fi

echo "==> Pointing ${DOMAIN_NAME} to ${SERVER_IP} with Proxy ON..."

# Make API Call to Cloudflare
RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
     -H "Authorization: Bearer ${CF_API_TOKEN}" \
     -H "Content-Type: application/json" \
     --data '{
       "type": "A",
       "name": "'"${DOMAIN_NAME}"'",
       "content": "'"${SERVER_IP}"'",
       "ttl": 1,
       "proxied": true
     }')

# Check for success status
if echo "$RESPONSE" | grep -q '"success":true'; then
    echo "==> Domain successfully added to Cloudflare and active instantly!"
else
    echo "==> Failed to add DNS record."
    echo "API Response: $RESPONSE"
    exit 1
fi
