#!/bin/bash
# =============================================================================
# tidelink_bringup.sh — CANONICAL TideLink pair bring-up (reference impl).
#
# Two modes:
#   manual      — the full deterministic recipe. SW drives every step of the
#                 PHY alignment + SYNC + credit handshake by hand. This is the
#                 recipe that is PROVEN byte-exact on silicon (see MEMORY).
#   autonomous  — arm the on-chip autoneg + training FSMs and let them converge
#                 with ZERO further bring-up pokes; then enable the data path.
#
# USAGE
#   tidelink_bringup.sh MASTER_IP SLAVE_IP MODE
#     MASTER_IP   IP of die_a (master / non-flip). e.g. 192.168.4.101
#     SLAVE_IP    IP of die_b (slave  / flip).     e.g. 192.168.6.101
#     MODE        manual | autonomous              (default: manual)
#
#   Env overrides: TIDELINK_BOARD_PASS (default xilinx),
#                  TL39 (path of tl39.py on the board, default /home/xilinx/tl39.py),
#                  FCSM_TRIES / CAL_TRIES / RA_TRIES (poll budgets, seconds).
#
#   Run on a host with routes to both boards (mapstone-dev). Hold the bridge1
#   lease (GRANTED, not queued). tl39.py MUST already be staged on each board
#   at $TL39 — this script uses ONLY tl39.py `rd`/`wr` for register access, so
#   every MMIO store goes through tl39.py's single-u32 ctypes helper (NOT the
#   struct.pack_into 5x-over-advance path that stalled the credit loop for
#   weeks — SoC Labs 2026-07-03).
#
# EXIT: 0 = both dies reached FCSM=4 (LINK_IDLE) and the data path is enabled.
#       1 = did not converge within the poll budget. 2 = setup / usage error.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
MASTER_IP="${1:-}"
SLAVE_IP="${2:-}"
MODE="${3:-manual}"

usage() {
    echo "usage: $0 MASTER_IP SLAVE_IP [manual|autonomous]" >&2
    exit 2
}
[ -n "$MASTER_IP" ] && [ -n "$SLAVE_IP" ] || usage
case "$MODE" in
    manual|autonomous) ;;
    *) echo "ERROR: unknown MODE '$MODE'" >&2; usage ;;
esac

PASS="${TIDELINK_BOARD_PASS:-xilinx}"
TL39="${TL39:-/home/xilinx/tl39.py}"
SSHC="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Poll budgets (each iteration is ~1s).
CAL_TRIES="${CAL_TRIES:-40}"    # wait for calibration_done (manual)
RA_TRIES="${RA_TRIES:-20}"      # wait for reanchor (manual)
FCSM_TRIES="${FCSM_TRIES:-90}"  # wait for bilateral FCSM=4

# =============================================================================
# REGISTER MAP  (absolute PS/GP0 addresses on the pynq-z2 pair bitstream)
#
# *** THE GOTCHA THAT COST DAYS ***
#   NEGO_CFG          0x44032090  is the WRITABLE autoneg-arm register.
#   NEGO_TRAIN_STATUS 0x44032110  is READ-ONLY. Writing 0x2110 to "arm autoneg"
#   does NOTHING (it is a status register) — a prior tool wrote the wrong
#   address and burned multiple debug sessions. ARM autoneg at 0x2090.
# See docs/TIDELINK_REGISTER_MAP.md for the full annotated map.
# =============================================================================
DEBUG_UNLOCK=0x44041000   # =1 opens the APB write path (must be first)
ROLE_W1S=0x44032080       # ROLE_CFG: [0]role(0=master,1=slave) [1]role_lock(W1S)
                          #   master/die_a -> 0x2 (role=0 + lock)
                          #   slave /die_b -> 0x3 (role=1 + lock)
NEGO_CFG=0x44032090       # *** WRITABLE autoneg arm ***  0x61 =
                          #   [0]nego_en | [5]nego_force_lock | [6]mask_hs_auto_en
NEGO_TRAIN_CFG=0x4403210C # [0] train_auto_en  (=1 to let the training FSM run)
NEGO_TRAIN_STATUS=0x44032110  # *** READ-ONLY — NEVER WRITE (this is not NEGO_CFG) ***

