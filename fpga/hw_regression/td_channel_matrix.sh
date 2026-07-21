#!/bin/bash
###############################################################################
# td_channel_matrix.sh — PENDING-DECISION #13 scaffold: define "all channels".
#
# Turns the open question "what does 'all channels' mean?" into a filled-in,
# enumerable matrix over FOUR axes:
#
#     {die_a, die_b}  x  {A->B, B->A}  x  {FCSM 0..4}  x  {doorbell}
#
# Today's coverage (proven_method_soak.sh, td_v2_channels.sh) is a FIXED channel
# set that only ever gates on fcsm==4 (LINK_IDLE / committed). This scaffold adds
# the die x direction x FCSM-level x doorbell axes on top of the SAME proven
# host primitives (sourced from td_v2_hwlib.sh), with a clear TODO at every cell
# where the per-FCSM-state assertion plugs in.
#
# SAFETY: this is a SCAFFOLD. By default it runs `--plan` (a DRY enumeration that
# touches NO hardware). It REFUSES to touch a board unless `--execute` is passed
# AND a lease is held — and even then the per-cell bodies are TODO stubs. Do not
# wire `--execute` into CI until the stubs are filled and reviewed.
#
#   ./td_channel_matrix.sh                 # dry plan: print the full matrix
#   ./td_channel_matrix.sh --fcsm 0-4      # restrict the FCSM axis
#   ./td_channel_matrix.sh --execute ...   # (guarded) run — stubs raise TODO
#
# References (all file:line verified 2026-07-17 against the RTL/RDL):
#   FCSM enum        src/rtl/local_overrides/WlinkGenericFCSM.v:658-676,:298,:420
#   FCSM names       docs/ARCHITECTURE_PHY_LINK.md:241
#   SWI_LANE_STATUS  src/rdl/tidelink_regs.rdl:433-441,:472  (0x108: [16]=cal, [20:17]=fcsm; bit20==0)
#   Doorbell         src/rdl/tidelink_regs.rdl:115-127,:191-196 ; tidelink_apb_regs.sv:238,:319-341
#   Apertures        pynq_host/tl_socmap.py:76-87 ; fpga/hw_regression/td_socmap.sh:31-42
###############################################################################
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the proven per-die primitives (a/b/fcsm/reanchored/send_*/data_ok/...)
# WITHOUT executing anything: td_v2_hwlib.sh only defines functions + constants.
# shellcheck source=/dev/null
[ -f "$HERE/td_v2_hwlib.sh" ] && source "$HERE/td_v2_hwlib.sh" 2>/dev/null || true

# =============================================================================
# FCSM 0..4 map  (WlinkGenericFCSM.state, exposed at SWI_LANE_STATUS[20:17],
#                 read as (status>>17)&7; bit[20] is hardwired 0)
# =============================================================================
declare -A FCSM_NAME=(
  [0]="INIT/ack-seen  (POR/flush; leaves to 1 once TX enabled)"
  [1]="EMIT_CR        (advertise credit; wedges here on the credit-path bug)"
  [2]="EMIT_CRACK     (credit-acknowledge)"
  [3]="TRANSITION     (post-CRACK settle; counts credits down; 3->4 at count==0)"
  [4]="LINK_IDLE      (COMMITTED/steady: bilateral, idle; 4->5 sends a data pkt)"
)
# (5 LINK_DATA, 6 SEND_ACK, 7 SEND_NACK exist but are transient/error.)
FCSM_LEVELS=(0 1 2 3 4)

# =============================================================================
# APERTURE MAP  <<< THE TABLE #13 ASKED FOR >>>
# Z2 bases (relocate for KR260 via td_remap / td_data_base in td_socmap.sh).
# Columns: aperture-base | role | direction | notes
# -----------------------------------------------------------------------------
#   0x40000000  ahb_sub     XHB peer window     bidir   host<->remote MEMORY across link
#   0x44000000  ahb_tx      TX aperture (legacy) out     write pkt into FC node (pre GP1-split)
#   0x44010000  ahb_fifo    LOCAL RX FIFO win    in      reads drain rx pkts + free credit
#   0x44020000  ahb_ptp     PTP AHB regs         n/a
#   0x44030000  apb         config plane         ctrl    +0x2000 = FIFO/status region
#   0x44032014  DOORBELL             (W1P)       out     ring peer's response accumulator
#   0x44032024  DOORBELL_RESPONSE_ACC (W-add/Rclr) in    peer arrivals; raises doorbell_irq
#   0x44032108  SWI_LANE_STATUS      (R)         obs     [16]=cal [20:17]=fcsm [31]=fe_full
#   0x84000000  ahb_tx (GP1 split)   out                 data TX target (txburst)
#   0x84010000  ahb_fifo (GP1 split) in                  REAL committed data landing zone
# The host-lib already encodes the live subset: R_FCSM/R_REANCHORED/GP1_RX
# (td_v2_hwlib.sh:70-81). A full matrix plugs the rows above into ONE table so
# the same (sender,receiver) loop drives every cell. <<< PLUG APERTURES HERE >>>
declare -A APERTURE=(
  [xhb_window]=0x40000000
  [tx_legacy]=0x44000000
  [rx_fifo_local]=0x44010000
  [apb_base]=0x44030000
  [doorbell]=0x44032014
  [doorbell_resp]=0x44032024
  [swi_lane_status]=0x44032108
  [gp1_tx]=0x84000000
  [gp1_rx]=0x84010000
)

