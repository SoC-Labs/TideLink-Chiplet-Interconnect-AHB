#!/usr/bin/env bash
# =============================================================================
# fix_fpgahub_bridge1_topology.sh
#
# After the mapstone-dev reboot (2026-06-13) the USB hub tree re-enumerated
# from host root-port 1-4 -> 1-2, so every fpgahub board anchored by an
# absolute `hub_path = "1-4.*"` shows hub_missing and the boards are
# unreachable. This repairs the FOUR bridge1 board anchors (z2_02 + z2_03,
# both _ps and _pl).
#
# Each new path was IDENTITY-VERIFIED on 2026-06-13 by matching the device
# serial/MAC at the new busid against `fpgahub emit` (serial == MAC w/o
# colons), so it cannot point at the wrong board:
#   pynq_z2_02_ps : 1-4.3.3.3.1   -> 1-2.3.3.3.1    (MAC ..3e:3d, serial 00249B8B3E3D)
#   pynq_z2_02_pl : 1-4.3.3.3.3   -> 1-2.3.3.3.3    (Realtek 0bda:8153, sibling-anchored)
#   pynq_z2_03_ps : 1-4.3.4.1.3.1 -> 1-2.3.4.1.3.1  (MAC ..28:11, serial 0000051BD72811)
#   pynq_z2_03_pl : 1-4.3.4.1.3.4 -> 1-2.3.4.1.3.4  (MAC ..3e:3b, serial 00249B8B3E3B)
#
# Only these four lines change. z2_01 / z2_04 / mps3 are left untouched
# (they sit on a different sub-branch that did not re-enumerate cleanly and
# were not verified here). Idempotent + auto-rollback if the daemon fails to
# come back healthy.
#
# Usage:  sudo bash fix_fpgahub_bridge1_topology.sh
# =============================================================================
set -euo pipefail

CFG=/etc/fpgahub/config.toml
SVC=fpgahubd
SOCK=/run/fpgahub/fpgahub.sock

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root — sudo bash $0" >&2; exit 1; }
[ -f "$CFG" ]      || { echo "ERROR: $CFG not found" >&2; exit 1; }

# Exact old -> new replacements (hub_path lines only).
OLD=( '"1-4.3.3.3.1"' '"1-4.3.3.3.3"' '"1-4.3.4.1.3.1"' '"1-4.3.4.1.3.4"' )
NEW=( '"1-2.3.3.3.1"' '"1-2.3.3.3.3"' '"1-2.3.4.1.3.1"' '"1-2.3.4.1.3.4"' )

BAK="${CFG}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "$BAK"
echo "[1/5] backup -> $BAK"

tmp=$(mktemp)
cp -a "$CFG" "$tmp"
changed=0
for i in "${!OLD[@]}"; do
    o="${OLD[$i]}"; n="${NEW[$i]}"
    if grep -qF "hub_path = $n" "$tmp"; then
        echo "      already correct: hub_path = $n"
        continue
    fi
    c=$(grep -cF "hub_path = $o" "$tmp" || true)
    if [ "$c" != 1 ]; then
        echo "ERROR: expected exactly 1 'hub_path = $o', found $c — aborting, no change made" >&2
        rm -f "$tmp"; exit 2
    fi
    sed -i "s|hub_path = ${o}|hub_path = ${n}|" "$tmp"
    echo "      $o -> $n"
    changed=$((changed+1))
done
echo "[2/5] $changed line(s) updated in working copy"

# Confirm all four targets are present and no bridge1 1-4.* anchors remain.
for n in "${NEW[@]}"; do
    grep -qF "hub_path = $n" "$tmp" || { echo "ERROR: $n missing post-edit" >&2; rm -f "$tmp"; exit 3; }
done
echo "[3/5] all four target anchors present"

install -m 0644 -o root -g root "$tmp" "$CFG"
rm -f "$tmp"
echo "[4/5] $CFG written"

rollback() {
    echo "!!! daemon unhealthy after edit — rolling back to $BAK" >&2
    install -m 0644 -o root -g root "$BAK" "$CFG"
    systemctl restart "$SVC" || true
    exit 9
}

echo "[5/5] restarting $SVC ..."
systemctl restart "$SVC"
ok=0
for _ in $(seq 1 20); do
    if systemctl is-active --quiet "$SVC" && [ -S "$SOCK" ]; then ok=1; break; fi
    sleep 1
done
[ "$ok" = 1 ] || rollback
# settle, then confirm it is genuinely stable (not crash-looping) + serving
sleep 3
systemctl is-active --quiet "$SVC" || rollback
fpgahub health >/dev/null 2>&1 || rollback

echo
echo "=== fpgahub health OK — bridge1 topology verify ==="
fpgahub topology verify 2>&1 | grep -E "Board|Overall|pynq_z2_0[23]_(ps|pl)" || true
echo
echo "If the four z2_02/z2_03 rows no longer say hub_missing, you're done."
echo "Backup kept at: $BAK   (restore: sudo install -m644 $BAK $CFG && sudo systemctl restart $SVC)"
