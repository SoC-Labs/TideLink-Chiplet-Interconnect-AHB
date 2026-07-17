#!/bin/bash
# =============================================================================
# td_v2_channels.sh — TideLink V2 CANONICAL on-silicon multi-channel regression
#
# Supersedes the ~245 hand-rolled one-shot bring-up/probe scripts that ride on
# mapstone-dev, and updates fpga/hw_regression/td_v2_regress.sh (2026-06-26,
# pre-deterministic-linkup) with the CURRENT proven July methodology:
#
#   * DETERMINISTIC link-up (no "eye lottery" --rolls retry loop). The July
#     deterministic-linkup work killed the bring-up lottery: R8 uses 0x1C
#     (bit0 CLEAR) as the sync/data base — bit0 (swi_training_mode) set was the
#     silent S_HOLD trap that made link-up a coin-flip. A POR-count still exists
#     but as a soak/robustness knob, NOT a retry-until-lucky loop.
#   * CORRECT register map (see REGS below). In particular autoneg is armed via
#     the RW NEGO_CFG at 0x44032090 — NOT the read-only status alias 0x44032110.
#   * Two bring-up modes: `manual` (deterministic poke recipe) and `autonomous`
#     (arm-once NEGO_CFG=0x61, longer poll to absorb the div-2 link clock).
#   * Channel gates run in a WEDGE-SAFE order (see main): cal=1 -> tl-data both
#     directions (rotation-aware ring compare) -> doorbell -> ptp (opt-in) ->
#     XHB transparent window (timeout-wrapped, bounded, ONLY after data is
#     proven).
#
# Runs ON a lab host that can SSH the PYNQ pair (e.g. mapstone-dev). Assumes
# tl39.py is already staged on both boards (TL39 path, default /home/xilinx).
# Does NOT hardcode mapstone-dev-only paths; boards + paths are env-overridable.
# Structure mirrors td_v2_regress.sh / td_v2_hwlib.sh and the canonical bring-up
# pynq_host/scripts/bringup_autocal_i2c.sh (autonomous NEGO_CFG=0x61) — build ON
# them; this file is self-contained so the July register map cannot drift back
# to the June (bit0-set) recipe.
#
# HARDWARE-SAFETY (z2_02 AHB-wedge discipline) baked in:
#   * every board register READ is THROTTLE-sleeved (no tight host<->ssh loops
#     — dense PS mmap access wedges the kernel, needs a physical power-cycle);
#   * NO premature AHB_TX writes — data is only pushed AFTER cal=1 gates PASS;
#   * XHB transparent-window reads are `timeout`-wrapped and TXN-BOUNDED, run
#     LAST and only if tl-data proved the datapath (the new ahb_sub HREADY
#     timeout backstop, cb33c9f, makes a window stall recoverable, but we still
#     bound it rather than trust the backstop alone);
#   * the window soak is BOUNDED (WIN_SOAK_TXNS), never unbounded.
#
# -----------------------------------------------------------------------------
# THE `ptp` CHANNEL (added 2026-07-15) — OPT-IN, NOT IN THE DEFAULT LIST.
# -----------------------------------------------------------------------------
# PTP only physically exists on the -ptp targets (kr260-pair-{,flip-}ptp, or
# pynq-z2-pair-all built with TIDELINK_FPGA_PTP=1). On every other bitstream the
# PHC hardware clock IP is NOT instantiated and its APB aperture (0x4405_0000) is
# NOT in any AXI address segment.
#
# *** WHY OPT-IN AND NOT AUTO-DETECT ***  Detecting the PHC requires READING its
# aperture, and on a non-PTP bitstream that read is itself the hazard: the
# SmartConnect decodes it to nothing -> DECERR -> external abort on the PS. That
# is the same failure class as the bootpy/base.bit incident (unmapped 0x4403_xxxx
# => "external abort 0x018" => dead board, physical power-cycle). An auto-probe
# that runs by DEFAULT would therefore fire that read on every existing non-PTP
# run — exactly the wedge this script is built to avoid. So:
#   * `ptp` is NOT in the default CHANNELS. Existing runs are bit-for-bit
#     unaffected and never touch 0x4405_0000.
#   * Selecting it (`--channels "data doorbell ptp"`) is the operator asserting
#     "this is a -ptp bitstream".
#   * Even then the FIRST PHC touch is a bounded CANARY (read+readback-verify the
#     RW ns_incr register). If it does not answer, or answers implausibly, the
#     channel reports SKIP — never FAIL — and touches nothing else.
# The canary is still a real (small) risk on a mis-selected bitstream: a
# programmed non-PTP TideLink PL should return DECERR promptly (SIGBUS kills the
# tl39 process, board survives, we SKIP), but that is expected behaviour, not a
# guarantee. Do not select `ptp` unless you know PTP is in the bitstream.
#
# What the ptp channel PROVES (see gate_ptp for the per-step argument):
#   1. a LIVE, free-running PHC time base exists on BOTH dies (software-captured
#      counter strictly advances between two throttled samples) — this is the
#      anti-tie-off check; a tied/absent PHC reads a frozen constant;
#   2. the master's HW_SYNC initiator actually EMITTED SYNCs (GM seq_num
#      advances);
#   3. the FULL PTP round trip crossed the link (slave servo reports a non-zero
#      hardware-computed offset — only possible if SYNC TX(t1) -> SYNC RX(t2) ->
#      DELAY_REQ TX(t3) -> DELAY_REQ RX(t4) -> FC SIDEBAND t1/t4 delivery ALL
#      completed);
#   4. the subordinate servo DISCIPLINED its clock (|offset| converges under
#      TD_PTP_TOL_NS).
# It deliberately does NOT use HW_SYNC_STATUS[18] (phc_locked): phc_locked_i is
# tied 0 in EVERY FPGA bitstream (the BD never connects tidelink_0/phc_locked_i,
# and PHC_LOCK_GATE_EN=0 so the initiator does not need it). That bit is the
# exact "spurious tied-off pass" the sim test test_ptp_link_sync.py was written
# to kill — reading it here would re-import the bug. Skew is likewise taken from
# the servo's OWN hardware-computed offset register, NOT from differencing two
# ssh-separated host captures: the ssh round-trip (~100s of ms) dwarfs the ns-scale
# quantity, so a host-differenced "skew" would measure the instrument, not the DUT.
#
# --demo: PRESENTATION ONLY. Adds a per-channel banner (name / what it proves /
# PASS-FAIL-SKIP / key measured numbers) and a closing summary table. It changes
# NOTHING about what is tested, in what order, or the exit code — so the script
# stays a CI gate with --demo on or off.
#
# USAGE:
#   ./td_v2_channels.sh [--mode manual|autonomous] [--channels "data doorbell xhb"]
#                       [--pors N] [--demo] [--no-lease] [--keep] [-h]
#   PTP demo (only on a -ptp bitstream):
#     ./td_v2_channels.sh --demo --channels "data doorbell ptp xhb"
#   Env overrides: TD_MASTER_IP TD_SLAVE_IP TD_MASTER_BOARD TD_SLAVE_BOARD
#                  TD_TL39 TD_THROTTLE TD_BOARD_PW TD_BOARD_USER TD_LEASE
#                  TD_SSH_TIMEOUT
#                  TD_PHC_BASE TD_PHC_NS_INCR TD_PTP_TOL_NS TD_PTP_ROUNDS
#                  TD_PTP_DWELL TD_PTP_STEP_NS
# Exit code: 0 = every selected channel PASS (SKIP is not a failure),
#            1 = any FAIL/abort (CI gate).
# =============================================================================
set -u

