#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### verify_asic_fileset_image.sh - prove, from the TOOL'S OWN OUTPUT, that a
### bitstream was built from the ASIC (tapeout) file set.
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### A flist line is not evidence. Neither is a build banner: both are things the
### build SAID it would do. This asks the tools which files they actually read
### and what actually ended up in the netlist.
###
### The chain, closed end to end:
###   repo ASIC source --package_ip--> imp/fpga/tidelink_ip/src --BD import-->
###   tidelink_project.gen/.../ipshared/<hash>/src --synth--> netlist
###
### [1] Vivado's own "[Synth 8-6157] synthesizing module '<m>' [<file>:<line>]"
###     lines. Vivado names the file for only SOME modules (it does not emit
###     8-6157 for the WlinkGenericFCSM* copies - checked, not assumed), but the
###     ones it does name establish WHICH DIRECTORY this synthesis run read.
### [2] sha256 of every divergent file in THAT directory against the ASIC source.
###     [1] identifies the directory from tool output; [2] says what was in it.
### [3] sha256 of the packaged IP's imported copy, so a divergence introduced at
###     either hop is localised rather than merely detected.
### [4] grep -c socl_ on the synthesised copy, run in BOTH directions: the same
###     grep on the FPGA twin MUST return non-zero, or "0 hits" is a dead grep.
### [5] --netlist: post-synthesis cell census. The strongest check and the only
###     one that inspects the actual hardware. Every marker is a FLOP (a netlist
###     grep for a `wire` is an unconditional zero), every "absent" is paired
###     with a must-be-present control on the same path, and the same search
###     must find cells in FCSM_6 - which both flists take from local_overrides
###     - or the search string is dead.
###
### usage: verify_asic_fileset_image.sh [TARGET] [--netlist]
###-----------------------------------------------------------------------------
set -u
TARGET="kr260-pair-onchip"
DO_NETLIST=0
for a in "$@"; do
    case "$a" in
        --netlist) DO_NETLIST=1 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *)  TARGET="$a" ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$HERE/../.." && pwd)"
RUNS="$TIDELINK_HOME/imp/fpga/project/$TARGET/tidelink_project.runs"
GEN="$TIDELINK_HOME/imp/fpga/project/$TARGET/tidelink_project.gen"
IPSRC="$TIDELINK_HOME/imp/fpga/tidelink_ip/src"
OUT="$TIDELINK_HOME/imp/fpga/output/$TARGET"
SYNTHDIR="$RUNS/tidelink_design_tidelink_0_0_synth_1"

DEPS="$TIDELINK_HOME/deps/axi-chiplet-controller/logical/wlink"
I2C="$TIDELINK_HOME/deps/axi-chiplet-controller/logical/i2c/rtl"
OVR="$TIDELINK_HOME/src/rtl/local_overrides"

DIVERGENT="WlinkGenericFCSM.v WlinkGenericFCSM_1.v WlinkGenericFCSM_2.v
WlinkGenericFCSM_3.v WlinkGenericFCSM_4.v WlinkGenericFCReplayAddrSync_18.v
WlinkGenericFCReplayV2_7.v WlinkGenericFCReplayV2_9.v i2c_master.v
tidelink_sram.sv"
FCSMS="WlinkGenericFCSM.v WlinkGenericFCSM_1.v WlinkGenericFCSM_2.v
WlinkGenericFCSM_3.v WlinkGenericFCSM_4.v"

asic_src_for(){
    case "$1" in
        i2c_master.v)     echo "$I2C/i2c_master.v" ;;
        tidelink_sram.sv) echo "$TIDELINK_HOME/src/rtl/fifo/asic/tidelink_sram.sv" ;;
        *)                echo "$DEPS/$1" ;;
    esac
}

