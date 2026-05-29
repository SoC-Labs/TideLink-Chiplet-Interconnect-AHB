#!/bin/bash
# Deploy the pynq-z2-pair bitstream onto a paired board and bring the link up.
#
# Run from a host that can reach the PYNQ Linux on the board (e.g. mapstone-dev,
# which has direct routes to the per-board /24 networks). Boards' default user
# is xilinx with password xilinx. Both .bin and .hwh must be staged at
# $ARTEFACTS_DIR (defaults to /tmp/tidelink_deploy).
#
# Usage:
#   deploy_pair.sh BOARD_IP BOARD_LABEL ROLE [ARTEFACTS_DIR] [options]
#     ROLE = die_a | die_b   (controls strap polarity — die_a -> master)
#     ARTEFACTS_DIR optional; defaults to /tmp/tidelink_deploy
#
#   Provenance options (Bug #32 — wrong-bitstream guard):
#     --expect-sha256 <hex>   abort unless the staged .bin matches this hash
#     --manifest <path>       read expected sha256 (+ label/commit) from a
#                             <bitstream>.manifest.json; default looked up as
#                             <ARTEFACTS>/<bin>.manifest.json if it exists
#     --no-verify             explicit escape hatch: deploy WITHOUT a hash
#                             check (otherwise an unverified deploy is loud)
#     --check-only            do NOT flash; read back the MD5 of the bitstream
#                             already loaded on the board and compare to the
#                             manifest/expected hash, then exit (Layer 4)
#
#   The May-6 phase-v2 mixup (Bug #32): a known-0/16 build (MD5 188ebdd8)
#   was left in the shared volatile staging dir by a population test and
#   deployed BLINDLY into the v1 release + every post-cycle test. With a
#   manifest or --expect-sha256 the wrong .bin now ABORTS instead of flashing.
#
# Example workflow on mapstone-dev:
#   mkdir -p /tmp/tidelink_deploy
#   # ... copy tidelink.bit/.bin/.hwh into that dir ...
#   ssh mapstone-dev /opt/fpgahub/bin/fpgahub pair lease acquire bridge1 \
#         --user $(whoami) --ttl 3600
#   ./deploy_pair.sh 192.168.4.101 z2_02 die_a
#   ./deploy_pair.sh 192.168.6.101 z2_03 die_b
#
# After both boards return:
#   - LD0 (link_active) should be solid on both
#   - LD1 (role_is_master_o) on for the die_a board only
#
# If you change the role or want to retry the link, the bitstream must be
# reloaded — role_lock_reg is W1S with POR-only clear.
#
# **HAZARD — DO NOT WRITE TO AHB_TX (0x4400_0000) FROM PS UNTIL THE LINK
# IS VERIFIED UP.**  If the Wlink TX FC node is wedged (RX deserializer
# unsynced, ribbon wiring wrong, RX clock unusable), the FC adapter never
# asserts HREADY back to the AXI-Lite-to-AHB bridge. SmartConnect then
# stalls, the PS mmap write hangs in kernel space, and SSH gets killed.
# Bench evidence (2026-04-27): an AHB_TX write on z2_02 took it offline
# and required a physical power-cycle (UART reboot did not recover).
#
# Safe-to-execute always: APB reads/writes, strap GPIO writes, role-lock
# writes, doorbell trigger (the doorbell goes through APB, which is a
# separate path). Run wlink_probe.sh first to inspect link state before
# attempting any AHB_TX traffic.
set -e

BOARD_IP="$1"
LABEL="$2"
ROLE="$3"
# 4th positional is ARTEFACTS_DIR only if it does not start with '-' (so the
# legacy 4-positional callers keep working while new --flags are accepted).
if [ -n "${4:-}" ] && [ "${4#-}" = "$4" ]; then
    ARTEFACTS="$4"; shift 4
else
    ARTEFACTS="/tmp/tidelink_deploy"; [ "$#" -ge 3 ] && shift 3