# ----- CLI ------------------------------------------------------------------
MODE=manual
# NOTE: `ptp` is deliberately NOT here — it is opt-in (see the header). Adding it
# to this default would fire a PHC-aperture read on every non-PTP bitstream.
CHANNELS="data doorbell xhb"
PORS=1
DO_LEASE=1
KEEP_LEASE=0
DEMO=0
while [ $# -gt 0 ]; do case "$1" in
  --mode)     MODE="$2"; shift;;
  --channels) CHANNELS="$2"; shift;;
  --pors)     PORS="$2"; shift;;
  --demo)     DEMO=1;;
  --no-lease) DO_LEASE=0;;
  --keep)     KEEP_LEASE=1;;
  -h|--help)  sed -n '2,105p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see -h)"; exit 2;;
esac; shift; done
case "$MODE" in manual|autonomous) ;; *) echo "bad --mode: $MODE"; exit 2;; esac

# ----- SoC address map ------------------------------------------------------
# Z2 default is an exact identity (see td_socmap.sh). Every register literal in
# this file stays Z2-CANONICAL: m()/s() hand them to tl39.py, which owns the
# single remap in the chain. Do NOT pre-relocate them here (double remap =
# undecoded address = the bus hang this is guarding against). Only bases used
# OUTSIDE a tl39 call are relocated below.
_TD_HERE_SOCMAP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fpga/hw_regression/td_socmap.sh
source "$_TD_HERE_SOCMAP/td_socmap.sh"

# ----- board / topology config (override via env) ---------------------------
# TD_MASTER_IP/TD_SLAVE_IP (this script's vocabulary) and TD_A_IP/TD_B_IP
# (td_v2_hwlib.sh's) name the same two boards. Accept both; if both are set and
# DISAGREE, abort — a silent pick would drive the wrong hardware.
MASTER_IP=$(td_reconcile TD_MASTER_IP TD_A_IP "die_a / master board IP")
MASTER_IP=${MASTER_IP:-192.168.4.101}       # die_a: master / non-flip (A->B sender)
SLAVE_IP=$(td_reconcile TD_SLAVE_IP TD_B_IP "die_b / slave board IP")
SLAVE_IP=${SLAVE_IP:-192.168.2.101}         # die_b: slave  / flip     (A->B receiver)
MASTER_BOARD=$(td_reconcile TD_MASTER_BOARD TD_A_BOARD "die_a / master board name")
MASTER_BOARD=${MASTER_BOARD:-z2_02}
SLAVE_BOARD=$(td_reconcile TD_SLAVE_BOARD TD_B_BOARD "die_b / slave board name")
SLAVE_BOARD=${SLAVE_BOARD:-z2_01}
TL39=${TD_TL39:-/home/xilinx/tl39.py}
LEASE_NAME=${TD_LEASE:-bridge1}
THROTTLE=${TD_THROTTLE:-0.25}               # sleep between board reads (PS-wedge guard)
SSH_TIMEOUT=${TD_SSH_TIMEOUT:-10}           # per-call ssh wall-clock timeout (s)
WIN_SOAK_TXNS=${TD_WIN_SOAK_TXNS:-8}        # BOUNDED XHB window soak transaction count

# ----- ptp channel knobs (only ever used if `ptp` is explicitly selected) ----
# PHC hardware-clock APB, Z2-CANONICAL (handed to tl39, which relocates it).
# CORRECTED 2026-07-16: the previous comment here claimed "Z2 pair-all + kr260
# -ptp both map it here (GP0/HPM0)". That is WRONG — fpga/docs/KR260_PORT.md
# puts phc apb at 0x8405_0000 on KR260, not 0x4405_0000. The stale claim was
# load-bearing: it told a reader no relocation was needed, and a raw
# 0x4405_0000 poke on ZynqMP is undecoded (bus hang). TIDELINK_SOC now does the
# relocation; leave this at the Z2 literal.
PHC_BASE=${TD_PHC_BASE:-0x44050000}
PHC_NS_INCR=${TD_PHC_NS_INCR:-40}     # ns added per phc_clk cycle. phc_clk = clk_wiz
                                      # clk_out2, CONFIG.CLKOUT2_REQUESTED_OUT_FREQ
                                      # {25.000} in BOTH pynq-z2-pair-all and
                                      # kr260-pair-ptp tidelink_design.tcl => 25 MHz
                                      # => 40 ns. (The "50 MHz" in those tcl HEADER
                                      # comments and in phc_vivado_wrapper.v's
                                      # "write NS_INCR=20" operator note are STALE —
                                      # the live clk_wiz CONFIG is authoritative.)
                                      # The PHC core POR is 4 (250 MHz ASIC target),
                                      # so this MUST be written or the counter runs
                                      # 10x slow. Rate only affects the reported
                                      # ns/s diagnostic, never the pass/fail gate.
PTP_ROUNDS=${TD_PTP_ROUNDS:-6}        # BOUNDED servo-offset samples (never a poll loop)
PTP_DWELL=${TD_PTP_DWELL:-1.0}        # seconds between servo-offset samples
PTP_STEP_NS=${TD_PTP_STEP_NS:-12000}  # SERVO_STEP_THRESH: above this the servo takes a
                                      # coarse SET_TIME phase step, below it rides the
                                      # PI frequency steer. Mirrors the sim test.
PTP_TOL_NS=${TD_PTP_TOL_NS:-12000}    # convergence gate on |servo offset|.
                                      # *** UNCALIBRATED ON SILICON ***  Chosen to
                                      # mirror test_ptp_link_sync.py (sim: init skew
                                      # 20000 ns -> steady |skew| ~4290 ns, gate
                                      # worst |offset| <= 12000). The FPGA link runs
                                      # far slower (6.25 MHz, /2 => 3.125 MHz) than
                                      # the sim, so real t1..t4 latency — and thus the
                                      # irreducible residual — may be LARGER. If the
                                      # first hardware run fails ONLY this gate while
                                      # offsets are clearly converging, that is a
                                      # tolerance calibration, not a DUT regression:
                                      # re-run with TD_PTP_TOL_NS raised and record
                                      # the measured floor.

# ----- register map (AUTHORITATIVE — current July deterministic methodology) -
#   APB base 0x4403_0000; TideLink cfg region at 0x4403_2000. Data on GP1.
R_NEGO_CFG=0x44032090        # NEGO_CFG (RW) — ARM autoneg here (NOT the RO 0x110)
R_NEGO_STS=0x44032110        # NEGO status (RO) alias — never write this
R_ROLE=0x44032080            # role W1S: master=0x2, slave=0x3
R_STATUS=0x44032108          # [16]=cal [19:17]=fcsm(4=bilateral) [23]=cr [31]=fe_full
R_NEGO_TRAIN=0x4403210C      # NEGO_TRAIN_CFG (autonomy-off = 0x0 for manual)
R_R8=0x44032100              # PHY ctrl: 0x1C sync / 0x1E->0x1C recal / 0x10 data-en
                             #           NEVER bit0 (swi_training_mode = S_HOLD trap)
                             # data-en MUST clear bit2 (SYNC_EN): 0x10 not 0x14. With
                             # SYNC_EN left on during the burst the framer injects SYNC
                             # beacons mid-packet -> ~3/28 words corrupt per burst
                             # (silicon-proven 2026-07-11: 0x10 => GP1 RX byte-exact;
                             # 0x14 => filt=25/28 rot=-1). Matches hwlib enter_data_mode
                             # ("strip SYNC so the framer runs packets to completion").
R_SLIPLO=0x44032104          # SWI_BIT_SLIP_LO ([23:0]slip [27:24]word_pin [28]auto_dis)
R_LANEMASK=0x44030214        # rx/tx lane mask (0x0000_e4e4 = active lanes 2,5,6,7)
R_SYNCTOL=0x44032128         # [12:8]=SYNC tol(5) [7:0]=per-lane mask(0xe4)
R_LOCKTHR=0x44032160         # per-lane Hamming lock threshold (0x5555_5555 = 5)
R_REANCHORED=0x44032140      # [0]=epoch_anchored (deskew aligned, sticky)
R_FCCTRL=0x44030208          # LL/FC-node bootstrap triplet target
R_FCQUIESCE=0x44030230       # FC-node quiesce (pre-bootstrap)
R_DOORBELL=0x44032014        # WO: write -> ring doorbell to peer (self-clearing)
R_DOORBELL_ACC=0x44032024    # W-add / R-clear: doorbell responses RECEIVED from peer

