#!/bin/bash

set -e
set -x  # Enable verbose logging

# Enable IP forwarding
#sysctl -w net.ipv4.ip_forward=1

# Initialize PKI if not already initialized
if [ ! -f "/etc/openvpn/pki/ca.crt" ]; then
    # Set environment variables for batch mode and certificate fields
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="MyVPN CA"
    export EASYRSA_REQ_COUNTRY="US"
    export EASYRSA_REQ_PROVINCE="State"
    export EASYRSA_REQ_CITY="City"
    export EASYRSA_REQ_ORG="MyVPN Org"
    export EASYRSA_REQ_EMAIL="admin@example.com"
    export EASYRSA_REQ_OU="MyVPN Unit"

    # Initialize the PKI directory
    make-cadir /etc/openvpn/easy-rsa
    cd /etc/openvpn/easy-rsa

    # Initialize the PKI
    ./easyrsa init-pki

    # Build the CA without a password
    ./easyrsa build-ca nopass

    # Generate DH parameters
    ./easyrsa gen-dh

    # Generate the TLS authentication key
    openvpn --genkey --secret /etc/openvpn/ta.key

    # Build the server certificate
    export EASYRSA_REQ_CN="server"
    ./easyrsa build-server-full server nopass

    # Copy necessary files to OpenVPN directory
    cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/
    cp /etc/openvpn/ta.key /etc/openvpn/
fi

# Start OpenVPN server
openvpn --config /etc/openvpn/server.conf