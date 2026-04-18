#!/usr/bin/env bash
set -euo pipefail

# Run on the Hetzner host (NOT inside the container), once per boot, to enable
# IP forwarding and allow tun0↔tun0 traffic between the VPN client subnet and
# the LAN subnet pushed via the pfSense site-client's iroute.

log() { printf '[host_init] %s %s\n' "$(date '+%F %T')" "$*"; }

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <VPN_SUBNET> <LAN_SUBNET> <VPN_INTERFACE>"
  echo "Example: $0 192.168.75.0/24 192.168.74.0/24 tun0"
  exit 1
fi

VPN_SUBNET="$1"     # e.g. 192.168.75.0/24 — OpenVPN client pool
LAN_SUBNET="$2"     # e.g. 192.168.74.0/24 — home LAN behind pfSense
VPN_INTERFACE="$3"  # e.g. tun0

# 1) Permanent IP forwarding
if grep -Fxq 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  log "IP forwarding already enabled in /etc/sysctl.conf – skipping"
else
  echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
  log "Added net.ipv4.ip_forward=1 to /etc/sysctl.conf"
fi
sysctl -p /etc/sysctl.conf >/dev/null
log "IP forwarding active in the running kernel"

# 2) FORWARD rules: symmetric, tun0↔tun0 between VPN subnet and LAN subnet.
#    No MASQUERADE — return path goes through pfSense, not Hetzner's WAN.
add_rule() {
  local src="$1" dst="$2"
  if iptables -C FORWARD -i "$VPN_INTERFACE" -o "$VPN_INTERFACE" -s "$src" -d "$dst" -j ACCEPT 2>/dev/null; then
    log "Forward rule $src → $dst already exists – skipping"
  else
    iptables -A FORWARD -i "$VPN_INTERFACE" -o "$VPN_INTERFACE" -s "$src" -d "$dst" -j ACCEPT
    log "Forward rule added: $src → $dst"
  fi
}

add_rule "$VPN_SUBNET" "$LAN_SUBNET"
add_rule "$LAN_SUBNET" "$VPN_SUBNET"

log "host_init.sh completed successfully"