# --- PTP / servo registers (TideLink APB cfg block, base 0x4403_2000) --------
# These live in the SAME always-mapped aperture as every other register above:
# they exist in EVERY bitstream, PTP or not (on a non-PTP build the block is
# present but its phc_* inputs are tied to zero xlconstants). Reading them is
# therefore as safe as reading R_STATUS. Offsets cross-checked against
# src/rtl/fifo/tidelink_apb_regs.sv (apb_region/servo_reg_addr decode),
# src/rtl/tidelink_ptp.sv and src/rtl/tidelink_ptp_servo.sv, and they match the
# sim map in cocotb/tidelink_top_pair/test_ptp_link_sync.py 1:1.
R_PTP_CTRL=0x44032034        # [0] ptp_enable (short-packet engine: RX accept + TX)
R_HW_SYNC_CTRL=0x44032040    # [0] enable [1] seq_clear(W1C) [2] force_en
R_HW_SYNC_INTERVAL=0x44032044
R_HW_SYNC_STATUS=0x44032048  # [0] active [1] busy [17:2] seq_num [18] phc_locked
                             # [18] is TIED 0 in every FPGA build (BD never connects
                             # tidelink_0/phc_locked_i) — NEVER gate on it. See header.
R_SERVO_CTRL=0x4403204C      # [0] enable [1] mode (0=Grandmaster, 1=Subordinate)
R_SERVO_STEP=0x44032058      # servo_step_thresh_r — coarse SET_TIME step threshold (ns)
R_SERVO_STATUS=0x4403205C    # [0] servo_locked [1] active(gm|sub)
R_SERVO_OFFSET=0x44032060    # last_offset_r — SIGNED ns, computed IN HARDWARE from
                             # t1..t4. Host-jitter immune: this is the instrument.
R_SERVO_DELAY=0x44032064     # last_delay_r — ns
SERVO_GM=0x1                 # enable, mode=0 -> Grandmaster
SERVO_SUB=0x3                # enable, mode=1 -> Subordinate
HW_SYNC_FORCE=0x5            # [2] force_en | [0] enable -> fire immediately + free-run

# --- PHC hardware-clock APB (0x4405_0000) — PRESENT ONLY ON -ptp BITSTREAMS --
# *** Do not read ANY of these unless the `ptp` channel was explicitly selected.
# *** On a non-PTP bitstream this aperture is unmapped => DECERR. See header.
# Offsets from src/rdl/phc_regs.rdl (region 0 = core cfg, region 1 = SW capture).
R_PHC_CTRL=$(printf 0x%08x $(( PHC_BASE + 0x000 )))    # [0] en [1] set_time [2] capture
R_PHC_STATUS=$(printf 0x%08x $(( PHC_BASE + 0x004 )))  # [0] running [1] pps_sticky(RC)
R_PHC_NS_INCR=$(printf 0x%08x $(( PHC_BASE + 0x008 ))) # [7:0] ns per phc_clk cycle (RW)
R_PHC_CAP_SEC_LO=$(printf 0x%08x $(( PHC_BASE + 0x020 )))  # SW-captured seconds[31:0]
R_PHC_CAP_NS=$(printf 0x%08x $(( PHC_BASE + 0x028 )))      # SW-captured nanoseconds[29:0]
PHC_EN=0x1                   # ctrl: en
PHC_EN_CAP=0x5               # ctrl: en | capture (capture is singlepulse/self-clearing)
                             # This is the REGION 1 software capture. It is explicitly
                             # independent of the REGION 2 HW_CAP_* registers that the
                             # PTP datapath uses (phc_regs.rdl: "preventing contention
                             # between PTP hardware captures and software diagnostic
                             # captures"), so sampling here cannot perturb the servo.

# Data-plane bases. These stay Z2-CANONICAL: every one of them is handed to
# tl39.py (see the xhb window soak's `m wr $addr`), and tl39 owns the single
# remap. Relocating here as well would double-remap on a KR260
# (0x4000_0000 -> 0x8000_0000 -> 0xC000_0000 = undecoded = bus hang).
#
# TX_BASE/RX_BASE are NOT used by this script — the data channel goes through
# tl39's own `txburst`/`drain`, which resolve the aperture themselves. They are
# validated-and-dropped rather than declared, so that an operator following the
# OLD KR260_PORT.md advice (`export TIDELINK_TX_BASE=0xA4000000`) gets a loud
# abort here instead of a value that silently does nothing.
td_data_base TIDELINK_TX_BASE     0x84000000 ahb_tx   >/dev/null
td_data_base TIDELINK_RXFIFO_BASE 0x84010000 ahb_fifo >/dev/null
XHB_WINDOW=${TIDELINK_XHB_WINDOW:-0x40000000} # transparent peer window (M_AXI_GP0); Z2-canonical, tl39 relocates

# LL/FC bootstrap triplet (bit0=swi_enable) and the R8 phase constants
FC_TRIPLET=(0x00027f09 0x00027f01 0x00027f07)
R8_SYNC=0x1C; R8_RECAL=0x1E; R8_DATA=0x10   # data-en strips SYNC_EN (bit2); see R_R8 note
NEGO_ARM=0x61                # nego_en | force_lock | mask_hs_auto_en (0x41 never latches)
ACTIVE_LANES="2 5 6 7"

# ----- SSH plumbing (one hop per call, throttled; modeled on td_v2_hwlib.sh) --
BOARD_PW=${TD_BOARD_PW:-xilinx}
# Board login — one knob, defaults to xilinx (the PYNQ-Z2 image) so Z2 runs are
# unchanged; set TD_BOARD_USER for images that use a different login.
BOARD_USER=${TD_BOARD_USER:-xilinx}
SSH="sshpass -p ${BOARD_PW} ssh -n -o StrictHostKeyChecking=no \
-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
# TIDELINK_SOC must cross the ssh hop — tl39.py runs ON THE BOARD and resolves
# its address map from its OWN environment. ssh does not forward env and sudo
# scrubs it, so pass it as a sudo-side assignment. Without this a KR260 run
# reaches tl39 with TIDELINK_SOC unset -> z2 identity -> Z2 control literals
# poked on ZynqMP -> undecoded AXI access -> hard PS hang. On z2 this passes
# TIDELINK_SOC=z2, identical to unset (proven), so Z2 is unchanged.
_PY="echo ${BOARD_PW} | sudo -S TIDELINK_SOC=$(td_soc) python3 $TL39"
# m/s: run a tl39 command on master/slave, wall-clock bounded so a wedged PS
# access degrades to a timeout (empty output) instead of hanging the suite.
m(){ timeout "$SSH_TIMEOUT" $SSH $BOARD_USER@$MASTER_IP "$_PY $*" 2>/dev/null; }
s(){ timeout "$SSH_TIMEOUT" $SSH $BOARD_USER@$SLAVE_IP  "$_PY $*" 2>/dev/null; }
# throttled reads: never issue back-to-back host->ssh reads without a sleep
mrd(){ local v; v=$(m rd $1); sleep "$THROTTLE"; echo "$v"; }
srd(){ local v; v=$(s rd $1); sleep "$THROTTLE"; echo "$v"; }
# hex/empty -> int. EMPTY is LOUD (defect class 1): m()/s() swallow stderr, so a
# staging failure or a wedged read returns nothing; silently mapping that to 0
# is exactly how a broken tool masquerades as cal=0/fcsm=0 == a dead link. The
# tl39 preflight below is the hard abort for the systematic case; this warns on
# any residual empty so an all-empty run can never pass quietly. (Called inside
# $() subshells, so `exit` here cannot stop the parent — hence WARN, not abort.)
val(){
  if [ -z "${1:-}" ]; then
    printf '### WARN: val() got EMPTY board output — read returned nothing (wedge / ssh timeout / tl39 staging fail); treating as 0. A run full of these is NOT a dead link, it is a dead instrument.\n' >&2
    echo 0; return
  fi
  printf "%d" $(( $1 )) 2>/dev/null || echo 0
}

