#!/bin/bash
# =============================================================================
# i2c_continuity_test.sh — SW-only I²C bus conductivity test for the deployed
# TideLink v9 PYNQ-Z2 pair (z2_02 master / z2_03 slave on bridge1).
#
# WHY THIS EXISTS
# ───────────────
# On v9 HEAD 4a5f875 the autoneg FSM never advances past sda_start_seen=0 on
# either die; both report miss_ack=1. The user reports the physical W9/V7
# ribbon "looks good" but wants a SW continuity check before re-seating.
#
# STRUCTURAL CONSTRAINT (READ BEFORE EDITING)
# ───────────────────────────────────────────
# The original plan was to drive i2c_master_axil directly via its AXI4
# sideband (s_i2c_axi_*) from the PS to bypass the autoneg FSM. THAT PATH
# DOES NOT EXIST ON v9 HARDWARE — `s_i2c_axi_*` is tied off via xlconstant
# INSIDE the BD on every pynq-z2-pair-* target (see
# fpga/targets/pynq-z2-pair-all/tidelink_design_wrapper.v:146-149). The PS
# has no AXI route to the I²C-master core. Additionally,
# axi_chiplet_controller.sv:811 holds the I²C master in reset whenever
#   ~role_is_master & ~nego_driving
# which means the master core is ONLY commandable from the in-die autoneg
# FSM (nego_driving), not from SW.
#
# So a literal "drive PRESCALE/COMMAND/DATA from devmem" test is impossible.
# Instead this script uses the autoneg FSM AS the stimulus and observes the
# wire's effect on the PEER's slave-side debug bits.
#
# TEST DESIGN (revised)
# ─────────────────────
# Step A — Quiescent baseline.
#   On both boards: write nego_cfg=0 (disable autoneg). Read ROLE_STATUS
#   (0x44032084) and NEGO_STATUS (0x44032094). Expect i2c_busy=0,
#   i2c_addressed=0, sda_start_seen=0. Establishes that nothing is
#   spuriously driving the wire.
#
# Step B — Master-driven unidirectional probe.
#   On z2_02 ONLY: enable autoneg (nego_cfg=0x61). Autoneg FSM will
#   immediately drive the W9/V7 I²C bus with a START + slave-addr write
#   trying to reach the peer. On z2_03 leave nego DISABLED — the slave core
#   is active by default whenever role_is_master=0 (slv_reset=role_is_master,
#   ll.811), so it observes traffic regardless of nego_cfg on its own die.
#
#   Race-poll z2_03's ROLE_STATUS at ~5 ms intervals for 3 s, recording the
#   set-bit-mask of i2c_busy (bit[2]) and i2c_addressed (bit[3]) ever seen.
#   Also sample z2_03's NEGO_STATUS to see if its sda_start_seen latches
#   (regardless of nego_cfg — the slave's edge detector lives in the core).
#
#   In PARALLEL also race-poll z2_02's OWN ROLE_STATUS — the master's
#   i2c_sda_i loops back through its own IOBUF, so if the local IOBUF is
#   alive the master will see its own SDA toggle. This is the Q2 IOBUF
#   liveness check we get FOR FREE in the same test.
#
# Step C — Reverse direction probe.
#   Z2_03 is slave-role-strapped; its autoneg FSM cannot transmit because
#   i2c_mst_reset=1 when role_is_master=0 & nego_driving=0 — and on the
#   slave die nego_driving never asserts because it never wins arbitration.
#   So no useful "z2_03 master drives" test exists on the deployed
#   bitstream. We document the asymmetry rather than fake it.
#
# Step D — Restore. nego_cfg=0 on both dies (quiet bus).
#
# VERDICT MATRIX
# ──────────────
#   Q1.a BUS OK + PEER LATCHES:
#       z2_03.sda_start_seen=1 at some point during Step B.
#       => Bus conducts; START framing detected by peer slave. Autoneg's
#          ongoing miss_ack failure has a different cause (slave addr,
#          NACK injection, FSM state).
#   Q1.b BUS OK + ADDR MISMATCH:
#       z2_03.i2c_busy=1 seen but sda_start_seen stays 0.
#       => Wire conducts edges but the slave START detector / address
#          decoder rejects. Compare i2c_slv_addr_reg @ 0x44032088 on z2_03
#          against the master FSM's hard-coded 0x7E (autoneg.sv).
#   Q1.c BUS BROKEN:
#       z2_03.i2c_busy stayed 0 AND sda_start_seen stayed 0 for the
#       entire 3 s window AND z2_02's OWN i2c_busy was seen high
#       (proving master IOBUF actually drove the bus). => Wire open.
#   Q2.a MASTER IOBUF STUCK:
#       z2_02 NEGO_STATUS.state advanced past idle but z2_02's OWN
#       i2c_busy stayed 0 AND sda_start_seen stayed 0 on z2_02.
#       => Master's local IOBUF is not driving (or not reading back).
#       RTL/BD fix point: i2c_sda_io / i2c_scl_io xlconstant or IOBUF in
#       fpga/targets/pynq-z2-pair-all/tidelink_design.tcl.
#   Q2.b BOTH IOBUFS DEAD:
#       Both dies' i2c_busy stayed 0 for full window. Unable to localise
#       between master-side IOBUF, slave-side IOBUF, and the wire from
#       this test alone — recommend scope on W9/V7 pads.
#   INDETERMINATE:
#       Autoneg state machine never moved off idle (won/lost/state stuck
#       at reset values). The FSM is gated upstream of the I²C transmit
#       and we have no SW path to push it. Recommend Region-8 W1P
#       NEGO_TRAIN_STEP poke.
#
# CONSTRAINTS HONOURED
# ─────────────────────
#   * No bitstream redeploy (script reads runtime state only).
#   * No branch switch / git push.
#   * No i2c_master_axil RTL edits.
#   * bash --noprofile --norc when SSHing to mapstone-dev (avoids the
#     "Agent pid" stdout corruption from the user's ~/.bashrc ssh-agent).
#   * /tmp/td_v9_priv/ is NOT used (script is fully read-only on board).
#   * Lease must be held by mapstone-dev for bridge1 before running.
#
# Usage:
#   pynq_host/scripts/i2c_continuity_test.sh [--master-ip IP] [--slave-ip IP]
#                                            [--window-s SECS]
#
# Exit 0 = verdict Q1.a (bus conducts, peer latched).
# Exit 1 = verdict Q1.b/Q1.c/Q2.a/Q2.b/INDETERMINATE — see stdout.
# Exit 2 = lease not held / SSH unreachable / autoneg never moved.
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

