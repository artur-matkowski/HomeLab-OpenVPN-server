#!/bin/bash

CLIENT=$1

if [ -z "$CLIENT" ]; then
    echo "Usage: generate_client.sh <client_name>"
    exit 1
fi

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="$CLIENT"
export EASYRSA_REQ_COUNTRY="US"
export EASYRSA_REQ_PROVINCE="State"
export EASYRSA_REQ_CITY="City"
export EASYRSA_REQ_ORG="MyVPN Org"
export EASYRSA_REQ_EMAIL="admin@example.com"
export EASYRSA_REQ_OU="MyVPN Unit"

cd /etc/openvpn/easy-rsa
./easyrsa build-client-full $CLIENT nopass

# Create client configuration directory if it doesn't exist
mkdir -p /etc/openvpn/clients

# Create client configuration file
cat > /etc/openvpn/clients/$CLIENT.ovpn <<EOF
client
dev tun
proto udp
remote "$YOUR_SERVER_IP_OR_DOMAIN" 1194
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
$(cat /etc/openvpn/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/pki/issued/$CLIENT.crt)
</cert>
<key>
$(cat /etc/openvpn/pki/private/$CLIENT.key)
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
key-direction 1
EOF