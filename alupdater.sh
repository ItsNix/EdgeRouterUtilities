#!/usr/bin/env bash
set -eo pipefail

vop="/opt/vyatta/bin/vyatta-op-cmd-wrapper"
vcfg="/opt/vyatta/sbin/vyatta-cfg-cmd-wrapper"

# Address group variables
address_group="Trusted"
description="Trusted IP Addresses"

# Hostnames to look up
hostnames=("ad.asdf.com" "bbb.live" "ccc.ddd.xyz")

# Static IPs to add to address group
static_ips=()

# Set the PATH environment variable
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Ensure the config session is ended even if a command fails
_cfg_cleanup() {
  "$vcfg" end 2>/dev/null || true
}

# Function to create an address group
create_address_group() {
  logger "Creating $address_group address group."
  "$vcfg" begin
  trap _cfg_cleanup EXIT
  "$vcfg" set firewall group address-group "$address_group" description "$description"
  for ip in "${resolved_ips[@]}"; do
    "$vcfg" set firewall group address-group "$address_group" address "$ip"
  done
  "$vcfg" commit
  "$vcfg" save
  trap - EXIT
  "$vcfg" end
}

# Function to update an address group
update_address_group() {
  logger "$address_group IPs changed. Updating address group."
  "$vcfg" begin
  trap _cfg_cleanup EXIT
  "$vcfg" delete firewall group address-group "$address_group"
  "$vcfg" set firewall group address-group "$address_group" description "$description"
  for ip in "${resolved_ips[@]}"; do
    "$vcfg" set firewall group address-group "$address_group" address "$ip"
  done
  "$vcfg" commit
  "$vcfg" save
  trap - EXIT
  "$vcfg" end
}

# Resolve trusted hostnames
mapfile -t resolved_ips < <(getent hosts "${hostnames[@]}" | awk '{ print $1 }')

# Add static IPs to resolved IPs
resolved_ips+=("${static_ips[@]}")

# Guard against empty resolution
if [[ ${#resolved_ips[@]} -eq 0 ]]; then
  logger "No IPs resolved for $address_group address group. Exiting without changes."
  exit 1
fi

# Check if address group exists
if "$vop" show firewall group "$address_group" | grep -q "Group \[$address_group\] has not been defined"; then
  create_address_group
  exit 0
fi

# Get current list of addresses in the address group
mapfile -t current_addresses < <("$vop" show firewall group "$address_group" | awk '/Members/{found=1; next} found && NF{print $1}')

# Match address group IPs against resolved IPs
mapfile -t matched_ips < <(comm -12 \
  <(printf '%s\n' "${current_addresses[@]}" | LC_ALL=C sort) \
  <(printf '%s\n' "${resolved_ips[@]}" | LC_ALL=C sort))

# Update address group if IPs changed
if [[ ${#matched_ips[@]} -ne ${#current_addresses[@]} ]] || [[ ${#matched_ips[@]} -ne ${#resolved_ips[@]} ]]; then
  update_address_group
fi
