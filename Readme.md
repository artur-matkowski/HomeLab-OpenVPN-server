# HomeLab OpenVPN Hub

A Docker-based OpenVPN **hub** for home-lab remote access. It runs on a public-IP
VPS (e.g. Hetzner) and lets road-warrior clients reach a home LAN that sits behind
CGNAT — a home **pfSense** router dials out to the hub as an OpenVPN site client,
and because pfSense is also the LAN gateway, the whole LAN becomes reachable with
no per-host routing.

```
  Laptop ──OpenVPN──►  VPS hub (this repo)  ◄──OpenVPN── pfSense ── LAN 192.168.74.0/24
```

## Quick start (on the VPS)

```bash
git clone <this-repo> && cd <this-repo>
cp .env.example .env
# Edit .env: set SERVER_ADDRESS, VPN_DNS, and PFSENSE_CLIENT_CN (at minimum).
./scripts/deploy-prod.sh       # builds :latest locally + docker compose up -d + tails logs
```

For a throwaway test build (`:dev` tag, same `.env`) use `./scripts/deploy-dev.sh`.

Then generate client profiles:

```bash
docker exec -it openvpn-hub generate_client.sh laptop1
docker cp openvpn-hub:/etc/openvpn/clients/laptop1.ovpn ./
```

## Documentation

This project is documented as a set of focused, dense docs (optimized so an LLM or a
new operator can rebuild full context without reading the scripts):

- **[CLAUDE.md](CLAUDE.md)** — one-page map, topology, and the critical invariants.
- **[docs/architecture.md](docs/architecture.md)** — routing/crypto model and design rationale.
- **[docs/configuration.md](docs/configuration.md)** — env vars, compose flags, generated `server.conf`.
- **[docs/deployment.md](docs/deployment.md)** — build + deploy on the VPS, host networking, first run.
- **[docs/client-management.md](docs/client-management.md)** — generating `.ovpn` profiles, multi-remote.
- **[docs/pfsense-setup.md](docs/pfsense-setup.md)** — pfSense UI walkthrough, field by field.
- **[docs/operations.md](docs/operations.md)** — verification, day-2 ops, monitoring, logs.
- **[docs/troubleshooting.md](docs/troubleshooting.md)** — symptom → cause → fix for known failures.
- **[docs/code-map.md](docs/code-map.md)** — what every script and config file does.

## License

Provided as-is for home-lab use. Issues and PRs welcome.
