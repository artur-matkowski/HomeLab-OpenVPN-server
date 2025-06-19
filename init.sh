#!/bin/bash
# inside entrypoint.sh
host_init.sh "${OPENVPN_HOST_NETWORK}"/24 \
             "$(get_interface.sh "${OPENVPN_NETWORK}")" \
             "$(get_interface.sh "${OPENVPN_HOST_NETWORK}")"
exec /init.sh "$@"