# tl39 PREFLIGHT (defect class 1): m()/s() run tl39 as `... 2>/dev/null`, so if
# tl39.py is staged without tl_socmap.py (or TIDELINK_SOC is wrong) it fails to
# stderr and vanishes -> every read empty -> cal=0/fcsm=0, indistinguishable
# from a dead link. Run tl39's no-bus `selftest` on each board WITH stderr shown
# and require the TL39_OK sentinel before ANY bus access.
tl39_preflight(){
  local who ip out fail=0
  for who in master slave; do
    [ "$who" = master ] && ip=$MASTER_IP || ip=$SLAVE_IP
    out=$(timeout "$SSH_TIMEOUT" $SSH $BOARD_USER@$ip "$_PY selftest" 2>&1)
    case "$out" in
      *TL39_OK*) echo "  tl39 preflight OK ($who $ip): $(printf '%s\n' "$out" | grep -m1 -o 'TL39_OK[^"]*')" ;;
      *) echo "### tl39 preflight FAILED ($who $ip): '${out:0:200}'" >&2
         echo "###   tl39.py did not answer TL39_OK — staged without tl_socmap.py, or a bad" >&2
         echo "###   TIDELINK_SOC. Every read would be EMPTY and misread as a dead link." >&2
         fail=1 ;;
    esac
  done
  return $fail
}

# ----- status decoders ------------------------------------------------------
# $1 = m|s (which die). fcsm / cal / cr read from R_STATUS, throttled.
_stat(){ [ "$1" = m ] && mrd $R_STATUS || srd $R_STATUS; }
fcsm(){ local v; v=$(val "$(_stat $1)"); echo $(( (v>>17)&7 )); }
cal(){  local v; v=$(val "$(_stat $1)"); echo $(( (v>>16)&1 )); }
cr(){   local v; v=$(val "$(_stat $1)"); echo $(( (v>>23)&1 )); }
reanchored(){ echo $(( $(val "$(srd $R_REANCHORED)")&1 )); }

