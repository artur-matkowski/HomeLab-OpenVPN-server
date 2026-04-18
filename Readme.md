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
- `PFSENSE_CLIENT_CN`: certificate CN of the pfSense site client (default: `pfsense-site`). The init script seeds `/etc/openvpn/ccd/<CN>` with `iroute <OPENVPN_HOST_NETWORK> <OPENVPN_HOST_NETMASK>`, which is what actually makes the LAN reachable through that peer.

### Certificate Authority
- `OPENVPN_COUNTRY`, `OPENVPN_PROVINCE`, `OPENVPN_CITY`, `OPENVPN_ORG`, `OPENVPN_EMAIL`, `OPENVPN_OU`

### Failover (legacy, optional)
- `SERVER_FALLBACK_PRIORITY`: keep at `0` for a single hub. The priority/server-list machinery is retained so multiple instances can still be combined into one `.ovpn` with ordered `remote` lines.

## Deployment

On the VPS:

```bash
# 1. Clone / copy this repo
# 2. Edit docker-compose.yml (SERVER_ADDRESS, VPN_DNS, etc.)
docker-compose up -d
docker-compose logs -f openvpn-hub

# 3. One-time host config (IP forwarding + FORWARD rules for tun0↔tun0)
sudo ./host_init.sh 192.168.75.0/24 192.168.74.0/24 tun0
```

`host_init.sh` runs on the VPS host, **not** inside the container. Re-run on boot (or install as a systemd oneshot / `iptables-persistent`).

## Client Management

### pfSense site client (generate once)

```bash
docker exec -it openvpn-hub generate_client.sh pfsense-site
docker cp openvpn-hub:/etc/openvpn/clients/pfsense-site.ovpn ./
```

On pfSense: **VPN → OpenVPN → Clients** → mode *Peer to Peer (SSL/TLS)*, UDP, remote = VPS FQDN:1194, paste CA / cert / key / ta from the `.ovpn`, key direction 1, cipher AES-256-CBC, auth SHA256, **IPv4 Remote network(s)** = `192.168.75.0/24`. Add firewall rules on the OpenVPN tab permitting `192.168.75.0/24 → LAN net`.

### Road-warrior clients

```bash
docker exec -it openvpn-hub generate_client.sh laptop1
docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

Generated `.ovpn` already includes `pull-filter ignore "redirect-gateway"` — clients keep their own internet and only reach the home LAN via the tunnel.

## Verification

- VPS: `docker-compose logs` shows `Initialization Sequence Completed`; `ip route` lists `192.168.74.0/24 dev tun0` once pfSense connects; `iptables -S FORWARD` shows the two tun0↔tun0 ACCEPT rules.
- pfSense: **Status → OpenVPN** shows the client Connected with a tunnel IP in `192.168.75.0/24`.
- Laptop: `ping 192.168.75.1` (hub), then `ping <LAN host>` (e.g. `192.168.74.200`) — both reply. `curl ifconfig.me` shows the laptop's own public IP (split tunnel).
- Reverse direction: from a LAN host, `ping <laptop tun IP>` (visible in the OpenVPN status page) — expect reply.

## Architecture

Scripts:
- `init.sh` — container entrypoint
- `init_vpn.sh` — one-shot PKI init, generates `server-${PRIORITY}.conf`, seeds CCD `iroute` for the pfSense peer, `exec`s OpenVPN
- `host_init.sh` — VPS-side IP forwarding + tun0↔tun0 FORWARD rules (no MASQUERADE — return path goes via pfSense, not the VPS WAN)
- `generate_client.sh` — builds client cert + assembles `.ovpn` with all registered remotes (from `/etc/openvpn/server-list/`)

## License

Provided as-is for home-lab use.

## Contributing

Issues and PRs welcome.