# =============================================================================
# Axes
# =============================================================================
DIES=(a b)
DIRS=(a2b b2a)          # sender->receiver: a2b = die_a sends, die_b receives
FCSM_SEL="0-4"
DO_DOORBELL=1
EXECUTE=0

while [ $# -gt 0 ]; do case "$1" in
  --fcsm)      FCSM_SEL="$2"; shift;;
  --dirs)      IFS=',' read -r -a DIRS <<< "$2"; shift;;
  --no-doorbell) DO_DOORBELL=0;;
  --execute)   EXECUTE=1;;
  --plan)      EXECUTE=0;;
  -h|--help)   sed -n '2,40p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (see -h)"; exit 2;;
esac; shift; done

# expand FCSM_SEL like "0-4" or "0,2,4"
_expand_fcsm(){
  local s="$1"
  if [[ "$s" == *-* ]]; then seq "${s%-*}" "${s#*-}"; else echo "${s//,/ }"; fi
}
SEL_LEVELS=($(_expand_fcsm "$FCSM_SEL"))

# -----------------------------------------------------------------------------
# Per-cell gate — TODO STUBS. Each returns 0=PASS 1=FAIL 77=SKIP (td_v2 contract).
# The decision #13 must specify, for each FCSM level, WHAT a data/doorbell cell
# asserts (e.g. at level<4 the link is not yet committed, so a data send must be
# EXPECTED to not deliver; only level 4 asserts byte-exact delivery). Until that
# spec exists, these stubs refuse rather than silently pass.
# -----------------------------------------------------------------------------
gate_data_cell(){   # $1=sender die  $2=receiver die  $3=fcsm level
  local snd="$1" rcv="$2" lvl="$3"
  # <<< TODO(#13): drive sender TX aperture (APERTURE[gp1_tx] on $snd), then
  #     assert on receiver (APERTURE[gp1_rx] on $rcv) CONDITIONED on $lvl:
  #       lvl 4  -> byte-exact {TX_HDR, TX_PAYLOAD} (reuse send_$dir / data_ok)
  #       lvl<4  -> link not committed: define the expected (no-deliver?) result
  #     Read fcsm via `fcsm $snd` / `fcsm $rcv` (td_v2_hwlib.sh:70). >>>
  echo "TODO: data cell snd=$snd rcv=$rcv fcsm=$lvl"; return 77
}
gate_doorbell_cell(){  # $1=sender die  $2=receiver die
  local snd="$1" rcv="$2"
  # <<< TODO(#13): clear ${APERTURE[doorbell_resp]} on $rcv; write
  #     ${APERTURE[doorbell]} on $snd; assert peer resp-acc != 0 (doorbell_irq).
  #     Reuse the doorbell path from proven_method_soak.sh:72-80. >>>
  echo "TODO: doorbell cell snd=$snd rcv=$rcv"; return 77
}

# -----------------------------------------------------------------------------
# Enumerate / drive the matrix
# -----------------------------------------------------------------------------
plan_only(){
  echo "===== TideLink channel matrix (PENDING-DECISION #13) ====="
  echo "FCSM levels selected: ${SEL_LEVELS[*]}"
  for l in "${SEL_LEVELS[@]}"; do
    printf '  FCSM %s = %s\n' "$l" "${FCSM_NAME[$l]:-<transient/error>}"
  done
  echo "----- data cells (sender -> receiver x FCSM) -----"
  local n=0
  for dir in "${DIRS[@]}"; do
    local snd rcv
    if [ "$dir" = "a2b" ]; then snd=a; rcv=b; else snd=b; rcv=a; fi
    for l in "${SEL_LEVELS[@]}"; do
      printf '  [data] %s->%s  fcsm=%s  tx=%s rx=%s\n' \
        "$snd" "$rcv" "$l" "${APERTURE[gp1_tx]}" "${APERTURE[gp1_rx]}"
      n=$((n+1))
    done
  done
  if [ "$DO_DOORBELL" = 1 ]; then
    for dir in "${DIRS[@]}"; do
      local snd rcv
      if [ "$dir" = "a2b" ]; then snd=a; rcv=b; else snd=b; rcv=a; fi
      printf '  [doorbell] %s->%s  ring=%s resp=%s\n' \
        "$snd" "$rcv" "${APERTURE[doorbell]}" "${APERTURE[doorbell_resp]}"
      n=$((n+1))
    done
  fi
  echo "----- total cells: $n -----"
  echo "(dry plan — NO hardware touched. Pass --execute to run, but the per-cell"
  echo " bodies are TODO stubs pending the #13 FCSM-level assertion spec.)"
}

run_matrix(){
  echo "ERROR: --execute is a guarded stub. The per-FCSM-level assertion spec"
  echo "(what a data cell means at fcsm 0..3 vs 4) is a DECISION, not yet made."
  echo "Fill gate_data_cell / gate_doorbell_cell, hold a board lease, then remove"
  echo "this guard. Refusing to touch hardware."
  return 3
}

if [ "$EXECUTE" = 1 ]; then run_matrix; else plan_only; fi
