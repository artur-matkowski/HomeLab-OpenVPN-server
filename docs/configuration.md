# Configuration

All hub settings are environment variables, set in `docker-compose.yml`. This page is
the reference for those vars, the compose-level flags, and the `server.conf` they
generate. For deploy steps see [deployment.md](deployment.md); for the scripts that
consume these, see [code-map.md](code-map.md).

## Environment variables

Defaults below are the script fallbacks (`: "${VAR:=default}"` in `init_vpn.sh` /
`generate_client.sh`). **Precedence:** compose `environment:` > `Dockerfile` `ENV` >
script default — the `:=` default only applies when the var is otherwise unset.

### Network

| Var | Default (script) | `docker-compose.yml` | Purpose |
|-----|------------------|----------------------|---------|
| `SERVER_ADDRESS` | `internal.net` | `myHetznerFqdn` | Public FQDN/IP of the VPS. Embedded in `.ovpn` `remote` lines and used as the **server cert CN**. |
| `SERVER_LISTENING_PORT` | `1194` | `1194` | OpenVPN listen port. |
| `OPENVPN_PROTO` | `udp` | `udp` | `udp` or `tcp`. `explicit-exit-notify` only valid for UDP. |
| `OPENVPN_NETWORK` | `192.168.1.0` | `192.168.75.0` | VPN client subnet network address. |
| `OPENVPN_NETMASK` | `255.255.255.0` | *(unset → default)* | VPN subnet mask. |
| `OPENVPN_HOST_NETWORK` | `192.168.0.0` *(but `Dockerfile` ENV pins `192.168.74.0`)* | `192.168.74.0` | Home LAN pushed to clients, routed, and `iroute`'d to pfSense. |
| `OPENVPN_HOST_NETMASK` | `255.255.255.0` | *(unset → default)* | Home LAN mask. |
| `VPN_DNS` | `8.8.4.4` | `192.168.74.200` | DNS pushed to clients (typically a LAN resolver). |

> Note: `OPENVPN_HOST_NETWORK` is set in **two** places — `Dockerfile` `ENV`
> (`192.168.74.0`) and compose. The Dockerfile ENV means the script's own
> `:=192.168.0.0` fallback is effectively dead. `OPENVPN_NETWORK` is **not** in the
> Dockerfile, so without the compose override it would fall back to `192.168.1.0`.

### pfSense peer

| Var | Default | `docker-compose.yml` | Purpose |
|-----|---------|----------------------|---------|
| `PFSENSE_CLIENT_CN` | `pfsense-site` | `matkoland` | **Cert CN of the pfSense site client.** Must exactly match the CN used in `generate_client.sh` and the filename `init_vpn.sh` creates in `/etc/openvpn/ccd/`. This is the CN-match invariant — see [architecture.md](architecture.md). |

### Certificate Authority (easy-rsa request fields)

| Var | Default | Used for |
|-----|---------|----------|
| `OPENVPN_SERVER_CN` | `MyVPN CA` | CA certificate CN (the server *cert* CN is `SERVER_ADDRESS`, not this). |
| `OPENVPN_COUNTRY` | `US` | cert subject |
| `OPENVPN_PROVINCE` | `LS` (compose: `State`) | cert subject |
| `OPENVPN_CITY` | `Ol` (compose: `City`) | cert subject |
| `OPENVPN_ORG` | `MyVPN Org` (compose: `MyVPN`) | cert subject |
| `OPENVPN_EMAIL` | `admin@example.com` | cert subject |
| `OPENVPN_OU` | `MyVPN Unit` (compose: `MyVPN_Unit`) | cert subject |

These only matter on **first run** (PKI generation) and when generating client certs.
Changing them later does not re-issue the existing CA/server cert.

### Failover (legacy, optional)

| Var | Default | `docker-compose.yml` | Purpose |
|-----|---------|----------------------|---------|
| `SERVER_FALLBACK_PRIORITY` | `0` | `0` | Names the generated `server-<N>.conf`, `server-<N>.log`, and `server-list/server-<N>.txt`. Keep `0` for a single hub. Lower = higher priority in multi-hub `.ovpn` assembly. |

