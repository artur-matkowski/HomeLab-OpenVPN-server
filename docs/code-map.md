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

generate_client.sh <name>          # on demand via `docker exec -it`; prompts for static IP
revoke_client.sh <name> [-f]       # on demand; revoke cert + refresh CRL + cleanup
get_interface.sh <ip>              # standalone helper, not called by anything else
```

Both `init_vpn.sh` and `generate_client.sh` `source /usr/local/lib/lib_net.sh` for the
shared IPv4 math (see `lib_net.sh` below).

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
3. **CRL bootstrap (revocation support):** if `pki/ca.crt` exists, generate `pki/crl.pem`
   when missing (`easyrsa gen-crl`) and publish a `0644` copy to `/etc/openvpn/crl.pem`.
   The published copy is what the dropped-privilege (`user nobody`) server re-reads on each
   new connection — `pki/crl.pem` (`0600`) under `pki/` (`0700`) is unreadable post-drop.
   All steps non-fatal (a CRL failure must not stop the hub). Sets `CRL_DIRECTIVE` to the
   `crl-verify …` line **only if** the published copy exists. See `revoke_client.sh`.
4. Writes `/etc/openvpn/server-list/server-${PRIORITY}.txt` = `"$SERVER_ADDRESS $PORT"`
   (consumed later by `generate_client.sh`).
5. **Always rewrites** `/etc/openvpn/server-${PRIORITY}.conf` (the `if [ ! -f ]` guard
   is commented out on purpose, so env-var changes take effect on restart). Includes
   `ifconfig-pool $OPENVPN_POOL_START $OPENVPN_POOL_END` — the dynamic range, reserved
   so it never overlaps static `ifconfig-push` pins — and `${CRL_DIRECTIVE}` (the
   `crl-verify` line, blank when no CRL). See the full emitted config in
   [configuration.md](configuration.md).
6. Rewrites `/etc/openvpn/ccd/$PFSENSE_CLIENT_CN` with the `iroute` (CN-match invariant)
   **and**, when `PFSENSE_CLIENT_IP` is valid and in the static range, an
   `ifconfig-push $PFSENSE_CLIENT_IP $OPENVPN_NETMASK` to pin pfSense's tunnel IP. An
   invalid/in-pool value is logged to stderr and skipped (pfSense → dynamic lease; the
   iroute still applies). This file is fully owned by `init_vpn.sh`; `generate_client.sh`
   refuses to write it.
7. `exec openvpn --config /etc/openvpn/server-${PRIORITY}.conf`.

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

Run via `docker exec -it openvpn-hub generate_client.sh <name>` (**interactive — needs a
TTY**). Steps:
1. Requires a `<client_name>` arg (no IP arg — the IP is asked interactively).
2. Applies cert-request env defaults (same vars as `init_vpn.sh`) plus the network/pool
   vars (`OPENVPN_NETWORK/NETMASK`, `OPENVPN_POOL_START/END`, `PFSENSE_CLIENT_CN`) it
   needs to size the static range and validate input. These arrive through `docker exec`,
   which inherits the container env.
3. **Interactive IP step** (skipped for the `PFSENSE_CLIENT_CN`, whose IP is env-managed;
   errors out if stdin is not a TTY): asks `Assign a static tunnel IP? [Y/n]` (default
   **Yes**). On Yes it loops asking for the **host octet only**, validating each entry via
   the `lib_net.sh` helpers — numeric, in-range, assignable (not network/broadcast/hub
   `.1`), not in the dynamic pool, and **not already pinned to another client** (scans
   `ccd/*`) — re-prompting until valid. Result: `CLIENT_IP` is a validated address or
   empty (dynamic). `set +x`/`set -x` brackets this block to keep the prompts readable.
4. `cd /etc/openvpn/easy-rsa`, `easyrsa build-client-full "$CLIENT" nopass`
   (cert CN = the client name → for pfSense this must equal `PFSENSE_CLIENT_CN`).
5. Assembles `remote` lines from every `/etc/openvpn/server-list/server-*.txt`, sorted
   with `sort -V` (so `2 < 10`); each file line is `"<addr> <port>"`. Errors out if no
   server-list files exist.
6. Writes `/etc/openvpn/clients/${CLIENT}.ovpn` with inline `<ca>`, `<cert>`, `<key>`,
   `<tls-auth>` blocks, `key-direction 1`, `auth SHA256`, `cipher AES-256-CBC`, and
   `pull-filter ignore "redirect-gateway"` (split tunnel).
7. **If a static IP was chosen,** writes `/etc/openvpn/ccd/${CLIENT}` with
   `ifconfig-push ${CLIENT_IP} ${OPENVPN_NETMASK}` (the pin). Answering `n` leaves `ccd/`
   untouched (dynamic client). Delete the CCD file to revert a client to dynamic.

`set -e` + `set -x`. Detail and the produced `.ovpn` layout: [client-management.md](client-management.md).

## `revoke_client.sh` — revoke a client cert + refresh the CRL

Run via `docker exec [-it] openvpn-hub revoke_client.sh <name> [-f|--force]`. Counterpart
to `generate_client.sh`. Steps:
1. Parses `<name>` and an optional `-f`/`--force` (skip confirmation).
2. Looks up the CN in `pki/index.txt`: a `V` line → revoke it; only an `R` line → already
   revoked (refresh CRL + clean up only); neither → error listing the known CNs.
3. **Confirmation:** prompts unless `-f`; errors if stdin isn't a TTY and `-f` is absent.
   If the CN is `PFSENSE_CLIENT_CN`, warns that this drops the LAN tunnel.
4. `cd /etc/openvpn/easy-rsa`, `EASYRSA_BATCH=1 ./easyrsa revoke <name>` (skipped if already
   revoked), then `./easyrsa gen-crl`, then `install -m 0644 pki/crl.pem /etc/openvpn/crl.pem`
   (the world-readable copy `crl-verify` enforces — see the `init_vpn.sh` CRL note).
5. Removes `/etc/openvpn/clients/<name>.ovpn` and the static pin `/etc/openvpn/ccd/<name>`
   (freeing the tunnel IP) — **except** for the pfSense CN, whose CCD (the iroute) is left
   intact.

Enforcement needs no restart: the server re-reads the CRL per new connection. `set -e` +
`set -x` (toggled off around validation/prompt). Detail: [client-management.md](client-management.md).

## `lib_net.sh` — shared IPv4 helpers (sourced, not executed)

Copied into the image at `/usr/local/lib/lib_net.sh` and `source`d by both `init_vpn.sh`
and `generate_client.sh`. Pure bash, no external commands. Single source of truth for the
address math so the two scripts can't disagree on what a valid static IP is (drift here
would silently hand out colliding tunnel IPs). Functions:

- `ip2int <dotted-quad>` → unsigned 32-bit integer.
- `valid_ipv4 <s>` → 0 if a well-formed dotted-quad, octets `0..255`.
- `ip_in_subnet <ip> <network> <netmask>` → 0 if `ip` belongs to the subnet.
- `ip_in_range <ip> <start> <end>` → 0 if `start ≤ ip ≤ end` (used for the pool test).
- `is_assignable_host <ip> <network> <netmask>` → 0 if a usable host (not network,
  broadcast, or the hub's `.1`).

Has a 15-case smoke test in the repo history; re-run any time the math changes.

## `get_interface.sh` — IP → egress interface helper

`get_interface.sh <ip>` runs `ip route get <ip>` and prints the word after `dev`
(the interface the kernel would use to reach that IP). **Standalone utility — not
invoked by any other script in this repo.** Present in the image for manual diagnostics.

## `scripts/build.sh` + `scripts/deploy-*.sh`

Host-side tooling — **not** copied into the image. All build locally on the target (no
registry/`docker push`).

- `scripts/build.sh [tag]` — `docker build -t arturmatkowski/openvpn-server:<tag> <repo-root>`
  (default tag `latest`). Resolves the repo root from `$0`, so it runs from any cwd; the
  build context is the repo root and the Dockerfile COPYs from `src/`.
- `scripts/deploy-prod.sh` — checks `.env` exists, `build.sh latest`, then
  `IMAGE_TAG=latest docker compose up -d`, then tails logs.
- `scripts/deploy-dev.sh` — same but `:dev` (`IMAGE_TAG=dev`). Dev and prod share the
  **same `.env`**; only the image tag differs.

Because compose runs `…:${IMAGE_TAG:-latest}` and each deploy script sets `IMAGE_TAG` to
the tag it just built, the built tag and the run tag always agree — no manual retag. See
[deployment.md](deployment.md).

## `Dockerfile`

- Base `ubuntu:22.04` (amd64 — targeted at an Intel N100).
- Installs `openvpn`, `easy-rsa`, `iptables`, `ca-certificates`.
- `ENV EASYRSA=/usr/share/easy-rsa`, `ENV EASYRSA_PKI=/etc/openvpn/pki`. **No config
  ENVs** — `OPENVPN_HOST_NETWORK` is no longer baked in; all config comes from `.env`
  (see [configuration.md](configuration.md)).
- Symlinks `/usr/share/easy-rsa → /etc/openvpn/easy-rsa`.
- Copies from `src/` (the COPY **sources** are under `src/`; the in-container
  **destinations** are unchanged): `src/init.sh`→`/init.sh`, `src/init_vpn.sh`→`/init_vpn.sh`,
  and `src/{generate_client,revoke_client,host_init,get_interface}.sh`→`/usr/local/bin/`
  (on `PATH`, so callable bare via `docker exec`). `chmod +x` all of them.
- Copies `src/lib_net.sh`→`/usr/local/lib/lib_net.sh` (sourced, so no `chmod +x` needed).
- `ENTRYPOINT ["/init.sh"]`.
- A `.dockerignore` keeps `docs/`, `scripts/`, `.env`, and `*.md` out of the build context.

## `docker-compose.yml`

Single service `openvpn-hub`. Host networking, privileged, `/dev/net/tun`,
`restart: unless-stopped`, `tty`/`stdin_open`, `/opt/openvpn:/etc/openvpn` bind mount,
`image: …:${IMAGE_TAG:-latest}`, and `env_file: .env` (all config injected from `.env`).
Full flag-by-flag rationale: [configuration.md](configuration.md).

## `.env` / `.env.example`

`.env` (gitignored) is the single source of truth for all hub config, injected into the
container via compose `env_file`. `.env.example` is the committed, documented template —
`cp .env.example .env` and edit. See [configuration.md](configuration.md) for the var
reference.

## Repo drift to be aware of

- **`management 127.0.0.1 5555`** in `server.conf` expects an openvpn-monitor sidecar
  that is **not** defined in compose.
- **No `openvpn-host-init.service`** systemd unit exists; host setup runs from the
  entrypoint. (Earlier doc text referenced such a unit — it was never in the repo.)