# ----- assert framework (mirrors td_v2_hwlib.sh) ----------------------------
TD_PASS=0; TD_FAIL=0; DETAIL=()
ok(){    TD_PASS=$((TD_PASS+1)); DETAIL+=("    ok   $1"); }
bad(){   TD_FAIL=$((TD_FAIL+1)); DETAIL+=("    FAIL $1"); }
assert(){ if [ "$2" = "$3" ]; then ok "$1: $3"; else bad "$1: got=$3 want=$2"; return 1; fi; }
flush(){ [ ${#DETAIL[@]} -gt 0 ] && printf '%s\n' "${DETAIL[@]}"; DETAIL=(); }

# ----- small numeric helpers ------------------------------------------------
s32(){ local v=$(( ${1:-0} & 0xFFFFFFFF ))   # 32-bit two's-complement -> signed
       if [ $(( (v>>31)&1 )) = 1 ]; then echo $(( v - 4294967296 )); else echo "$v"; fi; }
iabs(){ if [ "${1:-0}" -lt 0 ]; then echo $(( 0 - $1 )); else echo "${1:-0}"; fi; }

# ----- lease + board health -------------------------------------------------
board_up(){ ping -c1 -W2 "$1" >/dev/null 2>&1; }
lease_acquire(){ local out tok
  out=$(fpgahub pair lease acquire "$LEASE_NAME" --ttl "${1:-2400}" --json 2>/dev/null)
  tok=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
  echo "LEASE_TOKEN=$tok" > "$HOME/.td_channels_lease"; [ -n "$tok" ]; }
lease_release(){ local tok
  tok=$(grep -o 'LEASE_TOKEN=.*' "$HOME/.td_channels_lease" 2>/dev/null | cut -d= -f2)
  [ -n "$tok" ] && fpgahub pair lease release "$LEASE_NAME" --token "$tok" >/dev/null 2>&1; }

abort(){ echo "### ABORT: $1"; [ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release; exit 1; }

# ============================================================================
# BRING-UP MODES
# ============================================================================
# Deterministic manual recipe. R8 base = 0x1C (bit0 CLEAR). Only the master
# pulses recal (0x1E->0x1C); the slave holds 0x1C — matches the proven recipe.
bringup_manual(){
  echo "-- manual (deterministic) bring-up --"
  m wr $R_NEGO_TRAIN 0x0    >/dev/null;  s wr $R_NEGO_TRAIN 0x0    >/dev/null
  m wr $R_LANEMASK 0x0000e4e4>/dev/null; s wr $R_LANEMASK 0x0000e4e4>/dev/null
  m wr $R_ROLE 0x2          >/dev/null;  s wr $R_ROLE 0x3          >/dev/null
  m wr $R_LOCKTHR 0x55555555>/dev/null;  s wr $R_LOCKTHR 0x55555555>/dev/null
  m wr $R_SLIPLO 0x0        >/dev/null;  s wr $R_SLIPLO 0x0        >/dev/null
  m wr $R_SYNCTOL 0x000005e4>/dev/null;  s wr $R_SYNCTOL 0x000005e4>/dev/null
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
  m wr $R_R8 $R8_RECAL      >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null; sleep 0.03
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
}
# Autonomous: arm NEGO_CFG=0x61 ONCE per die, then poll longer for the div-2
# link clock to converge. mask/tol/R8 sync config MUST precede nego_en (the
# autoneg FSM samples mask_hs at arm) — same ordering as bringup_autocal_i2c.sh.
bringup_autonomous(){
  echo "-- autonomous (arm-once NEGO_CFG=$NEGO_ARM) bring-up --"
  m wr $R_LANEMASK 0x0000e4e4>/dev/null; s wr $R_LANEMASK 0x0000e4e4>/dev/null
  m wr $R_SYNCTOL 0x000005e4>/dev/null;  s wr $R_SYNCTOL 0x000005e4>/dev/null
  m wr $R_LOCKTHR 0x55555555>/dev/null;  s wr $R_LOCKTHR 0x55555555>/dev/null
  m wr $R_R8 $R8_SYNC       >/dev/null;  s wr $R_R8 $R8_SYNC       >/dev/null
  m wr $R_ROLE 0x2          >/dev/null;  s wr $R_ROLE 0x3          >/dev/null
  m wr $R_NEGO_CFG $NEGO_ARM>/dev/null;  s wr $R_NEGO_CFG $NEGO_ARM>/dev/null
  # readback-verify the arm landed (RW register); a stuck 0 = wrong aperture
  local ma sa; ma=$(( $(val "$(mrd $R_NEGO_CFG)")&0x7f )); sa=$(( $(val "$(srd $R_NEGO_CFG)")&0x7f ))
  DETAIL+=("    NEGO_CFG readback master=0x$(printf %02x $ma) slave=0x$(printf %02x $sa)")
}

# FC/LL bootstrap (data-mode entry) — quiesce then the 0x27f09/01/07 triplet.
handoff(){
  m wr $R_FCQUIESCE 0x0>/dev/null; s wr $R_FCQUIESCE 0x0>/dev/null; sleep 0.1
  local v; for v in "${FC_TRIPLET[@]}"; do
    m wr $R_FCCTRL $v>/dev/null; s wr $R_FCCTRL $v>/dev/null; sleep 0.2
  done; sleep 0.3
}

# ============================================================================
# CHANNEL GATES (wedge-safe order enforced by main)
# ============================================================================
# GATE 0 — link + cal. Deterministic; PORS is a soak knob (re-bring-up + retest)
# NOT an eye-lottery retry. Every downstream channel depends on cal=1, so a
# failure here ABORTS (pushing data at cal=0 is exactly what wedges the PS).
gate_link(){
  local por ok=1 tries secs=18
  for por in $(seq 1 "$PORS"); do
    [ "$MODE" = autonomous ] && secs=40   # div-2 link clock needs a longer poll
    if [ "$MODE" = manual ]; then bringup_manual; else bringup_autonomous; fi
    for tries in $(seq 1 "$secs"); do
      sleep 1
      [ "$(fcsm m)" = 4 ] && [ "$(fcsm s)" = 4 ] && { ok=0; break; }
    done
    [ "$ok" = 0 ] && break
    echo "   (POR $por/$PORS: no bilateral fcsm=4 yet; re-bring-up)"
  done
  # cal=1 is the safety gate for EVERY downstream channel — fail the gate if
  # link was not reached OR any of the four asserts fell (fcsm=4 with cal=0 must
  # NOT be allowed to proceed to the data push).
  local gfail=0 fm fs cm cs
  fm=$(fcsm m); fs=$(fcsm s); cm=$(cal m); cs=$(cal s)
  assert "fcsm master" 4 "$fm" || gfail=1
  assert "fcsm slave"  4 "$fs" || gfail=1
  assert "cal master"  1 "$cm" || gfail=1
  assert "cal slave"   1 "$cs" || gfail=1
  metric "master fcsm=$fm cal=$cm | slave fcsm=$fs cal=$cs (want fcsm=4 cal=1) | mode=$MODE"
  [ "$ok" = 0 ] && [ "$gfail" = 0 ]
}

# rotation-aware ring compare (host-side python). $1=label, then sent... "--" recv...
# PASS iff there is a cyclic rotation r with recv_filtered[i]==sent[(i+r)%N] for all i,
# where recv_filtered = recv words that are members of the sent set (drops packet
# headers / zeros / slack). Prints VERDICT PASS|FAIL and a diagnostic line.
ring_compare(){
  python3 - "$@" <<'PY'
import sys
args=sys.argv[1:]
label=args[0]; args=args[1:]
cut=args.index("--"); sent=[int(x,16) for x in args[:cut]]; recv=[int(x,16) for x in args[cut+1:]]
sset=set(sent); N=len(sent)
filt=[w for w in recv if w in sset][:N]
ok=False; roff=-1
if len(filt)==N:
    for r in range(N):
        if all(filt[i]==sent[(i+r)%N] for i in range(N)): ok=True; roff=r; break
print("VERDICT %s %s" % (label, "PASS" if ok else "FAIL"))
print("  sent=%d recv=%d filt=%d rot=%s" % (N,len(recv),len(filt),roff))
sys.exit(0 if ok else 1)
PY
}

# Build a 28-word unique nonzero sentinel ring for direction tag $1 (a2b|b2a)
ring_words(){ local tag=$1 base i out=""
  [ "$tag" = a2b ] && base=0xA2B00000 || base=0xB2A00000
  for i in $(seq 0 27); do out+=" $(printf 0x%08x $(( base + i )))"; done
  echo "$out"; }

# GATE 1 — tl-data both directions (rotation-aware 28-word ring).
# A->B first (the SAFE direction). B->A second, same throttling — now proven
# byte-exact on silicon, but ordered after A->B so an unexpected B->A wedge
# cannot poison the headline direction.
# Build a PROTOCOL-LEGAL frame for direction $1 (a2b|b2a):
#   word0 = length[31:20] (payload word count) | type/ids/tag (0 here)
#   word1 = dest_addr
#   word2.. = payload
# The RX FIFO takes the packet length from word0[31:20] (tidelink_fifo_mem.sv ->
# tidelink_fifo_ctrl.sv). The OLD test sent 28 RAW data words with no header, so
# word0 was 0xA2B00000 => a declared length of 0xA2B (2603) => write_complete NEVER
# fired and the packet was never committed. Send a legal frame.
PAYLOAD_N=28
frame_words(){ local tag=$1 base i out
  [ "$tag" = a2b ] && base=0xA2B00000 || base=0xB2A00000
  out="$(printf '0x%08x 0x00000000' $(( PAYLOAD_N << 20 )))"
  for i in $(seq 0 $((PAYLOAD_N-1))); do out+=" $(printf 0x%08x $(( base + i )))"; done
  echo "$out"; }

# Byte-exact payload compare (a legal frame lands at index 0 — no rotation needed).
frame_compare(){ python3 - "$@" <<'PY'
import sys
args=sys.argv[1:]; label=args[0]; args=args[1:]
cut=args.index("--")
sent=[int(x,16) for x in args[:cut]]
recv=[int(x,16) for x in args[cut+1:]]
payload = sent[2:]                      # skip word0 (length) + word1 (dest_addr)
got     = recv[2:2+len(payload)]
ok = (got == payload)
print("VERDICT %s %s" % (label, "PASS" if ok else "FAIL"))
if not ok:
    print("  want[0:4]=%s" % [hex(w) for w in payload[:4]])
    print("  got [0:4]=%s" % [hex(w) for w in got[:4]])
    print("  (payload starting 2 words late == the empty-FIFO PHANTOM POP:")
    print("   a read of an empty RX FIFO walks read_ptr by 2 words.")
    print("   RTL fix 2026-07-14: tidelink_fifo_ctrl.sv rx_fifo_empty guard.)")
sys.exit(0 if ok else 1)
PY
}

# Set once the FC handoff + R8 data-mode entry has been performed, so gate_ptp
# does not re-quiesce a live FC node when `data` already ran.
DATA_MODE_DONE=0

gate_data(){
  handoff
  m wr $R_FCCTRL 0x00027f07>/dev/null; s wr $R_FCCTRL 0x00027f07>/dev/null; sleep 0.5
  m wr $R_R8 $R8_DATA>/dev/null;       s wr $R_R8 $R8_DATA>/dev/null;       sleep 0.5
  DATA_MODE_DONE=1
  local rc=0 n=$((PAYLOAD_N+2)) a_ok=0 b_ok=0

  # NO pre-send `rxn` drain. `rxn` is a RAW ADDRESS SWEEP, and reading an EMPTY RX
  # FIFO used to pop a PHANTOM zero-length packet: a read of offset 0 latched a
  # length of 0 from the zeroed SRAM, and the next read fired read_complete and
  # advanced read_ptr by 2 words. Since the RX aperture is translated by read_ptr,
  # every later read came back SHIFTED BY TWO WORDS — which is precisely what made
  # this gate report false data failures (silicon 2026-07-14: 0/6 -> 8/8 once the
  # drain was dropped). Fixed in RTL (rx_fifo_empty guard), but the drain is
  # unnecessary anyway: a fresh POR leaves the FIFO empty. If a drain is ever truly
  # needed, use the FLUSH register (CTRL bit[1]) — never a read sweep.

  # ---- A->B ----
  local aw; aw=$(frame_words a2b)
  m txburst $aw >/dev/null 2>&1; sleep 1.2
  local arx; arx=$(s rxn $n); sleep "$THROTTLE"
  DETAIL+=("    [a2b rx] ${arx:0:64}...")
  if frame_compare a2b $aw -- $arx; then ok "tl-data A->B (28w framed, byte-exact)"; a_ok=1
  else bad "tl-data A->B (28w framed, byte-exact)"; rc=1; fi

  # ---- B->A ----  (guarded: slave is sender, master receives)
  local bw; bw=$(frame_words b2a)
  s txburst $bw >/dev/null 2>&1; sleep 1.2
  local brx; brx=$(m rxn $n); sleep "$THROTTLE"
  DETAIL+=("    [b2a rx] ${brx:0:64}...")
  if frame_compare b2a $bw -- $brx; then ok "tl-data B->A (28w framed, byte-exact)"; b_ok=1
  else bad "tl-data B->A (28w framed, byte-exact)"; rc=1; fi
  metric "A->B $([ $a_ok = 1 ] && echo "$((PAYLOAD_N*4))/$((PAYLOAD_N*4))" || echo "MISMATCH")\
 bytes byte-exact | B->A $([ $b_ok = 1 ] && echo "$((PAYLOAD_N*4))/$((PAYLOAD_N*4))" || echo "MISMATCH") bytes byte-exact"
  return $rc
}

# GATE 2 — doorbell. Ring the doorbell from each die; the peer's RESPONSE_ACC
# (W-add / R-clear) must increment. Read-clears, so read once and compare >0.
gate_doorbell(){
  local rc=0 before after ms_acc=0 sm_acc=0
  # master -> slave
  s rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep "$THROTTLE"     # clear
  m wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  after=$(val "$(srd $R_DOORBELL_ACC)"); ms_acc=$after
  if [ "$after" -gt 0 ]; then ok "doorbell M->S (acc=$after)"; else bad "doorbell M->S (acc=0)"; rc=1; fi
  # slave -> master
  m rd $R_DOORBELL_ACC >/dev/null 2>&1; sleep "$THROTTLE"
  s wr $R_DOORBELL 0x1 >/dev/null; sleep 0.4
  after=$(val "$(mrd $R_DOORBELL_ACC)"); sm_acc=$after
  if [ "$after" -gt 0 ]; then ok "doorbell S->M (acc=$after)"; else bad "doorbell S->M (acc=0)"; rc=1; fi
  metric "M->S response count=$ms_acc | S->M response count=$sm_acc (each must be >0)"
  return $rc
}

# GATE 2.5 — ptp (OPT-IN; auto-SKIPs when the PHC is absent). See the header for
# the full safety argument. Returns 0=PASS, 1=FAIL, 77=SKIP (PHC not present).
#
# Sample a die's PHC "now" via the REGION 1 software capture: pulse ctrl.capture
# (self-clearing) then read back the latched {seconds, nanoseconds}. Echoes total
# ns, or "" if either read did not answer. Every read is THROTTLE-sleeved.
phc_now_ns(){ # $1 = m|s
  local d=$1 sec ns
  $d wr $R_PHC_CTRL $PHC_EN_CAP >/dev/null; sleep "$THROTTLE"
  if [ "$d" = m ]; then sec=$(mrd $R_PHC_CAP_SEC_LO); ns=$(mrd $R_PHC_CAP_NS)
  else                  sec=$(srd $R_PHC_CAP_SEC_LO); ns=$(srd $R_PHC_CAP_NS); fi
  if [ -z "$sec" ] || [ -z "$ns" ]; then echo ""; return 1; fi
  # cap_nanoseconds is a 30-bit field; mask so a garbage upper bit cannot inflate it.
  echo $(( $(val "$sec") * 1000000000 + ( $(val "$ns") & 0x3FFFFFFF ) ))
}

gate_ptp(){
  local rc=0

  # ---- STEP 0: PHC presence CANARY (bounded, 2 reads + 1 readback per die) ---
  # The ONLY safe positive proof that a PHC register file is really there is an
  # RW register that holds what we write. ns_incr is 8-bit RW, POR=4. Anything
  # that is not a plausible ns_incr (no answer / 0 / bits above [7:0] set) means
  # no PHC => SKIP, and we touch nothing else in the aperture.
  local mi si
  mi=$(mrd $R_PHC_NS_INCR); si=$(srd $R_PHC_NS_INCR)
  if [ -z "$mi" ] || [ -z "$si" ]; then
    DETAIL+=("    PHC canary: no answer from $R_PHC_NS_INCR (master='$mi' slave='$si')")
    DETAIL+=("    -> aperture $PHC_BASE is not decoding: this is almost certainly a")
    DETAIL+=("       NON-PTP bitstream. Build a -ptp target (TIDELINK_FPGA_PTP=1 /")
    DETAIL+=("       SOC=kr260 PTP=1) to run this channel.")
    metric "PHC absent at $PHC_BASE (canary: no answer) — nothing tested"
    return 77
  fi
  local miv siv; miv=$(val "$mi"); siv=$(val "$si")
  if [ $(( miv & 0xFFFFFF00 )) != 0 ] || [ $(( siv & 0xFFFFFF00 )) != 0 ] \
     || [ "$miv" = 0 ] || [ "$siv" = 0 ]; then
    DETAIL+=("    PHC canary: implausible ns_incr (master=$mi slave=$si);")
    DETAIL+=("    ns_incr is an 8-bit field with POR=4 — bits [31:8] must read 0 and")
    DETAIL+=("    it is never 0. This is a decode artefact, not a PHC. SKIP.")
    metric "PHC absent at $PHC_BASE (canary: implausible ns_incr) — nothing tested"
    return 77
  fi
  # Positive confirmation: write ns_incr and require the readback to stick.
  m wr $R_PHC_NS_INCR $PHC_NS_INCR >/dev/null
  s wr $R_PHC_NS_INCR $PHC_NS_INCR >/dev/null
  mi=$(mrd $R_PHC_NS_INCR); si=$(srd $R_PHC_NS_INCR)
  if [ "$(val "$mi")" != "$PHC_NS_INCR" ] || [ "$(val "$si")" != "$PHC_NS_INCR" ]; then
    DETAIL+=("    PHC canary: ns_incr readback did not stick (wrote $PHC_NS_INCR,")
    DETAIL+=("    read master=$mi slave=$si) — no live PHC register file. SKIP.")
    metric "PHC at $PHC_BASE not writable (canary: readback mismatch) — nothing tested"
    return 77
  fi
  DETAIL+=("    PHC canary OK on both dies (ns_incr=$PHC_NS_INCR readback verified)")

  # ---- STEP 1: PHC free-run — the ANTI-TIE-OFF check -----------------------
  # PROVES: each die has a LIVE, independently-clocked PHC time base. A tied-off
  # or absent PHC returns a frozen constant, so a STRICTLY ADVANCING counter
  # between two throttled samples cannot be faked by a tie-off. Gate on delta>0
  # only (rate-agnostic): the implied ns/s is REPORTED as a diagnostic but not
  # gated, because the host sleep is measured over ssh and is far too coarse to
  # gate a clock rate on. (verify-the-instrument rule: do not assert on a number
  # the instrument cannot resolve.)
  m wr $R_PHC_CTRL $PHC_EN >/dev/null; s wr $R_PHC_CTRL $PHC_EN >/dev/null; sleep 0.2
  local m_t0 s_t0 m_t1 s_t1 dwell=2
  m_t0=$(phc_now_ns m); s_t0=$(phc_now_ns s)
  if [ -z "$m_t0" ] || [ -z "$s_t0" ]; then
    bad "PHC free-run: capture read did not answer (master='$m_t0' slave='$s_t0')"
    metric "PHC capture unreadable after canary passed"
    return 1
  fi
  sleep "$dwell"
  m_t1=$(phc_now_ns m); s_t1=$(phc_now_ns s)
  if [ -z "$m_t1" ] || [ -z "$s_t1" ]; then
    bad "PHC free-run: second capture read did not answer"
    metric "PHC second capture unreadable"
    return 1
  fi
  local m_d=$(( m_t1 - m_t0 )) s_d=$(( s_t1 - s_t0 ))
  DETAIL+=("    [phc] master advanced ${m_d} ns over ~${dwell}s of wall clock")
  DETAIL+=("    [phc] slave  advanced ${s_d} ns over ~${dwell}s of wall clock")
  DETAIL+=("    [phc] (implied rate is a DIAGNOSTIC only — the host sleep is measured")
  DETAIL+=("     over ssh and cannot resolve a clock rate; the gate is strictly delta>0)")
  # delta==0 => frozen (tied-off/absent time base). delta<0 => the counter went
  # BACKWARDS, which a free-running PHC cannot do: the ns field wraps at 1e9 but
  # carries into seconds, and phc_now_ns folds seconds back in — so a negative
  # delta means a bad read or a stray set_time, not a wrap. Both are FAILs, but
  # they are different faults, so do not report them with the same word.
  if   [ "$m_d" -gt 0 ]; then ok "PHC master free-running (+${m_d} ns, not tied)"
  elif [ "$m_d" = 0 ];   then bad "PHC master FROZEN (delta=0) — tied-off/absent time base"; rc=1
  else bad "PHC master went BACKWARDS (delta=${m_d} ns) — bad read or stray set_time"; rc=1; fi
  if   [ "$s_d" -gt 0 ]; then ok "PHC slave free-running (+${s_d} ns, not tied)"
  elif [ "$s_d" = 0 ];   then bad "PHC slave FROZEN (delta=0) — tied-off/absent time base"; rc=1
  else bad "PHC slave went BACKWARDS (delta=${s_d} ns) — bad read or stray set_time"; rc=1; fi
  if [ "$rc" != 0 ]; then
    metric "PHC free-run FAILED: master delta=${m_d} ns, slave delta=${s_d} ns over ${dwell}s"
    return 1
  fi

  # ---- STEP 2: PTP SYNC over the link + servo discipline -------------------
  # Needs data mode. gate_data already does the FC handoff + R8_DATA; only do it
  # here if `data` was not selected, so we never re-quiesce a live FC node.
  if [ "$DATA_MODE_DONE" != 1 ]; then
    DETAIL+=("    (data channel not selected — running FC handoff + data mode for ptp)")
    handoff
    m wr $R_FCCTRL 0x00027f07>/dev/null; s wr $R_FCCTRL 0x00027f07>/dev/null; sleep 0.5
    m wr $R_R8 $R8_DATA>/dev/null;       s wr $R_R8 $R8_DATA>/dev/null;       sleep 0.5
  fi

  # Roles: master = Grandmaster, slave = Subordinate. Ordering mirrors the sim's
  # _setup_ptp: step threshold + servo roles BEFORE ptp_enable, ptp_enable before
  # arming the initiator.
  m wr $R_SERVO_STEP $PTP_STEP_NS>/dev/null; s wr $R_SERVO_STEP $PTP_STEP_NS>/dev/null
  m wr $R_SERVO_CTRL $SERVO_GM   >/dev/null; s wr $R_SERVO_CTRL $SERVO_SUB  >/dev/null
  m wr $R_PTP_CTRL   0x1         >/dev/null; s wr $R_PTP_CTRL   0x1         >/dev/null
  sleep 0.3

  local seq0; seq0=$(( ( $(val "$(mrd $R_HW_SYNC_STATUS)") >> 2 ) & 0xFFFF ))
  DETAIL+=("    [ptp] GM seq before arm = $seq0")

  # Arm the master initiator with force_en: it re-arms and re-fires continuously
  # while held, which is what we want for a BOUNDED dwell (the alternative — the
  # ~1 s HW_SYNC_INTERVAL — makes the whole channel minutes long). The sim fires
  # one-shot because it can count hclk edges; over ssh we cannot, so we free-run
  # for a bounded window and sample the servo a bounded number of times.
  m wr $R_HW_SYNC_CTRL $HW_SYNC_FORCE>/dev/null

  local i off offs_nonzero=0 last_off=0 first_abs=-1 worst_abs=0 a
  for i in $(seq 1 "$PTP_ROUNDS"); do
    sleep "$PTP_DWELL"
    off=$(s32 "$(val "$(srd $R_SERVO_OFFSET)")")     # SUBORDINATE computes the offset
    a=$(iabs "$off")
    [ "$off" != 0 ] && offs_nonzero=$((offs_nonzero+1))
    [ "$first_abs" = -1 ] && first_abs=$a
    [ "$a" -gt "$worst_abs" ] && worst_abs=$a
    last_off=$off
    DETAIL+=("    [ptp] round $i/$PTP_ROUNDS: slave servo last_offset = ${off} ns")
  done

  local seq1; seq1=$(( ( $(val "$(mrd $R_HW_SYNC_STATUS)") >> 2 ) & 0xFFFF ))
  local seq_adv=$(( (seq1 - seq0) & 0xFFFF ))
  # STOP the free-running initiator BEFORE returning: leaving it armed would
  # inject SYNC beacons into the XHB window gate that runs after us.
  m wr $R_HW_SYNC_CTRL 0x0>/dev/null; sleep 0.2

  local sstat; sstat=$(val "$(srd $R_SERVO_STATUS)")
  local slocked=$(( sstat & 1 )) sactive=$(( (sstat>>1) & 1 ))
  local sdelay;  sdelay=$(val "$(srd $R_SERVO_DELAY)")
  local last_abs; last_abs=$(iabs "$last_off")

  # Gate 1 — the GM initiator actually emitted SYNCs.
  # PROVES: the master-side HW_SYNC FSM ran and pushed PTP short packets to the TX
  # router. seq_num is incremented by hardware per fire; it cannot advance if no
  # SYNC left the die.
  if [ "$seq_adv" -gt 0 ]; then ok "PTP GM emitted SYNCs (seq $seq0 -> $seq1, +$seq_adv)"
  else bad "PTP GM never fired (seq stuck at $seq0) — no SYNC crossed the link"; rc=1; fi

  # Gate 2 — the FULL round trip completed.
  # PROVES: SYNC TX(t1) -> link -> SYNC RX(t2) -> DELAY_REQ TX(t3) -> link ->
  # DELAY_REQ RX(t4) -> GM ships t1,t4 over the FC SIDEBAND -> slave latches all
  # four and computes offset = ((t2-t1)-(t4-t3))/2. A non-zero hardware-computed
  # offset is only reachable if EVERY one of those hops worked. This is the real
  # "PTP crossed the link" proof.
  if [ "$offs_nonzero" -gt 0 ]; then
    ok "PTP round trip complete (slave servo computed a real offset in $offs_nonzero/$PTP_ROUNDS rounds)"
  else
    bad "PTP round trip incomplete (slave servo offset stayed 0 in all $PTP_ROUNDS rounds)"
    DETAIL+=("    -> SYNC/DELAY_REQ/FC-SIDEBAND did not complete end-to-end.")
    rc=1
  fi

  # Gate 3 — convergence: the subordinate servo disciplined its clock.
  # PROVES: the loop is closed — the servo drove |offset| into (and held it in)
  # the fine PI frequency-steer regime rather than merely reporting an error.
  # servo_locked (hardware: |offset| < step_thresh/4) is reported as corroboration;
  # it is NOT the gate, since its threshold is not calibrated for this link speed.
  DETAIL+=("    [ptp] servo_locked=$slocked active=$sactive last_delay=${sdelay} ns")
  DETAIL+=("    [ptp] |offset|: first=${first_abs} worst=${worst_abs} final=${last_abs} ns (tol=${PTP_TOL_NS})")
  if [ "$last_abs" -le "$PTP_TOL_NS" ]; then
    ok "PTP servo converged (final |offset|=${last_abs} ns <= ${PTP_TOL_NS} ns, servo_locked=$slocked)"
  else
    bad "PTP servo did not converge (final |offset|=${last_abs} ns > ${PTP_TOL_NS} ns)"
    DETAIL+=("    -> if the offsets above are clearly SHRINKING this is a TOLERANCE")
    DETAIL+=("       calibration (TD_PTP_TOL_NS is UNCALIBRATED on silicon), not a")
    DETAIL+=("       DUT regression. Record the measured floor and re-run.")
    rc=1
  fi

  # Restore the pre-ptp link state so the XHB window gate sees a quiet link.
  m wr $R_PTP_CTRL 0x0>/dev/null; s wr $R_PTP_CTRL 0x0>/dev/null
  m wr $R_SERVO_CTRL 0x0>/dev/null; s wr $R_SERVO_CTRL 0x0>/dev/null; sleep 0.2

  metric "PHC free-run M+${m_d}ns S+${s_d}ns/${dwell}s | GM SYNCs +${seq_adv} | offset ${first_abs}->${last_abs} ns (tol ${PTP_TOL_NS}, locked=${slocked})"
  return $rc
}

# GATE 3 — XHB transparent window. LAST, only reached after data is proven.
# Every access is timeout-wrapped (m/s already wrap ssh in `timeout`); the soak
# is BOUNDED to WIN_SOAK_TXNS write/read round-trips. Missing output (a wedged
# access) is counted as a FAIL, never a hang.
gate_xhb_window(){
  local rc=0 i good=0 off addr wv rv
  for i in $(seq 0 $((WIN_SOAK_TXNS-1))); do
    off=$(( i*4 )); addr=$(printf 0x%x $(( XHB_WINDOW + off )))
    wv=$(printf 0x%08x $(( 0xC0DE0000 + i )))
    m wr $addr $wv >/dev/null 2>&1; sleep "$THROTTLE"         # transparent write to peer
    rv=$(m rd $addr); sleep "$THROTTLE"                       # transparent read-back
    if [ -z "$rv" ]; then
      DETAIL+=("    [win $i] TIMEOUT/empty at $addr (wedge-guarded)"); rc=1; continue
    fi
    if [ "$(( rv ))" = "$(( wv ))" ]; then good=$((good+1))
    else DETAIL+=("    [win $i] $addr got=$rv want=$wv"); rc=1; fi
  done
  assert "XHB window round-trip ($good/$WIN_SOAK_TXNS)" "$WIN_SOAK_TXNS" "$good"
  metric "$good/$WIN_SOAK_TXNS transparent write+readback round-trips to peer memory at $XHB_WINDOW"
  return $rc
}

# ============================================================================
# DEMO PRESENTATION (--demo)
# ============================================================================
# Reporting ONLY. Nothing below changes what is tested, the order it is tested
# in, or the exit code — --demo must never alter the CI verdict.
#
# GATE_METRIC is the one-line "key measured numbers" a gate hands back for the
# banner/summary. metric() is a pure sink: a gate that never calls it just shows
# a blank metric column.
GATE_METRIC=""
CH_METRIC=()
metric(){ GATE_METRIC="$1"; }

# One line per channel: what a PASS on it actually proves.
ch_proves(){ case "$1" in
  link)     echo "both dies reach PHY calibration (cal=1) and a bilateral FC state machine (fcsm=4)";;
  data)     echo "protocol-legal ${PAYLOAD_N}-word packets cross the link BYTE-EXACT in both directions";;
  doorbell) echo "the peer doorbell signalling path works in both directions";;
  ptp)      echo "a live PHC time base runs on both dies AND PTP SYNC/DELAY_REQ over the link disciplines the subordinate clock";;
  xhb)      echo "the transparent AHB window: the host reads/writes PEER memory across the link";;
  *)        echo "";;