fi
PASS="${TIDELINK_BOARD_PASS:-xilinx}"

# --- Provenance-guard option parsing (Bug #32) -----------------------------
EXPECT_SHA=""        # explicit --expect-sha256 value (highest precedence)
MANIFEST=""          # explicit --manifest path
NO_VERIFY=0          # --no-verify escape hatch
CHECK_ONLY=0         # --check-only (Layer 4: read-back, no flash)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --expect-sha256) EXPECT_SHA="$2"; shift 2 ;;
        --expect-sha256=*) EXPECT_SHA="${1#*=}"; shift ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        --manifest=*) MANIFEST="${1#*=}"; shift ;;
        --no-verify) NO_VERIFY=1; shift ;;
        --check-only) CHECK_ONLY=1; shift ;;
        *) echo "deploy_pair.sh: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# When using a STRAIGHT-THROUGH RPi GPIO ribbon (1:1 cable, e.g. The
# Pi Hut 40-pin), the two boards need MIRRORED pin maps so that one
# board's TX pads land on the other board's RX pads. die_a runs the
# standard pynq-z2-pair bitstream (TX on RPi GPIO 0..8); die_b runs
# the pynq-z2-pair-flip bitstream (TX on RPi GPIO 9..17). With a
# custom cross-strap ribbon you'd run pynq-z2-pair on both boards;
# set FORCE_ARTEFACTS=tidelink to opt out of the per-role selection.
if [ -n "${FORCE_ARTEFACTS:-}" ]; then
    BIN="${FORCE_ARTEFACTS}.bin"
    HWH="${FORCE_ARTEFACTS}.hwh"
elif [ -f "${ARTEFACTS}/tidelink.bin" ] && [ ! -f "${ARTEFACTS}/tidelink-flip.bin" ]; then
    # Single-bitstream layout (legacy / cross-strap-cable workflow).
    BIN="tidelink.bin"; HWH="tidelink.hwh"
else
    # Two-bitstream layout (straight-through cable). die_a gets the
    # canonical pynq-z2-pair bitstream; die_b gets the flip.
    case "$ROLE" in
        die_a) BIN="tidelink.bin";       HWH="tidelink.hwh" ;;
        die_b) BIN="tidelink-flip.bin";  HWH="tidelink-flip.hwh" ;;
    esac
fi

# PHASE = swi_phase_offset (Wlink PHY ctrl reg WL+0x0000, bits[20:17]).
# SHORTCOMINGS-14b: in strap-driven init, master's POR releases first;
# slave's RX deserialiser counter ends up ~3 pad_clks ahead of master's
# TX framing. Setting phase=3 on slave realigns adj_count to 0.
# Encoded as the full 32-bit register value: phase << 17.
case "$ROLE" in
    die_a) STRAP=0 ; CTRL=0x2 ; PHASE=0x00000000 ;;   # master, phase=0
    die_b) STRAP=1 ; CTRL=0x3 ; PHASE=0x00060000 ;;   # slave,  phase=3
    *) echo "ROLE must be die_a or die_b (got '$ROLE')" >&2; exit 2 ;;
esac

# Optional override: PHASE_OVERRIDE env var (full 32-bit register value).
# Used for empirical phase sweeps during bring-up debug.
if [ -n "${PHASE_OVERRIDE:-}" ]; then
    PHASE="$PHASE_OVERRIDE"
fi

[[ -z "$BOARD_IP" || -z "$LABEL" ]] && {
    sed -n '4,18p' "$0" | sed 's/^# *//'; exit 2; }

SSHCOMMON="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# === Provenance guard (Bug #32) ============================================
# Resolve the EXPECTED sha256 for the bitstream we are about to deploy, in
# precedence order: explicit --expect-sha256 > explicit --manifest >
# auto-discovered "<ARTEFACTS>/<BIN>.manifest.json". The manifest is a small
# JSON: {sha256, source_commit, build_host, build_date, target,
# expected_lock_min, label}. We extract sha256 + label with a portable grep
# (no jq dependency on the board-network host).
STAGED_BIN="$ARTEFACTS/$BIN"
MANIFEST_LABEL=""; MANIFEST_COMMIT=""; MANIFEST_LOCKMIN=""

