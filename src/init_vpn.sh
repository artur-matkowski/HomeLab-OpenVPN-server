#!/bin/bash

set -e
set -x  # Enable verbose logging for debugging

# Shared IPv4 helpers (ip2int / valid_ipv4 / is_assignable_host / ip_in_range).
. /usr/local/lib/lib_net.sh

# Optional environment variables with defaults
: "${SERVER_ADDRESS:=internal.net}"
: "${SERVER_LISTENING_PORT:=1194}"
: "${SERVER_FALLBACK_PRIORITY:=0}"
: "${OPENVPN_PROTO:=udp}"
: "${OPENVPN_NETWORK:=192.168.1.0}"
: "${OPENVPN_NETMASK:=255.255.255.0}"
: "${OPENVPN_HOST_NETWORK:=192.168.0.0}"
: "${OPENVPN_HOST_NETMASK:=255.255.255.0}"
: "${VPN_DNS:=8.8.4.4}"

# Address-pool split (the subnet prefix is derived from OPENVPN_NETWORK so the
# defaults track the configured /24). Dynamic clients are leased from
# [POOL_START, POOL_END]; everything below POOL_START (i.e. .2 – .127 by
# default, since the hub owns .1) is reserved for hardcoded static IPs assigned
# via CCD `ifconfig-push`. Reserving the range here means a dynamic client can
# never be handed an address that belongs to a (possibly offline) static client.
_SUBNET_PREFIX="${OPENVPN_NETWORK%.*}"
: "${OPENVPN_POOL_START:=${_SUBNET_PREFIX}.128}"
: "${OPENVPN_POOL_END:=${_SUBNET_PREFIX}.254}"
# Fixed tunnel IP for the pfSense site client (must be in the static range).
: "${PFSENSE_CLIENT_IP:=${_SUBNET_PREFIX}.2}"
: "${OPENVPN_SERVER_CN:=MyVPN CA}"
: "${OPENVPN_COUNTRY:=US}"
: "${OPENVPN_PROVINCE:=LS}"
: "${OPENVPN_CITY:=Ol}"
: "${OPENVPN_ORG:=MyVPN Org}"
: "${OPENVPN_EMAIL:=admin@example.com}"
: "${OPENVPN_OU:=MyVPN Unit}"
: "${PFSENSE_CLIENT_CN:=pfsense-site}"

# We do NOT enable IP forwarding here, that’s done on the host
# sysctl -w net.ipv4.ip_forward=1

# Initialize PKI if not already existing
if [ ! -f "/etc/openvpn/pki/ca.crt" ]; then
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="$OPENVPN_SERVER_CN"
    export EASYRSA_REQ_COUNTRY="$OPENVPN_COUNTRY"
    export EASYRSA_REQ_PROVINCE="$OPENVPN_PROVINCE"
    export EASYRSA_REQ_CITY="$OPENVPN_CITY"
    export EASYRSA_REQ_ORG="$OPENVPN_ORG"
    export EASYRSA_REQ_EMAIL="$OPENVPN_EMAIL"
    export EASYRSA_REQ_OU="$OPENVPN_OU"

    make-cadir /etc/openvpn/easy-rsa
    cd /etc/openvpn/easy-rsa

    # Build PKI
    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-dh
    openvpn --genkey --secret /etc/openvpn/ta.key

    # Build server cert
    export EASYRSA_REQ_CN="$SERVER_ADDRESS"
    ./easyrsa build-server-full "$SERVER_ADDRESS" nopass

    # Copy relevant files
    cp pki/ca.crt pki/private/ca.key pki/issued/"$SERVER_ADDRESS".crt \
       pki/private/"$SERVER_ADDRESS".key pki/dh.pem /etc/openvpn/
    cp /etc/openvpn/ta.key /etc/openvpn/
fi

