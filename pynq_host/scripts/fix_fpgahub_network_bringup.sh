#!/usr/bin/env bash
# =============================================================================
# fix_fpgahub_network_bringup.sh   (run AFTER fix_fpgahub_bridge1_topology.sh)
#
# The reboot re-enumerated USB 1-4 -> 1-2. The config.toml hub_path anchors
# were already repaired + verified green. This second step rebuilds the HOST
# integration that is also keyed on the old busid:
#   * /etc/udev/rules.d/70-fpgahub.rules  (net NIC rename usbX -> pynq_z2_0N_ps)
#     — regenerated the native way via `fpgahub apply` (the file's own header
#       says "Do not edit by hand; run `fpgahub apply`").
#   * systemd-networkd then assigns 192.168.4.1 / 192.168.6.1 once the NICs
#     carry their pynq_z2_0N_ps names again.
#
# Idempotent + read-mostly (only fpgahub's own regen writes files). Verifies
# the two bridge1 _ps boards are pingable at the end.
#
# Usage:  sudo bash fix_fpgahub_network_bringup.sh
# =============================================================================
set -uo pipefail
[ "$(id -u)" = 0 ] || { echo "ERROR: run as root — sudo bash $0" >&2; exit 1; }

echo "[1/5] fpgahub apply (regenerate udev rules from corrected config) ..."
fpgahub apply 2>&1 | tail -4

echo "[2/5] reload + re-trigger udev (net + usb) ..."
udevadm control --reload-rules
udevadm trigger --subsystem-match=net --subsystem-match=usb
sleep 2

echo "[3/5] reload systemd-networkd ..."
networkctl reload 2>&1 | tail -2 || systemctl restart systemd-networkd
sleep 4

echo "[4/5] interface state for the bridge1 _ps boards ..."
for nic in pynq_z2_02_ps pynq_z2_03_ps; do
    echo -n "  $nic: "
    ip -br addr show "$nic" 2>/dev/null || echo "(not yet renamed — NIC still generic)"
done
echo "  host IPs on board subnets:"
ip -br addr 2>/dev/null | grep -E "192\.168\.(4|6)\.1/" | sed 's/^/    /' || echo "    (none yet)"

echo "[5/5] ping the two boards ..."
rc=0
for ip in 192.168.4.101 192.168.6.101; do
    if ping -c1 -W3 "$ip" >/dev/null 2>&1; then echo "  $ip: REACHABLE"; else echo "  $ip: no reply"; rc=1; fi
done

echo
if [ "$rc" = 0 ]; then
    echo "SUCCESS — both bridge1 boards are reachable. SSH/deploy can proceed."
else
    echo "Boards not yet pinging. If the NICs above still show generic names"
    echo "(usbX/ethX) rather than pynq_z2_0N_ps, the udev net-rename did not"
    echo "re-apply on the live device — a clean re-trigger usually needs the"
    echo "device to re-appear. Try once more, or unplug/replug that board, or"
    echo "share this output and we'll narrow it."
fi
