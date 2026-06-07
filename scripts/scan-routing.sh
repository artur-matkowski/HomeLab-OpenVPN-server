#!/usr/bin/env bash
#
# scan-routing.sh  –  audit (and optionally clean) the host-side routing/firewall
#                     state this OpenVPN hub — or any *previous* version of it —
#                     leaves on the VPS.
#
# WHY THIS EXISTS
#   The hub runs with `network_mode: host` + `privileged`, so its entrypoint
#   (host_init.sh) edits the *host* kernel and *host* iptables, and OpenVPN itself
#   adds routes/tun devices in the host netns. Across versions the footprint has
#   drifted: the current code only adds a DOCKER-USER tun↔tun ACCEPT + ip_forward,
#   but OLDER versions also added `nat POSTROUTING … MASQUERADE` and direct
#   `FORWARD` rules. A box that has run several versions can accumulate stale rules
#   that silently shadow or contradict the intended design (see docs/architecture.md
#   "Why no NAT / MASQUERADE"). This tool finds that residue so you can decide.
#
# WHAT IT INSPECTS
#   1. iptables filter  – FORWARD / DOCKER-USER rules referencing a tunN iface or
#                         the configured VPN/LAN subnets (every version's ACCEPTs).
#   2. iptables nat     – POSTROUTING MASQUERADE/SNAT from an RFC1918 source
#                         (left by old versions; the current design adds none).
#   3. kernel routes    – routes via a tunN device + leftover tunN interfaces
#                         (persist-tun crash residue; normally vanish on shutdown).
#   4. sysctl           – net.ipv4.ip_forward=1 in the running kernel and in
#                         /etc/sysctl.conf (+ /etc/sysctl.d/*, reported only).
#
# SAFETY MODEL
#   * Read-only by default: it scans and prints; it changes nothing until you
#     answer a per-item prompt (y = remove this / n = keep / a = remove all
#     remaining / q = quit). `--report` disables prompting entirely.
#   * Highlights findings that match the CURRENT .env config (green = active
#     config) vs. residue from a different/older config (yellow).
#   * Protects the live hub: if container `openvpn-hub` is up, rules/routes it is
#     currently using are marked "IN USE" and skipped from cleaning unless you
#     pass --include-active (removing them would drop the running tunnel).
#
# USAGE
#   sudo ./scripts/scan-routing.sh [options]
#     --report            scan and print only; never prompt, never change anything
#     --include-active    also allow cleaning rules the running hub is using
#     --env FILE          path to the .env to read (default: repo-root .env)
#     --no-color          plain output (also auto-disabled when not a TTY)
#     -h, --help          this help
#
#   Cleaning iptables/routes/sysctl needs root — run under sudo. Without root the
#   scan still runs but is incomplete (iptables listing requires privileges) and
#   cleaning is disabled.
set -euo pipefail

# -----------------------------------------------------------------------------
# Args
# -----------------------------------------------------------------------------
REPORT_ONLY=0
INCLUDE_ACTIVE=0
NO_COLOR=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)         REPORT_ONLY=1 ;;
    --include-active) INCLUDE_ACTIVE=1 ;;
    --no-color)       NO_COLOR=1 ;;
    --env)            shift; ENV_FILE="${1:?--env needs a path}" ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ "$NO_COLOR" -eq 0 ]; then
  C_RESET=$'\e[0m'; C_HDR=$'\e[1m'; C_DIM=$'\e[2m'
  C_ENV=$'\e[1;32m'   # matches current .env (active config)
  C_RES=$'\e[33m'     # residue (old/foreign config)
  C_ACT=$'\e[36m'     # in use by the running hub
  C_WARN=$'\e[1;31m'
else
  C_RESET=; C_HDR=; C_DIM=; C_ENV=; C_RES=; C_ACT=; C_WARN=
fi

# -----------------------------------------------------------------------------
# Read current config from .env (best effort) so we can highlight live matches.
# env_file format is literal KEY=value, single-token (see .env.example), so a
# grep+cut parse is safe and avoids sourcing arbitrary content.
# -----------------------------------------------------------------------------
env_get() {
  local key="$1" def="${2:-}" val
  val="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  val="${val%$'\r'}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$def"
}

