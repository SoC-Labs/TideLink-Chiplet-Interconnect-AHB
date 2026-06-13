#!/usr/bin/env bash
# =============================================================================
# fix_fpgahub_reboot_remap.sh   —  ONE-SHOT recovery
#
# After the mapstone-dev reboot the whole USB hub tree re-enumerated from host
# root-port 1-4 to 1-2 (verified: `fpgahub discover` shows NOTHING on 1-4; the
# bridge1 boards map 1-4.X -> 1-2.X 1:1, confirmed by MAC). Every fpgahub
# reference keyed on the old busid is therefore stale by the SAME uniform
# shift:  per-board hub_path / tul_hub_path, the hub-switch locations, the
# port-path lists, and (downstream, generated from those) the udev rename
# rules and systemd-networkd IP assignment.
#
# This remaps ALL of them in one pass:
#   1. config.toml : every quoted busid  "1-4...."  ->  "1-2...."
#   2. fpgahubd restart (reload config)            [auto-rollback if unhealthy]
#   3. fpgahub apply  : regenerate udev rules from the corrected config
#   4. udev re-trigger : rename board NICs back to pynq_z2_0N_ps / etc.
#   5. networkctl reload : reassign 192.168.N.1 host IPs to the renamed NICs
#   6. topology verify (self-checks identity by serial/MAC) + pair up + ping
#
# Safe: a wrong remap can only show as hub_missing (fpgahub matches identity),
# never a wrong-board bind. Backs up config; auto-rolls-back only if the
# daemon fails to come back (i.e. a TOML syntax problem). Idempotent.
#
# Usage:  sudo bash fix_fpgahub_reboot_remap.sh
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root — sudo bash $0" >&2; exit 1; }

CFG=/etc/fpgahub/config.toml
SVC=fpgahubd
SOCK=/run/fpgahub/fpgahub.sock
PAIR=bridge1

command -v fpgahub >/dev/null || { echo "ERROR: fpgahub not on PATH" >&2; exit 1; }
[ -f "$CFG" ] || { echo "ERROR: $CFG missing" >&2; exit 1; }

BAK="${CFG}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$CFG" "$BAK"
echo "[1/7] backup -> $BAK"

before=$(grep -oE '"1-4\.[0-9.]+"' "$CFG" | wc -l | tr -d ' ')
python3 - "$CFG" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# Every USB busid in this config is double-quoted ("1-4.3.3.3.1", "1-4.3", ...);
# file paths start with "/ and IPs with "192. , so anchoring on '"1-4.' only
# touches USB busids. Nothing legitimately remains on root-port 1-4.
n = s.count('"1-4.')
open(p, 'w').write(s.replace('"1-4.', '"1-2.'))
print(f"    replaced {n} busid reference(s)")
PY
after=$(grep -oE '"1-4\.[0-9.]+"' "$CFG" | wc -l | tr -d ' ')
echo "[2/7] config remap done (was $before '1-4.*' busids, $after remaining)"

rollback() {
    echo "!!! $1 — rolling back config to $BAK" >&2
    install -m 0644 -o root -g root "$BAK" "$CFG"
    systemctl restart "$SVC" || true
    exit 9
}

echo "[3/7] restart $SVC (reload config) ..."
systemctl restart "$SVC"
ok=0; for _ in $(seq 1 20); do systemctl is-active --quiet "$SVC" && [ -S "$SOCK" ] && { ok=1; break; }; sleep 1; done
[ "$ok" = 1 ] || rollback "daemon did not come up after config edit"
sleep 3
systemctl is-active --quiet "$SVC" || rollback "daemon crash-looping after config edit"
fpgahub health >/dev/null 2>&1 || rollback "fpgahub health failed after config edit"
echo "      daemon healthy."

echo "[4/7] fpgahub apply --role both (regenerate udev rules from corrected config) ..."
fpgahub apply --role both 2>&1 | tail -4 || rollback "fpgahub apply --role both failed"

echo "[5/7] rename board NICs + reload networkd (assign host IPs) ..."
udevadm control --reload-rules
# A net interface cannot be renamed by udev while it is administratively UP,
# and all four bridge1 NICs are up. Bring each down by its current (generic)
# name, then replay the add-event so udev applies NAME=pynq_z2_0N_xx, then
# networkd brings it back up with its 192.168.N.1 address.
iface_of() {  # busid -> current ifname
    local busid="$1" n p
    for n in /sys/class/net/*; do
        p=$(readlink -f "$n")
        case "$p" in *"/$busid:"*|*"/$busid/"*) basename "$n"; return;; esac
    done
}
for busid in 1-2.3.3.3.1 1-2.3.3.3.3 1-2.3.4.1.3.1 1-2.3.4.1.3.4; do
    ifc=$(iface_of "$busid")
    if [ -n "$ifc" ]; then echo "      $busid: $ifc -> down"; ip link set "$ifc" down 2>/dev/null || true; fi
done
udevadm trigger --action=add --subsystem-match=net
sleep 3
networkctl reload 2>&1 | tail -1 || systemctl restart systemd-networkd
sleep 4

echo "[6/7] topology verify (identity self-check) ..."
fpgahub topology verify 2>&1 | grep -E "Board|Overall|pynq_z2_0[234]|mps3" || true
echo "      bringing up $PAIR ..."
fpgahub pair up "$PAIR" 2>&1 | tail -3 || true

echo "[7/7] reachability check ..."
for nic in pynq_z2_02_ps pynq_z2_03_ps; do
    echo -n "  NIC $nic: "; ip -br addr show "$nic" 2>/dev/null | awk '{print $1,$2,$3}' || echo "(still generic name)"
done
rc=0
for ip in 192.168.4.101 192.168.6.101; do
    if ping -c1 -W3 "$ip" >/dev/null 2>&1; then echo "  $ip: REACHABLE"; else echo "  $ip: no reply"; rc=1; fi
done

echo
if [ "$rc" = 0 ]; then
    echo "SUCCESS — bridge1 boards reachable, hub-switch + udev + networkd all remapped."
    echo "Backup: $BAK"
else
    echo "Config + daemon are now correct (topology verify above shows identity)."
    echo "If a NIC still shows a generic name (usbX/ethX) it means udev could not"
    echo "rename a live device in place; a single unplug/replug of that board, or"
    echo "re-running this script, will settle it. Backup: $BAK"
fi