esac; }

demo_open(){ [ "$DEMO" = 1 ] || return 0
  echo ""
  echo "########################################################################"
  echo "#  CHANNEL : $1"
  echo "#  PROVES  : $(ch_proves "$1")"
  echo "########################################################################"
}
demo_close(){ [ "$DEMO" = 1 ] || return 0
  echo "#  RESULT  : $2   (${3}s)"
  [ -n "$GATE_METRIC" ] && echo "#  MEASURED: $GATE_METRIC"
  echo "########################################################################"
  echo ""
}

# ----- per-channel PASS/FAIL/SKIP wrapper -----------------------------------
# Gate return contract: 0 = PASS, 77 = SKIP (channel not present in this
# bitstream — NOT a failure), anything else = FAIL. SKIP deliberately does not
# touch TD_PASS/TD_FAIL, so it cannot move the exit code either way.
CH_RESULT=()
run_gate(){ # name  fn
  local name=$1 fn=$2 t0=$SECONDS rc res
  GATE_METRIC=""
  demo_open "$name"
  echo "== $name =="
  $fn; rc=$?
  case $rc in
    0)  res=PASS;;
    77) res=SKIP;;
    *)  res=FAIL;;
  esac
  printf "  [%s] %-12s %ds\n" "$res" "$name" $((SECONDS-t0))
  CH_RESULT+=("$res $name")
  CH_METRIC+=("$GATE_METRIC")
  flush
  demo_close "$name" "$res" $((SECONDS-t0))
  return 0
}

