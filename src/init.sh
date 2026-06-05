#!/bin/bash
set -e

# Host-side setup: IP forwarding + DOCKER-USER ACCEPT for tun↔tun.
#
# This affects the *host* kernel and *host* iptables even though it runs
# inside the container. That works because docker-compose.yml sets
#   network_mode: host   — container shares the host's network namespace
#   privileged: true     — grants CAP_NET_ADMIN and friends
# So `iptables` and `sysctl -w` here touch the same kernel state the host
# sees. No systemd unit on the host is needed; `restart: unless-stopped`
# + docker auto-start on boot re-applies everything on reboots.
/usr/local/bin/host_init.sh tun0 \
    "${OPENVPN_NETWORK:-192.168.75.0}/24" \
    "${OPENVPN_HOST_NETWORK:-192.168.74.0}/24"

exec /init_vpn.sh "$@"
