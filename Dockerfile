# Use an ARM64 Ubuntu base image
FROM arm64v8/ubuntu:22.04


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

# Copy initialization scripts (we'll create these next)
COPY init.sh /init.sh
COPY generate_client.sh /usr/local/bin/generate_client.sh

# Make scripts executable
RUN chmod +x /init.sh /usr/local/bin/generate_client.sh

RUN chown -R 1001:100 /etc/openvpn

# Set the entrypoint
ENTRYPOINT ["/init.sh"]