FAIL=0
note(){ printf '  %-36s %s\n' "$1" "$2"; }
bad(){  printf '  %-36s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

echo "============================================================"
echo " ASIC FILE-SET IMAGE VERIFICATION - target $TARGET"
echo "============================================================"

SYNTHLOG="$SYNTHDIR/runme.log"
if [ ! -f "$SYNTHLOG" ]; then
    echo "UNKNOWN: no tidelink OOC synthesis log at $SYNTHLOG"
    echo "         Nothing to verify. This is NOT a pass."
    exit 2
fi
if ! grep -q "synth_design completed successfully" "$SYNTHLOG"; then
    echo "UNKNOWN: $SYNTHLOG does not say 'synth_design completed successfully'"
    echo "         An unfinished synthesis proves nothing. This is NOT a pass."
    exit 2
fi
echo "synthesis log: $SYNTHLOG"
echo ""

# --- [1] which directory did the tool read? -------------------------------
echo "[1] Vivado naming the source directory it read (its own 8-6157 lines)"
SRCDIR=""
for m in tidelink_sram i2c_master rf_16k tidelink_top; do
    line="$(grep -F "[Synth 8-6157] synthesizing module '$m'" "$SYNTHLOG" | head -1)"
    if [ -z "$line" ]; then
        note "$m" "(not named by 8-6157)"
        continue
    fi
    path="$(printf '%s' "$line" | sed -n 's/.*\[\(\/[^]]*\):[0-9]*\]$/\1/p')"
    note "$m" "$path"
    [ -z "$SRCDIR" ] && SRCDIR="$(dirname "$path")"
done
if [ -z "$SRCDIR" ] || [ ! -d "$SRCDIR" ]; then
    bad "source directory" "could not be established from the synthesis log"
    SRCDIR="$GEN/sources_1/bd/tidelink_design/ipshared"
fi
echo "  -> synthesis read from: $SRCDIR"
echo ""

# --- [2] what was in that directory? --------------------------------------
echo "[2] sha256 of each divergent file THERE vs the ASIC source"
for f in $DIVERGENT; do
    p="$SRCDIR/$f"; a="$(asic_src_for "$f")"
    if [ ! -f "$p" ]; then bad "$f" "absent from the synthesised source dir"; continue; fi
    if [ ! -f "$a" ]; then bad "$f" "ASIC source missing: $a"; continue; fi
    hp="$(sha256sum "$p" | cut -d' ' -f1)"; ha="$(sha256sum "$a" | cut -d' ' -f1)"
    ho="$(sha256sum "$OVR/$f" 2>/dev/null | cut -d' ' -f1)"
    if [ "$hp" = "$ha" ]; then
        note "$f" "${hp:0:16} == ASIC"
    elif [ -n "$ho" ] && [ "$hp" = "$ho" ]; then
        bad "$f" "${hp:0:16} == FPGA TWIN - this is NOT the tapeout copy"
    else
        bad "$f" "${hp:0:16} matches neither ASIC nor FPGA source"
    fi
done
echo ""

# --- [3] packaged IP hop --------------------------------------------------
echo "[3] sha256 of the packaged IP's imported copy vs the ASIC source"
for f in $DIVERGENT; do
    p="$IPSRC/$f"; a="$(asic_src_for "$f")"
    if [ ! -f "$p" ]; then bad "$f" "absent from packaged IP"; continue; fi
    if [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$(sha256sum "$a" | cut -d' ' -f1)" ]; then
        note "$f" "MATCHES"
    else
        bad "$f" "DIFFERS from $a"
    fi
done
echo ""

# --- [4] socl_ source census, both directions -----------------------------
echo "[4] socl_ census on the synthesised copy (0 = tapeout, ~72 = FPGA twin)"
for f in $FCSMS; do
    p="$SRCDIR/$f"
    [ -f "$p" ] || { bad "$f" "no synthesised copy to census"; continue; }
    n="$(grep -c socl_ "$p")"
    # MUST-BE-PRESENT CONTROL for the grep itself.
    c="$(grep -c socl_ "$OVR/$f" 2>/dev/null || echo 0)"
    if [ "$c" -eq 0 ]; then
        bad "$f" "CONTROL FAILED: 0 socl_ in the FPGA twin too - dead grep"
    elif [ "$n" -eq 0 ]; then
        note "$f" "0 socl_ (control: FPGA twin has $c) -> TAPEOUT copy"
    else
        bad "$f" "$n socl_ hits -> FPGA twin, NOT the tapeout copy"
    fi
done
echo ""

# --- [5] declared substitutions -------------------------------------------
echo "[5] declared substitutions"
if [ -f "$SRCDIR/rf_16k_fpga.v" ]; then
    note "rf_16k" "SUBSTITUTED <- fpga/asic_fileset/rf_16k_fpga.v (hard macro, no ASIC RTL exists)"
else
    bad "rf_16k" "substitute absent - what supplied the memory?"
fi
if grep -qF "cmsdk_fpga_sram" "$SRCDIR/tidelink_sram.sv" 2>/dev/null; then
    bad "tidelink_sram.sv" "instantiates cmsdk_fpga_sram - this is the FPGA wrapper"
else
    note "tidelink_sram.sv" "instantiates rf_16k - ASIC wrapper, verbatim"
fi
echo ""

# --- [6] netlist census (opt-in; needs Vivado) ----------------------------
if [ "$DO_NETLIST" = 1 ]; then
    echo "[6] post-synthesis netlist cell census"
    DCP="$SYNTHDIR/tidelink_design_tidelink_0_0.dcp"
    if [ ! -f "$DCP" ]; then
        bad "netlist" "no checkpoint at $DCP"
    else
        CENSUS="$TIDELINK_HOME/imp/asicfpga/census_$TARGET.txt"
        mkdir -p "$(dirname "$CENSUS")"
        ( cd "$(dirname "$CENSUS")" && TL_DCP="$DCP" \
            vivado -mode batch -source "$HERE/asic_fileset_netlist_census.tcl" \
                   -log census.log -journal census.jou 2>&1 ) \
            | grep -E "^CENSUS" > "$CENSUS"
        if ! grep -q CENSUS_DONE "$CENSUS"; then
            bad "netlist" "census did not complete (see $CENSUS)"
        else
            sed 's/^/  /' "$CENSUS"
            # controls first: a zero control voids every count below it
            if grep -q "CENSUS_CONTROL .* = 0$" "$CENSUS"; then
                bad "netlist control" "a state_reg control read 0 - hierarchy path wrong, census vacuous"
            fi
            xc="$(sed -n 's/^CENSUS_XCHECK .* = \([0-9]*\)$/\1/p' "$CENSUS")"
            if [ "${xc:-0}" -eq 0 ]; then
                bad "netlist cross-check" "socl_* found NOWHERE, not even in FCSM_6 - dead search"
            fi
            # every marker must be 0 inside the five AXI nodes
            while read -r _ name rest; do
                v="$(printf '%s' "$rest" | sed -n 's/^in_axi_nodes=\([0-9]*\).*/\1/p')"
                [ "${v:-0}" -eq 0 ] || bad "netlist $name" "$v cells in the AXI FC nodes - recovery IS present"
            done < <(grep '^CENSUS_MARKER' "$CENSUS")
        fi
    fi
    echo ""
fi

# --- [7] artefact identity ------------------------------------------------
echo "[7] artefact sha256 - PIN BY THIS."
echo "    The manifest's git_dirty is FAIL-OPEN on this branch: tl_git_sha"
echo "    returns bare \"unknown\" on rev-parse failure and its git-status catch"
echo "    short-circuits, so an indeterminate tree stamps git_dirty:false. The"
echo "    fix (df0f1f24) is NOT an ancestor here - it lives only on rev2/hygiene."
for f in "$OUT"/*.bit "$OUT"/*.bin "$OUT"/tidelink_manifest.json; do
    [ -f "$f" ] && printf '  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
echo ""

echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    echo " RESULT: VERIFIED - every divergent module came from the ASIC file set."
    exit 0
fi
echo " RESULT: $FAIL CHECK(S) FAILED - NOT proven to be the ASIC file set."
exit 1
