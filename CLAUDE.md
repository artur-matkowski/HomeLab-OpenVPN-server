# CLAUDE.md — LLM context entry point

> Auto-loaded each session. This file is the **map**: enough to rebuild the full
> mental model and route to the right detail doc without reading the scripts.
> Detailed docs live in [`docs/`](docs/). Human-facing intro is [`Readme.md`](Readme.md).

## What this repo is

A Docker image + scripts that run an **OpenVPN hub** on a public-IP VPS (Hetzner).
The hub lets road-warrior laptops/phones reach a home LAN that sits behind CGNAT
(no public/static IP at home). A home **pfSense** router dials *out* to the hub as
an OpenVPN site client; because pfSense is also the LAN gateway, every LAN host is
reachable through it with no per-host routes.

It is **infrastructure-as-scripts**, not an application: no build/test/lint suite.
"Running it" means `./scripts/deploy-prod.sh` on the VPS (build the image locally +
`docker compose up -d`). Config is read from `.env` (copy `.env.example` first).

## Topology (the one diagram that matters)

```
  Laptop ──OpenVPN──►  VPS hub (this repo)  ◄──OpenVPN── pfSense ── LAN 192.168.74.0/24
  192.168.75.x          192.168.75.1 / tun0   site client   (pfSense is LAN gateway too)
                        relays tun0 ↔ tun0
                        CCD iroute: LAN → pfSense cert CN
```

- VPN subnet (clients): `192.168.75.0/24`. Home LAN: `192.168.74.0/24`.
- Address split: `.2`–`.127` = **static** pins (CCD `ifconfig-push`, incl. pfSense `.2`);
  `.128`–`.254` = **dynamic** pool (`ifconfig-pool`). Kept disjoint so a dynamic lease
  never collides with an offline static client. See `docs/architecture.md` (Addressing).
- The hub only **relays** between tun endpoints. The return path to the LAN goes
  *back through pfSense*, so the hub does **no NAT/MASQUERADE**.
- Split tunnel: clients keep their own internet; only the LAN route is pushed.
- DNS is **server-pushed** (`VPN_DNS`); `server.conf` is rewritten every start, so edit
  `.env` + redeploy re-applies it — no `.ovpn` regen.

## Critical invariants (break one → silent failure)

1. **CN match (3 places).** The pfSense cert CN == the filename in
   `/etc/openvpn/ccd/<CN>` on the hub == `PFSENSE_CLIENT_CN` in `.env`.
   The CCD `iroute` is the *only* thing that makes the LAN reachable through pfSense.
   Mismatch ⇒ tunnel connects, road-warriors see the VPN subnet but never the LAN.
2. **tls-auth triad.** Control channel HMAC depends only on: `ta.key` bytes,
   key direction (hub `0` / client `1`), and `auth SHA256`. Any drift ⇒ HMAC failure.
   OpenVPN reads `ta.key` once at start and caches it — corruption surfaces only on
   restart (see `docs/troubleshooting.md`).
3. **`tun0 ↔ tun0 ACCEPT` in `DOCKER-USER`.** Docker sets `FORWARD DROP`; the hub's
   relay only works because `host_init.sh` inserts this rule. Missing ⇒ intra-VPN and
   VPN↔LAN forwarding silently dropped.
4. **No MASQUERADE on the hub.** Return routing relies on pfSense, not the VPS WAN.
5. **Split tunnel.** Client `.ovpn` ships `pull-filter ignore "redirect-gateway"`.

## Repo file map

Layout: **`src/`** = everything baked into the image (COPYed by the Dockerfile);
**`scripts/`** = host-side build/deploy tooling (never in the image); config lives
in **`.env`** (gitignored; `.env.example` is the committed template).