LANE_MASK=0x44030214      # Wlink lane mask  = 0x0000e4e4  (8-lane e4e4 pattern)
SYNC_CFG=0x44032128       # SYNC detector: [7:0] lane-mask, [11:8] tolerance.
                          #   proven value 0x000005e4 == tol 5 + mask 0xe4
                          #   (tl39.py labels this addr SWI_SYNC_LANE_MASK)
WORD_PIN=0x44032104       # SWI_BIT_SLIP_LO: [27:24]=word_pin [28]=auto_dis.
                          #   =0 -> per-lane-AUTO word-pin (proven; NOT forced)
SCRAMBLE=0x44032160       # PHY scramble / per-lane lock threshold = 0x55555555
                          #   (tl39.py labels this addr LOCKTHR)

# R8 control slot0 (0x44032100). Bit layout:
#   [0] swi_training_mode  <-- NEVER SET: bit0 traps the calibrator in S_HOLD
#   [1] swi_recal          recal strobe
#   [2] sync_insert_en     insert SYNC beacons on TX
#   [3] sync_force_always  force SYNC every word (bring-up only)
#   [4] sync_robust_detect robust RX SYNC detector
# Composite values used by the recipe:
#   0x1C = [4|3|2]        SYNC-config   (insert + force + robust; no train/recal)
#   0x1E = 0x1C | [1]     recal pulse   (pulse recal while holding SYNC-config)
#   0x14 = [4|2]          data-enable   (SYNC insert + robust, force OFF -> data)
R8=0x44032100
R8_SYNC_CFG=0x1C
R8_RECAL_PULSE=0x1E
R8_DATA_EN=0x14

STATUS=0x44032108         # [7:0]lane_locked [15:8]lane_fault [16]cal_done
                          #   [19:17]fcsm [23]cr_seen
REANCHOR=0x44032140       # SWI_EPOCH_STATUS: [0] reanchored (RA) [6:1] span

# LL (link-layer) bootstrap — Wlink Enable/Reset at 0x44030208:
#   [0]swi_enable [1]lltx_enable [2]llrx_enable [3]sw_reset
#   0x00027f09 = swi_enable + sw_reset      (assert reset)
#   0x00027f01 = swi_enable                 (release reset, LL still disabled)
#   0x00027f07 = swi_enable + lltx + llrx   (full enable)
#   (0x2xxx high bits = Max-Short-Pkt-ID 0x7f + PREQ-Data-ID 0x02, kept constant)
LL_ENREG=0x44030208
LL_PSTATE=0x44030230      # P-State Control — cleared to 0 before the triplet
LL_RESET=0x00027f09
LL_RELEASE=0x00027f01
LL_FULL=0x00027f07

# -----------------------------------------------------------------------------
# Low-level access: ONLY tl39.py rd/wr over SSH (single-u32 ctypes store).
# -----------------------------------------------------------------------------
fail() { echo "ERROR: $*" >&2; exit 2; }

# tl(IP, tl39-args...) — run tl39.py on one board, return its stdout.
tl() {
    local ip=$1; shift
    sshpass -p "$PASS" ssh -n $SSHC "xilinx@$ip" \
        "echo '$PASS' | sudo -S python3 $TL39 $*" 2>/dev/null
}

wr()  { tl "$1" wr "$2" "$3" >/dev/null; }   # wr IP ADDR VAL
rd()  { tl "$1" rd "$2"; }                    # rd IP ADDR -> 0x........

# Coordinated writes: apply the SAME value to BOTH dies within ~1 SSH RTT.
# Near-simultaneity matters for the SYNC/recal/enable edges (the two link-word
# counters must re-arm close together — see bringup_pair_converge.sh rationale).
wr_both() { wr "$MASTER_IP" "$1" "$2" & wr "$SLAVE_IP" "$1" "$2" & wait; }

# Field extractors (bash arithmetic parses the 0x.... string directly).
field() { local v=${1:-0}; echo $(( ( ${v} >> $2 ) & $3 )); }   # field VAL SHIFT MASK
get_fcsm()    { field "$(rd "$1" $STATUS)"   17 0x7; }
get_caldone() { field "$(rd "$1" $STATUS)"   16 0x1; }
get_cr()      { field "$(rd "$1" $STATUS)"   23 0x1; }
get_ra()      { field "$(rd "$1" $REANCHOR)"  0 0x1; }