mask2prefix() {
  local m="$1" o a b c d bits=0
  IFS=. read -r a b c d <<<"$m"
  for o in "$a" "$b" "$c" "$d"; do
    case "$o" in
      255) bits=$((bits+8));; 254) bits=$((bits+7));; 252) bits=$((bits+6));;
      248) bits=$((bits+5));; 240) bits=$((bits+4));; 224) bits=$((bits+3));;
      192) bits=$((bits+2));; 128) bits=$((bits+1));; 0) ;;
      *) printf 24; return;;
    esac
  done
  printf '%s' "$bits"
}

ENV_PRESENT=1
[ -f "$ENV_FILE" ] || ENV_PRESENT=0

OPENVPN_NETWORK="$(env_get OPENVPN_NETWORK 192.168.75.0)"
OPENVPN_NETMASK="$(env_get OPENVPN_NETMASK 255.255.255.0)"
OPENVPN_HOST_NETWORK="$(env_get OPENVPN_HOST_NETWORK 192.168.74.0)"
OPENVPN_HOST_NETMASK="$(env_get OPENVPN_HOST_NETMASK 255.255.255.0)"
TUN_IFACE="tun0"   # hard-coded by init.sh across every version

VPN_CIDR="${OPENVPN_NETWORK}/$(mask2prefix "$OPENVPN_NETMASK")"
LAN_CIDR="${OPENVPN_HOST_NETWORK}/$(mask2prefix "$OPENVPN_HOST_NETMASK")"

# -----------------------------------------------------------------------------
# Environment probes
# -----------------------------------------------------------------------------
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

HUB_RUNNING=0
if command -v docker >/dev/null 2>&1; then
  if [ -n "$(docker ps --filter 'name=^/openvpn-hub$' --format '{{.Names}}' 2>/dev/null || true)" ]; then
    HUB_RUNNING=1
  fi
fi
LIVE_TUN=0
ip link show "$TUN_IFACE" >/dev/null 2>&1 && LIVE_TUN=1

# -----------------------------------------------------------------------------
# Findings store (parallel arrays)
#   KIND: iptf | iptn | route | iface | sysctl-file | sysctl-other | sysctl-run
#   TAG : ENV (matches current .env) | RESIDUE (old/foreign) | INFO
# -----------------------------------------------------------------------------
F_CAT=(); F_KIND=(); F_PAYLOAD=(); F_TABLE=(); F_DESC=(); F_TAG=(); F_ACTIVE=(); F_CLEANABLE=()

add_finding() { # cat kind payload table desc tag active cleanable
  F_CAT+=("$1"); F_KIND+=("$2"); F_PAYLOAD+=("$3"); F_TABLE+=("$4")
  F_DESC+=("$5"); F_TAG+=("$6"); F_ACTIVE+=("$7"); F_CLEANABLE+=("$8")
}

# Tag a rule/route by comparing the /24-style tokens it carries against the
# current .env. Any foreign subnet => RESIDUE; only-current => ENV; no subnet
# (shape-only rule) => ENV iff it names the live tun iface.
tag_for() {
  local t="$1" tok foreign=0 hascur=0
  while read -r tok; do
    [ -z "$tok" ] && continue
    if [ "$tok" = "$VPN_CIDR" ] || [ "$tok" = "$LAN_CIDR" ]; then hascur=1; else foreign=1; fi
  done < <(printf '%s\n' "$t" | grep -oE '[0-9]+(\.[0-9]+){3}/[0-9]+' || true)
  if [ "$foreign" = 1 ]; then printf 'RESIDUE'; return; fi
  if [ "$hascur" = 1 ]; then printf 'ENV'; return; fi
  if printf '%s' "$t" | grep -qE "(^| )${TUN_IFACE}( |\$)"; then printf 'ENV'; else printf 'RESIDUE'; fi
}