MASTER_IP="192.168.4.101"
SLAVE_IP="192.168.6.101"
WINDOW_S="3"
PASS="${TIDELINK_BOARD_PASS:-xilinx}"
MAPSTONE_HOST="${MAPSTONE_HOST:-mapstone-dev}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --master-ip) MASTER_IP="$2"; shift 2 ;;
        --slave-ip)  SLAVE_IP="$2";  shift 2 ;;
        --window-s)  WINDOW_S="$2";  shift 2 ;;
        -h|--help)
            sed -n '1,90p' "$0" >&2; exit 0 ;;
        *) echo "i2c_continuity_test.sh: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

SSH_NOAGENT_PREFIX="bash --noprofile --norc -c"
SSH_BOARD_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

# Verify lease held on bridge1 by mapstone-dev. We don't auto-acquire —
# parent territory.
echo "─── lease pre-flight ───────────────────────────────────────────────"
LEASE_RAW=$(ssh "$MAPSTONE_HOST" "$SSH_NOAGENT_PREFIX 'fpgahub pair lease show bridge1 2>&1'" 2>/dev/null || true)
echo "$LEASE_RAW"
if ! echo "$LEASE_RAW" | grep -q "^granted\|held"; then
    if echo "$LEASE_RAW" | grep -q "^free"; then
        echo "ABORT: bridge1 lease is FREE. Acquire it first:" >&2
        echo "  ssh $MAPSTONE_HOST /opt/fpgahub/bin/fpgahub pair lease \\" >&2
        echo "      acquire bridge1 --ttl 3600 --tier interactive" >&2
        exit 2
    fi
