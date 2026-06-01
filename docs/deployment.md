# Deployment

How to build and run the hub on the VPS. Config surface: [configuration.md](configuration.md).
What the scripts do: [code-map.md](code-map.md). Verifying it works: [operations.md](operations.md).

## Prerequisites

- A VPS with a **public static IP**, Docker + Docker Compose, and the chosen UDP port
  (default `1194`) open in any cloud firewall.
- A site router capable of OpenVPN client mode (pfSense, OPNsense, OpenWRT, …).
- Home LAN subnet distinct from the VPN subnet (defaults: LAN `192.168.74.0/24`,
  VPN `192.168.75.0/24`), and distinct from any road-warrior's local network.

## Steps

```bash
# 1. Clone on the VPS.
git clone <this-repo> && cd <this-repo>

# 2. Edit docker-compose.yml. At minimum:
#      SERVER_ADDRESS      -> public FQDN/IP of this VPS
#      VPN_DNS             -> a resolver reachable over the tunnel (often a LAN host)
#      PFSENSE_CLIENT_CN   -> the CN you will use for pfSense's cert (CN-match invariant)

# 3. Build the image and bring up the container.
./buildDockerImage.sh          # builds arturmatkowski/openvpn-server:dev
docker compose up -d
docker compose logs -f openvpn-hub
```

Look for `Initialization Sequence Completed` in the logs.

### ⚠️ Image tag mismatch

`buildDockerImage.sh` builds the **`:dev`** tag, but `docker-compose.yml` references
**`:latest`**. So a fresh `docker compose up` may pull/run a different image than you
just built. Resolve one of these ways before deploying local changes:

```bash
# Option A — retag after building:
docker tag arturmatkowski/openvpn-server:dev arturmatkowski/openvpn-server:latest

# Option B — point compose at :dev (edit docker-compose.yml `image:`).
```

## What happens on first run

`init_vpn.sh` runs the PKI bootstrap **only because `/etc/openvpn/pki/ca.crt` doesn't
exist yet**: it builds the CA, DH params, `ta.key`, and the server cert (CN =
`SERVER_ADDRESS`), all `nopass`. These land on the host bind mount `/opt/openvpn` and
**persist** across container recreation. Subsequent starts skip PKI generation but
**always rewrite** `server-0.conf` and re-seed the CCD iroute from current env vars.

To force a clean PKI (invalidates all issued client certs): stop the container and
remove `/opt/openvpn/pki` (and `ta.key`) on the host, then `docker compose up -d`.

## Host-side networking (automatic)

**No separate host install is needed.** Because the container runs `network_mode: host`
+ `privileged: true`, the entrypoint `init.sh` invokes `host_init.sh` against the host's
kernel namespace, which:

- sets `net.ipv4.ip_forward=1` (and persists it in `/etc/sysctl.conf`), and
- inserts `tun0 → tun0 ACCEPT` into the `DOCKER-USER` iptables chain (creating the
  chain first if Docker hasn't started yet).

Both are idempotent and re-applied on **every** container start — including after a
host reboot (`restart: unless-stopped` + Docker auto-start). No MASQUERADE is added:
the return path goes via pfSense, not the VPS WAN (see [architecture.md](architecture.md)).

Running it manually (e.g. to test outside Docker) still works:

```bash
sudo ./host_init.sh tun0 192.168.75.0/24 192.168.74.0/24
```

## After deploy

Generate the pfSense site profile and at least one road-warrior profile — see
[client-management.md](client-management.md) — then configure pfSense per
[pfsense-setup.md](pfsense-setup.md), and validate with [operations.md](operations.md).
