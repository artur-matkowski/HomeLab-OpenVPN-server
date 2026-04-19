# pfSense OpenVPN Site-Client Setup

Step-by-step walkthrough for configuring pfSense as a site-to-site OpenVPN **client** that dials out to this hub. Tested against pfSense CE 2.7+ / Plus 23+.

## Mental model

pfSense is just a regular OpenVPN client to the hub — but because it's also the LAN gateway, every LAN host transparently reaches the VPN subnet through it (no per-host static routes anywhere). The hub binds the LAN subnet to pfSense's certificate via a CCD `iroute` entry. **CN of the cert == filename in `/etc/openvpn/ccd/` on the hub == value of `PFSENSE_CLIENT_CN` env var on the hub.** All three must match exactly.

## Prerequisites

You should already have:
- A `.ovpn` file generated on the hub for pfSense's CN, e.g. `matkoland.ovpn`:
  ```
  docker exec openvpn-hub generate_client.sh matkoland
  docker cp openvpn-hub:/etc/openvpn/clients/matkoland.ovpn ./
  ```
- The `PFSENSE_CLIENT_CN` env var on the hub set to that exact CN (see `docker-compose.yml`).
- The hub reachable from pfSense's WAN at the FQDN/IP and UDP port you used in `SERVER_ADDRESS` / `SERVER_LISTENING_PORT`.

## Step 0 — Extract blobs from the `.ovpn`

Open the `.ovpn` in a text editor. There are four tagged blocks. Each goes into a different pfSense form. Copy only the content **between** the tags.

| Block in `.ovpn`                  | Goes into                                |
|-----------------------------------|------------------------------------------|
| `<ca> … </ca>`                    | System → Cert. Manager → **CAs**         |
| `<cert> … </cert>`                | System → Cert. Manager → **Certificates** (cert data) |
| `<key>  … </key>`                 | System → Cert. Manager → **Certificates** (private key) |
| `<tls-auth> … </tls-auth>`        | OpenVPN client form, **TLS Key** field   |

## Step 1 — Import the CA

`System → Cert. Manager → CAs → + Add`

| Field | Value |
|---|---|
| Descriptive name | `vpn-hub-ca` (anything memorable) |
| Method | **Import an existing Certificate Authority** |
| Certificate data | paste `<ca>` block |
| Certificate Private Key | leave empty (pfSense is not the CA) |
| Serial for next certificate | leave empty |

Save.

## Step 2 — Import the client cert + key

`System → Cert. Manager → Certificates → + Add/Sign`

| Field | Value |
|---|---|
| Method | **Import an existing Certificate** |
| Descriptive name | `vpn-site-cert` |
| Certificate data | paste `<cert>` block |
| Private key data | paste `<key>` block |

Save.

## Step 3 — Create the OpenVPN client

`VPN → OpenVPN → Clients → + Add`

### General Information
| Field | Value |
|---|---|
| Disabled | unchecked |
| Server Mode | **Peer to Peer (SSL/TLS)** |
| Protocol | **UDP on IPv4 only** |
| Device Mode | **tun - Layer 3 Tunnel Mode** |
| Interface | **WAN** |
| Local port | *blank* |
| Server host or address | hub FQDN/IP (matches `SERVER_ADDRESS`) |
| Server port | `1194` (matches `SERVER_LISTENING_PORT`) |
| Proxy host / user / pass | *blank* |
| Server host name resolution | *Infinitely resolve server* |
| Description | `VPN Hub` |

### User Authentication Settings
Leave Username / Password **blank** — auth is by certificate alone.

### Cryptographic Settings
| Field | Value |
|---|---|
| TLS Configuration | ☑ **Use a TLS Key** |
| Automatically generate a TLS Key | ☐ unchecked |
| **TLS Key** | paste `<tls-auth>` block |
| TLS Key Usage Mode | **TLS Authentication** *(not Encryption + Authentication; the hub uses `tls-auth`, not `tls-crypt`)* |
| TLS keydir direction | **Direction 1** *(client side; the hub config uses `tls-auth ta.key 0`)* |
| Peer Certificate Authority | `vpn-hub-ca` |
| Client Certificate | `vpn-site-cert` |
| Data Encryption Negotiation | ☑ checked |
| Data Encryption Algorithms | add **AES-256-CBC** (you may also leave AES-256-GCM selected) |
| Fallback Data Encryption Algorithm | **AES-256-CBC** |
| Auth digest algorithm | **SHA256 (256-bit)** |
| Hardware Crypto | *No Hardware Crypto Acceleration* |

### Tunnel Settings
| Field | Value |
|---|---|
| IPv4 Tunnel Network | **leave blank** *(hub pushes via `topology subnet`)* |
| IPv6 Tunnel Network | blank |
| IPv4 Remote network(s) | `192.168.75.0/24` *(installs route to road-warriors on pfSense; because pfSense is the LAN gateway, all LAN hosts inherit this route)* |
| IPv6 Remote network(s) | blank |
| IPv4 Local network(s) | **leave blank** — informational only on a client; the actual LAN→peer binding is the **iroute in CCD on the hub**, not this field |
| Limit outgoing bandwidth | blank |
| Allow Compression | **Refuse any non-stub compression** |
| Topology | **Subnet — One IP address per client in a common subnet** |

