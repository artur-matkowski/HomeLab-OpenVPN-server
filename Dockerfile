# Use an amd64 Ubuntu base image (Intel N100)
FROM ubuntu:22.04

# Install necessary packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openvpn \
        easy-rsa \
        iptables \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Set environment variables for easy-rsa
ENV EASYRSA=/usr/share/easy-rsa
ENV EASYRSA_PKI=/etc/openvpn/pki

# Copy easy-rsa scripts
RUN mkdir -p /etc/openvpn/pki && \
    ln -s /usr/share/easy-rsa /etc/openvpn/easy-rsa

# Copy initialization scripts (sources live under src/; destinations unchanged)
COPY src/init.sh /init.sh
COPY src/generate_client.sh /usr/local/bin/generate_client.sh
COPY src/revoke_client.sh /usr/local/bin/revoke_client.sh
COPY src/host_init.sh /usr/local/bin/host_init.sh
COPY src/init_vpn.sh /init_vpn.sh
COPY src/get_interface.sh /usr/local/bin/get_interface.sh
# Shared IPv4 helpers, sourced (not executed) by init_vpn.sh + generate_client.sh
COPY src/lib_net.sh /usr/local/lib/lib_net.sh

# Make scripts executable
RUN chmod +x /init.sh /usr/local/bin/generate_client.sh /usr/local/bin/revoke_client.sh
RUN chmod +x /usr/local/bin/host_init.sh
RUN chmod +x /init_vpn.sh
RUN chmod +x /usr/local/bin/get_interface.sh

# Set the entrypoint
ENTRYPOINT ["/init.sh"]