manifest_field() {  # FILE FIELD  -> value (string, quotes stripped) or ""
    [ -f "$1" ] || { echo ""; return; }
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}
manifest_num() {    # FILE FIELD  -> numeric value or ""
    [ -f "$1" ] || { echo ""; return; }
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$1" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*//'
}

# Auto-discover a manifest next to the staged bitstream if none was given.
if [ -z "$MANIFEST" ] && [ -f "${STAGED_BIN}.manifest.json" ]; then
    MANIFEST="${STAGED_BIN}.manifest.json"
fi
if [ -n "$MANIFEST" ]; then
    if [ ! -f "$MANIFEST" ]; then
        echo "DEPLOY-ABORT: manifest not found: $MANIFEST" >&2; exit 4
    fi
    MANIFEST_LABEL=$(manifest_field "$MANIFEST" label)
    MANIFEST_COMMIT=$(manifest_field "$MANIFEST" source_commit)
    MANIFEST_LOCKMIN=$(manifest_num "$MANIFEST" expected_lock_min)
    [ -z "$EXPECT_SHA" ] && EXPECT_SHA=$(manifest_field "$MANIFEST" sha256)
fi

# Compute the actual sha256 of the staged bitstream (fast, ~4 MB).
ACTUAL_SHA=""
if [ -f "$STAGED_BIN" ]; then
    ACTUAL_SHA=$(sha256sum "$STAGED_BIN" 2>/dev/null | awk '{print $1}')
fi

# --- Layer 4: --check-only (read back what is loaded, do NOT flash) --------
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "==== CHECK-ONLY $LABEL @ $BOARD_IP — bitstream=$BIN ===="
    [ -n "$MANIFEST" ] && echo "  manifest: $MANIFEST (label=${MANIFEST_LABEL:-?} commit=${MANIFEST_COMMIT:-?})"
    echo "  staged   sha256 = ${ACTUAL_SHA:-<no staged file>}"
    [ -n "$EXPECT_SHA" ] && echo "  expected sha256 = $EXPECT_SHA"
    loaded_md5=$(sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
        "md5sum /lib/firmware/tidelink.bin 2>/dev/null" 2>/dev/null | awk '{print $1}')
    echo "  on-board /lib/firmware/tidelink.bin MD5 = ${loaded_md5:-<unreadable>}"
    if [ -n "$EXPECT_SHA" ] && [ -n "$ACTUAL_SHA" ]; then
        # The board exposes MD5 not SHA256; we cross-check the staged bin's
        # MD5 against the board so an operator can confirm same-file identity.
        staged_md5=$(md5sum "$STAGED_BIN" 2>/dev/null | awk '{print $1}')
        if [ -n "$loaded_md5" ] && [ "$loaded_md5" = "$staged_md5" ]; then
            echo "  RESULT: on-board bitstream MATCHES staged ($staged_md5)"
            if [ "$ACTUAL_SHA" = "$EXPECT_SHA" ]; then
                echo "  RESULT: staged sha256 MATCHES manifest — provenance OK"; exit 0
            else
                echo "DEPLOY-ABORT: staged sha256 mismatch vs manifest — expected $EXPECT_SHA, got $ACTUAL_SHA" >&2; exit 5
            fi
        else
            echo "DEPLOY-ABORT: on-board MD5 ($loaded_md5) != staged MD5 ($staged_md5) — board is running a DIFFERENT bitstream" >&2; exit 5
        fi
    fi
    echo "  (no expected hash given — readback only, provenance NOT verified)" >&2
    exit 0
fi

