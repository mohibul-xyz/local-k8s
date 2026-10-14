#!/usr/bin/env bash
# Creates/configures the VirtualBox host-only network the VMs live on.
# Run as your normal user (VirtualBox keeps DHCP server config per user).
#
# Usage: scripts/vbox-network.sh
# Override with env vars: IFACE, HOST_IP, NETMASK, DHCP_SERVER, DHCP_LOWER, DHCP_UPPER
set -euo pipefail

IFACE="${IFACE:-vboxnet0}"
HOST_IP="${HOST_IP:-192.168.56.1}"
NETMASK="${NETMASK:-255.255.255.0}"
DHCP_SERVER="${DHCP_SERVER:-192.168.56.2}"
DHCP_LOWER="${DHCP_LOWER:-192.168.56.100}"
DHCP_UPPER="${DHCP_UPPER:-192.168.56.199}"

if ! VBoxManage list hostonlyifs | grep -qE "^Name:[[:space:]]+${IFACE}\$"; then
  echo "Creating host-only interface..."
  created="$(VBoxManage hostonlyif create | sed -n "s/.*'\(.*\)'.*/\1/p")"
  if [[ "$created" != "$IFACE" ]]; then
    echo "error: VirtualBox created '$created', not '$IFACE'. Set IFACE=$created here and host_only_interface in terraform.tfvars." >&2
    exit 1
  fi
fi

echo "Setting $IFACE to $HOST_IP/$NETMASK"
VBoxManage hostonlyif ipconfig "$IFACE" --ip="$HOST_IP" --netmask="$NETMASK"

# VMs get a DHCP address on first boot (the provider waits for one), then
# Ansible moves them to their fixed IP outside this range.
dhcp_args=(--interface="$IFACE" --server-ip="$DHCP_SERVER" --netmask="$NETMASK"
  --lower-ip="$DHCP_LOWER" --upper-ip="$DHCP_UPPER" --enable)
if VBoxManage list dhcpservers | grep -qE "HostInterfaceNetworking-${IFACE}\$"; then
  VBoxManage dhcpserver modify "${dhcp_args[@]}"
else
  VBoxManage dhcpserver add "${dhcp_args[@]}"
fi

echo "Done: $IFACE = $HOST_IP, DHCP $DHCP_LOWER-$DHCP_UPPER. Use fixed IPs outside that range."