# Ensure an enforceable CRL exists (revocation support; see revoke_client.sh).
# Bootstrap an (empty) CRL on first run and on existing deployments that predate
# revocation support, then publish a world-readable copy that the dropped-
# privilege (user nobody) openvpn process can re-read on every new connection
# (pki/crl.pem is 0600 root and pki/ is 0700, so the copy under /etc/openvpn is
# the only path nobody can read). All non-fatal: a CRL hiccup must not stop the
# hub — if the published copy is absent, crl-verify is simply omitted below.
if [ -f /etc/openvpn/pki/ca.crt ]; then
    if [ ! -f /etc/openvpn/pki/crl.pem ]; then
        ( cd /etc/openvpn/easy-rsa && EASYRSA_BATCH=1 ./easyrsa gen-crl ) \
            || echo "WARNING: could not generate CRL; revocation will be disabled." >&2
    fi
    if [ -f /etc/openvpn/pki/crl.pem ]; then
        install -m 0644 /etc/openvpn/pki/crl.pem /etc/openvpn/crl.pem \
            || echo "WARNING: could not publish /etc/openvpn/crl.pem." >&2
    fi
fi

# Emit crl-verify only when the published CRL exists, so a PKI without one can
# never break server startup.
CRL_DIRECTIVE=""
if [ -f /etc/openvpn/crl.pem ]; then
    CRL_DIRECTIVE="crl-verify /etc/openvpn/crl.pem"
fi

mkdir -p /etc/openvpn/server-list

cat > /etc/openvpn/server-list/server-${SERVER_FALLBACK_PRIORITY}.txt <<EOF
$SERVER_ADDRESS $SERVER_LISTENING_PORT
EOF

# Generate server.conf if it doesn't exist yet 
# or do it always, to respect environment variables
#if [ ! -f "/etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.conf" ]; then
    cat > /etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.conf <<EOF
port $SERVER_LISTENING_PORT
proto $OPENVPN_PROTO
multihome
dev tun
ca /etc/openvpn/pki/ca.crt
cert /etc/openvpn/pki/issued/${SERVER_ADDRESS}.crt
key /etc/openvpn/pki/private/${SERVER_ADDRESS}.key
dh /etc/openvpn/pki/dh.pem
${CRL_DIRECTIVE}
auth SHA256
tls-auth /etc/openvpn/ta.key 0
topology subnet
server $OPENVPN_NETWORK $OPENVPN_NETMASK
ifconfig-pool $OPENVPN_POOL_START $OPENVPN_POOL_END
ifconfig-pool-persist ipp.txt
client-config-dir /etc/openvpn/ccd
route ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}
push "route ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}"
push "dhcp-option DNS ${VPN_DNS}"
push "dhcp-option DOMAIN ${SERVER_ADDRESS}"
keepalive 10 120
tun-mtu 1500
mssfix 1300
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status /etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.log
# Management interface for openvpn-monitor (read-only TCP, localhost only).
# Bound to 127.0.0.1 so it's never reachable from outside the host; the
# monitor sidecar runs with network_mode: host and connects via loopback.
management 127.0.0.1 5555
verb 3
explicit-exit-notify 1
EOF
#fi

# Seed CCD entry for the pfSense peer. The `iroute` is the LAN-reachability
# invariant (see docs/architecture.md); we additionally pin pfSense's tunnel IP
# with `ifconfig-push` so the site client always lands on a known address. This
# file is fully owned + rewritten by init_vpn.sh every start, so the env vars
# below always win — generate_client.sh deliberately refuses to touch it.
mkdir -p /etc/openvpn/ccd
{
    echo "iroute ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}"
    if valid_ipv4 "$PFSENSE_CLIENT_IP" \
       && is_assignable_host "$PFSENSE_CLIENT_IP" "$OPENVPN_NETWORK" "$OPENVPN_NETMASK" \
       && ! ip_in_range "$PFSENSE_CLIENT_IP" "$OPENVPN_POOL_START" "$OPENVPN_POOL_END"; then
        echo "ifconfig-push ${PFSENSE_CLIENT_IP} ${OPENVPN_NETMASK}"
    else
        # Bad/empty/in-pool value: skip the pin rather than crash the hub.
        # pfSense then falls back to a dynamic lease (the iroute still works).
        echo "WARNING: PFSENSE_CLIENT_IP='${PFSENSE_CLIENT_IP}' is invalid or" \
             "inside the dynamic pool (${OPENVPN_POOL_START}-${OPENVPN_POOL_END});" \
             "leaving pfSense on a dynamic tunnel IP." >&2
    fi
} > /etc/openvpn/ccd/"$PFSENSE_CLIENT_CN"

# Run OpenVPN
exec openvpn --config /etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.conf
