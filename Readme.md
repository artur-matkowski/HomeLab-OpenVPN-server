# HomeLab OpenVPN Server

A Docker-based OpenVPN server solution designed for high-availability home lab deployments with multi-instance support and Syncthing synchronization.

## Features

- **Multi-Instance Support**: Run primary and secondary OpenVPN servers with automatic failover
- **Docker-Based**: Easy deployment using Docker Compose
- **ARM64 Compatible**: Built for ARM-based systems (e.g., Raspberry Pi)
- **Certificate Management**: Automated PKI setup with easy-rsa
- **Client Configuration Generation**: Automated .ovpn profile generation with multi-server failover support
- **Network Routing**: Automatic iptables configuration for VPN traffic
- **Syncthing Integration**: Synchronized configuration across multiple nodes

## Prerequisites

- Docker and Docker Compose installed
- ARM64-based system (e.g., Raspberry Pi) or compatible architecture
- Syncthing (optional, for multi-node deployments)
- Network access to required ports (default: 8194, 8443)

## Configuration

The OpenVPN server is configured through environment variables in `docker-compose.yml`:

### Primary Server Configuration
- `SERVER_FALLBACK_PRIORITY`: Server priority (0 = highest priority)
- `SERVER_ADDRESS`: Public domain or IP address
- `SERVER_LISTENING_PORT`: OpenVPN listening port (default: 8194)
- `VPN_DNS`: DNS server to push to clients
- `OPENVPN_PROTO`: Protocol (udp/tcp)
- `OPENVPN_NETWORK`: VPN subnet (e.g., 192.168.200.0)
- `OPENVPN_HOST_NETWORK`: Host network to route through VPN

### Certificate Authority Settings
- `OPENVPN_COUNTRY`: Country code (default: US)
- `OPENVPN_PROVINCE`: State/Province
- `OPENVPN_CITY`: City
- `OPENVPN_ORG`: Organization name
- `OPENVPN_EMAIL`: Administrator email
- `OPENVPN_OU`: Organizational unit

## Deployment

### Multi-Node Deployment Workflow

When deploying OpenVPN across multiple nodes with Syncthing synchronization:

1. **Deploy on Machine A**
   - Start the Docker container on the primary machine
   - The container will automatically initialize the PKI if it doesn't exist

2. **Generate Certificates**
   - Generate all required certificates (server certificates are created automatically)
   - Client certificates can be generated as needed (see Client Management section)

3. **Restart Container**
   - Restart the container to update file ownership (`chown`)
   - This ensures proper permissions for OpenVPN operation

4. **Syncthing Synchronization**
   - Syncthing will automatically copy the configuration to remote machines
   - Ensure Syncthing is properly configured between nodes

5. **Verify Ownership on Machine B**
   - Confirm that configuration files on the secondary machine have the correct ownership
   - Files should be owned by the appropriate user/group for OpenVPN

6. **Deploy to Machine B**
   - Start the Docker container on the secondary machine
   - The secondary server will use the synchronized certificates and configuration

### Single-Node Deployment

For a single-node deployment:

```bash
# Pull the image
docker-compose pull

# Start the service
docker-compose up -d

# Check logs
docker-compose logs -f openvpn-primary
```

## Client Management

### Generating Client Certificates

To generate a client configuration file:

```bash
docker exec -it openvpn-primary generate_client.sh <client_name>
```

The generated `.ovpn` file will be created in `/etc/openvpn/clients/` inside the container and includes:
- All server addresses with automatic failover priority
- Embedded certificates and keys
- Pre-configured routing to access host network resources

### Retrieving Client Configuration

```bash
docker cp openvpn-primary:/etc/openvpn/clients/<client_name>.ovpn ./
```

## Syncthing Synchronization

### Files to Synchronize
The following directory should be synchronized between nodes:
- `/etc/openvpn` (mounted from host at `/home/pi/syncthing/openvpn`)

### Files to Exclude from Synchronization
⚠️ **Important**: The following files must be excluded from Syncthing synchronization:
- `server-*.conf` (server configuration files are instance-specific)
- `openvpn-status.log` (runtime status files)
- `server-*.log` (server-specific log files)

Each instance generates its own server configuration based on environment variables.

## Troubleshooting

### KDE (Plasma) NetworkManager VPN Route Configuration

If you need to configure VPN routing to use only VPN for specific resources:

1. Open **System Settings** → **Network** (or **Connections**)
2. Find your VPN connection and click **Edit**
3. Go to the **IPv4** or **IPv6** tab (depending on which you use)
4. Click the **Routes…** button to access advanced route options
5. Check or uncheck the option:
   - **"Use only for resources on its network"** (wording may vary by KDE version)
   
This setting controls whether all traffic or only specific network traffic goes through the VPN.

### Common Issues

- **Connection timeout**: Verify firewall rules allow traffic on the configured ports
- **Certificate errors**: Ensure PKI was properly initialized and certificates are synchronized
- **Routing issues**: Check that `host_init.sh` successfully configured iptables rules

## Architecture

The solution uses several scripts to manage the OpenVPN lifecycle:

- `init.sh`: Container entrypoint that initializes network configuration
- `init_vpn.sh`: Sets up PKI, generates certificates, and starts OpenVPN
- `host_init.sh`: Configures host iptables rules and IP forwarding
- `generate_client.sh`: Creates client certificates and .ovpn profiles
- `get_interface.sh`: Determines the correct network interface for routing

## Known Issues & TODO

### TODO
- **Client generation multi-server support**: After cleaning the environment, `generate_client.sh` no longer has addresses of all servers. 
  - **Proposed solution**: All instances should create a file with their server address in a shared directory (e.g., `/etc/openvpn/server-list/`). When a client certificate is created, scan this directory for all 'registered' servers and include them in the client configuration.
  - **Current status**: Partially implemented - server list functionality exists but may need refinement after environment cleanup.

## License

This project is provided as-is for home lab use.

## Contributing

Contributions are welcome! Please submit issues or pull requests through GitHub.