# ============================================================================
# MAIN
# ============================================================================
echo "======== TideLink V2 channel regression ($(date)) ========"
echo "  master=$MASTER_IP($MASTER_BOARD)  slave=$SLAVE_IP($SLAVE_BOARD)"
echo "  mode=$MODE  channels='$CHANNELS'  pors=$PORS  throttle=${THROTTLE}s"

board_up "$MASTER_IP" || abort "master $MASTER_IP unreachable (power-cycle?)"
board_up "$SLAVE_IP"  || abort "slave $SLAVE_IP unreachable (power-cycle?)"
# tl39 must actually run on both boards before any bus access (defect class 1).
tl39_preflight || abort "tl39 preflight failed — staging broken; see above (NOT a dead link)"
if [ "$DO_LEASE" = 1 ]; then lease_acquire 2400 || abort "could not acquire $LEASE_NAME lease"; fi
trap '[ "$DO_LEASE" = 1 ] && [ "$KEEP_LEASE" = 0 ] && lease_release' EXIT

# GATE 0 is mandatory + gating: no cal=1 => downstream channels would wedge.
run_gate link gate_link
case " ${CH_RESULT[*]} " in *"FAIL link"*) abort "no bilateral cal=1 link — downstream channels unsafe";; esac

# Selected channels, in the fixed wedge-safe order. This loop — NOT the order the
# operator types --channels in — defines execution order, so a demo invocation
# cannot accidentally hoist xhb ahead of data.
#   data -> doorbell -> ptp -> xhb
# ptp sits after doorbell (it needs a proven datapath: its SYNC/DELAY_REQ and FC
# SIDEBAND ride the same link) and before xhb (which stays LAST — it is the most
# wedge-prone channel). gate_ptp stops its free-running SYNC initiator before it
# returns, so xhb still runs against a quiet link.
for ch in data doorbell ptp xhb; do
  case " $CHANNELS " in *" $ch "*) ;; *) continue;; esac
  case $ch in
    data)     run_gate data     gate_data;;
    doorbell) run_gate doorbell gate_doorbell;;
    ptp)      run_gate ptp      gate_ptp;;
    xhb)      run_gate xhb      gate_xhb_window;;
  esac
