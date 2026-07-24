#!/bin/bash
# =============================================================================
# tl_z2_data_bringup_repro.sh — staged repro ladder for the 2026-07-24 Z2
# delivery blocker (link trains, packets reach the Wlink FE, nothing commits
# to the peer RX FIFO; EPOCH_140=0, SLICEMAP=POR, zero SYNCs).
#
# Evidence base: write-set diff of the working July flows vs deploy_pair.sh
# (docs/HANDOVER_LINK_GUI_Z2_2026_07_24.md §11b/§11c). deploy_pair.sh's entire
# post-load write-set is {strap GPIO 0x44040000}; the working flows also did:
#   R1: v39 deskew-anchor recipe (hold/lockthresh/wpauto/arm/STAGGERED freeze)
#       — wpauto (0x44032104) is "proven to fix the credit/send-gate" (tl39.py:12)
#   R1b: SYNC beacon R8 0x44032100 = 0x1C (sync_insert_en|sync_force_always)
#       — "the documented bring-up write" (docs/CRC_ROOTCAUSE.md:128)
#   R2: SEED pair-credit both directions (0x44032020 = delta -> bumps 0x028)
#       — "mandatory bring-up step, not an optimisation" (tl_perf_agent.py:1063)
#   R3: to_data_mode LL-swreset triplet (0x44030208: 27f08->27f00->27f07)
#       — "the load-bearing step" (docs/reference/TIDELINK_BRINGUP_USER_GUIDE.md:298)
#
# RUN ON mapstone-dev. Preconditions (NOT done by this script):
#   1. fpgahub board leases GRANTED on pynq_z2_02 AND pynq_z2_01.
#   2. Fresh POR (hub power-cycle BOTH) then deploy_pair.sh to BOTH dies
#      (golden first to validate the recipe, then v0 to unblock the campaign).
#   3. ~/tl39.sh present and pointing at die_a=192.168.4.101 die_b=192.168.2.101
#      (⚠ CHECK: some older helper scripts still carry die_b=.6.101 = z2_03,
#       which is NOT on the ribbon).
#   4. Delivery-proof script staged: /tmp/ldp_v0.sh (current repo
#      link_delivery_proof.sh).
#
# Apertures on BOTH golden and v0 images (GP1-split, from .hwh):
export TIDELINK_TX_BASE=0x84000000
export TIDELINK_RXFIFO_BASE=0x84010000
#
# Stop at the FIRST stage after which the delivery proof PASSES — that stage
# is the missing bring-up step to encode into the campaign deploy phase.
# =============================================================================
set -u
TL=~/tl39.sh
A_IP=192.168.4.101   # z2_02 die_a
B_IP=192.168.2.101   # z2_01 die_b  (NOT .6.101)
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
REPRO_DIR=$(cd "$(dirname "$0")" && pwd)

proof() {  # proof <label> — both directions; returns 0 if EITHER direction delivers.
    # NOTE: the proof's verdict is its EXIT CODE (0 = verified delivery). Piping to
    # tail would mask it (a pipeline returns the LAST command's status), so capture
    # the output first and test the real rc.
    local ok=1 out rc
    for pair in "$A_IP $B_IP:A->B" "$B_IP $A_IP:B->A"; do
        local ips="${pair%%:*}" dir="${pair##*:}"
        echo "---- delivery proof $dir ($1) ----"
        out=$(/tmp/ldp_v0.sh $ips 2>&1); rc=$?
        printf '%s\n' "$out" | tail -3
        [ $rc -eq 0 ] && ok=0
    done
    return $ok
}

poke() {  # poke <ip> <python-body>  — single-beat ctypes accessor on the board
    printf '%s\n' \
"import mmap, ctypes, os, time" \
"def _m(base):" \
"    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)" \
"    return mmap.mmap(fd, 4096, offset=base)" \
"def rd(m, o): return ctypes.c_uint32.from_buffer(m, o).value" \
"def wr(m, o, v): ctypes.c_uint32.from_buffer(m, o).value = v" \
"$2" | sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no xilinx@"$1" \
        "cat > /tmp/tl_poke_stage.py && echo $PASS | sudo -S python3 /tmp/tl_poke_stage.py 2>/dev/null"
}

echo "======================================================================"
echo " STAGE 0: pre-state (must be: fcsm=4 cal=1 both; epoch/slicemap at POR)"
echo "======================================================================"
$TL both probe 1
$TL both epoch
proof "stage0-baseline" && { echo "UNEXPECTED: delivery already works — recipe not needed"; exit 0; }

echo "======================================================================"
echo " STAGE 1: v39 deskew-anchor recipe (rank 1+2: wpauto + arm + staggered freeze)"
echo "======================================================================"
"$REPRO_DIR"/v39_data_test.sh 2>&1 | tail -30
$TL both epoch
proof "stage1-v39" && { echo "RESULT: STAGE 1 (v39 recipe) is the missing step"; exit 0; }

echo "======================================================================"
echo " STAGE 1b: + SYNC beacon R8=0x1C (syncon + syncforce), re-arm, re-freeze"
echo "======================================================================"
$TL both syncon
$TL both syncforce
$TL both arm; sleep 0.3
$TL b freeze; sleep 0.1; $TL a freeze; sleep 0.3
$TL both epoch
proof "stage1b-syncbeacon" && { echo "RESULT: STAGE 1b (R8=0x1C beacon) is the missing step"; exit 0; }

echo "======================================================================"
echo " STAGE 2: SEED pair-credit counter, both dies (peer-empty = 4096)"
echo "======================================================================"
for ip in $A_IP $B_IP; do
    echo "-- seed $ip --"
    poke "$ip" "m = _m(0x44032000)
print('pre  PAIR_CREDIT=%d' % rd(m, 0x028))
wr(m, 0x020, 4096)
_ = rd(m, 0x020)
print('post PAIR_CREDIT=%d' % rd(m, 0x028))"
done
proof "stage2-seed" && { echo "RESULT: STAGE 2 (credit seed) is the missing step"; exit 0; }

echo "======================================================================"
echo " STAGE 3: to_data_mode LL-swreset triplet (0x44030208) both dies"
echo "   (sw_coord_autocal_region8.sh:82-102 — drop training, then 27f08/27f00/27f07)"
echo "======================================================================"
for ip in $A_IP $B_IP; do
    echo "-- to_data_mode $ip --"
    poke "$ip" "mw = _m(0x44030000)
mr = _m(0x44032000)
wr(mr, 0x100, 0x0)
time.sleep(0.005)
wr(mw, 0x208, 0x00027f08)
time.sleep(0.005)
wr(mw, 0x208, 0x00027f00)
time.sleep(0.005)
wr(mw, 0x208, 0x00027f07)
print('R8=0x%08x WL208=0x%08x' % (rd(mr, 0x100), rd(mw, 0x208)))"
done
sleep 1
$TL both probe 1
proof "stage3-datamode" && { echo "RESULT: STAGE 3 (to_data_mode triplet) is the missing step"; exit 0; }

echo "======================================================================"
echo " ALL STAGES EXHAUSTED — delivery still failing. Capture full state and"
echo " escalate: \$TL both probe 3; \$TL both epoch; OBS_MASK_HS/OBS_FC_CREDIT"
echo " sweeps; compare against a golden+char_session.sh known-good replay."
echo "======================================================================"
exit 1
