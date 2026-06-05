# Configuration

All hub settings are environment variables, set in **`.env`** (gitignored; copy
`.env.example` and edit). `docker-compose.yml` injects the file into the container via
`env_file: .env`, where the in-container scripts read it. This page is the reference for
those vars, the compose-level flags, and the `server.conf` they generate. For deploy
steps see [deployment.md](deployment.md); for the scripts that consume these, see
[code-map.md](code-map.md).

## Environment variables

Defaults below are the script fallbacks (`: "${VAR:=default}"` in `init_vpn.sh` /
`generate_client.sh`). **Precedence:** `.env` (injected via `env_file`) > script default
— the `:=` default only applies when the var is otherwise unset. (The `Example`
columns below show the values seeded into `.env` from the previous compose block.)

### Network

| Var | Default (script) | Example (`.env`) | Purpose |
|-----|------------------|----------------------|---------|
| `SERVER_ADDRESS` | `internal.net` | `myHetznerFqdn` | Public FQDN/IP of the VPS. Embedded in `.ovpn` `remote` lines and used as the **server cert CN**. |
| `SERVER_LISTENING_PORT` | `1194` | `1194` | OpenVPN listen port. |
| `OPENVPN_PROTO` | `udp` | `udp` | `udp` or `tcp`. `explicit-exit-notify` only valid for UDP. |
| `OPENVPN_NETWORK` | `192.168.1.0` | `192.168.75.0` | VPN client subnet network address. |
| `OPENVPN_NETMASK` | `255.255.255.0` | *(unset → default)* | VPN subnet mask. |
| `OPENVPN_HOST_NETWORK` | `192.168.0.0` | `192.168.74.0` | Home LAN pushed to clients, routed, and `iroute`'d to pfSense. |
| `OPENVPN_HOST_NETMASK` | `255.255.255.0` | *(unset → default)* | Home LAN mask. |
| `VPN_DNS` | `8.8.4.4` | `192.168.74.200` | DNS pushed to clients (typically a LAN resolver). **Server-pushed, not baked into `.ovpn`** — see the DNS note below. |
| `OPENVPN_POOL_START` | `<prefix>.128` *(prefix from `OPENVPN_NETWORK`)* | `192.168.75.128` | First address of the **dynamic** lease pool. Clients without a CCD pin get addresses from `[START, END]`. |
| `OPENVPN_POOL_END` | `<prefix>.254` | `192.168.75.254` | Last address of the dynamic pool. Everything **below** `POOL_START` (`.2`–`.127`, since the hub owns `.1`) is the **static** range for hardcoded client IPs. |

> **Static vs dynamic addressing.** The `ifconfig-pool START END` line carves the
> subnet into a dynamic range (`.128`–`.254` by default) and a static range
> (`.2`–`.127`). Static IPs are assigned per-client via CCD `ifconfig-push`
> (`generate_client.sh` asks for the host octet interactively). Reserving the pool means a dynamic client can
> never be leased an address that belongs to an offline static client — see the
> addressing section in [architecture.md](architecture.md). The defaults derive the
> `.` prefix from `OPENVPN_NETWORK`, so they track the configured /24 automatically.

> Note: all of these are set in `.env` (the seed copied from `.env.example`). If a var
> is **omitted** from `.env`, the script `:=` fallback applies — e.g. dropping
> `OPENVPN_HOST_NETWORK` falls back to `192.168.0.0` and `OPENVPN_NETWORK` to
> `192.168.1.0`. The Dockerfile no longer bakes in any of these (it previously pinned
> `OPENVPN_HOST_NETWORK`), so config now has a single source of truth: `.env`.

### pfSense peer

