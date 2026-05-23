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
MAX_RETRIES="${MAX_RETRIES:-12}"
SETTLE="${SETTLE:-2}"         # seconds after recal (S_HOLD is sub-10ms @25MHz,
                              #  HOLD_CYCLES=8*128*32=32768 cyc; 2s ≫ that)
BESTOF="${BESTOF:-3}"         # quick reads/iter; report BEST popcount (locked
                              #  legitimately bounces — never demand N-equal)
POLL_GAP="${POLL_GAP:-0.4}"
RECAL_HOLD="${RECAL_HOLD:-0.25}"
# SWAP=1 : deploy die_b(flip) to MASTER_IP and die_a(non-flip) to SLAVE_IP
#          (role/bitstream swap — the physical-vs-logical discriminator for
#           the dead RX direction; needs NO rebuild).
SWAP="${SWAP:-0}"

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

# Best-of-N read. `locked` legitimately bounces every read (the calibrator
# continuously re-sweeps — fault=0x00), so demanding N-equal-in-a-row was
# v1's bug: it returned an arbitrary transient. Instead take BESTOF quick
# samples and keep the one with the most lanes locked (+ its cal/fcsm/cr).
best_read() {  # IP -> echoes the best status line of BESTOF reads
    local IP=$1 s pc best="" bestpc=-1 n=0
    while [ "$n" -lt "$BESTOF" ]; do
        s=$(read_status "$IP")
        if [ -n "$s" ]; then
            pc=$(echo "$s" | awk '{print $4+0}')
            if [ "${pc:-0}" -gt "$bestpc" ] 2>/dev/null; then bestpc=$pc; best="$s"; fi
        fi
        n=$((n+1)); [ "$n" -lt "$BESTOF" ] && sleep "$POLL_GAP"
    done
    echo "$best"
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

# Deploy one board for a given role. deploy_pair.sh maps ROLE->bitstream
# (die_a=tidelink.bin non-flip, die_b=tidelink-flip.bin) + strap + phase.
#
# Bug #12 wrapper: deploy_pair.sh's chatty stdout is uninteresting per
# iteration (PHY_CTRL/PAIR_BASE/ROLE_CFG echo) so we drop stdout, but we
# DELIBERATELY KEEP STDERR so "DEPLOY-FAIL: ..." markers from the verify+
# retry block reach the iteration log. v1 of this wrapper had >/dev/null
# 2>&1 which silently hid scp/load failures and made dead boards look
# like silicon bugs ("deploy-race misread as silicon").
deploy_one() {  # IP ROLE PHASEVAL
    # Force the deploy to use the staged manifest if one is present (the
    # default location). This kills the Bug #32 / 2026-05-23 link-decay-
    # bisect class of "wrong bin in /tmp/tidelink_deploy/" bug at source:
    # deploy_pair.sh either matches the manifest sha and proceeds, or
    # aborts with rc=4 / 5 and the iteration is FAIL — never a silent
    # flash of the stale bin. To deploy without a manifest, set
    # DEPLOY_PAIR_NOVERIFY=1 explicitly (e.g. local sandbox experiments).
    local _bin="tidelink.bin"
    [ "$2" = "die_b" ] && _bin="tidelink-flip.bin"
    local _manifest_flag=""
    if [ -f "$ARTEFACTS/$_bin.manifest.json" ]; then
        _manifest_flag="--manifest $ARTEFACTS/$_bin.manifest.json"
    elif [ "${DEPLOY_PAIR_NOVERIFY:-0}" = "1" ]; then
        _manifest_flag="--no-verify"
    fi
    PHASE_OVERRIDE=$(printf 0x%08x "$3") \
        bash "$DEPLOY_PAIR" "$1" z2_$2 "$2" "$ARTEFACTS" $_manifest_flag >/dev/null
}

# ---------------------------------------------------------------------------
# Role assignment. Normal: MASTER_IP=die_a(non-flip), SLAVE_IP=die_b(flip).
# SWAP=1: MASTER_IP=die_b(flip), SLAVE_IP=die_a(non-flip) — the physical-vs-
# logical discriminator. v1 HW showed the die_a/non-flip RX (clock on Y7-
# MRCC) DEAD and die_b/flip RX (clock on Y9-SRCC) alive. If after SWAP the
# dead RX FOLLOWS THE IP/board -> physical (that board's Y7 pin / that
# ribbon conductor). If it FOLLOWS THE ROLE/bitstream -> logical (the
# non-flip target's RX path). Decisive; needs NO rebuild.
if [ "$SWAP" = "1" ]; then
    A_IP=$SLAVE_IP;  A_LBL="SLAVE_IP($SLAVE_IP)"   # die_a -> the slave IP
    B_IP=$MASTER_IP; B_LBL="MASTER_IP($MASTER_IP)" # die_b -> the master IP
    MODE="SWAPPED (die_a->$SLAVE_IP, die_b->$MASTER_IP)"
else
    A_IP=$MASTER_IP; A_LBL="MASTER_IP($MASTER_IP)"
    B_IP=$SLAVE_IP;  B_LBL="SLAVE_IP($SLAVE_IP)"
    MODE="NORMAL (die_a->$MASTER_IP, die_b->$SLAVE_IP)"
fi

echo "=============================================================="
echo " TideLink coordinated closed-loop bring-up  $(date)"
echo "  $MODE"
echo "  die_a=$A_LBL (non-flip, RX-clk Y7-MRCC)  phase mp=$MP"
echo "  die_b=$B_LBL (flip,     RX-clk Y9-SRCC)  phase sp=$SP"
echo "  MAX_RETRIES=$MAX_RETRIES SETTLE=${SETTLE}s BESTOF=$BESTOF"
echo "  RTL: T3+S_HOLD calibrator + IDELAYE2 + FCSM-sticky (td-combined)"
echo "  v2: RE-DEPLOY per iteration (re-rolls role_lock/count skew — the"
echo "      actual lottery variable; v1's one-deploy-many-recal could not"
echo "      since swreset/recal does NOT re-sync WavD2DGpioRx.count)."
echo "=============================================================="

# Reachability pre-flight (fail fast, do not run a half-pair).
for ip in "$A_IP" "$B_IP"; do
    sshpass -p "$PASS" ssh $SSHCOMMON "xilinx@$ip" true 2>/dev/null \
        || fail "board $ip unreachable over SSH (check lease GRANTED + board up)"
done

# --- Provenance banner (Bug #32) -------------------------------------------
# Before the deploy loop, show EXACTLY what is about to be flashed: the
# sha256 (first 12) of each staged bitstream and, if a sibling manifest
# exists, its label/commit/expected_lock_min. This is the loud answer to
# "are we deploying the right bitstream?" that was missing when the May-6
# phase-v2 (MD5 188ebdd8, known-0/16) build got deployed blindly.
mf_field() {  # FILE FIELD -> string value or ""
    [ -f "$1" ] || { echo ""; return; }
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$1" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//'
}
mf_num() {   # FILE FIELD -> numeric value or ""
    [ -f "$1" ] || { echo ""; return; }
    grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" "$1" 2>/dev/null \
        | head -1 | sed 's/.*:[[:space:]]*//'
}
banner_for() {  # BINNAME
    local bin="$1" path="$ARTEFACTS/$1" mf sha label commit lockmin
    if [ ! -f "$path" ]; then echo "  $bin: <NOT STAGED in $ARTEFACTS>"; return; fi
    sha=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
    mf="${path}.manifest.json"
    if [ -f "$mf" ]; then
        label=$(mf_field "$mf" label); commit=$(mf_field "$mf" source_commit)
        lockmin=$(mf_num "$mf" expected_lock_min)
        local mfsha; mfsha=$(mf_field "$mf" sha256)
        if [ -n "$mfsha" ] && [ "$mfsha" != "$sha" ]; then
            echo "  $bin: sha256 ${sha:0:12}… ** MISMATCHES MANIFEST ${mfsha:0:12}… ** (label=${label:-?})"
            echo "  *** WARNING: staged $bin does NOT match its manifest — deploy will ABORT (Bug #32 guard) ***" >&2
        else
            echo "  $bin: sha256 ${sha:0:12}…  label=${label:-?}  commit=${commit:-?}  expect_lock>=${lockmin:-?}"
        fi
    else
        echo "  $bin: sha256 ${sha:0:12}…  (NO MANIFEST — provenance UNVERIFIED)"
    fi
}
echo "=============================================================="
echo " PROVENANCE — bitstreams about to be deployed (from $ARTEFACTS):"
banner_for tidelink.bin
[ -f "$ARTEFACTS/tidelink-flip.bin" ] && banner_for tidelink-flip.bin
echo "=============================================================="

printf '%-4s | %-30s | %-30s | %s\n' IT \
    "die_a@${A_IP##*.} lk/ft cal# fs cr" "die_b@${B_IP##*.} lk/ft cal# fs cr" "tot/16"

best=-1; best_it=0; best_line=""; conv_it=0
for it in $(seq 1 "$MAX_RETRIES"); do
    # v2 core fix: re-deploy BOTH in parallel each iteration. Each deploy
    # reloads the bitstream (fresh POR) and re-asserts role_lock, so
    # WavD2DGpioRx.count is re-rolled — the one variable that actually
    # gates word alignment and that recal alone cannot move.
    # Bug #13: persist per-child rc via tempfile so completion ORDER does
    # not matter. The previous `wait $ap; arc=$?; wait $bp; brc=$?` pattern
    # returned rc=127 ("not a child of this shell") for whichever finished
    # FIRST if its PID was already reaped by the second `wait`. That made
    # the WARN line cosmetic-noisy and indistinguishable from a real deploy
    # failure. The tempfile pattern (subshell writes its rc into a known
    # file) is robust against any completion order and against `set -u`.
    rc_a=$(mktemp -t tdli_a_rc.XXXXXX); rc_b=$(mktemp -t tdli_b_rc.XXXXXX)
    ( deploy_one "$A_IP" die_a "$MPV" ; echo $? > "$rc_a" ) & ap=$!
    ( deploy_one "$B_IP" die_b "$SPV" ; echo $? > "$rc_b" ) & bp=$!
    wait "$ap" "$bp"
    arc=$(cat "$rc_a" 2>/dev/null); brc=$(cat "$rc_b" 2>/dev/null)
    rm -f "$rc_a" "$rc_b"
    : "${arc:=99}"; : "${brc:=99}"
    [ "$arc" -eq 0 ] || echo "  WARN it=$it: die_a@$A_IP deploy rc=$arc"
    [ "$brc" -eq 0 ] || echo "  WARN it=$it: die_b@$B_IP deploy rc=$brc"
    sleep 1
    recal_cycle
    AR=$(best_read "$A_IP")
    BR=$(best_read "$B_IP")
    alk=$(echo "$AR" | awk '{print $1}'); aft=$(echo "$AR" | awk '{print $2}')
    acd=$(echo "$AR" | awk '{print $3}'); apc=$(echo "$AR" | awk '{print $4}')
    afs=$(echo "$AR" | awk '{print $5}'); acr=$(echo "$AR" | awk '{print $6}')
    blk=$(echo "$BR" | awk '{print $1}'); bft=$(echo "$BR" | awk '{print $2}')
    bcd=$(echo "$BR" | awk '{print $3}'); bpc=$(echo "$BR" | awk '{print $4}')
    bfs=$(echo "$BR" | awk '{print $5}'); bcr=$(echo "$BR" | awk '{print $6}')
    apc=${apc:-0}; bpc=${bpc:-0}
    tot=$(( apc + bpc ))
    printf '%-4s | %-30s | %-30s | %s\n' "$it" \
        "${alk:-?}/${aft:-?} ${apc} ${acd:-?} fs${afs:-?} cr${acr:-?}" \
        "${blk:-?}/${bft:-?} ${bpc} ${bcd:-?} fs${bfs:-?} cr${bcr:-?}" \
        "$tot"
    if [ "$tot" -gt "$best" ] 2>/dev/null; then
        best=$tot; best_it=$it
        best_line="die_a@$A_IP[$AR]  die_b@$B_IP[$BR]"
    fi
    if [ "$apc" -eq 8 ] 2>/dev/null && [ "$bpc" -eq 8 ] 2>/dev/null \
       && [ "${acd:-0}" -eq 1 ] 2>/dev/null && [ "${bcd:-0}" -eq 1 ] 2>/dev/null; then
        conv_it=$it
        break
    fi
done

echo "=============================================================="
if [ "$conv_it" -gt 0 ]; then
    echo "RESULT: CONVERGED — full 16/16 bidirectional link at iteration $conv_it"
    echo "  $best_line"
    echo "  (Doorbell / AHB_TX end-to-end is a SEPARATE step — wedge hazard.)"
    exit 0
else
    echo "RESULT: NOT CONVERGED in $MAX_RETRIES re-deploys ($MODE)."
    echo "  Best seen: ${best}/16 at iteration $best_it"
    echo "  $best_line"
    echo "  Interpretation (v1 already proved S_HOLD/T3/IDELAYE2 ARE in"
    echo "  this bitstream — do NOT re-question that):"
    echo "   * one side stuck ~0 across ALL re-deploys, other side alive:"
    echo "       a stable DIRECTIONAL dead. If SWAP flips which IP is dead"
    echo "       -> the dead is tied to die_a/non-flip RX path (logical)."
    echo "       If the SAME IP stays dead under SWAP -> that board's"
    echo "       physical Y7 RX pin / that ribbon conductor (physical)."
    echo "   * best climbs with re-deploys then plateaus high (12-15/16):"
    echo "       per-lane sub-UI / IDELAYE2-tap ceiling — characterise the"
    echo "       named stuck lane(s) (fault byte)."
    echo "   * both alive but neither reaches 8 and uncorrelated: residual"
    echo "       count-skew beyond calibrator range — needs the unbuilt"
    echo "       comma/word-realign (T3a), not more deploys."
    exit 1
fi
