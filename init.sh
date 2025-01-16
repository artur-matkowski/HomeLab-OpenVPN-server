#!/bin/bash

set -e
set -x  # Enable verbose logging for debugging

response=$(curl -s https://ipinfo.io)

# Optional environment variables with defaults
: "${OPENVPN_PORT:=1194}"
: "${OPENVPN_PROTO:=udp}"
: "${OPENVPN_SERVER_NAME:=server}"
: "${OPENVPN_NETWORK:=192.168.33.0}"
: "${OPENVPN_NETMASK:=255.255.255.0}"
: "${OPENVPN_HOST_NETWORK:=192.168.1.0}"
: "${OPENVPN_HOST_NETMASK:=255.255.255.0}"
: "${INTERNAL_DOMAIN:=internal.net}"
: "${THIS_SERVER_LISTENING_PORT:=1194}"
: "${HOME_DNS:=192.168.1.207}"
: "${OPENVPN_SERVER_CN:=MyVPN CA}"
OPENVPN_COUNTRY="${OPENVPN_COUNTRY:-$(echo "$response" | jq -r '.country')}"
OPENVPN_PROVINCE="${OPENVPN_PROVINCE:-$(echo "$response" | jq -r '.region')}"
OPENVPN_CITY="${OPENVPN_CITY:-$(echo "$response" | jq -r '.city')}"
: "${OPENVPN_ORG:=MyVPN Org}"
: "${OPENVPN_EMAIL:=admin@example.com}"
: "${OPENVPN_OU:=MyVPN Unit}"

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
    export EASYRSA_REQ_CN="$OPENVPN_SERVER_NAME"
    ./easyrsa build-server-full "$OPENVPN_SERVER_NAME" nopass

    # Copy relevant files
    cp pki/ca.crt pki/private/ca.key pki/issued/"$OPENVPN_SERVER_NAME".crt \
       pki/private/"$OPENVPN_SERVER_NAME".key pki/dh.pem /etc/openvpn/
    cp /etc/openvpn/ta.key /etc/openvpn/
fi

# Generate server.conf if it doesn't exist yet 
if [ ! -f "/etc/openvpn/server.conf" ]; then
    cat > /etc/openvpn/server.conf <<EOF
port $OPENVPN_PORT
proto $OPENVPN_PROTO
dev tun
ca /etc/openvpn/pki/ca.crt
cert /etc/openvpn/pki/issued/${OPENVPN_SERVER_NAME}.crt
key /etc/openvpn/pki/private/${OPENVPN_SERVER_NAME}.key
dh /etc/openvpn/pki/dh.pem
auth SHA256
tls-auth /etc/openvpn/ta.key 0
topology subnet
server $OPENVPN_NETWORK $OPENVPN_NETMASK
ifconfig-pool-persist ipp.txt
push "route ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}"
push "dhcp-option DNS ${HOME_DNS}"
push "dhcp-option DOMAIN ${INTERNAL_DOMAIN}"
keepalive 10 120
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status /etc/openvpn/openvpn-status.log
verb 3
explicit-exit-notify 1
EOF
fi

# Run OpenVPN
exec openvpn --config /etc/openvpn/server.conf
