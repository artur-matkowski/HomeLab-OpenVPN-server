#!/usr/bin/env bash
#
# generate_client.sh  –  create a client certificate and .ovpn profile
#                       Server addresses come from /etc/openvpn/server-list/server-*.txt
#                       (lower number = higher priority)
#
#   Usage: generate_client.sh <client_name>     (run with a TTY: docker exec -it)
#
#   The script INTERACTIVELY asks whether this client should get a hardcoded
#   (static) tunnel IP and, if so, for the host octet only — the network prefix
#   is fixed by OPENVPN_NETWORK. A static IP is pinned via a CCD `ifconfig-push`
#   so you always know who connects on which address (for static routes over the
#   VPN). The pfSense site client is exempt: its IP is owned by PFSENSE_CLIENT_IP
#   in docker-compose.yml, so the prompt is skipped for that CN.
#
set -e
set -x                                      # verbose for debugging

# Shared IPv4 helpers (valid_ipv4 / is_assignable_host / ip_in_range).
. /usr/local/lib/lib_net.sh

###############################################################################
# 1.  Parse CLI
###############################################################################
CLIENT=${1:-}
if [[ -z "$CLIENT" ]]; then
    echo "Usage: $0 <client_name>   (interactive; run with: docker exec -it ...)"
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

# Network defaults — must mirror init_vpn.sh so the static/dynamic split tested
# here matches the `ifconfig-pool` the running server actually enforces. These
# arrive from docker-compose.yml: `docker exec` inherits the container's env.
: "${OPENVPN_NETWORK:=192.168.1.0}"
: "${OPENVPN_NETMASK:=255.255.255.0}"
_SUBNET_PREFIX="${OPENVPN_NETWORK%.*}"
: "${OPENVPN_POOL_START:=${_SUBNET_PREFIX}.128}"
: "${OPENVPN_POOL_END:=${_SUBNET_PREFIX}.254}"
: "${PFSENSE_CLIENT_CN:=pfsense-site}"

###############################################################################
# 2b. Interactively decide the client's tunnel IP (static pin vs dynamic lease)
###############################################################################
# Ends with CLIENT_IP either empty (dynamic lease) or a validated static address.
CLIENT_IP=""

# Displayable static-range bounds (host octets). The static range is everything
# below the dynamic pool; the real gate is the lib_net validation in the loop.
_POOL_START_OCTET=${OPENVPN_POOL_START##*.}
_STATIC_MIN_OCTET=2                                   # .0 = network, .1 = hub
_STATIC_MAX_OCTET=$(( _POOL_START_OCTET - 1 ))

# is_ip_taken <ip> -> 0 if some OTHER client's CCD file already pins this IP.
# Sets TAKEN_BY to that client's name. Lets us guarantee a 1:1 IP↔client map.
is_ip_taken() {
    local ip=$1 esc f
    esc=${ip//./\\.}
    [ -d /etc/openvpn/ccd ] || return 1
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ "$(basename "$f")" = "$CLIENT" ] && continue    # our own pin: fine
        TAKEN_BY=$(basename "$f")
        return 0
    done < <(grep -rlE "^[[:space:]]*ifconfig-push[[:space:]]+${esc}"'([[:space:]]|$)' \
             /etc/openvpn/ccd/ 2>/dev/null || true)
    return 1
}

if [[ "$CLIENT" == "$PFSENSE_CLIENT_CN" ]]; then
    echo "Note: '$CLIENT' is the pfSense site client — its tunnel IP is set by"
    echo "      PFSENSE_CLIENT_IP in docker-compose.yml. Skipping the static-IP prompt."
else
    set +x                                            # keep prompts readable
    if [ ! -t 0 ]; then
        echo "ERROR: generate_client.sh is interactive — run it with a TTY:" >&2
        echo "       docker exec -it openvpn-hub generate_client.sh $CLIENT" >&2
        exit 1
    fi

    read -r -p "Assign a static tunnel IP to '$CLIENT'? [Y/n] " _ans
    case "${_ans,,}" in
        n|no)
            echo "→ '$CLIENT' will get a dynamic IP from the pool (${OPENVPN_POOL_START}-${OPENVPN_POOL_END})."
            ;;
        *)  # default (empty) = Yes; loop until a valid, free octet is entered
            while true; do
                read -r -p "  Host octet for ${_SUBNET_PREFIX}.?  [${_STATIC_MIN_OCTET}-${_STATIC_MAX_OCTET}]: " _octet
                if ! [[ "$_octet" =~ ^[0-9]{1,3}$ ]]; then
                    echo "  ✗ '${_octet}' is not a 1–3 digit number — try again."; continue
                fi
                _octet=$(( 10#$_octet ))              # force base-10 (avoid octal on leading 0)
                _cand="${_SUBNET_PREFIX}.${_octet}"
                if ! valid_ipv4 "$_cand"; then
                    echo "  ✗ ${_octet} is out of range (0–255)."; continue
                fi
                if ! is_assignable_host "$_cand" "$OPENVPN_NETWORK" "$OPENVPN_NETMASK"; then
                    echo "  ✗ ${_cand} is reserved (network, broadcast, or the hub's .1)."; continue
                fi
                if ip_in_range "$_cand" "$OPENVPN_POOL_START" "$OPENVPN_POOL_END"; then
                    echo "  ✗ ${_cand} is in the dynamic pool — pick ${_STATIC_MIN_OCTET}–${_STATIC_MAX_OCTET}."; continue
                fi
                if is_ip_taken "$_cand"; then
                    echo "  ✗ ${_cand} is already pinned to '${TAKEN_BY}' — choose another."; continue
                fi
                CLIENT_IP="$_cand"
                echo "→ '$CLIENT' will be pinned to ${CLIENT_IP}."
                break
            done
            ;;
    esac
    set -x                                            # restore verbose logging
fi

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

###############################################################################
# 6.  (Optional) pin the client to its static tunnel IP via CCD
###############################################################################
# Written only when a static IP was given. The filename MUST equal the cert CN
# (= $CLIENT) for OpenVPN to match the CCD file. `topology subnet` means the
# second ifconfig-push arg is the subnet netmask, not a peer address. To revert
# a client to a dynamic lease, delete /etc/openvpn/ccd/<name>.
if [[ -n "$CLIENT_IP" ]]; then
    mkdir -p /etc/openvpn/ccd
    cat > /etc/openvpn/ccd/"$CLIENT" <<EOF
# Static tunnel IP for ${CLIENT} (generated by generate_client.sh).
ifconfig-push ${CLIENT_IP} ${OPENVPN_NETMASK}
EOF
    echo "✓ Pinned ${CLIENT} → ${CLIENT_IP} (CCD: /etc/openvpn/ccd/${CLIENT})"
fi
