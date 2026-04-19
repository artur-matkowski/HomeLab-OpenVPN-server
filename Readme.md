# HomeLab OpenVPN Server

A Docker-based OpenVPN hub for home-lab remote access. Deployed on a public-IP VPS (e.g. Hetzner), with a site router (e.g. pfSense) dialing in as a peer so the home LAN is reachable from road-warrior clients even when the home ISP has no static or public IP (CGNAT).

## Topology

```
  Laptop ──OpenVPN──►  VPS hub (this repo)  ◄──OpenVPN── pfSense ── LAN 192.168.74.0/24
  192.168.75.x          192.168.75.1/tun0     site client   (pfSense is also LAN gateway)
                        forwards tun0 ↔ tun0
                        CCD iroute LAN → pfSense cert
```

- The VPS runs this container as the OpenVPN **server**.
- pfSense connects as an OpenVPN **site client**; a matching CCD entry (`iroute`) tells the server that the LAN lives behind the pfSense peer's cert CN.
- Road-warriors are regular OpenVPN clients; the server pushes a route to the home LAN only (split tunnel — clients keep their own internet).
- Because pfSense is simultaneously the LAN default gateway and the site client, all LAN hosts automatically reach the VPN subnet through pfSense — no per-host static routes.

## Features

- Docker-based, `ubuntu:22.04` amd64 image
- Automated easy-rsa PKI init on first run
- CCD + `iroute` wiring for the pfSense site peer
- Client `.ovpn` generator with multi-remote (fallback) list support
- Host-side iptables + IP forwarding helper for the VPS (`host_init.sh`)

## Prerequisites

- VPS with public static IP, Docker + Docker Compose, UDP port 1194 open
- A site router capable of OpenVPN client mode (pfSense, OPNsense, OpenWRT, …)
- Home LAN subnet distinct from the VPN subnet (defaults: LAN `192.168.74.0/24`, VPN `192.168.75.0/24`)

## Configuration

All server settings are passed via environment variables in `docker-compose.yml`:

### Network
- `SERVER_ADDRESS`: public FQDN or IP of the VPS (embedded into `.ovpn` files)
- `SERVER_LISTENING_PORT`: OpenVPN port (default: `1194`)
- `OPENVPN_PROTO`: `udp` or `tcp` (default: `udp`)
- `OPENVPN_NETWORK` / `OPENVPN_NETMASK`: VPN client subnet (default: `192.168.75.0` / `255.255.255.0`)
- `OPENVPN_HOST_NETWORK` / `OPENVPN_HOST_NETMASK`: home LAN pushed to clients and routed to the pfSense peer (default: `192.168.74.0` / `255.255.255.0`)
- `VPN_DNS`: DNS server pushed to clients (typically a LAN resolver)

### pfSense peer
- `PFSENSE_CLIENT_CN`: **certificate CN of the pfSense site client. Must exactly match the CN you use when generating the cert with `generate_client.sh`** — the init script seeds `/etc/openvpn/ccd/<this value>` with `iroute <OPENVPN_HOST_NETWORK> <OPENVPN_HOST_NETMASK>`, and that iroute is the *only* mechanism that makes the LAN reachable through that peer. Mismatch = pfSense connects fine, road-warriors see only the VPN subnet, never the LAN.

### Certificate Authority
- `OPENVPN_COUNTRY`, `OPENVPN_PROVINCE`, `OPENVPN_CITY`, `OPENVPN_ORG`, `OPENVPN_EMAIL`, `OPENVPN_OU`

### Failover (legacy, optional)
- `SERVER_FALLBACK_PRIORITY`: keep at `0` for a single hub. The priority/server-list machinery is retained so multiple instances can still be combined into one `.ovpn` with ordered `remote` lines.

## Deployment

On the VPS:

```bash
# 1. Clone the repo.
git clone https://github.com/artur-matkowski/HomeLab-OpenVPN-server
cd HomeLab-OpenVPN-server

# 2. Edit docker-compose.yml — at minimum set SERVER_ADDRESS, VPN_DNS,
#    and PFSENSE_CLIENT_CN (must equal the CN you'll use for pfSense's cert).

# 3. Build the image and bring up the container.
./buildDockerImage.sh
docker compose up -d
docker compose logs -f openvpn-hub
```

**No host-side install is needed.** Because the container runs `network_mode: host` + `privileged: true`, its entrypoint (`init.sh`) invokes `host_init.sh` against the host's shared kernel namespace — setting `net.ipv4.ip_forward=1` and adding a `tun0↔tun0 ACCEPT` rule to the `DOCKER-USER` iptables chain. On every container start (including after a host reboot, thanks to `restart: unless-stopped`) those settings are re-applied idempotently. If you want to run the host-side setup manually anyway (e.g. to test outside docker), `host_init.sh` still works as a standalone script: `sudo ./host_init.sh tun0`.

### Why `DOCKER-USER` and not `FORWARD`

When the docker daemon starts, it sets `iptables -P FORWARD DROP` and inserts its own chains at the top of FORWARD. Rules appended directly to FORWARD live below docker's chains and are easy to miss; rules in `DOCKER-USER` are explicitly carved out for site-local additions and are evaluated first. `host_init.sh` puts the `tun↔tun ACCEPT` in `DOCKER-USER` so it survives `systemctl restart docker` and container recreation.

## Client Management

### pfSense site client (generate once)

The CN you pass here MUST equal `PFSENSE_CLIENT_CN` in `docker-compose.yml`:

```bash
docker exec -it openvpn-hub generate_client.sh "$PFSENSE_CLIENT_CN"
docker cp "openvpn-hub:/etc/openvpn/clients/$PFSENSE_CLIENT_CN.ovpn" ./
```

For the pfSense UI side — every form, every field, every gotcha — see [`pfsense-setup.md`](pfsense-setup.md).

### Road-warrior clients

```bash
docker exec -it openvpn-hub generate_client.sh laptop1
docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

Generated `.ovpn` already includes `pull-filter ignore "redirect-gateway"` — clients keep their own internet and only reach the home LAN via the tunnel.

## Verification

- VPS: `docker compose logs` shows `Initialization Sequence Completed`; `ip route` lists a route for `192.168.74.0/24` via tun0 once pfSense connects; `iptables -S DOCKER-USER` shows the `tun0 → tun0 ACCEPT` rule.
- pfSense: **Status → OpenVPN** shows the client Connected with a tunnel IP in `192.168.75.0/24`.
- Laptop: `ping 192.168.75.1` (hub), then `ping <LAN host>` (e.g. `192.168.74.200`) — both reply. `curl ifconfig.me` shows the laptop's own public IP (split tunnel).
- Reverse direction: from a LAN host, `ping <laptop tun IP>` (visible in the OpenVPN status page) — expect reply.

## Architecture

Scripts and units:
- `init.sh` — container entrypoint
- `init_vpn.sh` — one-shot PKI init, generates `server-${PRIORITY}.conf`, seeds CCD `iroute` for the pfSense peer, `exec`s OpenVPN
- `host_init.sh` — VPS-side IP forwarding + `DOCKER-USER` ACCEPT for `tun0 → tun0` (no MASQUERADE — return path goes via pfSense, not the VPS WAN)
- `openvpn-host-init.service` — systemd oneshot that runs `host_init.sh` on boot
- `generate_client.sh` — builds client cert + assembles `.ovpn` with all registered remotes (from `/etc/openvpn/server-list/`)

## License

Provided as-is for home-lab use.

## Contributing

Issues and PRs welcome.