### Ping settings
Leave defaults.

### Advanced Configuration
**Custom options** — paste:

```
pull-filter ignore "route 192.168.74.0"
pull-filter ignore "dhcp-option"
```

Why: the hub pushes a route for `192.168.74.0/24` to all clients (handy for road-warriors). pfSense already owns that LAN as a directly-connected interface — accepting the pushed route is harmless but creates a dueling-routes condition; filtering it keeps the route table clean. Same for the pushed DNS option.

| Field | Value |
|---|---|
| UDP Fast I/O | checked (optional) |
| Gateway creation | **IPv4 only** |
| Verbosity level | `3` |

Save.

## Step 4 — Assign the OpenVPN interface

1. `Interfaces → Assignments`. In the "Available network ports" dropdown you'll see `ovpnc1 (VPN Hub)` (or higher if you have other clients). Click **Add**. It becomes `OPT1` (or next available).
2. Click the `OPT1` link at the top:

| Field | Value |
|---|---|
| Enable | ☑ |
| Description | `VPNHUB` (no spaces — becomes interface name) |
| IPv4 Configuration Type | **None** |
| IPv6 Configuration Type | **None** |

Save → Apply Changes (top banner).

## Step 5 — Firewall rules

Two tabs. Start permissive to validate connectivity, tighten later.

### `Firewall → Rules → OpenVPN`
| Field | Value |
|---|---|
| Action | Pass |
| Interface | OpenVPN |
| Address Family | IPv4 |
| Protocol | any |
| Source | Network `192.168.75.0/24` |
| Destination | any |
| Description | Allow VPN clients in |

### `Firewall → Rules → VPNHUB`
Without a rule on the assigned-interface tab, return/stateful traffic can be dropped on some pfSense versions.

| Field | Value |
|---|---|
| Action | Pass |
| Interface | VPNHUB |
| Source | `192.168.75.0/24` |
| Destination | any |
| Description | Allow from VPN subnet |

Apply.

## Step 6 — Verify

1. **`Status → OpenVPN`**: row "VPN Hub" → **up**, Virtual Address inside `192.168.75.0/24`.
2. **On the hub**:
   ```
   docker exec openvpn-hub cat /etc/openvpn/server-0.log
   ```
   `ROUTING TABLE` section must show your pfSense CN with both:
   - the tunnel IP it received (`192.168.75.x`)
   - the LAN: `192.168.74.0/24,<your_cn>,…`
   If the LAN line is missing, see "Troubleshooting → Iroute not active".
3. **From a LAN host**: `ping 192.168.75.1` (the hub) → should reply.
4. **From a road-warrior client**: `ping <some LAN host>` → should reply.

## Troubleshooting

### Tunnel up, but LAN unreachable from road-warriors
Almost always **CCD/CN mismatch**. Verify the three values are identical:

```
# On the hub:
docker exec openvpn-hub ls /etc/openvpn/ccd/
docker exec openvpn-hub grep PFSENSE_CLIENT_CN /proc/1/environ | tr '\0' '\n'
docker exec openvpn-hub grep "Common Name" /etc/openvpn/server-0.log
```

All three must show the same string. If they don't:
- Update `PFSENSE_CLIENT_CN` in `docker-compose.yml`
- `docker compose up -d openvpn-hub` to recreate
- Bounce pfSense's OpenVPN client (`Status → OpenVPN → Restart this client`) to re-trigger CCD lookup

### Pings within `192.168.75.0/24` (e.g. road-warrior → pfSense's tun IP) fail
On the hub, FORWARD chain may not have the tun↔tun ACCEPT rule:

```
ssh hub iptables -nL DOCKER-USER
```

Should contain `ACCEPT all -- ... tun0 tun0`. If empty, the container's entrypoint didn't complete — check `docker logs openvpn-hub` for errors from `host_init.sh`. A `docker compose restart openvpn-hub` re-runs it.

### `Status → OpenVPN` says "Reconnecting; tls-error"
- Cipher / digest mismatch → recheck the "Cryptographic Settings" section
- TLS keydir direction wrong → must be **Direction 1** on pfSense (server uses 0)
- Time skew → `Status → System Logs → OpenVPN` will say "Replay-window backtrack" or "TLS handshake failed" — fix NTP on either side

### LAN hosts see traffic from `192.168.75.x` but replies never arrive at road-warriors
pfSense missing the return route. `Diagnostics → Routes`, search `192.168.75` — must show a route via the OpenVPN client interface. If absent, the **IPv4 Remote network(s)** field in Step 3 wasn't saved. Re-edit the OpenVPN client, save, apply.

### One LAN host works, another doesn't
That host has a custom default gateway (not pfSense). Either change its gateway, or add a per-host static route for `192.168.75.0/24` via pfSense.