# --- Layer 1: pre-flash sha256 verification --------------------------------
if [ -n "$EXPECT_SHA" ]; then
    if [ -z "$ACTUAL_SHA" ]; then
        echo "DEPLOY-ABORT: cannot hash staged bitstream $STAGED_BIN (missing/unreadable) — refusing to flash" >&2
        exit 4
    fi
    if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
        echo "DEPLOY-ABORT: bitstream SHA mismatch — expected $EXPECT_SHA, got $ACTUAL_SHA (refusing to flash wrong bitstream)" >&2
        exit 4
    fi
    SHA12="${ACTUAL_SHA:0:12}"
    echo "  provenance OK: $BIN sha256 ${SHA12}… matches ${MANIFEST:+manifest }${MANIFEST_LABEL:+(label=$MANIFEST_LABEL) }expected"
elif [ "$NO_VERIFY" -eq 1 ]; then
    echo "WARNING: --no-verify set — flashing $BIN WITHOUT provenance check (sha256=${ACTUAL_SHA:-?})" >&2
else
    # Hard abort on UNVERIFIED DEPLOY — recommended by 2026-05-23 link-decay
    # bisect (docs/LINK_DECAY_BISECT.md). The same class of bug as #32
    # bit twice today: build #8 bins were staged into ~/td_milestone_stage/
    # but /tmp/tidelink_deploy/ on the boards still held rc2, and the
    # WARNING-only path let PHC Phase-1 read rc2's marginal link as a
    # build-#8 regression for ~3 hours. WARNINGs do not stop the deploy,
    # and bus-y operators (especially in setsid-detached form) don't read
    # them. Aborting forces every deploy to declare provenance up front.
    #
    # Bypass: pass --no-verify EXPLICITLY when you genuinely want to deploy
    # without checking (e.g. local sandbox experiments). Or generate a
    # sibling .manifest.json with make_bitstream_manifest.sh.
    echo "DEPLOY-ABORT: UNVERIFIED DEPLOY — no --expect-sha256, --manifest or --no-verify given." >&2
    echo "  Refusing to flash $STAGED_BIN (sha256=${ACTUAL_SHA:-?}) with no provenance guard." >&2
    echo "  This is the Bug #32 class of mistake — see docs/LINK_DECAY_BISECT.md for" >&2
    echo "  today's recurrence (build #8 bins staged but rc2 deployed by mistake)." >&2
    echo "  Fix: pass --manifest <f>.manifest.json (preferred) or --no-verify (explicit)." >&2
    exit 5
fi
# ===========================================================================

echo "==== $LABEL @ $BOARD_IP — role=$ROLE strap=$STRAP ctrl=$CTRL bitstream=$BIN ===="

