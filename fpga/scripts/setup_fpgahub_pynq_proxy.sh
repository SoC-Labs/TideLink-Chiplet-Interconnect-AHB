#!/usr/bin/env bash
# setup_fpgahub_pynq_proxy.sh — inject a `proxy = "<user>@<ip>"` field into
# each PYNQ-Z2 board's [boards.<n>.host] block in /etc/fpgahub/config.toml,
# so fpgahubd reaches the boards via ProxyJump (mapstone-dev) instead of
# direct master↔slave routes.
#
# Why: the per-board /24 → /24 routing through mapstone-dev is fragile
# (rp_filter / send_redirects / destination cache). Going through
# mapstone-dev as an SSH jumphost sidesteps the IP-layer puzzle entirely
# — the daemon (running as root on mapstone-dev) connects to itself as
# david first, then tunnels to xilinx@<board>.
#
# Idempotent: re-running with the same proxy is a no-op. Different proxy
# replaces the existing line.
#
# Run on mapstone-dev:
#     sudo /home/dam1n19/SoCLabs/tidelink/fpga/scripts/setup_fpgahub_pynq_proxy.sh
# or:
#     sudo /home/dam1n19/SoCLabs/tidelink/fpga/scripts/setup_fpgahub_pynq_proxy.sh --dry-run

set -euo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

if [ "$(id -u)" -ne 0 ] && [ $DRY_RUN -eq 0 ]; then
    echo "ERROR: run as root (or with sudo). Pass --dry-run to preview." >&2
    exit 1
fi

CONFIG=/etc/fpgahub/config.toml
[ -f "$CONFIG" ] || { echo "ERROR: $CONFIG not found." >&2; exit 2; }

# board → proxy. The proxy IP is mapstone-dev's address on the *board's*
# /24, so the board can always reach it (no inter-/24 routing needed).
declare -A PROXY=(
    [pynq_z2_02_pl]="david@192.168.4.1"
    [pynq_z2_02_ps]="david@192.168.4.1"
    [pynq_z2_03_pl]="david@192.168.6.1"
    [pynq_z2_03_ps]="david@192.168.6.1"
)

TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$CONFIG.bak-$TS"
echo "Backing up $CONFIG → $BACKUP"
[ $DRY_RUN -eq 1 ] || cp -p "$CONFIG" "$BACKUP"

TMP_OUT=$(mktemp)
trap 'rm -f "$TMP_OUT"' EXIT

# Build a flat string "name1=proxy1;name2=proxy2;..." to feed awk.
MAP=""
for k in "${!PROXY[@]}"; do
    MAP+="$k=${PROXY[$k]};"
done

awk -v map="$MAP" '
BEGIN {
    # Parse the map into targets[name] = proxy.
    n = split(map, items, ";")
    for (i = 1; i <= n; i++) {
        if (items[i] == "") continue
        eq = index(items[i], "=")
        targets[substr(items[i], 1, eq-1)] = substr(items[i], eq+1)
    }
}

# Match [boards.<name>.host] header.
/^\[boards\.[A-Za-z0-9_]+\.host\][[:space:]]*$/ {
    name = $0
    sub(/^\[boards\./, "", name); sub(/\.host\][[:space:]]*$/, "", name)
    print
    in_target = (name in targets) ? 1 : 0
    injected_for[name] = 0
    next
}

# Any subsequent [...] header closes the current host section. If we never
# replaced an existing proxy line, inject ours now (right before the new
# header).
/^\[/ {
    if (in_target && name && !injected_for[name]) {
        print "proxy = \"" targets[name] "\""
        injected_for[name] = 1
    }
    in_target = 0
    print
    next
}

# Replace any existing proxy line inside a target host section.
in_target && /^[[:space:]]*proxy[[:space:]]*=/ {
    print "proxy = \"" targets[name] "\""
    injected_for[name] = 1
    next
}

{ print }

END {
    if (in_target && name && !injected_for[name]) {
        print "proxy = \"" targets[name] "\""
    }
}
' "$CONFIG" > "$TMP_OUT"

if [ $DRY_RUN -eq 1 ]; then
    echo "[dry-run] resulting host blocks:"
    for B in "${!PROXY[@]}"; do
        echo "  $B:"
        awk -v target="$B" '
            BEGIN { inside = 0 }
            /^\[boards\.[A-Za-z0-9_]+\.host\][[:space:]]*$/ {
                name = $0; sub(/^\[boards\./, "", name); sub(/\.host\][[:space:]]*$/, "", name)
                inside = (name == target) ? 1 : 0
                if (inside) print "    " $0
                next
            }
            /^\[/ { inside = 0 }
            inside { print "    " $0 }
        ' "$TMP_OUT"
    done
    exit 0
fi

cp -p "$TMP_OUT" "$CONFIG"

echo "Validating $CONFIG..."
if ! /opt/fpgahub/bin/python -c "
from pathlib import Path
from fpgahub.config import Config
Config.load(Path('$CONFIG'))
print('  OK')
" ; then
    echo "ERROR: config validation failed — restoring backup." >&2
    cp -p "$BACKUP" "$CONFIG"
    exit 4
fi

echo "Reloading fpgahubd..."
systemctl reload-or-restart fpgahubd
sleep 1
systemctl is-active fpgahubd >/dev/null || {
    echo "ERROR: fpgahubd not active. See 'journalctl -u fpgahubd -n 30'." >&2
    exit 5
}

for B in "${!PROXY[@]}"; do
    echo "Reloading manifest for $B..."
    /opt/fpgahub/bin/fpgahub manifest reload "$B" || true
done

cat <<EOF

Done. ProxyJump injected for ${!PROXY[*]}.

Verify:
    grep -A2 '^\[boards\.pynq_z2_02_pl\.host\]' $CONFIG
    fpgahub actions run pynq_z2_02_pl stress_pair

To revert: cp -p $BACKUP $CONFIG && systemctl reload fpgahubd
EOF
