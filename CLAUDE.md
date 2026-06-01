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
"Running it" means building the image and `docker compose up -d` on the VPS.

## Topology (the one diagram that matters)

```
  Laptop ──OpenVPN──►  VPS hub (this repo)  ◄──OpenVPN── pfSense ── LAN 192.168.74.0/24
  192.168.75.x          192.168.75.1 / tun0   site client   (pfSense is LAN gateway too)
                        relays tun0 ↔ tun0
                        CCD iroute: LAN → pfSense cert CN
```

- VPN subnet (clients): `192.168.75.0/24`. Home LAN: `192.168.74.0/24`.
- The hub only **relays** between tun endpoints. The return path to the LAN goes
  *back through pfSense*, so the hub does **no NAT/MASQUERADE**.
- Split tunnel: clients keep their own internet; only the LAN route is pushed.

## Critical invariants (break one → silent failure)

1. **CN match (3 places).** The pfSense cert CN == the filename in
   `/etc/openvpn/ccd/<CN>` on the hub == `PFSENSE_CLIENT_CN` in `docker-compose.yml`.
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

| File | Role | Detail |
|------|------|--------|
| `init.sh` | container entrypoint → runs host setup, then exec's the VPN init | `docs/code-map.md` |
| `init_vpn.sh` | PKI init, writes `server-0.conf`, seeds CCD iroute, exec's openvpn | `docs/code-map.md` |
| `host_init.sh` | host-namespace: `ip_forward` + `DOCKER-USER` tun↔tun ACCEPT | `docs/code-map.md` |
| `generate_client.sh` | build client cert + assemble `.ovpn` (multi-remote) | `docs/client-management.md` |
| `get_interface.sh` | standalone helper: IP → egress iface (unused by other scripts) | `docs/code-map.md` |
| `buildDockerImage.sh` | `docker build … :dev` | `docs/deployment.md` |
| `Dockerfile` | `ubuntu:22.04` + openvpn/easy-rsa/iptables | `docs/code-map.md` |
| `docker-compose.yml` | host networking, privileged, `/opt/openvpn` bind mount, env | `docs/configuration.md` |

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

- **Image tag mismatch:** `buildDockerImage.sh` builds `:dev`; `docker-compose.yml`
  pulls `:latest`. After a local build you must retag or edit the compose tag.
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
- Env defaults use `: "${VAR:=default}"` — only fill *unset* vars; compose wins,
  then `Dockerfile` `ENV`, then the script default.
- Persistent state (PKI, `ta.key`, `ccd/`, logs, `.ovpn`) lives under `/etc/openvpn`
  in-container, bind-mounted to `/opt/openvpn` on the host.
