#!/bin/bash
# =============================================================================
# bringup_pair_converge.sh — Coordinated closed-loop TideLink pair bring-up.
#
# WHY THIS EXISTS (the thing that was missing for months)
#   The FPGA "lottery" (mean ~3.5/16 lanes, 7/10 deploys lock zero, byte-
#   identical bitstream, uncorrelated deploy-to-deploy) was diagnosed at
#   length as "HW/runtime nondeterminism" and answered with elaborate RTL
#   (P&R-XDC, IDELAYE2, calibrator re-sweep T3, S_HOLD T3.2). The RTL fixes
#   are real and now consolidated on this branch (feat/td-combined). But
#   the *actual* dominant cause of non-convergence was never in the
#   bitstream: deploy_pair.sh asserts role_lock inside each board's OWN
#   separate SSH run, the two runs seconds apart, and WavD2DGpioRx.count
#   free-runs from role_lock — so the two deserialiser word-boundary
#   counters start with a multi-millisecond (≫ 320 ns alignment window)
#   random skew EVERY deploy. The trainable window is µs; the skew is ms.
#   Coincidence is pure chance == the lottery.
#
#   The only existing "repeatability" tool (redeploy_repeatability.sh) is a
#   ONE-SHOT characteriser: one recal_cycle, one snapshot read, and a
#   verdict heuristic written to *prove* the lottery — not a bring-up tool.
#
#   This script is the bring-up tool. It exploits the consolidated RTL:
#     - T3   (1e5f4e0): calibrator re-sweeps continuously until genuinely
#                       locked instead of latching a give-up state.
#     - T3.2 (50f7869): S_HOLD — the first end to lock holds training_mode
#                       HOLD_CYCLES so a skew-delayed peer can still
#                       converge against a live training pattern.
#     - IDELAYE2 (fff8df2 + 1b2e87e/54b5879/a4f0605): real per-lane RX
#                       delay so sub-UI bit sampling is actually tunable.
#     - FCSM sticky (submodule 678a9b3 ⊇ 0e126b0): credit-path doesn't
#                       drop cr_pkt_seen during bring-up.
#
#   With that RTL present, the residual skew no longer has to be won on a
#   single coin flip: a *coordinated, parallel, repeated* recal re-arms
#   BOTH calibrators near-simultaneously and lets S_HOLD bridge the
#   residual jitter — looped until both ends genuinely converge, then
#   measured by settle-then-read instead of a single fixed-delay snapshot.
#
# WHAT IT DOES
#   1. Deploy both boards IN PARALLEL (role_lock skew -> SSH-launch jitter,
#      not seconds), phase=0 both sides so the calibrator owns alignment
#      and is NOT OR-corrupted by a static swi_phase_offset.
#   2. Closed loop, up to MAX_RETRIES: parallel coordinated recal_cycle
#      (re-arm both calibrators within ~one SSH RTT of each other), then
#      SETTLE-then-read (poll SWI_LANE_STATUS until `locked` is stable for
#      STABLE consecutive reads — NOT a single snapshot). Stop as soon as
#      both ends report all 8 lanes locked.
#   3. Report per-side locked/fault/cal_done + FCSM/cr_pkt observability,
#      total/16, the iteration it converged on (or best-seen), PASS/FAIL.
#
# SAFETY
#   Only ever touches APB reads, strap/debug_unlock/role_lock/phase/swreset
#   writes and the Region-8 slot0 train/recal bit — every one of these is
#   on the "safe-to-execute always" list in deploy_pair.sh / wlink_probe.sh.
#   It NEVER writes AHB_TX (0x4400_0000) and NEVER rings the doorbell, so
#   it cannot trip the wedge-the-board hazard. Lane-lock + cal_done + FCSM
#   advance is the convergence proxy; end-to-end FC traffic (the dangerous
#   AHB_TX path) is deliberately out of scope.
#
# USAGE
#   [MASTER_IP=..] [SLAVE_IP=..] [MP=0 SP=0] [MAX_RETRIES=20] [STABLE=3] \
#   [SETTLE=2] [DEPLOY_PAIR=/path/to/deploy_pair.sh] \
#   bringup_pair_converge.sh
#
#   Run on a host with board-network routes (mapstone-dev). Operator must
#   hold the bridge1 lease (verify it is GRANTED, not queued). Bins staged
#   in /tmp/tidelink_deploy. scp is broken on these hosts (see deploy_pair).
#
#   Exit 0 = full bidirectional link (16/16 lanes, stable). Exit 1 = did
#   not converge within MAX_RETRIES (best-seen reported). Exit 2 = setup
#   error (missing bins / deploy_pair.sh / unreachable board).
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

MASTER_IP="${MASTER_IP:-192.168.4.101}"
SLAVE_IP="${SLAVE_IP:-192.168.6.101}"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_PAIR="${DEPLOY_PAIR:-$SCRIPT_DIR/deploy_pair.sh}"
ARTEFACTS="${ARTEFACTS:-/tmp/tidelink_deploy}"

