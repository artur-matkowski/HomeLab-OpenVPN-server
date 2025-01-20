#!/bin/bash
set -e
set -x

# This script enables IP forwarding, sets up NAT, and adds
# iptables rules to allow forwarding between a VPN interface and LAN.
#
# Usage:
#   ./host_init.sh <VPN_SUBNET> <VPN_INTERFACE> <LAN_INTERFACE>
# Example:
#   ./host_init.sh 192.168.34.0/24 tun0 eth0

if [ $# -lt 3 ]; then
  echo "Usage: $0 <VPN_SUBNET> <VPN_INTERFACE> <LAN_INTERFACE>"
  echo "Example: $0 192.168.34.0/24 tun0 eth0"
  exit 1
fi

VPN_SUBNET="$1"
VPN_INTERFACE="$2"
LAN_INTERFACE="$3"

# 1) Enable IP forwarding in /etc/sysctl.conf if not already set
if grep -Fxq "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "IP forwarding already enabled in /etc/sysctl.conf"
else
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

# 2) Reload sysctl settings
sudo sysctl -p /etc/sysctl.conf
echo "IP forwarding enabled on the host!"

# 3) Set up NAT (POSTROUTING) for the VPN subnet through the LAN interface
sudo iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$LAN_INTERFACE" -j MASQUERADE
echo "NAT rule added for $VPN_SUBNET via $LAN_INTERFACE"

# 4) Allow forwarding between VPN interface and LAN interface
sudo iptables -A FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -s "$VPN_SUBNET" -j ACCEPT
sudo iptables -A FORWARD -o "$VPN_INTERFACE" -i "$LAN_INTERFACE" -d "$VPN_SUBNET" -j ACCEPT
echo "Forwarding rules added between $VPN_INTERFACE <-> $LAN_INTERFACE"