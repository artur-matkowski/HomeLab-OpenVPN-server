# Client management

Generating `.ovpn` profiles for the pfSense site client and for road-warriors. The
generator is `generate_client.sh` (see [code-map.md](code-map.md)); the pfSense UI side
is [pfsense-setup.md](pfsense-setup.md).

## pfSense site client (generate once)

The CN you pass **must equal `PFSENSE_CLIENT_CN`** in `docker-compose.yml` — this is the
CN-match invariant (see [architecture.md](architecture.md)). With the default
`PFSENSE_CLIENT_CN=matkoland`:

```bash
docker exec -it openvpn-hub generate_client.sh matkoland
docker cp openvpn-hub:/etc/openvpn/clients/matkoland.ovpn ./
```

Then import its four inline blocks into pfSense per [pfsense-setup.md](pfsense-setup.md).

## Road-warrior clients

```bash
docker exec -it openvpn-hub generate_client.sh laptop1
docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

The generated `.ovpn` already includes `pull-filter ignore "redirect-gateway"`, so the
client keeps its own internet and only reaches the home LAN over the tunnel (split
tunnel). Import the file into any OpenVPN client app.

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
