#!/usr/bin/env bash
# =============================================================================
# unjam_fc_node.sh — diagnose + recover a jammed TideLink FC node on one board.
#
# Reads SWI_LANE_STATUS @ 0x44032108 and classifies the node against the
# known jam signatures (bit decode per pynq_host/scripts/tlchar.py — the
# authoritative packing; fcsm is [19:17], THREE bits):
#
#   [16] cal_done   [19:17] fcsm        [20] a2l_replay_app_valid
#   [23] cr_seen    [24] crack_seen     [30] a2l_fc_replay_link_valid
#   [31] fe_rx_is_full
#
# Signature matrix:
#
#   CLASSIC (CTRL-cycle recoverable — root-caused 2026-06-11,
#   docs/archive/AUTOCAL_CLOSURE_2026_06_10.md residual #6):
#     fcsm==5 (LINK_DATA) && a2l_fc_replay_link_valid==1 && fe_rx_is_full==0
#     An in-flight LONG packet whose NACK/ACK return was lost on the
#     marginal direction; no timeout, so every later word queues forever.
#     Recovery: the proven LL swreset cycle (CTRL_DIS -> settle ->
#     CTRL_FULL -> clear swi_training_mode (M12) -> CR/CRACK re-exchange).
#
#   HELD-REPLAY (reflash ONLY — observed 2026-06-12):
#     fcsm==4 (LINK_IDLE) && a2l_replay_app_valid==1 && fe_rx_is_full==1
#     A replay packet is held on the app side with the RX framer full.
#     The CTRL cycle does NOT flush the held replay — only a reflash
#     (deploy_pair.sh; no PS reboot needed) clears it. This script will
#     NOT attempt the cycle and will NOT claim success.
#
#   BUS-ERROR (reflash ONLY — observed 2026-06-12):
#     Post-bootstrap PS AXI bus-error on APB reads: the /dev/mem probe
#     itself dies (SIGBUS) or hangs instead of returning a status word.
#     Recovery = reflash via deploy_pair.sh; no reboot needed.
#
# NOTE: the CTRL cycle resets the LINK LAYER on this board; run it on BOTH
# boards (or follow with bringup_pair_converge.sh) if the peer was
# mid-handshake.
#
# Usage:  unjam_fc_node.sh <BOARD_IP>   [TIDELINK_BOARD_PASS=xilinx]
# Exit:   0 = jam recovered + verified (fcsm=4, a2l_lnk=0)
#         1 = no known jam signature present (decode printed)
#         2 = jam present but needs reflash (exact command printed)
#         3 = recovery attempted and failed, or board not diagnosable
# =============================================================================
set -u

# --- ZynqMP (KR260) SAFETY GUARD (inline) ------------------------------------
# This tool mmaps RAW Pynq-Z2 control literals (0x4403_xxxx / 0x4404_xxxx /
# 0x4405_xxxx) over /dev/mem, un-relocated. On a ZynqMP (KR260) those addresses
# are UNDECODED with NO bus timeout => a hard PS hang (power-cycle to recover).
# Pynq-Z2 ONLY. Refuse the moment we start if TIDELINK_SOC names anything else.
# Safe on a KR260: tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.
_tl_guard_soc=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
case "$_tl_guard_soc" in
  ""|z2|pynq-z2|pynq_z2|zynq7|zynq) : ;;
  *)
    printf '\n[%s] REFUSING TO RUN on TIDELINK_SOC=%s — mmaps RAW Z2 literals (0x4403_xxxx)\n' "${0##*/}" "$TIDELINK_SOC" >&2
    printf '  UNDECODED on a ZynqMP (KR260) => hard PS hang. This tool is Pynq-Z2 ONLY.\n' >&2
    printf '  On a KR260 use tl_poke.py (absolute 0x8403_xxxx) or tl39.py with tl_socmap.py.\n' >&2
    exit 3 ;;
esac

IP="${1:?usage: unjam_fc_node.sh <BOARD_IP>}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHC="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -q"

# Exact reflash invocation (deploy_pair.sh BOARD_IP BOARD_LABEL ROLE [DIR]).
# Label/role defaults follow the bridge1 convention from deploy_pair.sh's
# own header (z2_02=192.168.4.101 die_a, z2_03=192.168.6.101 die_b);
# anything else gets explicit placeholders.
case "$IP" in
    192.168.4.101) RELABEL="z2_02"; REROLE="die_a" ;;
    192.168.6.101) RELABEL="z2_03"; REROLE="die_b" ;;
    *)             RELABEL="<BOARD_LABEL>"; REROLE="<die_a|die_b>" ;;
