#!/usr/bin/env bash
#
# revoke_client.sh  –  revoke a client certificate and refresh the CRL.
#                      Counterpart to generate_client.sh.
#
#   Usage: revoke_client.sh <client_name> [-f|--force]
#          (interactive confirmation unless -f; run with: docker exec -it ...)
#
# What it does:
#   1. Revokes the client's certificate (easyrsa revoke).
#   2. Regenerates the CRL the server enforces (crl-verify) and publishes a
#      world-readable copy at /etc/openvpn/crl.pem. The hub runs as `user nobody`
#      and re-reads the CRL on every new TLS connection, but pki/crl.pem is
#      0600 root and pki/ is 0700 — so the dropped-privilege process can only
#      read the 0644 copy under /etc/openvpn (mode 0755). Revocation therefore
#      takes effect on the client's next (re)connect, no hub restart required.
#   3. Removes the client's generated .ovpn and its static CCD pin (freeing the IP).
#
# The pfSense site client (INTRANET_PEER_CN) is guarded: revoking it tears down
# the LAN tunnel, and its CCD file (the iroute, owned by init_vpn.sh) is left
# untouched. Revoking it still needs explicit confirmation / --force.
#
set -e
set -x                                      # verbose for debugging (toggled off below)

: "${INTRANET_PEER_CN:=pfsense-site}"

PKI=/etc/openvpn/pki
CRL_PUB=/etc/openvpn/crl.pem
CLIENTS_DIR=/etc/openvpn/clients
CCD_DIR=/etc/openvpn/ccd

###############################################################################
# 1.  Parse CLI
###############################################################################
CLIENT=""
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force|-y|--yes) FORCE=1 ;;
        -h|--help) echo "Usage: $0 <client_name> [-f|--force]"; exit 0 ;;
        -*) echo "ERROR: unknown option '$1'" >&2; exit 1 ;;
        *)  if [ -z "$CLIENT" ]; then CLIENT="$1"
            else echo "ERROR: unexpected argument '$1'" >&2; exit 1; fi ;;
    esac
    shift
done

if [ -z "$CLIENT" ]; then
    echo "Usage: $0 <client_name> [-f|--force]"
    echo "  Revokes the cert, refreshes the CRL, and removes the .ovpn + CCD pin."
    exit 1
fi

###############################################################################
# 2.  Validate the client exists; decide if it's already revoked
###############################################################################
set +x                                      # keep validation/prompt readable

if [ ! -f "$PKI/index.txt" ]; then
    echo "ERROR: $PKI/index.txt not found — no PKI to revoke against." >&2
    exit 1
fi

# Escape regex metacharacters in the (untrusted) client name before matching.
esc=$(printf '%s' "$CLIENT" | sed 's/[][\.*^$/]/\\&/g')

ALREADY_REVOKED=0
if grep -qE "^V[[:space:]].*/CN=${esc}\$" "$PKI/index.txt"; then
    :                                        # a currently-valid cert: revoke it
elif grep -qE "^R[[:space:]].*/CN=${esc}\$" "$PKI/index.txt"; then
    ALREADY_REVOKED=1
    echo "Note: '${CLIENT}' is already revoked — refreshing the CRL + cleaning up only."
else
    echo "ERROR: no certificate with CN '${CLIENT}' found in the PKI." >&2
    echo "       Known CNs:" >&2
    sed -n 's#.*/CN=\(.*\)$#  \1#p' "$PKI/index.txt" >&2
    exit 1
fi

###############################################################################
# 3.  Confirm (revocation is irreversible)
###############################################################################
if [ "$CLIENT" = "$INTRANET_PEER_CN" ]; then
    echo "WARNING: '${CLIENT}' is the pfSense site client. Revoking it drops the LAN"
    echo "         tunnel for ALL road-warriors until pfSense gets a new certificate."
fi

if [ "$FORCE" -ne 1 ]; then
    if [ ! -t 0 ]; then
        echo "ERROR: refusing to revoke without confirmation. Re-run with -f, or" >&2
        echo "       interactively: docker exec -it openvpn-hub revoke_client.sh ${CLIENT}" >&2
        exit 1
    fi
    read -r -p "Revoke certificate '${CLIENT}'? This cannot be undone. [y/N] " _ans
    case "${_ans,,}" in
        y|yes) ;;
        *) echo "Aborted — nothing changed."; exit 0 ;;
    esac
fi

set -x                                      # restore verbose logging

###############################################################################
# 4.  Revoke + regenerate and publish the CRL
###############################################################################
cd /etc/openvpn/easy-rsa
export EASYRSA_BATCH=1

if [ "$ALREADY_REVOKED" -ne 1 ]; then
    ./easyrsa revoke "$CLIENT"
fi
./easyrsa gen-crl

# Publish a world-readable CRL copy for the dropped-privilege openvpn process.
install -m 0644 "$PKI/crl.pem" "$CRL_PUB"

set +x
echo "✓ CRL refreshed and published → ${CRL_PUB}"

###############################################################################
# 5.  Clean up the client's artifacts
###############################################################################
if [ -f "${CLIENTS_DIR}/${CLIENT}.ovpn" ]; then
    rm -f "${CLIENTS_DIR}/${CLIENT}.ovpn"
    echo "✓ Removed ${CLIENTS_DIR}/${CLIENT}.ovpn"
fi

if [ "$CLIENT" = "$INTRANET_PEER_CN" ]; then
    echo "• Left ${CCD_DIR}/${CLIENT} in place (owned by init_vpn.sh — carries the iroute)."
elif [ -f "${CCD_DIR}/${CLIENT}" ]; then
    rm -f "${CCD_DIR}/${CLIENT}"
    echo "✓ Removed static CCD pin ${CCD_DIR}/${CLIENT} (its tunnel IP is free again)."
fi

###############################################################################
# 6.  Report
###############################################################################
echo
echo "✓ '${CLIENT}' revoked."
echo "  The running hub re-reads the CRL on each new TLS connection, so ${CLIENT} is"
echo "  rejected on its next (re)connect. To drop an already-connected session"
echo "  immediately, run: docker compose restart openvpn-hub"
