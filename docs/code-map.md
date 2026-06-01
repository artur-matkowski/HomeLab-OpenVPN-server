# Code map

Every script and config file, what it does, and its invariants — enough to reason
about behavior without opening the source. Concepts live in
[architecture.md](architecture.md); env vars in [configuration.md](configuration.md).

## Execution flow

```
docker compose up
   └─ image ENTRYPOINT = /init.sh
        ├─ /usr/local/bin/host_init.sh tun0 <vpn/24> <lan/24>   # host kernel + iptables
        └─ exec /init_vpn.sh                                    # PKI, server.conf, CCD
              └─ exec openvpn --config /etc/openvpn/server-0.conf

generate_client.sh <name>   # run on demand via `docker exec`, independent of the above
get_interface.sh <ip>       # standalone helper, not called by anything else
```

## `init.sh` — container entrypoint

- Runs `host_init.sh tun0 "${OPENVPN_NETWORK:-192.168.75.0}/24" "${OPENVPN_HOST_NETWORK:-192.168.74.0}/24"`.
  This touches the **host** kernel/iptables because of `network_mode: host` +
  `privileged: true` (documented inline in the script).
- Then `exec /init_vpn.sh "$@"` — replaces PID 1 with the VPN init so signals/`status`
  behave correctly.
- `set -e`. The subnet args passed to `host_init.sh` are informational only.

## `init_vpn.sh` — one-shot init + exec openvpn

Responsibilities, in order:
1. Apply env defaults via `: "${VAR:=…}"` (see [configuration.md](configuration.md)).
2. **PKI init, only if `/etc/openvpn/pki/ca.crt` is absent:** `make-cadir`,
   `easyrsa init-pki`, `build-ca nopass`, `gen-dh`, `openvpn --genkey ta.key`, then
   `build-server-full "$SERVER_ADDRESS" nopass` (server cert CN = `SERVER_ADDRESS`).
   Copies `ca.crt`, `ca.key`, the server `.crt`/`.key`, `dh.pem`, and `ta.key` into
   `/etc/openvpn/`.
3. Writes `/etc/openvpn/server-list/server-${PRIORITY}.txt` = `"$SERVER_ADDRESS $PORT"`
   (consumed later by `generate_client.sh`).
4. **Always rewrites** `/etc/openvpn/server-${PRIORITY}.conf` (the `if [ ! -f ]` guard
   is commented out on purpose, so env-var changes take effect on restart). See the
   full emitted config in [configuration.md](configuration.md).
5. Seeds `/etc/openvpn/ccd/$PFSENSE_CLIENT_CN` with
   `iroute $OPENVPN_HOST_NETWORK $OPENVPN_HOST_NETMASK` — the CN-match invariant.
6. `exec openvpn --config /etc/openvpn/server-${PRIORITY}.conf`.

Gotchas / notes:
- `set -e` + `set -x` (verbose — every line echoed to container logs).
- The server's own cert CN is `SERVER_ADDRESS`, **not** `OPENVPN_SERVER_CN` (that's the
  CA CN). `server.conf` references the PKI paths under `pki/`; the root copies of
  `ca.crt`/`ca.key`/`dh.pem` are largely vestigial, but the root **`ta.key` is the one
  actually used** (`tls-auth /etc/openvpn/ta.key 0`).
- Does **not** enable `ip_forward` (deliberately left to `host_init.sh`).

## `host_init.sh` — host-side networking

Idempotent, safe to re-run. Usage: `host_init.sh <VPN_IFACE> [<VPN_SUBNET>] [<LAN_SUBNET>]`
(subnet args informational/logged only). Three steps:
1. **Persistent IP forwarding:** appends `net.ipv4.ip_forward=1` to `/etc/sysctl.conf`
   (only if not already a full-line match) and runs `sysctl -p`.
2. **Ensure `DOCKER-USER` exists:** if missing (Docker hasn't started yet on a fresh
   boot), creates it and hooks it into `FORWARD` (`-N DOCKER-USER`, `-I FORWARD -j DOCKER-USER`).
   The Docker daemon later reuses this chain rather than replacing it.