done

# ----- report ---------------------------------------------------------------
echo "========================================================"
echo "  per-channel:"; printf '    %s\n' "${CH_RESULT[@]}"
TOT=$((TD_PASS+TD_FAIL))
echo "  asserts: $TD_PASS/$TOT passed"
if [ "$TD_FAIL" = 0 ]; then echo "  PASS — all selected V2 channels intact"; RC=0
else echo "  FAIL — $TD_FAIL assertion(s) regressed"; RC=1; fi
echo "========================================================"

# Demo summary. Printed AFTER the machine-readable block above and derived from
# the same CH_RESULT/TD_FAIL data — it is a second view of the same verdict, not
# a second verdict. RC is already final and is not touched here.
if [ "$DEMO" = 1 ]; then
  echo ""
  echo "############ TideLink V2 — PER-CHANNEL DEMO SUMMARY ############"
  i=0
  for r in "${CH_RESULT[@]}"; do
    res=${r%% *}; name=${r#* }
    printf "  %-9s %-5s %s\n" "$name" "$res" "$(ch_proves "$name")"
    [ -n "${CH_METRIC[$i]:-}" ] && printf "  %-9s %-5s measured: %s\n" "" "" "${CH_METRIC[$i]}"
    i=$((i+1))
  done
  echo "  ---------------------------------------------------------------"
  case " ${CH_RESULT[*]} " in *" SKIP "*)
    echo "  NOTE: a SKIP means that channel is not present in this bitstream"
    echo "        (e.g. ptp on a non-PTP target). It is NOT a failure and does"
    echo "        not affect the exit code.";;
  esac
  if [ "$RC" = 0 ]; then echo "  OVERALL: PASS — every selected channel demonstrated"
  else echo "  OVERALL: FAIL — $TD_FAIL assertion(s) regressed"; fi
  echo "###############################################################"
fi
exit $RC
