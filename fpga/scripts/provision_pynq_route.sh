#!/usr/bin/env bash
# provision_pynq_route.sh — one-time per board: install a static route
# to the peer board's PS-side /24 via mapstone-dev as gateway, persistent
# across reboots via systemd-networkd drop-in.
#
# Without this, the peer-agent SSH spawn from one board to the other
# fails with "Network is unreachable" — the boards are on separate
# /24s and only mapstone-dev bridges them. After this lands, ssh
# xilinx@<peer-IP> works directly from one board to the other.
#
# Designed to be invoked by a fpgahub manifest action (see
# fpga/fpgahub.toml ::provision_pynq_route). Works equally well as a
# standalone tool when run from the host that has SSH access to the
# board.
#
# Required env (one or more):
#   PYNQ_HOST=user@host       — SSH target. Default: arg $1.
#   PYNQ_PROXY=user@jumphost  — Optional ProxyJump.
#   PYNQ_PASSWORD=...         — sudo password (or NOPASSWD-aware).
#   PEER_NET=192.168.6.0/24   — Peer board's /24. Default: arg $2.
#   GATEWAY=192.168.4.1       — This board's local /24 gateway IP
#                                (= mapstone-dev's interface address).
#                                Default: arg $3.
#
# Idempotent: detects an existing route file with the same destination
# and exits 0 without touching anything. Replaces a stale entry that
# points elsewhere.

set -euo pipefail

PYNQ_HOST="${PYNQ_HOST:-${1:-}}"
PEER_NET="${PEER_NET:-${2:-}}"
GATEWAY="${GATEWAY:-${3:-}}"
PYNQ_PROXY="${PYNQ_PROXY:-}"
PASSWORD="${PYNQ_PASSWORD:-}"

if [ -z "$PYNQ_HOST" ] || [ -z "$PEER_NET" ] || [ -z "$GATEWAY" ]; then
    echo "ERROR: required: PYNQ_HOST, PEER_NET=<peer/24>, GATEWAY=<local-net-gateway>" >&2
    echo "  e.g. PYNQ_HOST=xilinx@192.168.4.101 PEER_NET=192.168.6.0/24 GATEWAY=192.168.4.1 $0" >&2
    exit 2
fi
if [ -z "$PASSWORD" ]; then
    echo "ERROR: PYNQ_PASSWORD env required (sudo). In fpgahub action this comes from secret_env." >&2
    exit 2
fi

SSH_OPTS=(-oBatchMode=yes -oStrictHostKeyChecking=accept-new -oUserKnownHostsFile=/dev/null)
if [ -n "$PYNQ_PROXY" ]; then
    SSH_OPTS+=(-oProxyJump="$PYNQ_PROXY")
fi

echo "Provisioning route on $PYNQ_HOST: $PEER_NET via $GATEWAY..."

# We use a systemd-networkd drop-in keyed off the .network file that
# already governs the ethernet interface — but we don't know which one
# a priori (eth0 vs eth1 depending on the PYNQ image's naming). Instead
# install a free-standing 50-tidelink-peer-route.network drop-in that
# matches the interface that owns the GATEWAY's /24 (so the route is
# attached when that interface is up).
ssh "${SSH_OPTS[@]}" "$PYNQ_HOST" \
    "PASSWORD='$PASSWORD' PEER_NET='$PEER_NET' GATEWAY='$GATEWAY' bash -s" <<'REMOTE_SCRIPT'
set -eu

# Find the interface owning GATEWAY's /24. The gateway is .1 in its
# subnet; figure out which interface has an IP on that subnet.
GATEWAY_NET=${GATEWAY%.*}.0/24
IFACE=$(ip -o -4 addr show | awk -v net="${GATEWAY_NET%/*}" '
    {
        split($4, a, "/")
        split(a[1], b, ".")
        if (b[1]"."b[2]"."b[3]".0" == net) { print $2; exit }
    }')

if [ -z "$IFACE" ]; then
    echo "ERROR: no interface owns $GATEWAY_NET — cannot determine which iface to attach the route to" >&2
    exit 3
fi

echo "Local interface for $GATEWAY_NET: $IFACE"

# systemd-networkd drop-in. Match by interface name; declare the
# specific peer-net route via the gateway. We use a 50- prefix so
# it sorts after the image's default (typically 80- or 99-).
DROPIN_FILE=/etc/systemd/network/50-tidelink-peer-route.network
EXPECTED=$(cat <<EOF
# Installed by tidelink/fpga/scripts/provision_pynq_route.sh.
# Adds a kernel route to the peer PYNQ-Z2 board's PS-side /24 via
# mapstone-dev as gateway, so the stress runner's peer-agent SSH
# works without manual ProxyJump plumbing.
[Match]
Name=$IFACE

[Network]
# Inherit DHCP/static behaviour from whatever the image's primary
# .network unit declares; we only contribute a route here. Leaving
# this section empty is intentional.

[Route]
Destination=$PEER_NET
Gateway=$GATEWAY
EOF
)

# Idempotency: if the file already has the expected content, no-op.
if [ -f "$DROPIN_FILE" ] && \
   echo "$PASSWORD" | sudo -S diff -q <(echo "$EXPECTED") "$DROPIN_FILE" >/dev/null 2>&1; then
    echo "Route already provisioned: $DROPIN_FILE matches expected content."
else
    echo "Installing $DROPIN_FILE..."
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    echo "$EXPECTED" > "$TMP"
    chmod 0644 "$TMP"
    echo "$PASSWORD" | sudo -S install -m 0644 -o root -g root "$TMP" "$DROPIN_FILE"
fi

# Live-apply the route now (so the user doesn't have to reboot).
# Idempotent — `ip route replace` is happy if the route already exists.
echo "$PASSWORD" | sudo -S ip route replace "$PEER_NET" via "$GATEWAY" dev "$IFACE"

# Verify.
if ip route show "$PEER_NET" | grep -q "via $GATEWAY"; then
    echo "OK: route to $PEER_NET via $GATEWAY is live and persistent."
else
    echo "ERROR: route insertion didn't stick. Check 'ip route show $PEER_NET'." >&2
    exit 4
fi

# Trigger systemd-networkd to pick up the drop-in (no-op if active route
# already exists; gives us a clean state for next reboot).
echo "$PASSWORD" | sudo -S systemctl reload systemd-networkd 2>/dev/null || true
REMOTE_SCRIPT

echo "Done. Route on $PYNQ_HOST is live and persistent."
