# Troubleshooting

Symptom → cause → fix. For the model behind these, see [architecture.md](architecture.md);
for healthy-state checks see [operations.md](operations.md).

## Tunnel is up, but road-warriors can't reach the LAN

**Almost always a CN / CCD mismatch.** The pfSense cert CN must be byte-identical to the
CCD filename and `PFSENSE_CLIENT_CN`. Verify all three on the hub:

```bash
docker exec openvpn-hub ls /etc/openvpn/ccd/
docker exec openvpn-hub grep PFSENSE_CLIENT_CN /proc/1/environ | tr '\0' '\n'
docker exec openvpn-hub grep "Common Name" /etc/openvpn/server-0.log
```

All three must show the same string. If they differ:
1. Fix `PFSENSE_CLIENT_CN` in `.env`; `docker compose up -d openvpn-hub` (or re-run a deploy script).
2. On pfSense, `Status → OpenVPN → Restart this client` to re-trigger the CCD lookup.

Confirm the fix: `server-0.log`'s `ROUTING TABLE` now lists `192.168.74.0/24,<CN>,…`.

## Pings within `192.168.75.0/24` fail (e.g. road-warrior → pfSense tun IP)

The `tun↔tun ACCEPT` rule is missing from `DOCKER-USER`:

```bash
iptables -nL DOCKER-USER          # expect: ACCEPT all -- ... tun0 tun0
```

If absent, the entrypoint didn't finish `host_init.sh` — check `docker logs openvpn-hub`
for errors. `docker compose restart openvpn-hub` re-runs it. (Recall Docker's
`FORWARD DROP` default is why this rule is mandatory — [architecture.md](architecture.md).)

## A client doesn't get its hardcoded static IP (or two clients fight over one)

The static pin lives in `/etc/openvpn/ccd/<name>` as `ifconfig-push <ip> <netmask>` and is
matched by **cert CN == CCD filename**. Check, in order:

```bash
docker exec openvpn-hub cat /etc/openvpn/ccd/<name>     # the pin exists?
docker exec openvpn-hub grep -E '^(server|ifconfig-pool) ' /etc/openvpn/server-0.conf
```

- **CCD filename ≠ cert CN** → OpenVPN never reads the file. The name passed to
  `generate_client.sh` must equal the client's cert CN. (Same matching rule as the pfSense
  iroute, above.)
- **Static IP sits inside the dynamic pool** → another client may have leased it while this
  one was offline, so the two collide. The static range is everything **below**
  `OPENVPN_POOL_START` (`.2`–`.127` by default); the interactive prompt only accepts that
  range, but a pin created before the `ifconfig-pool` reservation existed (or hand-edited)
  could still overlap. Re-issue with an address in the static range, or widen the reservation.
- **pfSense didn't move to `PFSENSE_CLIENT_IP`** → that pin is written by `init_vpn.sh`
  only on (re)start. Run `docker compose up -d openvpn-hub`, then restart the pfSense
  client. An invalid/in-pool `PFSENSE_CLIENT_IP` is logged as a `WARNING` in
  `docker logs openvpn-hub` and skipped (pfSense stays on a dynamic lease).
- **Stale `ipp.txt`** → after changing the pool boundaries, the persisted leases in
  `/etc/openvpn/ipp.txt` can hand out now-out-of-range addresses. Deleting `ipp.txt`
  (it is regenerated) forces clean reassignment.

## `Status → OpenVPN` says "Reconnecting; tls-error"

Control-channel negotiation is failing. Check, in order:
- **Cipher / digest mismatch** — pfSense must offer `AES-256-CBC` and `auth SHA256`
  (see the pfSense crypto section of [pfsense-setup.md](pfsense-setup.md)).
- **TLS keydir direction** — must be **Direction 1** on pfSense (the hub uses `0`).
- **Time skew** — `Status → System Logs → OpenVPN` showing "TLS handshake failed" or
  "Replay-window backtrack" → fix NTP on either end.

## `packet HMAC authentication failed` / tunnel breaks only after a restart

The **tls-auth triad** (`ta.key` bytes + key direction + `auth SHA256`) no longer matches
between hub and client. The classic trap: **OpenVPN reads `ta.key` once at daemon start
and caches it in memory**, so an on-disk key/config that became corrupt keeps working on
a long-running daemon — and fails only when the process restarts and re-reads the broken
config. A tunnel that "worked for months and then died on reconnect" is the signature.

Fix:
1. Re-export a known-good `.ovpn` from the hub and re-paste its `<tls-auth>` block (and
   confirm `auth SHA256`, TLS keydir **Direction 1**) on the client/pfSense.
2. If pfSense self-corrupted the stored key (common after snapshot-build upgrades or the
   OpenVPN 2.6 / DCO migration), use pfSense **Diagnostics → Backup & Restore → Config
   History** to find the change that rewrote it.

Prevention: back up pfSense config before updates, keep a known-good `.ovpn` exported,
and prefer stable over snapshot pfSense builds.

## LAN hosts receive traffic from `192.168.75.x` but replies never arrive

pfSense is missing the **return route**. `Diagnostics → Routes`, search `192.168.75` —
there must be a route via the OpenVPN client interface. If absent, the **IPv4 Remote
network(s)** field (`192.168.75.0/24`) in the pfSense client wasn't saved. Re-edit the
OpenVPN client, save, apply.

## One LAN host works, another doesn't

The broken host has a **custom default gateway** (not pfSense), so it never learns the
return route. Either point its gateway at pfSense, or add a per-host static route for
`192.168.75.0/24` via pfSense.

## "Deployed behaves differently than the repo says"

The live container may predate repo edits — config persists on `/opt/openvpn` and a
long-running container keeps the `server.conf` it started with. Verify the live config
and recreate if needed — see [operations.md](operations.md) "Confirm deployed config".

## Image changes don't take effect after a rebuild

The deploy scripts build and run the **same** tag (`scripts/deploy-prod.sh` → `:latest`,
`scripts/deploy-dev.sh` → `:dev`), so a rebuild is normally picked up automatically. If
you ran `docker compose up` by hand with a stale `IMAGE_TAG`, re-run the matching deploy
script — see [deployment.md](deployment.md).
