#!/bin/bash
# inside entrypoint.sh
host_init.sh "${OPENVPN_NETWORK}"/24 \
             tun0 \
             "$(get_interface.sh "${OPENVPN_HOST_NETWORK}")"
exec /init_vpn.sh "$@"

