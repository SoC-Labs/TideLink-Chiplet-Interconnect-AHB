#!/bin/bash
# =============================================================================
# td_l9_probe_fcsm_credit_asym.sh — diagnostic probe for L9 hypothesis H-3
#
# Reads FCSM_6 (TideLink, id 0xa1) header registers on both sides and emits
# a single diff-friendly line per side. Discriminates between credit-config
# asymmetry (the SW-fixable H-3 in docs/TIDELINK_L9_TIDELINK_FC_ASYM_2026_05_26.md)
# and the deeper deadlock hypotheses H-1/H-2.
#
# READ-ONLY. Does NOT write AHB_TX or any other potentially wedging path.
# Safe to run at any link state.
#
# Wlink offset map (per wlink_probe.sh):
#   0x1700  TideLink FC (id 0xa1)
#     [0x00] channel byte-pattern   = 0x47464544 ("DEFG" — ack_id/cr_id/...)
#     [0x04] channel id             = 0xa1
#     [0x08] a2l_fc_replay.link_empty (1=empty, 0=pending TX — see L9 doc §2)
#     [0x0C] reserved 0
#     [0x10] FC config              = 0x00020601 (default)
#     [0x14] FC params              = 0x00000708 (default)
#     [0x18] CRC errors counter (16b) + flags
#     [0x1C] tx-side credit observability (if present)
#
# Usage:
#   td_l9_probe_fcsm_credit_asym.sh             # uses default MASTER/SLAVE IPs
#   MASTER_IP=192.168.4.101 SLAVE_IP=192.168.6.101 td_l9_probe_fcsm_credit_asym.sh
#
# Exit 0 = both probes succeeded (delta printable). Exit 1 = either side
# unreachable. The script does NOT decide pass/fail itself — that judgment
# is human-eyeball on the diff between the two output lines.
# =============================================================================
set -u
MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

probe_one() {
    local IP=$1 LBL=$2
    local OUT
    OUT=$(sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap, struct, os
P=4096
fd=os.open(\"/dev/mem\", os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
    b=a&~(P-1); o=a-b; pages=((sz+o+P-1)//P)*P
    return mmap.mmap(fd, pages, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=b), o
WL = 0x44030000
TL_FC = WL + 0x1700                  # FCSM_6 (TideLink) APB header
r, o = mm(TL_FC, 64)
vals = [struct.unpack_from(\"<I\", r, o+i)[0] for i in (0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C)]
# Also pull SWI_LANE_STATUS for FCSM state + CR/CRACK observability
tl, to = mm(0x44032000)
st = struct.unpack_from(\"<I\", tl, to+0x108)[0]
fcsm = (st >> 17) & 0xF
cr   = (st >> 23) & 0x1
crack= (st >> 24) & 0x1
ll_rx= (st >> 21) & 0x3
locked = st & 0xFF
print(\"  0x1700 ids/empty/cfg/params/crc/credit: \"
      \"%08x %08x %08x %08x %08x %08x %08x %08x\"
      \"  | fcsm=%d cr=%d crack=%d ll_rx=%d locked=0x%02x\"
      % (vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7],
         fcsm, cr, crack, ll_rx, locked))
'" 2>/dev/null) || { echo "  $LBL ($IP): UNREACHABLE"; return 1; }
    echo "  $LBL ($IP):"
    echo "$OUT"
}

echo "=============================================================="
echo " L9 TideLink FC asymmetry probe   $(date)"
echo "  H-3 check: master vs slave FCSM_6 config/credit regs"
echo "=============================================================="
probe_one "$MASTER_IP" "MASTER"
probe_one "$SLAVE_IP"  "SLAVE "
echo "=============================================================="
echo ""
echo "Interpretation key:"
echo "  field 2 (offset 0x08) — a2l_fc_replay.link_empty:"
echo "    1 = FIFO empty (nothing queued for TX)"
echo "    0 = FIFO has pending TX not draining (the L9 symptom on master)"
echo ""
echo "  field 4 (offset 0x10) FC config: expect 0x00020601 BOTH sides"
echo "  field 5 (offset 0x14) FC params: expect 0x00000708 BOTH sides"
echo ""
echo "  IF master [0x10] or [0x14] differ from slave's by a credit-bit:"
echo "    -> H-3 confirmed (credit-window asymmetry)"
echo "    -> Fix: APB-write the bad-side's [0x10]/[0x14] to match good side"
echo "  IF both sides match AND master's [0x08]=0 AND slave's [0x08]=1:"
echo "    -> H-3 falsified, deeper deadlock (H-1/H-2) — write the sim test"
echo ""
echo "DO NOT execute against bridge1 from this branch — this script is"
echo "intentionally staged on the L9 branch for the next session to invoke."