# -----------------------------------------------------------------------------
# LL bootstrap: bring the Wlink link layer up so the FC credit path can run.
# Clear P-State, then pulse the Enable/Reset triplet, on BOTH dies together.
# -----------------------------------------------------------------------------
ll_bootstrap() {
    echo "  >> LL bootstrap: clear P-State, then Enable/Reset triplet (both dies)"
    wr_both $LL_PSTATE 0x0
    wr_both $LL_ENREG  $LL_RESET     ; sleep 0.05   # swi_enable + sw_reset
    wr_both $LL_ENREG  $LL_RELEASE   ; sleep 0.05   # release reset (LL disabled)
    wr_both $LL_ENREG  $LL_FULL      ; sleep 0.20   # full enable (swi+lltx+llrx)
}

# Poll both dies until FCSM=4 (LINK_IDLE) or the budget runs out.
poll_fcsm4() {
    local i mf sf mc sf_cr
    echo "  >> polling for bilateral FCSM=4 (LINK_IDLE), up to ${FCSM_TRIES}s ..."
    for ((i=1; i<=FCSM_TRIES; i++)); do
        mf=$(get_fcsm "$MASTER_IP"); sf=$(get_fcsm "$SLAVE_IP")
        printf "     t=%3ds  master fcsm=%s cr=%s | slave fcsm=%s cr=%s\n" \
            "$i" "${mf:-?}" "$(get_cr "$MASTER_IP")" "${sf:-?}" "$(get_cr "$SLAVE_IP")"
        if [ "${mf:-0}" -eq 4 ] 2>/dev/null && [ "${sf:-0}" -eq 4 ] 2>/dev/null; then
            echo "  >> CONVERGED: both dies at FCSM=4."
            return 0
        fi
        sleep 1
    done
    return 1
}

# -----------------------------------------------------------------------------
echo "=============================================================="
echo " TideLink bring-up  ($MODE)  $(date)"
echo "  master (die_a) = $MASTER_IP"
echo "  slave  (die_b) = $SLAVE_IP"
echo "  tl39.py        = $TL39"
echo "=============================================================="

# Reachability pre-flight (fail fast).
for ip in "$MASTER_IP" "$SLAVE_IP"; do
    sshpass -p "$PASS" ssh -n $SSHC "xilinx@$ip" true 2>/dev/null \
        || fail "board $ip unreachable over SSH (lease GRANTED? board up?)"
done

