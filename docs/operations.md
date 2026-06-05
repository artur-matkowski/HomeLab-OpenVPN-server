# Operations

Verification and day-2 tasks. Failures and their fixes are in
[troubleshooting.md](troubleshooting.md).

## Verify a healthy hub

**On the VPS / hub:**

```bash
docker compose logs openvpn-hub        # expect: "Initialization Sequence Completed"
ip route                               # expect a route for 192.168.74.0/24 via tun0 once pfSense is up
iptables -S DOCKER-USER                # expect: -A DOCKER-USER -i tun0 -o tun0 -j ACCEPT
docker exec openvpn-hub cat /etc/openvpn/server-0.log   # status file; ROUTING TABLE section
```

In `server-0.log`'s `ROUTING TABLE`, the pfSense CN must appear with **both** its tunnel
IP (`192.168.75.x`) and the LAN (`192.168.74.0/24,<CN>,…`). A missing LAN line means the
CCD iroute isn't active → [troubleshooting.md](troubleshooting.md) "LAN unreachable".

**On pfSense:** `Status → OpenVPN` shows the client **up**, virtual address inside
`192.168.75.0/24`.

**End-to-end:**

```
laptop$  ping 192.168.75.1          # the hub
laptop$  ping 192.168.74.200        # a LAN host (through pfSense)
laptop$  curl ifconfig.me           # shows the LAPTOP's own public IP (split tunnel works)
LANhost$ ping <laptop tun IP>       # reverse path; tun IP visible in pfSense OpenVPN status
```

## Confirm deployed config matches the repo

The deployed container may predate repo edits (config persists on `/opt/openvpn`, and a
long-running container keeps the config it started with). Always check the **live**
config, not just the repo:

```bash
docker exec openvpn-hub cat /etc/openvpn/server-0.conf
docker exec openvpn-hub grep -c 'tun-mtu\|management' /etc/openvpn/server-0.conf
```

To apply repo changes to a running hub: rebuild/retag the image (see
[deployment.md](deployment.md)) then `docker compose up -d openvpn-hub` (recreates the
container; `server-0.conf` is rewritten from current env on start).

## Day-2 tasks

| Task | Command |
|------|---------|
| Add a road-warrior | `docker exec -it openvpn-hub generate_client.sh <name>` → `docker cp …` |
| Recreate after env change | edit `.env`, `docker compose up -d openvpn-hub` (or re-run a deploy script) |
| Restart in place | `docker compose restart openvpn-hub` (re-runs `host_init.sh` too) |
| Tail VPN status | `docker exec openvpn-hub cat /etc/openvpn/server-0.log` |
| Re-apply host iptables manually | `sudo ./src/host_init.sh tun0 192.168.75.0/24 192.168.74.0/24` |

Changing crypto-affecting settings (`auth`, `cipher`, `ta.key`, key direction) requires
re-syncing pfSense and re-exporting road-warrior `.ovpn`s — see the tls-auth triad in
[architecture.md](architecture.md) and the HMAC failure mode in
[troubleshooting.md](troubleshooting.md).

## Monitoring (management interface)

`server.conf` enables `management 127.0.0.1 5555` — a **read-only** OpenVPN management
socket bound to loopback (never reachable off-host). It is intended for an
`openvpn-monitor` sidecar that would run with `network_mode: host` and connect via
`127.0.0.1:5555`.

**Status: not wired up.** `docker-compose.yml` defines no monitor service yet. The
directive alone is harmless. To add monitoring, define a sidecar service (host network)
that speaks the OpenVPN management protocol to `127.0.0.1:5555`. Until then, use the
`status` log file (`server-0.log`) for connection state.