fi
echo

# Board-side Python (single script, parameterised by ROLE_TAG and ACTION).
# Reads/writes /dev/mem via mmap. APB write of nego_cfg is the only mutation
# (and we restore it to 0 in the FINAL step on both boards).
#
# Register map (per local_overrides/axi_chiplet_controller.sv:546-558):
#   TL_BASE  = 0x44032000
#   CR base  = TL_BASE + 0x80   (ctrl_reg window: region4 idx 0..7)
#     +0x00 ROLE_CFG       (RW; bit[0]=role_cfg_w1s, bit[1]=role_lock W1S)
#     +0x04 ROLE_STATUS    (RO; bit[0]=role_eff, bit[1]=role_locked,
#                               bit[2]=i2c_slv_busy, bit[3]=i2c_slv_addressed)
#     +0x08 I2C_SLV_ADDR   (RW; bits[6:0])
#     +0x0C I2C_PRESCALE   (RW; bits[15:0])
#     +0x10 NEGO_CFG       (RW; bit[0]=nego_en, bit[5]=force_lock,
#                                bit[6]=mask_hs_auto_en)
#     +0x14 NEGO_STATUS    (RO; [3:0]=state, [4]=done, [5]=error,
#                                [6]=won, [7]=lost, [8]=sda_start_seen,
#                                [9]=mask_mismatch)
PY_PROBE=$(cat <<'PYEOF'
import mmap, os, struct, sys, time, json
TL=0x44032000; CR=0x80
ROLE_CFG=CR+0x00; ROLE_STS=CR+0x04; SLV_ADDR=CR+0x08
NEGO_CFG=CR+0x10; NEGO_STS=CR+0x14
PG=4096
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
base=TL & ~(PG-1); offs=TL-base
mm=mmap.mmap(fd,PG,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=base)
def rd(o): return struct.unpack_from("<I", mm, offs+o)[0]
def wr(o,v):
    struct.pack_into("<I", mm, offs+o, v & 0xFFFFFFFF)

ACTION = sys.argv[1] if len(sys.argv)>1 else "probe"
TAG    = sys.argv[2] if len(sys.argv)>2 else "?"
WIN_S  = float(sys.argv[3]) if len(sys.argv)>3 else 3.0

# Identify bitstream version (bail loud if not loaded).
ver = rd(0x14)
if ver in (0, 0xFFFFFFFF):
    print(json.dumps({"tag":TAG,"action":ACTION,"ABORT":"version_invalid","ver":ver}))
    sys.exit(4)

if ACTION == "quiesce":
    # Disable autoneg, sanitise. Read back state.
    wr(NEGO_CFG, 0x00)
    time.sleep(0.05)
    PSC = CR+0x0C  # I2C_PRESCALE
    out = {"tag":TAG,"action":"quiesce",
           "ver":ver, "role_sts":rd(ROLE_STS),
           "nego_cfg":rd(NEGO_CFG)&0x7F, "nego_sts":rd(NEGO_STS),
           "slv_addr":rd(SLV_ADDR)&0x7F,
           "i2c_prescale":rd(PSC)&0xFFFF}
    out["i2c_busy"]      = bool((out["role_sts"]>>2)&1)
    out["i2c_addressed"] = bool((out["role_sts"]>>3)&1)
    out["sda_start_seen"]= bool((out["nego_sts"]>>8)&1)
    out["nego_state"]    = out["nego_sts"]&0xF
    print(json.dumps(out)); sys.exit(0)

if ACTION == "arm_master":
    # nego_cfg = 0x61 (en | force_lock | mask_hs_auto_en) — same combo as
    # bringup_autocal_i2c.sh. We do NOT write NEGO_TRAIN_CFG here because
    # we want to maximise the I²C transmit pressure, not run the FSM
    # all the way through training.
    wr(NEGO_CFG, 0x61)
    time.sleep(0.01)
    out = {"tag":TAG,"action":"arm_master","nego_cfg":rd(NEGO_CFG)&0x7F}
    print(json.dumps(out)); sys.exit(0)

if ACTION == "poll":
    # High-rate poll loop. Record ever-set masks of {i2c_busy, i2c_addressed,
    # sda_start_seen} and the maximum nego_state observed.
    seen_busy = 0; seen_addr = 0; seen_sda = 0
    max_state = 0; samples = 0
    nego_done_seen = False; nego_err_seen = False
    nego_won_seen = False;  nego_lost_seen = False
    t0 = time.time()
    while (time.time() - t0) < WIN_S:
        rs = rd(ROLE_STS); ns = rd(NEGO_STS)
        if (rs>>2)&1: seen_busy = 1
        if (rs>>3)&1: seen_addr = 1
        if (ns>>8)&1: seen_sda  = 1
        st = ns & 0xF
        if st > max_state: max_state = st
        if (ns>>4)&1: nego_done_seen = True
        if (ns>>5)&1: nego_err_seen  = True
        if (ns>>6)&1: nego_won_seen  = True
        if (ns>>7)&1: nego_lost_seen = True
        samples += 1
        # Tight loop — devmem mmap reads ~50 µs each, no sleep. At prescale
        # 128 the I²C master's busy pulse for a START+addr-byte is ~2.5 ms;
        # at prescale 1 (which is what the v9 RTL default + nego_cfg=0x61
        # leaves us with unless I2C_PRESCALE was poked) it could be only
        # a few µs. Polling at ~50 µs cadence covers both.
    final_rs = rd(ROLE_STS); final_ns = rd(NEGO_STS)
    out = {"tag":TAG,"action":"poll","window_s":WIN_S,"samples":samples,
           "seen_i2c_busy":bool(seen_busy),
           "seen_i2c_addressed":bool(seen_addr),
           "seen_sda_start":bool(seen_sda),
           "max_nego_state":max_state,
           "nego_done_seen":nego_done_seen, "nego_err_seen":nego_err_seen,
           "nego_won_seen":nego_won_seen,   "nego_lost_seen":nego_lost_seen,
           "final_role_sts":final_rs, "final_nego_sts":final_ns}
    print(json.dumps(out)); sys.exit(0)

print(json.dumps({"ABORT":"unknown_action","action":ACTION})); sys.exit(3)
PYEOF
)
# Base64-encode the Python so we don't have to fight shell quoting on the
# remote side (the source contains "<I" format strings that the outer
# bash would otherwise eat).
PY_PROBE_B64=$(printf '%s' "$PY_PROBE" | base64 -w0)

