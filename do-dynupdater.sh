#!/bin/bash
set -euo pipefail

# Configuration
TOKEN_FILE="token.txt" # DigitalOcean API token file
DOMAIN="${1:-}"        # The domain you want to update
RECORD_NAME="${2:-}"   # The name of the DNS record you want to update
INTERFACE="${3:-}"     # Network interface to get the IP from or 'curl' for public IP
TIMEOUT=10             # Timeout in seconds for API requests

# Validate inputs
if [[ -z "$DOMAIN" || -z "$RECORD_NAME" || -z "$INTERFACE" ]]; then
    echo "Usage: $0 <domain> <record_name> <interface|curl>"
    exit 1
fi

validate_ipv4() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r -a octets <<< "$ip"
    local octet
    for octet in "${octets[@]}"; do
        (( octet <= 255 )) || return 1
    done
}

get_ip_address() {
    if [ "$1" == "curl" ]; then
        # Get public IP using external service
        curl -s https://ipinfo.io/ip --max-time "$TIMEOUT"
    else
        # Get the IP address of the specific interface
        ip addr show "$1" | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}'
    fi
}

is_private_ip() {
    [[ "$1" =~ ^10\. ]] ||
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||
    [[ "$1" =~ ^192\.168\. ]] ||
    [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]
}

# Get the IP address
IP_ADDRESS=$(get_ip_address "$INTERFACE")

# Check if IP address was retrieved successfully
if [ -z "$IP_ADDRESS" ]; then
    echo "Could not get the IP address from the interface: $INTERFACE"
    exit 1
fi

# Validate the IP address format
if ! validate_ipv4 "$IP_ADDRESS"; then
    echo "Invalid IP address received: '$IP_ADDRESS'"
    exit 1
fi

# Check if IP address is private (RFC 1918 or RFC 6598)
if is_private_ip "$IP_ADDRESS"; then
    echo "IP address $IP_ADDRESS is a private (RFC 1918) or shared (RFC 6598) address. Exiting."
    exit 1
fi

# Read the token from the token file
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(< "$TOKEN_FILE")
else
    echo "Token file does not exist: $TOKEN_FILE"
    exit 1
fi

# File to store the last IP address, named after the interface
IP_FILE="${INTERFACE}.txt"

# Read the last IP address from the file
if [[ -f "$IP_FILE" ]]; then
    LAST_IP=$(< "$IP_FILE")
else
    LAST_IP=""
fi

# If the IP address hasn't changed, there is nothing to do
if [ "$LAST_IP" == "$IP_ADDRESS" ]; then
    echo "IP address has not changed. No update needed."
    exit 0
fi

# Create a temp file for curl response bodies; clean it up on exit
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# Get the DNS record ID
HTTP_CODE=$(curl -s -o "$TMP_FILE" -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    "https://api.digitalocean.com/v2/domains/$DOMAIN/records" \
    --max-time "$TIMEOUT")

if [[ "$HTTP_CODE" != "200" ]]; then
    echo "Failed to fetch DNS records (HTTP $HTTP_CODE)"
    exit 1
fi

RECORD_ID=$(jq -r ".domain_records[] | select(.name == \"$RECORD_NAME\") | .id" < "$TMP_FILE")

# Check if record ID was retrieved successfully
if [ -z "$RECORD_ID" ]; then
    echo "Could not get the record ID for record name: $RECORD_NAME"
    exit 1
fi

# Update the DNS record using DigitalOcean API
HTTP_CODE=$(curl -s -o "$TMP_FILE" -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"data\":\"$IP_ADDRESS\"}" \
    "https://api.digitalocean.com/v2/domains/$DOMAIN/records/$RECORD_ID" \
    --max-time "$TIMEOUT")

# Check if the update was successful
if [[ "$HTTP_CODE" == "200" ]]; then
    echo "DNS record updated successfully."
    # Atomic file write
    echo "$IP_ADDRESS" > "${IP_FILE}.tmp" && mv "${IP_FILE}.tmp" "$IP_FILE"
else
    echo "Failed to update DNS record (HTTP $HTTP_CODE)"
    exit 1
fi
