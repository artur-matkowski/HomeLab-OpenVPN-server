# Client management

Generating `.ovpn` profiles for the pfSense site client and for road-warriors. The
generator is `generate_client.sh` (see [code-map.md](code-map.md)); the pfSense UI side
is [pfsense-setup.md](pfsense-setup.md).

## pfSense site client (generate once)

The CN you pass **must equal `PFSENSE_CLIENT_CN`** in `.env` — this is the
CN-match invariant (see [architecture.md](architecture.md)). With the default
`PFSENSE_CLIENT_CN=matkoland`:

```bash
docker exec -it openvpn-hub generate_client.sh matkoland
docker cp openvpn-hub:/etc/openvpn/clients/matkoland.ovpn ./
```

Then import its four inline blocks into pfSense per [pfsense-setup.md](pfsense-setup.md).
Do **not** pass an IP here — pfSense's fixed tunnel IP comes from `PFSENSE_CLIENT_IP` in
`.env` (default `192.168.75.2`), written into `ccd/$PFSENSE_CLIENT_CN`
alongside the iroute by `init_vpn.sh`.

## Road-warrior clients

```bash
docker exec -it openvpn-hub generate_client.sh laptop1
docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

`generate_client.sh` is **interactive** and will ask whether to assign a static IP — see
[Hardcoded (static) client IPs](#hardcoded-static-client-ips) below; answer `n` for an
ordinary dynamic road-warrior. The generated `.ovpn` already includes
`pull-filter ignore "redirect-gateway"`, so the client keeps its own internet and only
reaches the home LAN over the tunnel (split tunnel). Import the file into any OpenVPN
client app.

## Hardcoded (static) client IPs

`generate_client.sh` is **interactive** — there is no IP argument. After you give the
client name it asks whether to pin a static tunnel IP and, if so, for the **host octet
only** (the network prefix is fixed by `OPENVPN_NETWORK`). A static IP lets you always
know who connects on which address — the prerequisite for static routes over the VPN.
Run it with a TTY (`-it`):

```text
$ docker exec -it openvpn-hub generate_client.sh laptop1
Assign a static tunnel IP to 'laptop1'? [Y/n]        # Enter = Yes (default)
  Host octet for 192.168.75.?  [2-127]: 10
→ 'laptop1' will be pinned to 192.168.75.10.
✓ Client config created: /etc/openvpn/clients/laptop1.ovpn
✓ Pinned laptop1 → 192.168.75.10 (CCD: /etc/openvpn/ccd/laptop1)
$ docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

This writes `/etc/openvpn/ccd/laptop1` containing `ifconfig-push 192.168.75.10
255.255.255.0`, which OpenVPN applies whenever the cert with CN `laptop1` connects (the
CCD filename must equal the cert CN — it does, because both are the client name).

The prompt **only accepts the static range** — below `OPENVPN_POOL_START`, i.e. `.2`–`.127`
with the defaults (the hub owns `.1`). It **re-prompts on bad input** (non-numeric, out of
range, network/broadcast/hub `.1`, inside the dynamic pool, or already pinned to another
client) until you enter a valid, free octet. Why the split matters:

> The dynamic pool (`ifconfig-pool`) and static pins (`ifconfig-push`) are **independent**
> allocators. If a static IP also sat in the dynamic range, OpenVPN could lease it to a
> different client while the static one was offline — two machines fighting over one
> address. Keeping statics out of the pool (enforced by `OPENVPN_POOL_START/END`) makes
> the pin reliable. See [configuration.md](configuration.md) and [architecture.md](architecture.md).

Notes:
- **Answer `n`** to keep the client dynamic (nothing is written to `ccd/`). Re-running the
  script and answering `n` does **not** remove an existing pin — to revert a client to
  dynamic, delete `/etc/openvpn/ccd/<name>`.
- **Duplicate-proof:** the prompt scans existing `ccd/*` pins and refuses an address
  already assigned to another client, so the IP↔client map stays 1:1.
- **The pin takes effect on the client's next (re)connect** — no restart of the hub is
  required (CCD is read per-connection).
- **Needs a TTY:** because it prompts, run it with `docker exec -it`. Without a TTY it
  exits with a message instead of guessing.
- **pfSense is special:** its tunnel IP is set by the `PFSENSE_CLIENT_IP` env, not here.
  `generate_client.sh` skips the prompt for the pfSense CN so it can't clobber the iroute
  in that CCD file (see [configuration.md](configuration.md)).

## DNS served to clients

DNS is **server-pushed** via `push "dhcp-option DNS ${VPN_DNS}"`, *not* baked into each
`.ovpn`. Because `init_vpn.sh` rewrites `server.conf` on every start, changing `VPN_DNS`
in `.env` and redeploying updates DNS for **all** clients
on their next reconnect — you do **not** regenerate or redistribute any `.ovpn`. (Trade-off:
DNS is therefore global, not per-client.)

## What the generated `.ovpn` contains

`generate_client.sh` writes `/etc/openvpn/clients/<name>.ovpn` with:

```
client
dev tun
proto <OPENVPN_PROTO>
remote <addr> <port>        # one line per server-list entry, priority order
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth   SHA256               # must match the hub (tls-auth triad)
cipher AES-256-CBC
verb   3
pull-filter ignore "redirect-gateway"   # split tunnel
<ca> … </ca>                # inline from /etc/openvpn/pki/ca.crt
<cert> … </cert>            # inline from pki/issued/<name>.crt
<key> … </key>              # inline from pki/private/<name>.key
<tls-auth> … </tls-auth>    # inline from /etc/openvpn/ta.key
key-direction 1             # client side of `tls-auth … 0` on the hub
```

Everything is inlined, so the single `.ovpn` is self-contained.

## Multi-remote / failover mechanism

The `remote` lines come from `/etc/openvpn/server-list/server-*.txt`, sorted with
`sort -V` (numeric-aware: `server-2` before `server-10`). Each file contains
`"<address> <port>"`. `init_vpn.sh` writes one file per hub instance, named by
`SERVER_FALLBACK_PRIORITY` (lower = higher priority). With a single hub there is just
`server-0.txt` → one `remote` line.

To assemble a profile with **fallback** across multiple hubs, drop additional
`server-<N>.txt` files into `/etc/openvpn/server-list/` before generating, and OpenVPN
will try the `remote` lines in priority order. This is the residual purpose of the
otherwise-legacy `SERVER_FALLBACK_PRIORITY` machinery (see [architecture.md](architecture.md)).

## Where profiles and PKI live

| Path (in-container) | Host (bind mount) | Contents |
|---------------------|-------------------|----------|
| `/etc/openvpn/clients/` | `/opt/openvpn/clients/` | generated `.ovpn` files |
| `/etc/openvpn/pki/` | `/opt/openvpn/pki/` | CA, issued certs, private keys, `dh.pem` |
| `/etc/openvpn/ta.key` | `/opt/openvpn/ta.key` | tls-auth static key |
| `/etc/openvpn/ccd/` | `/opt/openvpn/ccd/` | per-CN config (the pfSense `iroute`) |

Revoking a client cert is **not** automated here — use easy-rsa directly inside the
container (`cd /etc/openvpn/easy-rsa && ./easyrsa revoke <name>` + `gen-crl`, then add
`crl-verify` to `server.conf`) if you need revocation.
