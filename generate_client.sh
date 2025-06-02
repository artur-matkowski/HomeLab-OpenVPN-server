#!/usr/bin/env bash
#
# generate_client.sh  –  create a client certificate and .ovpn profile
#                       Server addresses come from /etc/openvpn/server-list/server-*.txt
#                       (lower number = higher priority)
#
set -e
set -x                                      # verbose for debugging

###############################################################################
# 1.  Parse CLI
###############################################################################
CLIENT=${1:-}
if [[ -z "$CLIENT" ]]; then
    echo "Usage: $0 <client_name>"
    exit 1
fi

###############################################################################
# 2.  (Optional) certificate-request defaults
###############################################################################
: "${OPENVPN_PROTO:=udp}"
: "${OPENVPN_SERVER_CN:=MyVPN CA}"
: "${OPENVPN_COUNTRY:=US}"
: "${OPENVPN_PROVINCE:=State}"
: "${OPENVPN_CITY:=City}"
: "${OPENVPN_ORG:=MyVPN Org}"
: "${OPENVPN_EMAIL:=admin@example.com}"
: "${OPENVPN_OU:=MyVPN Unit}"

###############################################################################
# 3.  Build client certificate
###############################################################################
cd /etc/openvpn/easy-rsa

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="$CLIENT"
export EASYRSA_REQ_COUNTRY="$OPENVPN_COUNTRY"
export EASYRSA_REQ_PROVINCE="$OPENVPN_PROVINCE"
export EASYRSA_REQ_CITY="$OPENVPN_CITY"
export EASYRSA_REQ_ORG="$OPENVPN_ORG"
export EASYRSA_REQ_EMAIL="$OPENVPN_EMAIL"
export EASYRSA_REQ_OU="$OPENVPN_OU"

./easyrsa build-client-full "$CLIENT" nopass

###############################################################################
# 4.  Assemble list of remote servers
###############################################################################
REMOTE_LINES=""
SERVER_LIST_DIR="/etc/openvpn/server-list"

if compgen -G "${SERVER_LIST_DIR}/server-*.txt" >/dev/null; then
    # Use version sort (-V) so that 2 < 10
    for FILE in $(ls "${SERVER_LIST_DIR}/server-"*.txt | sort -V); do
        # Each line in the file should be: "<address> <port>"
        while read -r ADDR PORT _; do
            [[ -z "$ADDR" || -z "$PORT" ]] && continue   # skip empty or malformed
            REMOTE_LINES+="remote ${ADDR} ${PORT}"$'\n'
        done < "$FILE"
    done
else
    echo "ERROR: No server list files found in ${SERVER_LIST_DIR}"
    exit 1
fi

###############################################################################
# 5.  Create client configuration
###############################################################################
OUT_DIR=/etc/openvpn/clients
mkdir -p "$OUT_DIR"

cat > "${OUT_DIR}/${CLIENT}.ovpn" <<EOF
client
dev   tun
proto $OPENVPN_PROTO

# --- Remote servers (priority order) ---
${REMOTE_LINES%\\n}

resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server

auth   SHA256
cipher AES-256-CBC
verb   3
pull-filter ignore "redirect-gateway"

<ca>
$(cat /etc/openvpn/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/pki/issued/${CLIENT}.crt)
</cert>
<key>
$(cat /etc/openvpn/pki/private/${CLIENT}.key)
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
key-direction 1
EOF

echo "✓ Client config created: ${OUT_DIR}/${CLIENT}.ovpn"