# 1+2. Copy artefacts + load bitstream via fpga_manager, with verify+retry.
#
# Bug #12 (deploy-race misread as silicon): sshpass+scp/ssh is single-shot;
# a transient ssh failure used to leave the board with NO bitstream loaded
# but deploy_pair.sh would still exit 0 because `set -e` only catches the
# final command's rc, and any caller running deploy_pair under
# `>/dev/null 2>&1` (e.g. bringup_pair_converge.sh::deploy_one) would
# silently misread the resulting dead board as a silicon/RTL bug.
#
# Fix: explicit verify of /sys/class/fpga_manager/fpga0/state == "operating"
# after load_overlay, with up to MAX_LOAD_ATTEMPTS retries. Failures are
# echoed to STDERR (not stdout) so wrappers that do `>/dev/null` but not
# `2>&1` (the recommended pattern) still see them. Final hard-fail with
# distinctive marker so log-greppers can spot it from miles away.
MAX_LOAD_ATTEMPTS="${MAX_LOAD_ATTEMPTS:-2}"
load_attempt=1
loaded=0
while [ "$load_attempt" -le "$MAX_LOAD_ATTEMPTS" ]; do
    # 1. Copy artefacts (renaming on the board to the canonical name so
    #    fpga_manager always loads from /lib/firmware/tidelink.bin).
    if ! sshpass -p "$PASS" scp $SSHCOMMON \
            "$ARTEFACTS/$BIN" \
            "xilinx@$BOARD_IP:/tmp/tidelink.bin" >&2; then
        echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: scp .bin attempt $load_attempt/$MAX_LOAD_ATTEMPTS failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    if ! sshpass -p "$PASS" scp $SSHCOMMON \
            "$ARTEFACTS/$HWH" \
            "xilinx@$BOARD_IP:/tmp/tidelink.hwh" >&2; then
        echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: scp .hwh attempt $load_attempt/$MAX_LOAD_ATTEMPTS failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    # 2. Load bitstream via Linux fpga_manager
    if ! sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
            "echo '$PASS' | sudo -S sh -c '
                cp /tmp/tidelink.bin /lib/firmware/tidelink.bin
                cp /tmp/tidelink.hwh /lib/firmware/tidelink.hwh
                echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware
                sleep 1
                printf \"  fpga_manager: %s\n\" \"\$(cat /sys/class/fpga_manager/fpga0/state)\"
            '"; then
        echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: load_overlay ssh attempt $load_attempt/$MAX_LOAD_ATTEMPTS failed" >&2
        load_attempt=$((load_attempt+1)); continue
    fi
    # Bug #12 verify: re-read fpga_manager state out-of-band. The printf
    # above is informational only; this read is the load-of-record. We use
    # a fresh ssh so any cached/buffered transport problem fails here, not
    # silently in the load step above.
    state=$(sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
        "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null" 2>/dev/null \
        | tr -d '[:space:]')
    if [ "$state" = "operating" ]; then
        loaded=1
        break
    fi
    echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: fpga_manager state='$state' (expected 'operating') attempt $load_attempt/$MAX_LOAD_ATTEMPTS" >&2
    load_attempt=$((load_attempt+1))
    sleep 1
done
if [ "$loaded" -ne 1 ]; then
    echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: GIVING UP after $MAX_LOAD_ATTEMPTS load attempts — board NOT in 'operating' state" >&2
    exit 3
fi

# 3. Configure straps + address translator + per-lane phase. PAIR_BASE_ADDR
#    is the base address the local FC uses when sending doorbell / credit
#    frames to the peer (frame target = pair_base_addr + reg_offset).
#    Both boards have TideLink APB at the SAME local address 0x44032000,
#    so each peer's PAIR_BASE_ADDR points to that same value.
#
#    PHASE 3 AUTONOMY CHANGES (awaiting HW gate, see Phase 3 of
#    docs/ASIC_FPGA_IDENTICAL_AUTONOMOUS_BRINGUP_PLAN_2026_05_29.md):
#    - ROLE_CFG W1S write (was 0x44032080) REMOVED. The autoneg FSM
#      now drives role_lock autonomously after the I²C mask handshake
#      (NEGO_CFG_RESET=0x61 + NEGO_TRAIN_CFG_RESET=0x0001 at POR —
#      see commits fb4d70d / fe95c46).
#    - Wlink 0x208 swreset triplet REMOVED. The autoneg FSM's
#      local_swreset_pulse_w re-arms the calibrator inside the chiplet
#      controller (commit fb4d70d). Discovery 1 hypothesis: the 5 ms
#      0x208[3] pulse this script used to issue was an FCSM-level
#      recovery rendered obsolete by the calibrator fix at 85f0e48
#      (Fix A2+B). If HW deploy shows the link wedged after this
#      change, restore the 0x208 triplet — that indicates the FCSM
#      reset is still needed and the autoneg FSM should also drive
#      Wlink swreset (Discovery 1 hypothesis (b) — a new gap).
#    - Straps + swi_phase_offset + PAIR_BASE_ADDR kept (Phases 4-5).
sshpass -p "$PASS" ssh $SSHCOMMON xilinx@$BOARD_IP \
    "echo '$PASS' | sudo -S python3 -c '