# Is a finding currently relied upon by the running hub?
active_for() { # kind text
  local kind="$1" text="$2"
  [ "$HUB_RUNNING" -eq 1 ] || { printf 0; return; }
  case "$kind" in
    sysctl-run|sysctl-file|sysctl-other) printf 1 ;;   # forwarding underpins the hub
    iface)  [ "$text" = "$TUN_IFACE" ] && printf 1 || printf 0 ;;
    route|iptf|iptn)
      if printf '%s' "$text" | grep -qE "(^| )${TUN_IFACE}( |\$)"; then printf 1; else printf 0; fi ;;
    *) printf 0 ;;
  esac
}

# -----------------------------------------------------------------------------
# Scanners
# -----------------------------------------------------------------------------
scan_filter() {
  local line
  while read -r line; do
    case "$line" in -A*) ;; *) continue;; esac
    # Skip Docker's own bridge plumbing — never our rule, dangerous to remove.
    printf '%s' "$line" | grep -qE '(docker0|br-[0-9a-f]+|veth)' && continue
    # Candidate only if it references a tunN iface. Every version of host_init.sh
    # tags its FORWARD/DOCKER-USER rules with `-i tun0`/`-o tun0`, so this catches
    # them all while never matching the host's own (physical-NIC) firewall rules.
    printf '%s' "$line" | grep -qE -- '-(i|o) tun[0-9]+' || continue
    add_finding "iptables filter (FORWARD / DOCKER-USER)" "iptf" "$line" "" \
      "$line" "$(tag_for "$line")" "$(active_for iptf "$line")" 1
  done < <(iptables -S 2>/dev/null || true)
}

scan_nat() {
  local line
  while read -r line; do
    case "$line" in -A*) ;; *) continue;; esac
    printf '%s' "$line" | grep -qE -- '-j (MASQUERADE|SNAT)' || continue
    printf '%s' "$line" | grep -qE '(docker0|br-[0-9a-f]+|veth)' && continue   # Docker's NAT
    # Broad: any private-source masquerade/snat (the current hub adds none at all).
    printf '%s' "$line" | grep -qE -- '-s (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' || continue
    add_finding "iptables nat (POSTROUTING MASQUERADE/SNAT)" "iptn" "$line" "nat" \
      "$line" "$(tag_for "$line")" "$(active_for iptn "$line")" 1
  done < <(iptables -t nat -S 2>/dev/null || true)
}

scan_routes() {
  local line
  while read -r line; do
    [ -z "$line" ] && continue
    # Only routes that egress via a tunN device. A VPN/LAN subnet reachable via a
    # physical NIC is the host's own connected network, NOT something we added —
    # flagging it would offer to delete the box's real routing.
    printf '%s' "$line" | grep -qE 'dev tun[0-9]+' || continue
    add_finding "kernel routes (via tunN)" "route" "$line" "" \
      "$line" "$(tag_for "$line")" "$(active_for route "$line")" 1
  done < <(ip route show 2>/dev/null || true)
}

scan_ifaces() {
  local dev
  while read -r dev; do
    [ -z "$dev" ] && continue
    local tag; [ "$dev" = "$TUN_IFACE" ] && tag=ENV || tag=RESIDUE
    add_finding "tun interfaces" "iface" "$dev" "" \
      "$dev (tunnel device)" "$tag" "$(active_for iface "$dev")" 1
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^tun[0-9]+$' || true)
}

scan_sysctl() {
  local f
  for f in /etc/sysctl.conf /etc/sysctl.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' "$f" 2>/dev/null; then
      if [ "$f" = /etc/sysctl.conf ]; then
        add_finding "sysctl ip_forward (persistent)" "sysctl-file" "$f" "" \
          "net.ipv4.ip_forward=1  in  $f" "ENV" "$(active_for sysctl-file "")" 1
      else
        # Not written by this software — report, but do not offer to edit someone
        # else's drop-in. Cleanable=0 => print-only with a manual hint.
        add_finding "sysctl ip_forward (persistent)" "sysctl-other" "$f" "" \
          "net.ipv4.ip_forward=1  in  $f  (not managed by this repo)" "INFO" "$(active_for sysctl-other "")" 0
      fi
    fi
  done
  local run; run="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)"
  if [ "$run" = "1" ]; then
    add_finding "sysctl ip_forward (running kernel)" "sysctl-run" "" "" \
      "net.ipv4.ip_forward = 1  (running kernel)" "ENV" "$(active_for sysctl-run "")" 1
  fi
}