3. **`tun↔tun ACCEPT`:** `iptables -C` check, then `-I DOCKER-USER 1 -i $IFACE -o $IFACE -j ACCEPT`.
   Inserted at the top so it's evaluated first. **No NAT rule is added** — see the
   "no MASQUERADE" rationale in [architecture.md](architecture.md).

`set -euo pipefail`. Logs via a `log()` helper. The extensive header comment explains
why `DOCKER-USER` over `FORWARD` and why a blanket tun↔tun ACCEPT.

## `generate_client.sh` — client cert + `.ovpn`

Run via `docker exec -it openvpn-hub generate_client.sh <name>`. Steps:
1. Requires a `<client_name>` arg.
2. Applies cert-request env defaults (same vars as `init_vpn.sh`).
3. `cd /etc/openvpn/easy-rsa`, `easyrsa build-client-full "$CLIENT" nopass`
   (cert CN = the client name → for pfSense this must equal `PFSENSE_CLIENT_CN`).
4. Assembles `remote` lines from every `/etc/openvpn/server-list/server-*.txt`, sorted
   with `sort -V` (so `2 < 10`); each file line is `"<addr> <port>"`. Errors out if no
   server-list files exist.
5. Writes `/etc/openvpn/clients/${CLIENT}.ovpn` with inline `<ca>`, `<cert>`, `<key>`,
   `<tls-auth>` blocks, `key-direction 1`, `auth SHA256`, `cipher AES-256-CBC`, and
   `pull-filter ignore "redirect-gateway"` (split tunnel).

`set -e` + `set -x`. Detail and the produced `.ovpn` layout: [client-management.md](client-management.md).

## `get_interface.sh` — IP → egress interface helper

`get_interface.sh <ip>` runs `ip route get <ip>` and prints the word after `dev`
(the interface the kernel would use to reach that IP). **Standalone utility — not
invoked by any other script in this repo.** Present in the image for manual diagnostics.

## `buildDockerImage.sh`

`docker build -t arturmatkowski/openvpn-server:dev .` — builds the **`:dev`** tag.
`docker-compose.yml` pulls **`:latest`**. After a local build, retag (`docker tag …:dev …:latest`)
or edit the compose `image:` before `docker compose up` will pick up changes. See
[deployment.md](deployment.md).

## `Dockerfile`

- Base `ubuntu:22.04` (amd64 — targeted at an Intel N100).
- Installs `openvpn`, `easy-rsa`, `iptables`, `ca-certificates`.
- `ENV EASYRSA=/usr/share/easy-rsa`, `ENV EASYRSA_PKI=/etc/openvpn/pki`,
  **`ENV OPENVPN_HOST_NETWORK=192.168.74.0`** (this baked-in value overrides the
  script's `:=192.168.0.0` default — see [configuration.md](configuration.md)).
- Symlinks `/usr/share/easy-rsa → /etc/openvpn/easy-rsa`.
- Copies `init.sh`→`/init.sh`, `init_vpn.sh`→`/init_vpn.sh`, and
  `generate_client.sh`/`host_init.sh`/`get_interface.sh`→`/usr/local/bin/` (on `PATH`,
  so they're callable bare via `docker exec`). `chmod +x` all of them.
- `ENTRYPOINT ["/init.sh"]`.

## `docker-compose.yml`

Single service `openvpn-hub`. Host networking, privileged, `/dev/net/tun`,
`restart: unless-stopped`, `tty`/`stdin_open`, `/opt/openvpn:/etc/openvpn` bind mount,
and the env block. Full flag-by-flag rationale: [configuration.md](configuration.md).

## Repo drift to be aware of

- **`:dev` vs `:latest`** image-tag mismatch (above).
- **`management 127.0.0.1 5555`** in `server.conf` expects an openvpn-monitor sidecar
  that is **not** defined in compose.
- **No `openvpn-host-init.service`** systemd unit exists; host setup runs from the
  entrypoint. (Earlier doc text referenced such a unit — it was never in the repo.)