## Compose-level flags (`docker-compose.yml`)

| Setting | Value | Why |
|---------|-------|-----|
| `image` | `arturmatkowski/openvpn-server:latest` | Pulled image tag. **Mismatch:** `buildDockerImage.sh` builds `:dev`. See [deployment.md](deployment.md). |
| `network_mode` | `host` | Container shares host net namespace so its entrypoint can touch host iptables/sysctl. |
| `privileged` | `true` + `cap_add: NET_ADMIN` | Lets `host_init.sh` modify host kernel/iptables. |
| `devices` | `/dev/net/tun` | TUN device for OpenVPN. |
| `restart` | `unless-stopped` | Re-applies host setup + restarts VPN after reboot/crash. |
| `tty` / `stdin_open` | `true` | Keeps the container interactive for `docker exec -it`. |
| `volumes` | `/opt/openvpn:/etc/openvpn` | **Persistence**: PKI, `ta.key`, `ccd/`, `server-*.conf/.log`, `clients/`, `ipp.txt`. |

### Persistence & first-run behavior

Everything under `/etc/openvpn` is on the host bind mount `/opt/openvpn`. On start
`init_vpn.sh` regenerates the PKI **only if `/etc/openvpn/pki/ca.crt` is missing**.
So PKI and `ta.key` survive container recreation; deleting `/opt/openvpn/pki` forces a
fresh CA (and invalidates every issued client cert). `server-<N>.conf` is **rewritten
every start** to reflect current env vars; the CCD iroute file is re-seeded every start.

## Generated `server.conf` (what `init_vpn.sh` emits)

Written to `/etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.conf`:

```
port $SERVER_LISTENING_PORT
proto $OPENVPN_PROTO
multihome                                  # bind/reply correctly when host has multiple IPs
dev tun
ca   /etc/openvpn/pki/ca.crt
cert /etc/openvpn/pki/issued/${SERVER_ADDRESS}.crt
key  /etc/openvpn/pki/private/${SERVER_ADDRESS}.key
dh   /etc/openvpn/pki/dh.pem
auth SHA256                                # control-channel digest (tls-auth triad)
tls-auth /etc/openvpn/ta.key 0             # hub direction 0; clients use 1
topology subnet
server $OPENVPN_NETWORK $OPENVPN_NETMASK   # VPN subnet, hub takes .1
ifconfig-pool-persist ipp.txt
client-config-dir /etc/openvpn/ccd         # enables per-CN CCD / iroute
route ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}        # hub kernel route into tun
push "route ${OPENVPN_HOST_NETWORK} ${OPENVPN_HOST_NETMASK}" # tell clients LAN is via VPN
push "dhcp-option DNS ${VPN_DNS}"
push "dhcp-option DOMAIN ${SERVER_ADDRESS}"
keepalive 10 120
tun-mtu 1500                               # MTU tuning (see note)
mssfix 1300
cipher AES-256-CBC
user nobody
group nogroup
persist-key
persist-tun
status /etc/openvpn/server-${SERVER_FALLBACK_PRIORITY}.log
management 127.0.0.1 5555                   # read-only mgmt for openvpn-monitor (see below)
verb 3
explicit-exit-notify 1                      # UDP-only graceful disconnect notice
```

Notes:
- **`tun-mtu 1500` / `mssfix 1300`** were added to mitigate fragmentation/path-MTU
  issues over the tunnel. A long-running deployed container may predate this — verify
  with `docker exec openvpn-hub cat /etc/openvpn/server-0.conf`.
- **`management 127.0.0.1 5555`** exposes a read-only management socket on loopback for
  an `openvpn-monitor` sidecar. **No such sidecar is defined in `docker-compose.yml`
  yet** — the directive is harmless on its own. See [operations.md](operations.md).
- The non-pushed `route` vs the `push "route …"` vs the CCD `iroute` are three distinct
  mechanisms — see the routing walkthrough in [architecture.md](architecture.md).