| Var | Default | Example (`.env`) | Purpose |
|-----|---------|----------------------|---------|
| `PFSENSE_CLIENT_CN` | `pfsense-site` | `matkoland` | **Cert CN of the pfSense site client.** Must exactly match the CN used in `generate_client.sh` and the filename `init_vpn.sh` creates in `/etc/openvpn/ccd/`. This is the CN-match invariant — see [architecture.md](architecture.md). |
| `PFSENSE_CLIENT_IP` | `<prefix>.2` | `192.168.75.2` | **Fixed tunnel IP for the pfSense site client.** `init_vpn.sh` writes it as an `ifconfig-push` next to the iroute in `ccd/$PFSENSE_CLIENT_CN`. Must be in the static range (below `OPENVPN_POOL_START`); an invalid or in-pool value is **skipped with a warning** and pfSense falls back to a dynamic lease (the iroute still works, so LAN reachability is unaffected). Unlike road-warriors, pfSense's IP is **not** set via `generate_client.sh` — that script refuses the pfSense CN. |

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

| Var | Default | Example (`.env`) | Purpose |
|-----|---------|----------------------|---------|
| `SERVER_FALLBACK_PRIORITY` | `0` | `0` | Names the generated `server-<N>.conf`, `server-<N>.log`, and `server-list/server-<N>.txt`. Keep `0` for a single hub. Lower = higher priority in multi-hub `.ovpn` assembly. |

## Compose-level flags (`docker-compose.yml`)

| Setting | Value | Why |
|---------|-------|-----|
| `image` | `arturmatkowski/openvpn-server:${IMAGE_TAG:-latest}` | Image tag, built locally by `scripts/build.sh`. `IMAGE_TAG` is set by the deploy scripts (`dev`/`latest`); a bare `docker compose up` defaults to `:latest`. See [deployment.md](deployment.md). |
| `env_file` | `.env` | All hub config is injected from `.env` (gitignored; template is `.env.example`). |
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
crl-verify /etc/openvpn/crl.pem            # revocation list (emitted only if present)
auth SHA256                                # control-channel digest (tls-auth triad)
tls-auth /etc/openvpn/ta.key 0             # hub direction 0; clients use 1
topology subnet
server $OPENVPN_NETWORK $OPENVPN_NETMASK   # VPN subnet, hub takes .1
ifconfig-pool $OPENVPN_POOL_START $OPENVPN_POOL_END   # dynamic range; statics live below
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
- **DNS is server-pushed, not baked into the `.ovpn`.** The `push "dhcp-option DNS
  ${VPN_DNS}"` line lives in `server.conf`, which `init_vpn.sh` **rewrites on every
  container start** (the `if [ ! -f ]` guard is deliberately commented out). So DNS is
  *not* fixed at first run: edit `VPN_DNS` in `.env`, redeploy (`docker compose up -d`),
  and the new value reaches every client on its next (re)connect
  — **no client-cert or `.ovpn` regeneration needed.** The same is true for any other
  `server.conf`-derived setting (routes, MTU, the address pool).
- **`ifconfig-pool START END`** reserves the dynamic range so it can't collide with
  static `ifconfig-push` assignments — see the addressing note above and
  [client-management.md](client-management.md).
- **`crl-verify /etc/openvpn/crl.pem`** enables certificate revocation. `init_vpn.sh`
  bootstraps an (empty) CRL on every start and publishes a `0644` copy at
  `/etc/openvpn/crl.pem` (the in-PKI `pki/crl.pem` is `0600`/`0700` and unreadable after
  the `user nobody` privilege drop, which would otherwise break the per-connection CRL
  re-read). The line is **emitted only when that copy exists**, so a CRL hiccup can never
  block startup. Revoke with `revoke_client.sh` — see [client-management.md](client-management.md).
  Existing deployments gain this automatically on their next deploy.
- **`tun-mtu 1500` / `mssfix 1300`** were added to mitigate fragmentation/path-MTU
  issues over the tunnel. A long-running deployed container may predate this — verify
  with `docker exec openvpn-hub cat /etc/openvpn/server-0.conf`.
- **`management 127.0.0.1 5555`** exposes a read-only management socket on loopback for
  an `openvpn-monitor` sidecar. **No such sidecar is defined in `docker-compose.yml`
  yet** — the directive is harmless on its own. See [operations.md](operations.md).
- The non-pushed `route` vs the `push "route …"` vs the CCD `iroute` are three distinct
  mechanisms — see the routing walkthrough in [architecture.md](architecture.md).