# Run a single board-side python action and emit the JSON line.
run_board() {
    local IP="$1" TAG="$2" ACTION="$3" WIN_S_ARG="${4:-0}"
    sshpass -p "$PASS" ssh $SSH_BOARD_OPTS "xilinx@$IP" \
        "echo '$PASS' | sudo -S bash -c 'echo $PY_PROBE_B64 | base64 -d | python3 - $ACTION $TAG $WIN_S_ARG' 2>&1 | tail -n 1"
}

echo "─── Step A: quiesce both boards (nego_cfg=0) ──────────────────────"
A_MASTER=$(run_board "$MASTER_IP" master quiesce)
A_SLAVE=$( run_board "$SLAVE_IP"  slave  quiesce)
echo "  master: $A_MASTER"
echo "  slave : $A_SLAVE"
echo

# Sanity check: both should report quiescent i2c lines.
if ! echo "$A_MASTER" | grep -q '"ver":'; then
    echo "ABORT: master did not return version JSON — bitstream not loaded?" >&2
    exit 2
fi
if ! echo "$A_SLAVE" | grep -q '"ver":'; then
    echo "ABORT: slave did not return version JSON — bitstream not loaded?" >&2
    exit 2
fi

echo "─── Step B: arm master only, race-poll BOTH for ${WINDOW_S} s ─────"
B_ARM=$(run_board "$MASTER_IP" master arm_master)
echo "  arm: $B_ARM"