| File | Role | Detail |
|------|------|--------|
| `src/init.sh` | container entrypoint → runs host setup, then exec's the VPN init | `docs/code-map.md` |
| `src/init_vpn.sh` | PKI init, writes `server-0.conf` (+`ifconfig-pool`, `crl-verify`), bootstraps/publishes CRL, seeds CCD iroute + pfSense IP pin, exec's openvpn | `docs/code-map.md` |
| `src/host_init.sh` | host-namespace: `ip_forward` + `DOCKER-USER` tun↔tun ACCEPT | `docs/code-map.md` |
| `src/generate_client.sh` | build client cert + assemble `.ovpn` (multi-remote); **interactive** static-IP pin via CCD | `docs/client-management.md` |
| `src/revoke_client.sh` | revoke a client cert, refresh+publish the CRL, drop its `.ovpn`+CCD pin; pfSense-guarded | `docs/client-management.md` |
| `src/lib_net.sh` | shared IPv4 helpers, sourced by `init_vpn.sh` + `generate_client.sh` | `docs/code-map.md` |
| `src/get_interface.sh` | standalone helper: IP → egress iface (unused by other scripts) | `docs/code-map.md` |
| `scripts/build.sh` | `build.sh [tag]` → `docker build … :<tag>` (default `latest`); context = repo root | `docs/deployment.md` |
| `scripts/deploy-dev.sh` | build `:dev` + `IMAGE_TAG=dev docker compose up -d` (testing) | `docs/deployment.md` |
| `scripts/deploy-prod.sh` | build `:latest` + `IMAGE_TAG=latest docker compose up -d` (VPS) | `docs/deployment.md` |
| `Dockerfile` | `ubuntu:22.04` + openvpn/easy-rsa/iptables; COPYs from `src/` | `docs/code-map.md` |
| `docker-compose.yml` | host networking, privileged, `/opt/openvpn` bind mount, `env_file: .env`, `image …:${IMAGE_TAG:-latest}` | `docs/configuration.md` |
| `.env` / `.env.example` | all hub config (gitignored) / committed template | `docs/configuration.md` |

## Documentation index — read what you need

| Doc | Read it when you need… |
|-----|------------------------|
| [`docs/architecture.md`](docs/architecture.md) | the routing/crypto model and *why* each design choice |
| [`docs/configuration.md`](docs/configuration.md) | env var reference, compose flags, generated `server.conf` |
| [`docs/deployment.md`](docs/deployment.md) | how to build + deploy on the VPS, host networking, first run |
| [`docs/client-management.md`](docs/client-management.md) | generating pfSense/road-warrior `.ovpn`, multi-remote |
| [`docs/pfsense-setup.md`](docs/pfsense-setup.md) | the pfSense UI walkthrough, field by field |
| [`docs/operations.md`](docs/operations.md) | verification, day-2 ops, logs, the management interface |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | symptom → cause → fix for every known failure mode |
| [`docs/code-map.md`](docs/code-map.md) | what every script/file does, line by line, with gotchas |

## Known drift / gotchas (verify before trusting)

- **No monitor sidecar yet:** `init_vpn.sh` enables `management 127.0.0.1 5555`
  for an openvpn-monitor sidecar, but `docker-compose.yml` defines no such service.
- **No systemd unit in the repo:** older docs mentioned `openvpn-host-init.service`;
  host setup actually runs from the container entrypoint (`init.sh` → `host_init.sh`).
- **Deployed config can lag the repo.** PKI/`ta.key` persist on the VPS bind mount
  `/opt/openvpn` and are regenerated only if `ca.crt` is missing; a long-running
  container may predate repo changes (e.g. MTU, `management`). Verify against the
  live container, not the repo: `docker exec openvpn-hub cat /etc/openvpn/server-0.conf`.

## Conventions

- Scripts are `bash`, run with `set -e` (and `set -x` for verbose container logs).
- Env defaults use `: "${VAR:=default}"` — only fill *unset* vars; `.env` (injected
  via compose `env_file`) wins, then the script default. (The Dockerfile no longer
  bakes in config ENVs — config lives in `.env`.)
- Persistent state (PKI, `ta.key`, `ccd/`, logs, `.ovpn`) lives under `/etc/openvpn`
  in-container, bind-mounted to `/opt/openvpn` on the host.
