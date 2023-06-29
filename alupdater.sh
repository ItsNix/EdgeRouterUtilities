#!/usr/bin/env bash
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

# Function to create an address group
create_address_group() {
  logger "Creating $address_group address group."
  "$vcfg" begin
  "$vcfg" set firewall group address-group "$address_group" description "$description"
  for ip in "${resolved_ips[@]}"; do
    "$vcfg" set firewall group address-group "$address_group" address "$ip"
  done
  "$vcfg" commit
  "$vcfg" save
  "$vcfg" end
}

# Function to update an address group
update_address_group() {
  logger "Trusted WAN IPs changed. Updating $address_group address group."
  "$vcfg" begin
  "$vcfg" delete firewall group address-group "$address_group"
  "$vcfg" set firewall group address-group "$address_group" description "$description"
  for ip in "${resolved_ips[@]}"; do
    "$vcfg" set firewall group address-group "$address_group" address "$ip"
  done
  "$vcfg" commit
  "$vcfg" save
  "$vcfg" end
}

# Resolve trusted hostnames
resolved_ips=($(getent hosts "${hostnames[@]}" | awk '{ print $1 }'))

# Add static IPs to resolved IPs
resolved_ips+=("${static_ips[@]}")

# Check if address group exists
if "$vop" show firewall group "$address_group" | grep -q "Group \[$address_group\] has not been defined"; then
  create_address_group
  exit 0
fi

# Get current list of addresses in the address group
current_addresses=($("$vop" show firewall group "$address_group" | grep -A5 Members | grep -v Members | awk '{ print $1 }'))

# Match address group IPs against resolved IPs
matched_ips=($(comm -12 <(printf '%s\n' "${current_addresses[@]}" | LC_ALL=C sort) <(printf '%s\n' "${resolved_ips[@]}" | LC_ALL=C sort)))

# Update address group if IPs changed
if [[ ${#matched_ips[@]} -ne ${#current_addresses[@]} ]] || [[ ${#matched_ips[@]} -ne ${#resolved_ips[@]} ]]; then
  update_address_group
fi
