#!/bin/bash

# Configuration
TOKEN_FILE="token.txt" # DigitalOcean API token file
DOMAIN=$1 # The domain you want to update
RECORD_NAME=$2 # The name of the DNS record you want to update
INTERFACE=$3 # Network interface to get the IP from or 'curl' for public IP
TIMEOUT=10 # Timeout in seconds for API requests

# Validate inputs
if [[ -z "$DOMAIN" || -z "$RECORD_NAME" || -z "$INTERFACE" ]]; then
    echo "Usage: $0 <domain> <record_name> <interface>"
    exit 1
fi

get_ip_address() {
    if [ "$1" == "curl" ]; then
        # Get public IP using external service
        curl -s http://ipinfo.io/ip --max-time $TIMEOUT
    else
        # Get the IP address of the specific interface
        ip addr show $1 | grep 'inet ' | awk '{print $2}' | cut -f1 -d'/'
    fi
}

is_private_ip() {
    [[ "$1" =~ ^10\. ]] ||
    [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||
    [[ "$1" =~ ^192\.168\. ]] ||
    [[ "$1" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]
}

# Get the IP address
IP_ADDRESS=$(get_ip_address $INTERFACE)

# Check if IP address was retrieved successfully
if [ -z "$IP_ADDRESS" ]; then
    echo "Could not get the IP address from the interface: $INTERFACE"
    exit 1
fi

# Check if IP address is private (RFC 1918 or RFC 6598)
if is_private_ip "$IP_ADDRESS"; then
    echo "IP address $IP_ADDRESS is a private (RFC 1918) or shared (RFC 6598) address. Exiting."
    exit 1
fi

# Read the token from the token file
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(cat "$TOKEN_FILE")
else
    echo "Token file does not exist: $TOKEN_FILE"
    exit 1
fi

# File to store the last IP address, named after the interface
IP_FILE="${INTERFACE}.txt"

# Read the last IP address from the file
if [[ -f "$IP_FILE" ]]; then
    LAST_IP=$(cat "$IP_FILE")
else
    LAST_IP=""
fi

# If the IP address hasn't changed, there is nothing to do
if [ "$LAST_IP" == "$IP_ADDRESS" ]; then
    echo "IP address has not changed. No update needed."
    exit 0
fi

# Get the DNS record ID
RECORD_ID=$(curl -s -X GET -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    "https://api.digitalocean.com/v2/domains/$DOMAIN/records" --max-time $TIMEOUT | jq -r ".domain_records[] | select(.name == \"$RECORD_NAME\") | .id")

# Check if record ID was retrieved successfully
if [ -z "$RECORD_ID" ]; then
    echo "Could not get the record ID for record name: $RECORD_NAME"
    exit 1
fi

# Update the DNS record using DigitalOcean API
RESPONSE=$(curl -s -X PUT -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d "{\"data\":\"$IP_ADDRESS\"}" "https://api.digitalocean.com/v2/domains/$DOMAIN/records/$RECORD_ID" --max-time $TIMEOUT)

# Check if the update was successful
if [[ "$RESPONSE" == *'"message":"Unauthorized"'* ]]; then
    echo "Failed to update DNS record: Unauthorized"
    exit 1
elif [[ "$RESPONSE" == *'"domain_record":'* ]]; then
    echo "DNS record updated successfully."
    # Atomic file write
    echo "$IP_ADDRESS" > "${IP_FILE}.tmp" && mv "${IP_FILE}.tmp" "$IP_FILE"
else
    echo "Failed to update DNS record for an unknown reason."
    exit 1
fi
