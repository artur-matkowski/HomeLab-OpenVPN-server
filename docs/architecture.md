# Architecture

How the hub works and **why** each design choice was made. For the env-var and
config surface see [configuration.md](configuration.md); for per-file detail see
[code-map.md](code-map.md).

## Roles

| Component | Role | Address |
|-----------|------|---------|
| VPS hub (this repo) | OpenVPN **server**, packet relay | `192.168.75.1` on `tun0`, public WAN IP |
| pfSense | OpenVPN **site client** *and* home LAN gateway | tunnel `192.168.75.x`, LAN `192.168.74.1` |
| Road-warriors (laptop/phone) | regular OpenVPN **clients** | `192.168.75.x` |

The hub is the only node with a public, reachable IP. Both pfSense and the
road-warriors *dial out* to it; nothing dials in to the home network. This is what
makes the design work behind CGNAT.

## Topology

```
  Laptop ──OpenVPN──►  VPS hub (this repo)  ◄──OpenVPN── pfSense ── LAN 192.168.74.0/24
  192.168.75.x          192.168.75.1 / tun0   site client   (pfSense is LAN gateway too)
                        relays tun0 ↔ tun0
                        CCD iroute: LAN → pfSense cert CN
```

- **VPN subnet** (assigned to all OpenVPN clients): `192.168.75.0/24`, `topology subnet`.
- **Home LAN** (behind pfSense): `192.168.74.0/24`.
- The two subnets must be distinct, and distinct from any road-warrior's local LAN.

## Addressing — static pins vs the dynamic pool

The VPN subnet is split into two non-overlapping ranges so that "who is on which IP" is
stable enough to write static routes against:

```
 192.168.75.1            hub (OpenVPN server, always .1)
 192.168.75.2 – .127     STATIC range  — hardcoded per-client via CCD ifconfig-push
 192.168.75.128 – .254   DYNAMIC pool  — leased by the server (ifconfig-pool)
```

- **Static pins** come from a per-client CCD file (`ccd/<cert-CN>`) containing
  `ifconfig-push <ip> <netmask>`. `generate_client.sh` writes it for road-warriors after
  **interactively** asking for the host octet; `init_vpn.sh` writes pfSense's
  (`INTRANET_TUNNEL_IP`, default `.2`) next to its iroute. The CCD filename must equal the
  cert CN — the same matching rule as the pfSense iroute (see CN match below).
- **The dynamic pool** is fixed by `ifconfig-pool START END` in `server.conf`.

**Why reserve the pool instead of just "agreeing" to keep statics low.**
`ifconfig-push` (static) and `ifconfig-pool` (dynamic) are *independent* allocators —
OpenVPN does not subtract a pinned address from the pool. If a static IP also sat inside
the pool, the server could lease it to some other client while the pinned client was
**offline**; when the pinned client reconnected, two machines would claim one address
(intermittent, hard-to-diagnose breakage that defeats the whole point of pinning). Making
the ranges disjoint — enforced by `OPENVPN_POOL_START/END`, validated by
`generate_client.sh` — removes the possibility entirely. The boundaries are tunable via
env; the defaults derive the subnet prefix from `OPENVPN_NETWORK`.

## Routing model — follow a packet

**Road-warrior → LAN host** (`192.168.75.20` → `192.168.74.200`):

1. Client has the pushed route `192.168.74.0/24 → tun`, so the packet enters the tunnel.
2. Hub receives it on `tun0`. The hub's own routing table has `route 192.168.74.0/24`
   (non-pushed `route` line in `server.conf`) pointing at `tun0`.
3. OpenVPN's internal routing maps `192.168.74.0/24` to the **pfSense peer** via the
   CCD **`iroute`** bound to pfSense's cert CN. The packet leaves `tun0` toward pfSense.
4. Kernel forwarding (`tun0`→`tun0`) is permitted by the `DOCKER-USER` ACCEPT rule.
5. pfSense receives it on its OpenVPN client interface and, being the LAN gateway,
   delivers it to `192.168.74.200`.

**LAN host → road-warrior** (the return path):

1. `192.168.74.200`'s default gateway is pfSense (true for every LAN host — that's the
   whole point), so replies go to pfSense with no per-host route.
2. pfSense has `192.168.75.0/24` as an **IPv4 Remote network** on its OpenVPN client,
   installing a route back through the tunnel to the hub.
3. Hub relays `tun0`→`tun0` to the road-warrior. **No NAT happens anywhere.**

### Why the two `route`/`iroute`/`push` lines are all needed

