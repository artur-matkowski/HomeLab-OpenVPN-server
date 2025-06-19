#!/usr/bin/env bash
set -euo pipefail

# ---------- tiny logger ------------------------------------------------------
log() { printf '[host_init] %s %s\n' "$(date '+%F %T')" "$*"; }
# -----------------------------------------------------------------------------

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <VPN_SUBNET> <VPN_INTERFACE> <LAN_INTERFACE>"
  echo "Example: $0 192.168.34.0/24 tun0 eth0"
  exit 1
fi

VPN_SUBNET="$1"   # e.g. 192.168.34.0/24
VPN_INTERFACE="$2" # e.g. tun0
LAN_INTERFACE="$3" # e.g. eth0

###############################################################################
# 1) Ensure IP forwarding is enabled permanently
###############################################################################
if grep -Fxq 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  log "IP forwarding already enabled in /etc/sysctl.conf  – skipping"
else
  echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
  log "Added net.ipv4.ip_forward=1 to /etc/sysctl.conf"
fi

sysctl -p /etc/sysctl.conf >/dev/null
log "IP forwarding active in the running kernel"

###############################################################################
# 2) NAT: masquerade traffic from VPN subnet out of the LAN interface
###############################################################################
if iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$LAN_INTERFACE" -j MASQUERADE 2>/dev/null; then
  log "NAT rule for $VPN_SUBNET via $LAN_INTERFACE already exists – skipping"
else
  iptables -t nat -A POSTROUTING -s "$VPN_SUBNET" -o "$LAN_INTERFACE" -j MASQUERADE
  log "NAT rule added for $VPN_SUBNET via $LAN_INTERFACE"
fi

###############################################################################
# 3) Forwarding rules: VPN ➜ LAN
###############################################################################
if iptables -C FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -s "$VPN_SUBNET" -j ACCEPT 2>/dev/null; then
  log "Forward rule $VPN_INTERFACE → $LAN_INTERFACE already exists – skipping"
else
  iptables -A FORWARD -i "$VPN_INTERFACE" -o "$LAN_INTERFACE" -s "$VPN_SUBNET" -j ACCEPT
  log "Forward rule added: $VPN_INTERFACE → $LAN_INTERFACE"
fi

###############################################################################
# 4) Forwarding rules: LAN ➜ VPN
###############################################################################
if iptables -C FORWARD -o "$VPN_INTERFACE" -i "$LAN_INTERFACE" -d "$VPN_SUBNET" -j ACCEPT 2>/dev/null; then
  log "Forward rule $LAN_INTERFACE → $VPN_INTERFACE already exists – skipping"
else
  iptables -A FORWARD -o "$VPN_INTERFACE" -i "$LAN_INTERFACE" -d "$VPN_SUBNET" -j ACCEPT
  log "Forward rule added: $LAN_INTERFACE → $VPN_INTERFACE"
fi

log "host_init.sh completed successfully"