# Race-poll both boards concurrently. We background the slave poll and run
# the master poll in foreground so this script blocks for ~WINDOW_S, then
# joins on the slave.
SLAVE_OUT=$(mktemp)
run_board "$SLAVE_IP" slave poll "$WINDOW_S" > "$SLAVE_OUT" &
SLAVE_PID=$!
B_MASTER=$(run_board "$MASTER_IP" master poll "$WINDOW_S")
wait "$SLAVE_PID" || true
B_SLAVE=$(cat "$SLAVE_OUT"); rm -f "$SLAVE_OUT"
echo "  master poll: $B_MASTER"
echo "  slave  poll: $B_SLAVE"
echo

echo "─── Step D: restore quiet (nego_cfg=0 both) ────────────────────────"
D_MASTER=$(run_board "$MASTER_IP" master quiesce)
D_SLAVE=$( run_board "$SLAVE_IP"  slave  quiesce)
echo "  master: $D_MASTER"
echo "  slave : $D_SLAVE"
echo

# ── Verdict logic ─────────────────────────────────────────────────────────
# Extract booleans from the slave-poll JSON.
py_extract() {
    # $1 = json line, $2 = key
    python3 -c "
import json,sys
try:
    j=json.loads('''$1''')
    v=j.get('$2', None)
    if isinstance(v,bool): print('1' if v else '0')
    elif v is None: print('?')
    else: print(v)
except Exception as e:
    print('?')
" 2>/dev/null
}

S_SDA=$(py_extract "$B_SLAVE"  "seen_sda_start")
S_BUSY=$(py_extract "$B_SLAVE"  "seen_i2c_busy")
S_ADDR=$(py_extract "$B_SLAVE"  "seen_i2c_addressed")
M_BUSY=$(py_extract "$B_MASTER" "seen_i2c_busy")
M_SDA=$( py_extract "$B_MASTER" "seen_sda_start")
M_STATE=$(py_extract "$B_MASTER" "max_nego_state")
M_WON=$( py_extract "$B_MASTER" "nego_won_seen")
M_LOST=$(py_extract "$B_MASTER" "nego_lost_seen")
M_ERR=$( py_extract "$B_MASTER" "nego_err_seen")

echo "─── Verdict inputs ─────────────────────────────────────────────────"
printf "  slave  seen_sda_start    = %s\n" "$S_SDA"
printf "  slave  seen_i2c_busy     = %s\n" "$S_BUSY"
printf "  slave  seen_i2c_addressed= %s\n" "$S_ADDR"
printf "  master seen_i2c_busy     = %s   (own-IOBUF loopback)\n" "$M_BUSY"
printf "  master seen_sda_start    = %s   (own-SDA edge readback)\n" "$M_SDA"
printf "  master max_nego_state    = %s\n" "$M_STATE"
printf "  master nego_won/lost/err = %s/%s/%s\n" "$M_WON" "$M_LOST" "$M_ERR"
echo

# Classify.
if [ "$M_STATE" = "0" ] || [ "$M_STATE" = "?" ]; then
    echo "VERDICT: INDETERMINATE — master autoneg FSM never moved off state 0."
    echo "         No I²C transmit was even attempted; can't probe the wire."
    echo "         Recommend: poke Region-8 NEGO_TRAIN_STEP W1P @ 0x44032114"
    echo "         then re-run, OR examine pin-strap on master die."
    exit 2
fi

if [ "$S_SDA" = "1" ]; then
    echo "VERDICT: Q1.a — BUS CONDUCTS + PEER LATCHES START."
    echo "         z2_03 saw sda_start_seen=1 while z2_02 drove I²C."
    echo "         Hypothesis tree for why autoneg STILL wedges with sda_start_seen=0"
    echo "         on the master die:"
    echo "         (1) MASTER-side START detector blind to its OWN driven edges."
    echo "             Mostly a pipeline/CDC bug in nego_sda_start_seen capture"
    echo "             — the slave's edge detector works but the master's doesn't."
    echo "         (2) FSM advances past the START phase before its own edge"
    echo "             detector latches (race between FSM state advance and"
    echo "             sda_start_seen sample). Look at tidelink_autoneg.sv around"
    echo "             the I²C-master command issue and sda_start_seen latch."
    echo "         (3) The slave NACKs after addressing, master FSM reports"
    echo "             miss_ack=1 (which is what we observe today). Check the"
    echo "             slave's i2c_slv_addr_reg (0x44032088) vs the FSM's"
    echo "             hard-coded 0x7E target."
    exit 0