esac
print_reflash() {
    echo ""
    echo "RECOVERY = reflash this board (no PS reboot needed). From mapstone-dev,"
    echo "with .bin/.hwh staged in /tmp/tidelink_deploy:"
    echo ""
    echo "  $(dirname "$0")/deploy_pair.sh $IP $RELABEL $REROLE /tmp/tidelink_deploy"
    echo ""
    echo "(verify label/role against the lease before flashing; if the peer was"
    echo " mid-handshake follow with bringup_pair_converge.sh)"
}

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
    # SWI_LANE_STATUS @0x108, authoritative decode per tlchar.py:
    # fcsm=[19:17] (3 bits), cal_done=[16], a2l_replay_app_valid=[20],
    # cr_seen=[23], a2l_fc_replay_link_valid=[30], fe_rx_is_full=[31].
    # A PS-AXI bus error on this read kills the process with SIGBUS —
    # the bash side classifies a missing "OK" line as the bus-error class.
    v = rd(r8, 0x108)
    print("OK 0x%08x %d %d %d %d %d %d" % (
        v, (v >> 17) & 0x7, (v >> 16) & 1, (v >> 20) & 1,
        (v >> 30) & 1, (v >> 31) & 1, (v >> 23) & 1))
elif cmd == "cycle":
    wr(wl, 0x208, 0x00027f00)   # CTRL_DIS
    time.sleep(0.1)
    wr(wl, 0x208, 0x00027f07)   # CTRL_FULL
    time.sleep(0.1)
    wr(r8, 0x100, 0x0)          # M12: clear swi_training_mode
    print("cycled")
PYEOF
if ! sshpass -p "$PASS" scp $SSHC "$HELPER" "xilinx@$IP:/tmp/tl_unjam.py"; then
    rm -f "$HELPER"
    echo "scp to xilinx@$IP failed — board unreachable, cannot diagnose"
    exit 3
fi
rm -f "$HELPER"

board() { # CMD
    sshpass -p "$PASS" ssh $SSHC "xilinx@$IP" \
        "echo '$PASS' | sudo -S timeout 8 python3 /tmp/tl_unjam.py $1" 2>/dev/null
}

probe_decode() { # sets: ok raw fcsm cal app lnk full cr
    local out
    out=$(board probe | grep '^OK ' | head -n1)
    if [ -z "$out" ]; then
        ok=0; raw=""; fcsm=""; cal=""; app=""; lnk=""; full=""; cr=""
        return
    fi
    ok=1
    read -r _ raw fcsm cal app lnk full cr <<< "$out"
}

report() { # LABEL
    echo "$1: status=${raw:-?} fcsm=${fcsm:-?} cal_done=${cal:-?}" \
         "a2l_app=${app:-?} a2l_lnk=${lnk:-?} fe_full=${full:-?} cr=${cr:-?}"
}

probe_decode
if [ "$ok" != "1" ]; then
    # SSH itself works (scp above succeeded) but the /dev/mem read died or
    # hung => post-bootstrap PS AXI bus-error class. CTRL cycle pokes would
    # hit the same dead APB window; do not attempt.
    echo "pre : APB probe FAILED (no status word returned)"
    echo "SIGNATURE: BUS-ERROR — post-bootstrap PS AXI bus-error on APB reads"
    print_reflash
    exit 2
fi
report "pre "

if [ "$fcsm" = "4" ] && [ "$app" = "1" ] && [ "$full" = "1" ]; then
    echo "SIGNATURE: HELD-REPLAY — fcsm=4 + a2l_replay_app_valid=1 + fe_rx_is_full=1"
    echo "The CTRL cycle does NOT flush a held replay packet — not attempting it."
    print_reflash
    exit 2
fi

if ! { [ "$fcsm" = "5" ] && [ "$lnk" = "1" ] && [ "$full" = "0" ]; }; then
    echo "no known jam signature:"
    echo "  CLASSIC     = fcsm=5 + a2l_lnk=1 + fe_full=0   (CTRL-cycle recoverable)"
    echo "  HELD-REPLAY = fcsm=4 + a2l_app=1 + fe_full=1   (reflash)"
    echo "  BUS-ERROR   = APB probe dies/hangs             (reflash)"
    echo "nothing to do"
    exit 1
fi

echo "SIGNATURE: CLASSIC — fcsm=5 + a2l_fc_replay_link_valid=1 + fe_rx_is_full=0"
echo "running LL swreset cycle..."
board cycle >/dev/null
sleep 1.0

probe_decode
if [ "$ok" != "1" ]; then
    echo "post: APB probe FAILED after CTRL cycle — bus now erroring"
    print_reflash
    exit 2
fi
report "post"
if [ "$lnk" = "0" ] && [ "$fcsm" = "4" ]; then
    echo "UNJAMMED (verified: fcsm=4, a2l_lnk=0)"
    exit 0
fi
echo "recovery incomplete — peer may need the same cycle, or run bringup_pair_converge.sh"
exit 3
