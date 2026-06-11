#!/usr/bin/env bash
# =============================================================================
# unjam_fc_node.sh — recover a jammed TideLink FC node on one board.
#
# Jam signature (root-caused 2026-06-11, docs/archive/AUTOCAL_CLOSURE_2026_06_10.md
# residual #6): FCSM stuck at 5 (LINK_DATA) with a2l_replay_link_valid=1
# (0x108[30]) and fe_rx_is_full=0 (0x108[31]) — an in-flight LONG packet whose
# NACK/ACK return was lost on the marginal direction. The node has no timeout,
# so every later word (data AND doorbell/sideband) queues behind it forever.
#
# Recovery = the proven LL swreset cycle (same mechanism as the converge
# script's sync_bootstrap): CTRL_DIS -> settle -> CTRL_FULL -> clear
# swi_training_mode (M12) -> let CR/CRACK re-exchange.
#
# NOTE: this resets the LINK LAYER on this board; run it on BOTH boards (or
# follow with bringup_pair_converge.sh) if the peer was mid-handshake.
#
# Usage:  unjam_fc_node.sh <BOARD_IP>   [TIDELINK_BOARD_PASS=xilinx]
# Exit:   0 = jam cleared (fcsm=4, a2l_lnk=0), 1 = not jammed, 2 = failed
# =============================================================================
set -u
IP="${1:?usage: unjam_fc_node.sh <BOARD_IP>}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHC="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -q"

# Stage the /dev/mem helper on the board (triple-shell quoting is fragile;
# a real file is robust — same pattern as the converge/probe tooling).
HELPER=$(mktemp)
cat > "$HELPER" <<'PYEOF'
import mmap, struct, os, sys, time
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
def mk(base):
    return mmap.mmap(fd, 4096, mmap.MAP_SHARED,
                     mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
r8 = mk(0x44032000)   # Region-8 window (lane status, training)
wl = mk(0x44030000)   # Wlink APB window (CTRL)
def rd(m, o):    return struct.unpack_from("<I", m, o)[0]
def wr(m, o, v): struct.pack_into("<I", m, o, v)

cmd = sys.argv[1]
if cmd == "probe":
    v = rd(r8, 0x108)
    print("%d %d %d %d" % ((v>>17)&0xF, (v>>30)&1, (v>>31)&1, (v>>23)&1))
elif cmd == "cycle":
    wr(wl, 0x208, 0x00027f00)   # CTRL_DIS
    time.sleep(0.1)
    wr(wl, 0x208, 0x00027f07)   # CTRL_FULL
    time.sleep(0.1)
    wr(r8, 0x100, 0x0)          # M12: clear swi_training_mode
    print("cycled")
PYEOF
sshpass -p "$PASS" scp $SSHC "$HELPER" "xilinx@$IP:/tmp/tl_unjam.py" || {
    echo "scp failed"; rm -f "$HELPER"; exit 2; }
rm -f "$HELPER"

board() { # CMD
    sshpass -p "$PASS" ssh $SSHC "xilinx@$IP" \
        "echo '$PASS' | sudo -S timeout 8 python3 /tmp/tl_unjam.py $1" 2>/dev/null
}

read -r fs lnk full cr <<< "$(board probe)"
echo "pre : fcsm=${fs:-?} a2l_lnk=${lnk:-?} fe_full=${full:-?} cr=${cr:-?}"
if ! { [ "${fs:-}" = "5" ] && [ "${lnk:-}" = "1" ] && [ "${full:-}" = "0" ]; }; then
    echo "node not in the jam signature (fcsm=5 + a2l_lnk=1 + fe_full=0) — nothing to do"
    exit 1
fi

echo "JAMMED — running LL swreset cycle..."
board cycle >/dev/null
sleep 1.0

read -r fs lnk full cr <<< "$(board probe)"
echo "post: fcsm=${fs:-?} a2l_lnk=${lnk:-?} fe_full=${full:-?} cr=${cr:-?}"
if [ "${lnk:-}" = "0" ] && [ "${fs:-}" = "4" ]; then
    echo "UNJAMMED"
    exit 0
fi
echo "recovery incomplete — peer may need the same cycle, or run bringup_pair_converge.sh"
exit 2