fi

if [ "$S_BUSY" = "1" ] && [ "$S_SDA" = "0" ]; then
    echo "VERDICT: Q1.b — BUS CONDUCTS, PEER START-DETECT FAILS."
    echo "         z2_03 i2c_busy toggled (its I²C engine saw bus activity)"
    echo "         but sda_start_seen never latched (the START framing wasn't"
    echo "         decoded). Either the SDA/SCL edge order is wrong (open-drain"
    echo "         glitch on a slow bus — W9/V7 has no on-board pull-up, only"
    echo "         the weak internal pull at prescale ≥128), or the prescaler"
    echo "         on the master is too fast for the wire. Try I2C_PRESCALE=200"
    echo "         in bringup_autocal_i2c.sh and re-test."
    exit 1
fi

if [ "$S_BUSY" = "0" ] && [ "$S_SDA" = "0" ]; then
    if [ "$M_BUSY" = "1" ] || [ "$M_SDA" = "1" ]; then
        echo "VERDICT: Q1.c — BUS ELECTRICALLY BROKEN."
        echo "         Master's OWN IOBUF saw activity (i2c_busy=$M_BUSY,"
        echo "         sda_start=$M_SDA on z2_02) — so the master IS driving"
        echo "         W9/V7 — but z2_03 saw nothing on its W9/V7 input."
        echo "         RECOMMEND PHYSICAL ACTION:"
        echo "           (1) Re-seat the W9 and V7 jumper wires on BOTH boards."
        echo "           (2) Continuity-test the W9↔W9 and V7↔V7 conductors"
        echo "               with a multimeter (pads exposed on the J13 strip)."
        echo "           (3) Verify the ground reference between the two PYNQ"
        echo "               boards is shared — W9/V7 I²C uses internal weak pulls"
        echo "               only, so a floating GND will look like an open."
        echo "           (4) If wires are intact, scope SDA/SCL on z2_03's W9/V7"
        echo "               IOBUF inputs while z2_02 transmits — confirm whether"
        echo "               the edges arrive at the FPGA pin."
        exit 1
    else
        echo "VERDICT: Q2.b — BOTH IOBUFS APPEAR DEAD."
        echo "         Neither die's i2c_busy ever asserted, yet master autoneg"
        echo "         state advanced (max_state=$M_STATE). Either the master"
        echo "         IOBUF is stuck (most likely — would explain miss_ack=1"
        echo "         on both, the symptom matching the original bug report)"
        echo "         OR the FSM advances without actually commanding the I²C"
        echo "         master core (logic bug)."
        echo "         RTL/BD fix locations to check:"
        echo "           - fpga/targets/pynq-z2-pair-all/tidelink_design.tcl"
        echo "             search for 'i2c_sda_io', 'i2c_scl_io', the IOBUF"
        echo "             instantiation, and whether i2c_*_t (tristate-enable)"
        echo "             is wired to a register driven by the chiplet."
        echo "           - src/rtl/local_overrides/axi_chiplet_controller.sv:1135-1144"
        echo "             confirms the tristate mux; sniff with ILA on the master."
        echo "         Also recommend scoping SCL/SDA at z2_02's W9/V7 pads to"
        echo "         localise: if pads are stuck HIGH, IOBUF tristate is wedged"
        echo "         enabled (so the master is never pulling LOW)."
        exit 1
    fi
fi

echo "VERDICT: UNCLASSIFIED — slave busy=$S_BUSY sda=$S_SDA master busy=$M_BUSY sda=$M_SDA"
exit 1
