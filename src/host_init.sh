#!/usr/bin/env bash
set -euo pipefail

# Run on the VPS host (NOT inside the container) once per boot.
# Idempotent — safe to re-run.
#
# Two responsibilities:
#   1. Make IP forwarding persistent.
#   2. Allow tun0↔tun0 traffic past Docker's default-DROP FORWARD policy.
#
# Why DOCKER-USER and not FORWARD:
#   When the docker daemon starts, it sets `iptables -P FORWARD DROP` and
#   inserts its own chains (DOCKER-USER, DOCKER-FORWARD, …) at the top of
#   FORWARD. DOCKER-USER is the chain Docker promises never to touch — it
#   exists specifically for site-local rules. Putting our ACCEPT here means:
#     - it survives `systemctl restart docker` and container recreation,
#     - it is evaluated before any docker-managed rules,
#     - we never need to fight ordering with `-I FORWARD 1`.
#
# We deliberately use a blanket `-i tun0 -o tun0 -j ACCEPT`. The hub's only
# job is to relay packets between tun endpoints (road-warrior ↔ pfSense site
# ↔ road-warrior). Any tun0→tun0 packet is by definition VPN traffic that
# must pass; per-host/port filtering belongs on pfSense, not here.

log() { printf '[host_init] %s %s\n' "$(date '+%F %T')" "$*"; }

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <VPN_INTERFACE> [<VPN_SUBNET>] [<LAN_SUBNET>]"
  echo "Example: $0 tun0 192.168.75.0/24 192.168.74.0/24"
  echo "  Subnet args are informational only (logged for the operator)."
  exit 1
fi

VPN_INTERFACE="$1"             # e.g. tun0
VPN_SUBNET="${2:-<unset>}"     # informational
LAN_SUBNET="${3:-<unset>}"     # informational

# 1) Permanent IP forwarding ---------------------------------------------------
if grep -Fxq 'net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  log "IP forwarding already enabled in /etc/sysctl.conf – skipping"
else
  echo 'net.ipv4.ip_forward=1' | tee -a /etc/sysctl.conf >/dev/null
  log "Added net.ipv4.ip_forward=1 to /etc/sysctl.conf"
fi
sysctl -p /etc/sysctl.conf >/dev/null
log "IP forwarding active in the running kernel"

# 2) Ensure DOCKER-USER chain exists ------------------------------------------
# It only appears once docker has started at least once. Create it ourselves
# if absent, so this script also works on first-boot orderings where docker
# hasn't started yet (the daemon will reuse our chain, not replace it).
if ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  iptables -N DOCKER-USER
  iptables -I FORWARD -j DOCKER-USER
  log "Created empty DOCKER-USER chain (docker daemon not yet started)"
fi

# 3) tun↔tun ACCEPT in DOCKER-USER --------------------------------------------
if iptables -C DOCKER-USER -i "$VPN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT 2>/dev/null; then
  log "$VPN_INTERFACE↔$VPN_INTERFACE rule already in DOCKER-USER – skipping"
else
  # Insert at the top so it's evaluated before any later additions.
  iptables -I DOCKER-USER 1 -i "$VPN_INTERFACE" -o "$VPN_INTERFACE" -j ACCEPT
  log "Inserted ACCEPT for $VPN_INTERFACE↔$VPN_INTERFACE in DOCKER-USER (covers VPN $VPN_SUBNET ↔ LAN $LAN_SUBNET and intra-VPN)"
fi

log "host_init.sh completed successfully"