MP="${MP:-0}"                 # master phase (0 = let calibrator own it)
SP="${SP:-0}"                 # slave  phase (0 = let calibrator own it)
MAX_RETRIES="${MAX_RETRIES:-20}"
STABLE="${STABLE:-3}"         # consecutive equal reads required = "settled"
SETTLE="${SETTLE:-2}"         # seconds to let a recal sweep run before polling
POLL_GAP="${POLL_GAP:-0.3}"   # seconds between settle-poll reads
RECAL_HOLD="${RECAL_HOLD:-0.25}"

MPV=$(( MP << 17 )); SPV=$(( SP << 17 ))

# ---------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 2; }

[ -x "$DEPLOY_PAIR" ] || [ -f "$DEPLOY_PAIR" ] || \
    fail "deploy_pair.sh not found at $DEPLOY_PAIR (set DEPLOY_PAIR=)"
[ -f "$ARTEFACTS/tidelink.bin" ] || \
    fail "no tidelink.bin staged in $ARTEFACTS"

# Region-8 slot0 (0x44032000+0x100): {bit0 train, bit1 recal}. Writing it
# also opens debug_unlock (0x44041000) so the slave APB path is live —
# identical helper to redeploy_repeatability.sh / phase_recal_sweep.sh.
set_slot0() {   # IP VAL
    local IP=$1 VAL=$2
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
g,go=mm(0x44041000); struct.pack_into(\"<I\",g,go,1)
r,ro=mm(0x44032000,0x400); struct.pack_into(\"<I\",r,ro+0x100,$VAL)'" 2>/dev/null
}

# Read SWI_LANE_STATUS (0x44032000+0x108): locked[7:0] fault[15:8]
# cal_done[16] FCSM[20:17] LL_RX[22:21] cr[23] crack[24].
# Emits: "lkHex ftHex calDone popcount fcsm crSeen"  (or "" on failure)
read_status() {  # IP
    local IP=$1
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$IP" \
      "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a,sz=4096):
 b=a&~(P-1); o=a-b; pg=((sz+o+P-1)//P)*P
 return mmap.mmap(fd,pg,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),o
r,o=mm(0x44032000,0x400); s=struct.unpack_from(\"<I\",r,o+0x108)[0]
lk=s&0xff; ft=(s>>8)&0xff
print(\"0x%02x 0x%02x %d %d %d %d\"%(lk,ft,(s>>16)&1,bin(lk).count(\"1\"),(s>>17)&0xF,(s>>23)&1))'" 2>/dev/null
}

# Settle-then-read: poll until `locked` repeats STABLE times in a row
# (or give up after STABLE*4 polls and return the last sample). This is
# the measurement fix — never trust a single fixed-delay snapshot.
settle_read() {  # IP  -> echoes the settled status line
    local IP=$1 last="" lk prev="" run=0 polls=0 maxpolls=$(( STABLE * 4 + 2 ))
    while [ "$polls" -lt "$maxpolls" ]; do
        last=$(read_status "$IP")
        [ -z "$last" ] && { sleep "$POLL_GAP"; polls=$((polls+1)); continue; }
        lk=$(echo "$last" | awk '{print $1}')
        if [ "$lk" = "$prev" ]; then
            run=$((run+1)); [ "$run" -ge "$STABLE" ] && break
        else
            run=1; prev="$lk"
        fi
        sleep "$POLL_GAP"; polls=$((polls+1))
    done
    echo "$last"
}

# Coordinated parallel recal: re-arm BOTH calibrators within ~1 SSH RTT.
# slot0=0x3 (train+recal hold) on both -> settle -> slot0=0x1 (recal
# falling edge -> calibrator S_ARM/S_SWEEP) on both. With S_HOLD in RTL
# the first to lock holds training so the skew-delayed peer converges.
recal_cycle() {
    set_slot0 "$MASTER_IP" 0x3 & set_slot0 "$SLAVE_IP" 0x3 & wait
    sleep "$RECAL_HOLD"
    set_slot0 "$MASTER_IP" 0x1 & set_slot0 "$SLAVE_IP" 0x1 & wait
    sleep "$SETTLE"
}

# ---------------------------------------------------------------------------
echo "=============================================================="
echo " TideLink coordinated closed-loop bring-up  $(date)"
echo "  master=$MASTER_IP slave=$SLAVE_IP  phase mp=$MP sp=$SP"
echo "  MAX_RETRIES=$MAX_RETRIES STABLE=$STABLE SETTLE=${SETTLE}s"
echo "  RTL: T3+S_HOLD calibrator + IDELAYE2 + FCSM-sticky (td-combined)"
echo "=============================================================="

# Reachability pre-flight (fail fast, do not run a half-pair).
for ip in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" true 2>/dev/null \
        || fail "board $ip unreachable over SSH (check lease GRANTED + board up)"
done

echo "--- Phase 1: parallel deploy (role_lock skew = SSH-launch jitter) ---"
PHASE_OVERRIDE=$(printf 0x%08x $MPV) \
    bash "$DEPLOY_PAIR" "$MASTER_IP" z2_master die_a "$ARTEFACTS" >/dev/null 2>&1 &
mpid=$!
PHASE_OVERRIDE=$(printf 0x%08x $SPV) \
    bash "$DEPLOY_PAIR" "$SLAVE_IP"  z2_slave  die_b "$ARTEFACTS" >/dev/null 2>&1 &
spid=$!
wait $mpid; mrc=$?
wait $spid; src=$?
[ $mrc -eq 0 ] || echo "  WARN: master deploy_pair.sh rc=$mrc (continuing — closed loop may still recover)"
[ $src -eq 0 ] || echo "  WARN: slave  deploy_pair.sh rc=$src (continuing — closed loop may still recover)"
sleep 1

echo "--- Phase 2: closed-loop coordinated recal until converged ---"
printf '%-4s | %-30s | %-30s | %s\n' IT "MASTER lk/ft cal# fcsm cr" "SLAVE lk/ft cal# fcsm cr" "tot/16"

best=-1; best_it=0; best_line=""; conv_it=0
for it in $(seq 1 "$MAX_RETRIES"); do
    recal_cycle
    MR=$(settle_read "$MASTER_IP")
    SR=$(settle_read "$SLAVE_IP")
    mlk=$(echo "$MR" | awk '{print $1}'); mft=$(echo "$MR" | awk '{print $2}')
    mcd=$(echo "$MR" | awk '{print $3}'); mpc=$(echo "$MR" | awk '{print $4}')
    mfs=$(echo "$MR" | awk '{print $5}'); mcr=$(echo "$MR" | awk '{print $6}')
    slk=$(echo "$SR" | awk '{print $1}'); sft=$(echo "$SR" | awk '{print $2}')
    scd=$(echo "$SR" | awk '{print $3}'); spc=$(echo "$SR" | awk '{print $4}')
    sfs=$(echo "$SR" | awk '{print $5}'); scr=$(echo "$SR" | awk '{print $6}')
    mpc=${mpc:-0}; spc=${spc:-0}
    tot=$(( mpc + spc ))
    printf '%-4s | %-30s | %-30s | %s\n' "$it" \
        "${mlk:-?}/${mft:-?} ${mpc} ${mcd:-?} fs${mfs:-?} cr${mcr:-?}" \
        "${slk:-?}/${sft:-?} ${spc} ${scd:-?} fs${sfs:-?} cr${scr:-?}" \
        "$tot"
    if [ "$tot" -gt "$best" ] 2>/dev/null; then
        best=$tot; best_it=$it
        best_line="M[$MR] S[$SR]"
    fi
    # Converged = both sides all 8 lanes locked AND both cal_done.
    if [ "$mpc" -eq 8 ] 2>/dev/null && [ "$spc" -eq 8 ] 2>/dev/null \
       && [ "${mcd:-0}" -eq 1 ] 2>/dev/null && [ "${scd:-0}" -eq 1 ] 2>/dev/null; then
        conv_it=$it
        break
    fi
done

echo "=============================================================="
if [ "$conv_it" -gt 0 ]; then
    echo "RESULT: CONVERGED — full 16/16 bidirectional link at iteration $conv_it"
    echo "        $best_line"
    echo "  This is what the consolidated RTL + coordinated closed-loop"
    echo "  deploy was supposed to deliver. Bring-up is up. (Doorbell /"
    echo "  AHB_TX end-to-end is a SEPARATE step — observe the wedge hazard.)"
    exit 0
else
    echo "RESULT: NOT CONVERGED in $MAX_RETRIES iterations."
    echo "  Best seen: ${best}/16 at iteration $best_it"
    echo "  $best_line"
    echo "  Interpretation guide:"
    echo "   * best climbs across iters then plateaus high (e.g. 12-15/16):"
    echo "       residual is per-lane sub-UI / IDELAYE2 tap precision — a"
    echo "       genuine, now-isolable RTL ceiling (raise MAX_RETRIES; then"
    echo "       characterise the stuck lane(s) — fault byte names them)."
    echo "   * one side always ~0, the other climbs: that side's recovered"
    echo "       RX clock / role_lock did not take — check its deploy WARN"
    echo "       and ROLE_CFG lock bit via wlink_probe.sh."
    echo "   * both sides bounce uncorrelated with NO upward trend across"
    echo "       iters: S_HOLD/T3 not actually in this bitstream — verify"
    echo "       the build is from feat/td-combined (S_HOLD in calibrator)."
    exit 1
fi
