#!/bin/bash
# =============================================================================
# td_v2_regress.sh — TideLink V2 ON-SILICON regression suite
#
# Runs the proven A->B path end-to-end and asserts each stage, so a future RTL
# / build / recipe change cannot silently regress link-up, the PHY eye, deskew
# alignment, or A->B data delivery. Produces a PASS/FAIL report + exit code
# (0=all pass) suitable for CI / a pre-merge gate.
#
# TESTS (each builds on the shared bring-up — the real datapath order):
#   01 link_up        both dies reach fcsm=4 (bilateral)
#   02 phy_rx_clean   die_b receives every active-lane SYNC slice BYTE-EXACT
#                     (post-deskew RAWWORD == golden slice) — proves the eye/PHY
#   03 deskew_align   reanchored=1 AND sync_seen_vec=0xe4 (all 4 lanes armed)
#   04 data_a2b       txburst -> GP1 RX aperture 0x84010000 == sent payload
#
# USAGE (run on the lab host that can SSH the PYNQ pair, e.g. mapstone-dev):
#   ./td_v2_regress.sh [--no-deploy] [--no-lease] [--keep] [--rolls N]
#     --no-deploy   skip re-flashing the boards (use what is loaded; faster,
#                   but a stale GP1 RX FIFO can false-PASS test 04 — deploy for
#                   a trustworthy run)
#     --no-lease    skip fpgahub lease acquire/release (caller holds it)
#     --keep        do not release the lease at the end
#     --rolls N     bring-up POR retries for the eye lottery (default 6)
#   Bitstream under test must be staged at $TD_DEPLOY_DIR (tidelink.bin = die_a,
#   tidelink-flip.bin = die_b). Override boards/paths via TD_* env (see hwlib).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/td_v2_hwlib.sh"

DO_DEPLOY=1; DO_LEASE=1; KEEP_LEASE=0; ROLLS=6
while [ $# -gt 0 ]; do case "$1" in
  --no-deploy) DO_DEPLOY=0;; --no-lease) DO_LEASE=0;; --keep) KEEP_LEASE=1;;
  --rolls) ROLLS=$2; shift;; -h|--help) sed -n '2,30p' "$0"; exit 0;;
  *) echo "unknown arg: $1"; exit 2;; esac; shift; done

run_test(){ # name  fn
  local name=$1 fn=$2 t0=$SECONDS rc
  echo "== $name =="
  if $fn; then rc=0; printf "  [PASS] %-14s %ds\n" "$name" $((SECONDS-t0))
  else        rc=1; printf "  [FAIL] %-14s %ds\n" "$name" $((SECONDS-t0)); fi
  flush_detail; return $rc
}
abort(){ echo "### ABORT: $1"; [ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release; exit 1; }

echo "======== TideLink V2 HW regression ($(date)) ========"
echo "  die_a=$A_IP($A_BOARD)  die_b=$B_IP($B_BOARD)  deploy=$DO_DEPLOY  dir=$DEPLOY_DIR"

# --- preflight -------------------------------------------------------------
boards_up || abort "a board is unreachable (power-cycle? $A_IP / $B_IP)"
if [ "$DO_LEASE" = 1 ]; then lease_acquire 2400 || abort "could not acquire $LEASE_NAME lease"; fi
trap '[ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release' EXIT

# --- shared bring-up -------------------------------------------------------
[ "$DO_DEPLOY" = 1 ] && { echo "-- deploying bitstream under test --"; deploy_pair; sleep 1; }
rcp

# ===== test 01: link_up ====================================================
t_link_up(){ wait_bilateral "$ROLLS" 16 || { TD_DETAIL+=("    FAIL no bilateral fcsm=4 in $ROLLS rolls"); TD_FAIL=$((TD_FAIL+1)); return 1; }
  assert_eq "fcsm die_a" 4 "$(fcsm a)"; assert_eq "fcsm die_b" 4 "$(fcsm b)"; }
run_test link_up t_link_up || abort "no link — downstream tests meaningless"

# data-mode entry (FC node) BEFORE alignment — part of the proven recipe; the FC
# node must be set up or committed data never reaches the GP1 RX aperture.
echo "-- handoff (FC data-mode entry) --"; handoff

# bring the link to the aligned state once (shared by tests 02-04)
echo "-- winscan + align --"; winscan

# ===== test 02: phy_rx_clean (byte-exact reception => eye/PHY good) =========
t_phy_rx_clean(){ a wr $R_R8 0x1C>/dev/null; b wr $R_R8 0x1C>/dev/null; sleep 0.8   # force_always so RAWWORD == SYNC slices
  local L ok=0
  for L in $MASK_ACTIVE_LANES; do assert_eq "lane$L rx slice" "${EXP_SLICE[$L]}" "$(rx_slice $L)" || ok=1; sleep "$TD_THROTTLE"; done
  return $ok; }
run_test phy_rx_clean t_phy_rx_clean

# ===== test 03: deskew_align ===============================================
t_deskew_align(){ a wr $R_R8 0x14>/dev/null; b wr $R_R8 0x14>/dev/null   # idle-gated -> reanchored
  local w; for w in $(seq 1 6); do sleep 1.0; [ "$(reanchored)" = 1 ] && break; done
  assert_eq "reanchored"     1            "$(reanchored)"
  assert_eq "sync_seen_vec"  $EXP_SYNC_SEEN "$(sync_seen)"; }
run_test deskew_align t_deskew_align

# ===== test 04: data_a2b (the headline: byte-exact A->B payload) ============
t_data_a2b(){ enter_data_mode
  TD_DETAIL+=("    [state] $(data_state)")       # diagnostic: send-gate / FC / reanchored
  local n; for n in $(seq 1 32); do gp1_rx 0 >/dev/null; done    # drain stale GP1 (pops on read)
  for n in 1 2 3 4; do send_a2b; sleep 0.2; done; sleep 1.5      # L9 resync accepts the first data pkt
  # GP1 RX aperture pops on read — read each word EXACTLY ONCE (hdr + payload[0..1]).
  local w0 w1 w2
  w0=$(printf 0x%08x $(($(gp1_rx 0)))); sleep "$TD_THROTTLE"
  w1=$(printf 0x%08x $(($(gp1_rx 1)))); sleep "$TD_THROTTLE"
  w2=$(printf 0x%08x $(($(gp1_rx 2)))); sleep "$TD_THROTTLE"
  TD_DETAIL+=("    [rx] GP1=$w0 $w1 $w2")
  local ok=0
  assert_eq "GP1 header"     $(printf 0x%08x $((TX_HDR)))          "$w0" || ok=1
  assert_eq "GP1 payload[0]" $(printf 0x%08x $((${TX_PAYLOAD[0]}))) "$w1" || ok=1
  assert_eq "GP1 payload[1]" $(printf 0x%08x $((${TX_PAYLOAD[1]}))) "$w2" || ok=1
  return $ok; }
run_test data_a2b t_data_a2b

# --- report ----------------------------------------------------------------
echo "========================================================"
TOT=$((TD_PASS+TD_FAIL))
echo "  RESULT: $TD_PASS/$TOT asserts passed across the suite"
if [ "$TD_FAIL" = 0 ]; then echo "  ✅ ALL TESTS PASS — V2 A->B path intact"; RC=0
else echo "  ❌ $TD_FAIL assertion(s) FAILED — regression detected"; RC=1; fi
echo "========================================================"
exit $RC