import mmap,struct,os
P=4096; fd=os.open(\"/dev/mem\",os.O_RDWR|os.O_SYNC)
def mm(a):
    b=a&~(P-1); return mmap.mmap(fd,P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=b),(a-b)
s,so=mm(0x44040000)              # strap GPIO (Phase 6: bond-pad emulation)
struct.pack_into(\"<I\",s,so,$STRAP)
# Phase 4 deletion candidate: debug_unlock GPIO. Production silicon ties
# apb_debug_unlock_i to 0; FPGA today asserts it so the local PYNQ APB
# can reach Wlink on the slave side. Kept pending HW verification that
# the autoneg-driven role_lock + mask_hs_match path leaves the debug
# strap unused.
d,do=mm(0x44041000)              # debug_unlock GPIO
struct.pack_into(\"<I\",d,do,1)
r,ro=mm(0x44032000)              # TideLink APB (chiplet-controller @+0x80)
w,wo=mm(0x44030000)              # Wlink APB (PHY ctrl @+0x00)
struct.pack_into(\"<I\",r,ro+0x00,0x44032000)   # PAIR_BASE_ADDR (Phase 5: → TIDELINK_PAIR_BASE param)
# SHORTCOMINGS-14b: write swi_phase_offset BEFORE role_lock asserts.
# Two reset domains:
#   - swi_phase_offset reg has reset = apb_reset (~hresetn) — always low
#     during normal operation, so APB writes ALWAYS land regardless of
#     role_lock state.
#   - WavD2DGpioRx.count reg has reset = io_por_reset (= wlink_por =
#     ~poresetn | ~role_locked). Resets to 4hF while role_lock=0;
#     starts incrementing the moment role_lock=1.
# So the only chance to influence the deserialiser counter alignment
# is to have the right swi_phase_offset value LOADED before role_lock
# asserts. With Phase 3 autonomy, role_lock now asserts ~10-20 ms after
# this script writes the phase offset (autoneg I²C latency), so the
# ordering still holds — phase is loaded long before role_lock fires.
struct.pack_into(\"<I\",w,wo+0x00,$PHASE)        # PHY ctrl swi_phase_offset (Phase 5: → calibrator output or strap)
phy=struct.unpack_from(\"<I\",w,wo+0x00)[0]
pba=struct.unpack_from(\"<I\",r,ro+0x00)[0]
val=struct.unpack_from(\"<I\",r,ro+0x80)[0]
print(\"  PHY_CTRL       = 0x{:08x} (swi_phase_offset={})\".format(phy,(phy>>17)&0xF))
print(\"  PAIR_BASE_ADDR = 0x{:08x}\".format(pba))
print(\"  ROLE_CFG       = 0x{:02x} (lock={}, cfg={}) — expect lock=0 here; autoneg FSM latches it ~10-20 ms post-deploy\".format(val,(val>>1)&1,val&1))
'"

# --- Layer 3: provenance ledger ------------------------------------------
# Append one JSON line per deploy to <ARTEFACTS>/deployed.json so "what is
# actually loaded right now" is always answerable after the fact. Best-effort:
# a ledger write must never fail an otherwise-good deploy.
LEDGER="${TIDELINK_LEDGER:-$ARTEFACTS/deployed.json}"
{
    printf '{"timestamp":"%s","board":"%s","ip":"%s","role":"%s","bin":"%s","sha256":"%s","source_path":"%s","label":"%s","commit":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LABEL" "$BOARD_IP" "$ROLE" \
        "$BIN" "${ACTUAL_SHA:-unknown}" "$STAGED_BIN" \
        "${MANIFEST_LABEL:-unverified}" "${MANIFEST_COMMIT:-unknown}" \
        >> "$LEDGER"
} 2>/dev/null || echo "WARNING: could not write provenance ledger $LEDGER" >&2

echo "==== $LABEL done (sha256=${ACTUAL_SHA:0:12}… label=${MANIFEST_LABEL:-unverified}) ===="