- `push "route 192.168.74.0/24"` — tells **clients** the LAN is reachable via the VPN.
- `route 192.168.74.0/24` (non-push) — tells the **hub kernel** to send LAN traffic to
  `tun0` instead of its WAN. Without it the hub wouldn't route LAN packets into the tunnel.
- `iroute 192.168.74.0/24` in `ccd/<pfSense-CN>` — tells **OpenVPN's internal router**
  which *peer* owns the LAN. This is the binding that makes the LAN exit toward pfSense
  specifically. It is the single most fragile invariant (see CN match, below).

## Why no NAT / MASQUERADE on the hub

A typical road-warrior gateway MASQUERADEs client traffic onto its WAN. This hub does
**not**: LAN destinations are not on the hub's WAN, they're behind pfSense, and pfSense
already has a route back to the VPN subnet. MASQUERADE would rewrite source addresses
and break the symmetric, stateful path through pfSense. `host_init.sh` therefore only
enables forwarding + a blanket `tun0↔tun0 ACCEPT`, and adds **no** `nat` rules.

## Why `DOCKER-USER`, not `FORWARD`

When the Docker daemon starts it sets `iptables -P FORWARD DROP` and inserts its own
chains at the top of `FORWARD`. A rule appended to `FORWARD` lands *below* Docker's
chains and is easily shadowed; `DOCKER-USER` is the chain Docker promises never to
touch and evaluates first. Putting `tun0↔tun0 ACCEPT` there means it:

- survives `systemctl restart docker` and container recreation,
- is evaluated before any Docker-managed rule,
- needs no fragile `-I FORWARD 1` ordering.

The rule is intentionally a blanket `-i tun0 -o tun0 -j ACCEPT`: any tun→tun packet is
by definition VPN traffic that must pass. Per-host/port filtering belongs on pfSense.

## Why host networking + privileged

`docker-compose.yml` runs the container with `network_mode: host` and `privileged: true`.
This lets the container's entrypoint configure the **host** kernel and **host** iptables
directly (the container shares the host's network namespace and has `CAP_NET_ADMIN`).
Consequence: **no separate host-side install or systemd unit is required** — host setup
re-applies on every container start, including after a reboot (`restart: unless-stopped`
+ Docker auto-start). The trade-off is reduced isolation, acceptable for a single-purpose
VPN appliance VPS.

## Crypto & control channel

| Layer | Setting | Notes |
|-------|---------|-------|
| Control-channel HMAC | `tls-auth ta.key 0` (hub) / `key-direction 1` (client) | Static-key HMAC on the TLS handshake. Hub uses direction `0`, clients `1`. |
| Auth digest | `auth SHA256` | Must match on both ends or the control HMAC fails. |
| Data cipher | `cipher AES-256-CBC` | Legacy CBC; pfSense must list AES-256-CBC (see pfSense crypto section). |
| PKI | easy-rsa, CA + server cert (`nopass`) | Generated on first run; persisted on the bind mount. |

The **tls-auth triad** = `ta.key` bytes + direction + digest. If any of the three
drifts between hub and a client, the symptom is `packet HMAC authentication failed`.
OpenVPN reads `ta.key` once at daemon start, so such corruption can stay invisible
until a restart — see [troubleshooting.md](troubleshooting.md).

## Split tunnel

Road-warriors keep their own internet. The generated `.ovpn` ships
`pull-filter ignore "redirect-gateway"`, and the hub never pushes a default route —
only the LAN route. pfSense additionally filters the pushed LAN route/DNS because it
already owns that LAN directly (see [pfsense-setup.md](pfsense-setup.md)).

## CN match — the cross-cutting invariant

The pfSense certificate's **CN** must be byte-identical in three places:

```
pfSense cert CN  ==  /etc/openvpn/ccd/<CN> on the hub  ==  INTRANET_PEER_CN env var
```

`init_vpn.sh` seeds `ccd/$INTRANET_PEER_CN` with the `iroute`. If pfSense connects
with a different CN, OpenVPN finds no matching CCD file, never installs the iroute,
and the LAN is unreachable from road-warriors even though every tunnel is "up".

## Failover machinery (legacy, single hub today)

`generate_client.sh` assembles the `.ovpn` `remote` lines from
`/etc/openvpn/server-list/server-<priority>.txt` (lower number = higher priority).
With one hub there is a single `server-0.txt`. The mechanism is retained so multiple
hub instances could be combined into one `.ovpn` with ordered fallback `remote` lines.
See [client-management.md](client-management.md).