# -----------------------------------------------------------------------------
# Removal dispatch (only ever called after an explicit per-item confirmation)
# -----------------------------------------------------------------------------
undo_cmd() { # i -> prints the equivalent manual command (for display / report mode)
  local i="$1" kind="${F_KIND[$i]}" p="${F_PAYLOAD[$i]}"
  case "$kind" in
    iptf) printf 'iptables -D %s' "${p#-A }" ;;
    iptn) printf 'iptables -t nat -D %s' "${p#-A }" ;;
    route) printf 'ip route del %s' "$p" ;;
    iface) printf 'ip link del %s' "$p" ;;
    sysctl-file)  printf "sed -i '/net.ipv4.ip_forward[[:space:]]*=[[:space:]]*1/d' %s" "$p" ;;
    sysctl-other) printf '# edit %s by hand (drop-in not managed here)' "$p" ;;
    sysctl-run)   printf 'sysctl -w net.ipv4.ip_forward=0' ;;
  esac
}

do_remove() { # i -> 0 ok / 1 fail
  local i="$1" kind="${F_KIND[$i]}" p="${F_PAYLOAD[$i]}" tbl="${F_TABLE[$i]}"
  local -a parts
  case "$kind" in
    iptf|iptn)
      read -r -a parts <<< "$p"; parts[0]="-D"          # "-A CHAIN …" -> "-D CHAIN …"
      if [ -n "$tbl" ]; then iptables -t "$tbl" "${parts[@]}"; else iptables "${parts[@]}"; fi ;;
    route)
      local dest dev
      dest="$(awk '{print $1}' <<<"$p")"
      dev="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$p")"
      if [ -n "$dev" ]; then ip route del "$dest" dev "$dev"; else ip route del "$dest"; fi ;;
    iface)
      ip link del "$p" ;;
    sysctl-file)
      cp -a "$p" "${p}.scan-routing.bak.$(date +%s)"
      grep -vE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' "$p" > "${p}.scan-routing.tmp" \
        && mv "${p}.scan-routing.tmp" "$p" ;;
    sysctl-run)
      sysctl -w net.ipv4.ip_forward=0 >/dev/null ;;
    *) return 1 ;;
  esac
}

# -----------------------------------------------------------------------------
# Run scanners
# -----------------------------------------------------------------------------
scan_filter
scan_nat
scan_routes
scan_ifaces
scan_sysctl

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
total="${#F_CAT[@]}"

echo
printf '%s== OpenVPN hub — host routing/firewall audit ==%s\n' "$C_HDR" "$C_RESET"
if [ "$ENV_PRESENT" -eq 1 ]; then
  printf '  config (.env): VPN %s   LAN %s   iface %s\n' "$VPN_CIDR" "$LAN_CIDR" "$TUN_IFACE"
else
  printf '  %s.env not found at %s — highlighting assumes defaults (%s / %s)%s\n' \
    "$C_WARN" "$ENV_FILE" "$VPN_CIDR" "$LAN_CIDR" "$C_RESET"
fi
printf '  hub container: %s   |   %s exists: %s   |   root: %s\n' \
  "$([ "$HUB_RUNNING" -eq 1 ] && echo "${C_ACT}RUNNING${C_RESET}" || echo stopped)" \
  "$TUN_IFACE" "$([ "$LIVE_TUN" -eq 1 ] && echo yes || echo no)" \
  "$([ "$IS_ROOT" -eq 1 ] && echo yes || echo "${C_WARN}no${C_RESET}")"
printf '  legend: %smatches .env%s  %sresidue/old config%s  %sIN USE (protected)%s\n' \
  "$C_ENV" "$C_RESET" "$C_RES" "$C_RESET" "$C_ACT" "$C_RESET"
[ "$IS_ROOT" -eq 0 ] && printf '  %s! not root: iptables scan is incomplete and cleaning is disabled (re-run with sudo)%s\n' "$C_WARN" "$C_RESET"
echo

if [ "$total" -eq 0 ]; then
  echo "No hub-related routing/firewall state detected. Nothing to do."
  exit 0
