#!/bin/bash

set -e
set -x  # Enable verbose logging for debugging

# Optional environment variables with defaults
: "${OPENVPN_PROTO:=udp}"
: "${OPENVPN_HOSTNAME:=myDomain.com}"   # Primary server domain
: "${OPENVPN_PORT:=1194}"
: "${OPENVPN_HOSTNAME2:=backupDomain.com}"  # Backup domain (optional)
: "${OPENVPN_PORT2:=1194}"             # Possibly the same or different port

CLIENT=$1
if [ -z "$CLIENT" ]; then
    echo "Usage: generate_client.sh <client_name>"
    exit 1
fi

# If you want to re-use the same environment variables from init.sh:
: "${OPENVPN_SERVER_CN:=MyVPN CA}"
: "${OPENVPN_COUNTRY:=US}"
: "${OPENVPN_PROVINCE:=State}"
: "${OPENVPN_CITY:=City}"
: "${OPENVPN_ORG:=MyVPN Org}"
: "${OPENVPN_EMAIL:=admin@example.com}"
: "${OPENVPN_OU:=MyVPN Unit}"

# Build client cert
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

# Create client config
mkdir -p /etc/openvpn/clients

cat > /etc/openvpn/clients/${CLIENT}.ovpn <<EOF
client
dev tun
proto $OPENVPN_PROTO

# Primary server
remote $OPENVPN_HOSTNAME $OPENVPN_PORT

# (Optional) Secondary/backup server
remote $OPENVPN_HOSTNAME2 $OPENVPN_PORT2

resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-CBC
verb 3
pull-filter ignore "redirect-gateway"

<ca>
$(cat /etc/openvpn/ca.crt)
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

echo "Client config created: /etc/openvpn/clients/${CLIENT}.ovpn"