# =============================================================================
# MANUAL MODE — full deterministic recipe.
# =============================================================================
manual_bringup() {
    echo "--- [1] debug unlock (open the APB write path) ---"
    wr_both $DEBUG_UNLOCK 1

    echo "--- [2] PHY static config: lane mask / SYNC tol / word-pin / scramble ---"
    wr_both $LANE_MASK 0x0000e4e4    # 8-lane e4e4 mask
    wr_both $SYNC_CFG  0x000005e4    # SYNC tolerance 5 + lane mask 0xe4
    wr_both $WORD_PIN  0x0           # per-lane-AUTO word-pin (NOT forced)
    wr_both $SCRAMBLE  0x55555555    # scramble / lock threshold

    echo "--- [3] R8 = SYNC-config (0x1C: insert+force+robust, NO training) ---"
    wr_both $R8 $R8_SYNC_CFG

    echo "--- [4] role W1S: master=0x2 (role0+lock), slave=0x3 (role1+lock) ---"
    wr "$MASTER_IP" $ROLE_W1S 0x2 & wr "$SLAVE_IP" $ROLE_W1S 0x3 & wait

    echo "--- [5] recal pulse (0x1E -> 0x1C) to re-arm both calibrators ---"
    wr_both $R8 $R8_RECAL_PULSE ; sleep 0.25
    wr_both $R8 $R8_SYNC_CFG

    echo "--- [6] poll calibration_done (0x2108[16]) on both dies ---"
    local i mcd scd
    for ((i=1; i<=CAL_TRIES; i++)); do
        mcd=$(get_caldone "$MASTER_IP"); scd=$(get_caldone "$SLAVE_IP")
        printf "     t=%3ds  master cal_done=%s | slave cal_done=%s\n" \
            "$i" "${mcd:-?}" "${scd:-?}"
        [ "${mcd:-0}" -eq 1 ] 2>/dev/null && [ "${scd:-0}" -eq 1 ] 2>/dev/null && break
        sleep 1
    done
    if [ "${mcd:-0}" -ne 1 ] || [ "${scd:-0}" -ne 1 ]; then
        echo "  WARNING: cal_done not set on both (m=${mcd:-?} s=${scd:-?}) after ${CAL_TRIES}s"
        echo "  (continuing to LL bootstrap; convergence may still fail)"
    fi

    echo "--- [7] LL bootstrap (Enable/Reset triplet) ---"
    ll_bootstrap

    echo "--- [8] R8 = data-enable (0x14: SYNC insert + robust, force OFF) ---"
    wr_both $R8 $R8_DATA_EN

    echo "--- [9] wait for reanchor RA (0x2140[0]) on both dies ---"
    local ra_m ra_s
    for ((i=1; i<=RA_TRIES; i++)); do
        ra_m=$(get_ra "$MASTER_IP"); ra_s=$(get_ra "$SLAVE_IP")
        printf "     t=%3ds  master RA=%s | slave RA=%s\n" "$i" "${ra_m:-?}" "${ra_s:-?}"
        [ "${ra_m:-0}" -eq 1 ] 2>/dev/null && [ "${ra_s:-0}" -eq 1 ] 2>/dev/null && break
        sleep 1
    done

    echo "--- [10] final LL full-enable re-assert (0x208 = 0x00027f07) ---"
    wr_both $LL_ENREG $LL_FULL
}

# =============================================================================
# AUTONOMOUS MODE — arm the FSMs and let them converge with NO further pokes.
# =============================================================================
autonomous_bringup() {
    echo "--- [1] debug unlock (open the APB write path) ---"
    wr_both $DEBUG_UNLOCK 1

    echo "--- [2] arm training FSM: NEGO_TRAIN_CFG.train_auto_en = 1 (0x210C) ---"
    wr_both $NEGO_TRAIN_CFG 0x1

    echo "--- [3] arm autoneg: NEGO_CFG = 0x61 (0x2090 — the WRITABLE reg!) ---"
    echo "        (0x61 = nego_en | nego_force_lock | mask_hs_auto_en)"
    wr_both $NEGO_CFG 0x61

    echo "--- [4] hands OFF: poll status only, ZERO further bring-up pokes ---"
    # The on-chip autoneg + training + calibrator FSMs now drive role-lock,
    # SYNC, reanchor and the credit handshake by themselves.
}

# -----------------------------------------------------------------------------
# Run the selected recipe, then converge + enable data.
# -----------------------------------------------------------------------------
if [ "$MODE" = "manual" ]; then
    manual_bringup
else
    autonomous_bringup
fi

if poll_fcsm4; then
    if [ "$MODE" = "autonomous" ]; then
        # Autonomous convergence brings the LINK up hands-off; the DATA path
        # still needs its LL enable pulse. (Manual already did this in step 7/10.)
        echo "--- autonomous: LL bootstrap for data path ---"
        ll_bootstrap
        wr_both $LL_ENREG $LL_FULL
    fi
    echo "=============================================================="
    echo "RESULT: LINK UP — both dies FCSM=4, data path enabled ($MODE)."
    echo "  (End-to-end AHB_TX / FIFO delivery is a SEPARATE step —"
    echo "   see link_delivery_proof.sh.)"
    echo "=============================================================="
    exit 0
else
    echo "=============================================================="
    echo "RESULT: NOT CONVERGED in ${FCSM_TRIES}s ($MODE)."
    echo "  master fcsm=$(get_fcsm "$MASTER_IP") cr=$(get_cr "$MASTER_IP") | slave fcsm=$(get_fcsm "$SLAVE_IP") cr=$(get_cr "$SLAVE_IP")"
    echo "  Re-run with a larger poll budget (FCSM_TRIES=...) or check hardware."
    echo "=============================================================="
    exit 1
fi