fi

last_cat=""
for i in $(seq 0 $((total-1))); do
  if [ "${F_CAT[$i]}" != "$last_cat" ]; then
    last_cat="${F_CAT[$i]}"
    printf '%s%s%s\n' "$C_HDR" "$last_cat" "$C_RESET"
  fi
  case "${F_TAG[$i]}" in
    ENV) col="$C_ENV"; badge="[.env]   ";;
    RESIDUE) col="$C_RES"; badge="[residue]";;
    *) col="$C_DIM"; badge="[info]   ";;
  esac
  marker=""
  [ "${F_ACTIVE[$i]}" = "1" ] && marker=" ${C_ACT}<IN USE>${C_RESET}"
  [ "${F_CLEANABLE[$i]}" = "0" ] && marker="${marker} ${C_DIM}(manual only)${C_RESET}"
  printf '  %s[%2d]%s %s%s%s %s%s\n' "$C_DIM" "$i" "$C_RESET" "$col" "$badge" "$C_RESET" "${F_DESC[$i]}" "$marker"
  printf '       %s↳ %s%s\n' "$C_DIM" "$(undo_cmd "$i")" "$C_RESET"
done
echo

# -----------------------------------------------------------------------------
# Interactive cleaning
# -----------------------------------------------------------------------------
if [ "$REPORT_ONLY" -eq 1 ]; then
  echo "Report-only mode (--report): nothing was changed. Copy the ↳ commands above to act manually."
  exit 0
fi
if [ "$IS_ROOT" -eq 0 ]; then
  echo "Not running as root: cleaning is disabled. Re-run with sudo, or use the ↳ commands above."
  exit 0
fi
if [ ! -r /dev/tty ]; then
  echo "No interactive terminal available: skipping cleaning. Use --report, or run from a TTY."
  exit 0
fi

echo "Choose what to remove. Per item: [y]es  [n]o(keep)  [a]ll-remaining  [q]uit"
[ "$INCLUDE_ACTIVE" -eq 0 ] && echo "(IN USE items are protected and skipped; pass --include-active to override.)"
echo

removed=0; failed=0; skipped=0; clean_all=0
for i in $(seq 0 $((total-1))); do
  desc="${F_DESC[$i]}"
  if [ "${F_CLEANABLE[$i]}" = "0" ]; then
    skipped=$((skipped+1)); continue
  fi
  if [ "${F_ACTIVE[$i]}" = "1" ] && [ "$INCLUDE_ACTIVE" -eq 0 ]; then
    printf '  %s[skip IN USE]%s %s\n' "$C_ACT" "$C_RESET" "$desc"
    skipped=$((skipped+1)); continue
  fi

  ans="y"
  if [ "$clean_all" -eq 0 ]; then
    [ "${F_ACTIVE[$i]}" = "1" ] && printf '  %s(this is IN USE by the running hub — removing it may drop the tunnel)%s\n' "$C_WARN" "$C_RESET"
    printf '  remove [%2d] %s ? [y/n/a/q] ' "$i" "$desc"
    read -r ans </dev/tty || ans="q"
  fi
  case "$ans" in
    a|A) clean_all=1; ans="y" ;;
    q|Q) echo "  quit."; break ;;
  esac
  if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
    if do_remove "$i" 2>/tmp/scan-routing.err; then
      printf '    %s✓ removed%s\n' "$C_ENV" "$C_RESET"; removed=$((removed+1))
    else
      printf '    %s✗ failed%s: %s\n' "$C_WARN" "$C_RESET" "$(tr -d '\n' </tmp/scan-routing.err)"; failed=$((failed+1))
    fi
  else
    skipped=$((skipped+1))
  fi
done
rm -f /tmp/scan-routing.err

echo
printf '%sDone.%s removed=%d  failed=%d  kept/skipped=%d\n' "$C_HDR" "$C_RESET" "$removed" "$failed" "$skipped"
if [ "$removed" -gt 0 ]; then
  echo "Note: redeploying the hub (./scripts/deploy-prod.sh) re-applies the rules the current design needs."
fi
exit 0
