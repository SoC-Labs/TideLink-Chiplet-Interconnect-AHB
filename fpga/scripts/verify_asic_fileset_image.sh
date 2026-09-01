#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### verify_asic_fileset_image.sh - prove, from the SYNTHESIS TOOL'S OWN OUTPUT,
### that a bitstream was built from the ASIC (tapeout) file set.
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
### build SAID it would do. This script asks Vivado which PHYSICAL FILE it
### actually parsed for each of the ten modules the two file lists resolve
### differently, by grepping the OOC synthesis run's own log, and cross-checks
### the packaged IP's imported copy by sha256.
###
### Four independent lines of evidence, all required. The chain is closed end
### to end, from the repo source to the file the synthesiser actually opened:
###
###   repo ASIC source --package_ip--> tidelink_ip/src --BD import-->
###   tidelink_project.gen/.../ipshared/<hash>/src --synth--> netlist
###
###   1. Vivado's own "[Synth 8-6157] synthesizing module '<m>' [<file>:<line>]"
###      lines in the tidelink OOC synthesis run log. This is the TOOL saying
###      which physical file each module came from - not a flist, not a banner.
###   2. sha256 of the file named in (1) - the ipshared copy the synthesiser
###      opened - against the ASIC source on disk. This closes the chain; (1)
###      alone only proves a path was opened, not what was in it.
###   3. sha256 of the packaged IP's imported copy against the same ASIC
###      source, so a divergence introduced at either hop is localised.
###   4. grep -c socl_ on the synthesised copy -> ZERO for a real ASIC FCSM,
###      ~72 for the FPGA twin. Run in BOTH directions: the same grep on the
###      FPGA twin MUST return non-zero, or "0 hits" is a dead grep proving
###      nothing. (A netlist grep for a wire is an unconditional zero; this is
###      a SOURCE grep with its own must-be-present control.)
###
### usage: verify_asic_fileset_image.sh [TARGET]     (default kr260-pair-onchip)
###-----------------------------------------------------------------------------
set -u
TARGET="${1:-kr260-pair-onchip}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$HERE/../.." && pwd)"
RUNS="$TIDELINK_HOME/imp/fpga/project/$TARGET/tidelink_project.runs"
IPSRC="$TIDELINK_HOME/imp/fpga/tidelink_ip/src"
OUT="$TIDELINK_HOME/imp/fpga/output/$TARGET"

DEPS="$TIDELINK_HOME/deps/axi-chiplet-controller/logical/wlink"
I2C="$TIDELINK_HOME/deps/axi-chiplet-controller/logical/i2c/rtl"
OVR="$TIDELINK_HOME/src/rtl/local_overrides"

FAIL=0
note(){ printf '  %-52s %s\n' "$1" "$2"; }
bad(){ printf '  %-52s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

echo "============================================================"
echo " ASIC FILE-SET IMAGE VERIFICATION - target $TARGET"
echo "============================================================"

# --- locate the tidelink OOC synth log ------------------------------------
SYNTHLOG="$(ls "$RUNS"/tidelink_design_tidelink_0_0_synth_1/runme.log 2>/dev/null | head -1)"
if [ -z "$SYNTHLOG" ] || [ ! -f "$SYNTHLOG" ]; then
    echo "UNKNOWN: no tidelink OOC synthesis log under $RUNS"
    echo "         Nothing to verify - this is NOT a pass."
    exit 2
fi
echo "synthesis log: $SYNTHLOG"
echo ""

# --- (1)+(2) which physical file did the TOOL open, and what was in it? ---
DIVERGENT="WlinkGenericFCSM.v WlinkGenericFCSM_1.v WlinkGenericFCSM_2.v \
WlinkGenericFCSM_3.v WlinkGenericFCSM_4.v WlinkGenericFCReplayAddrSync_18.v \
WlinkGenericFCReplayV2_7.v WlinkGenericFCReplayV2_9.v i2c_master.v \
tidelink_sram.sv"

asic_src_for(){
    case "$1" in
        i2c_master.v)     echo "$I2C/i2c_master.v" ;;
        tidelink_sram.sv) echo "$TIDELINK_HOME/src/rtl/fifo/asic/tidelink_sram.sv" ;;
        *)                echo "$DEPS/$1" ;;
    esac
}

# module name -> expected source basename, for the 8-6157 lookup.
mod_for(){ echo "${1%.*}"; }

echo "[1] Vivado's own 'synthesizing module' lines (the tool naming the file)"
declare -A SYNTH_PATH
for f in $DIVERGENT rf_16k_fpga.v; do
    m="$(mod_for "$f")"
    [ "$f" = "rf_16k_fpga.v" ] && m="rf_16k"
    line="$(grep -F "[Synth 8-6157] synthesizing module '$m'" "$SYNTHLOG" | head -1)"
    if [ -z "$line" ]; then
        bad "$m" "NOT named by the synthesiser (cannot verify)"
        continue
    fi
    path="$(printf '%s' "$line" | sed -n 's/.*\[\(\/[^]]*\):[0-9]*\]$/\1/p')"
    if [ -z "$path" ]; then
        bad "$m" "8-6157 line present but path unparseable: $line"
        continue
    fi
    SYNTH_PATH[$f]="$path"
    note "$m" "$path"
done
echo ""

echo "[2] sha256 of the file the SYNTHESISER opened == ASIC source"
for f in $DIVERGENT; do
    p="${SYNTH_PATH[$f]:-}"
    a="$(asic_src_for "$f")"
    if [ -z "$p" ]; then bad "$f" "no synthesised path to hash"; continue; fi
    if [ ! -f "$p" ]; then bad "$f" "synthesised path does not exist: $p"; continue; fi
    if [ ! -f "$a" ]; then bad "$f" "ASIC source missing: $a"; continue; fi
    hp="$(sha256sum "$p" | cut -d' ' -f1)"
    ha="$(sha256sum "$a" | cut -d' ' -f1)"
    if [ "$hp" = "$ha" ]; then
        note "$f" "${hp:0:16}... == $a"
    else
        bad "$f" "synthesised ${hp:0:16}... != ASIC ${ha:0:16}... ($a)"
    fi
done
echo ""

# --- (2) sha256 of the packaged copy vs the ASIC source -------------------
echo "[3] packaged IP copy sha256 == ASIC source sha256"
cmp_sha(){ # name  asic_path
    local n="$1" a="$2" p="$IPSRC/$1"
    if [ ! -f "$p" ]; then bad "$n" "absent from packaged IP"; return; fi
    if [ ! -f "$a" ]; then bad "$n" "ASIC source missing: $a"; return; fi
    if [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$(sha256sum "$a" | cut -d' ' -f1)" ]; then
        note "$n" "MATCHES $a"
    else
        bad "$n" "DIFFERS from $a"
    fi
}
for m in WlinkGenericFCSM.v WlinkGenericFCSM_1.v WlinkGenericFCSM_2.v \
         WlinkGenericFCSM_3.v WlinkGenericFCSM_4.v \
         WlinkGenericFCReplayAddrSync_18.v WlinkGenericFCReplayV2_7.v \
         WlinkGenericFCReplayV2_9.v; do
    cmp_sha "$m" "$DEPS/$m"
done
cmp_sha i2c_master.v   "$I2C/i2c_master.v"
cmp_sha tidelink_sram.sv "$TIDELINK_HOME/src/rtl/fifo/asic/tidelink_sram.sv"
echo ""

# --- (3) socl_ census, BOTH directions ------------------------------------
echo "[4] socl_ recovery-marker census (0 = tapeout copy, ~72 = FPGA twin)"
for m in WlinkGenericFCSM.v WlinkGenericFCSM_1.v WlinkGenericFCSM_2.v \
         WlinkGenericFCSM_3.v WlinkGenericFCSM_4.v; do
    p="${SYNTH_PATH[$m]:-$IPSRC/$m}"
    [ -f "$p" ] || { bad "$m" "no synthesised copy to census"; continue; }
    n="$(grep -c socl_ "$p")"
    # MUST-BE-PRESENT CONTROL for the grep itself: the SAME grep on the FPGA
    # twin must return non-zero. A grep that returns 0 on both files is a dead
    # grep, and "0 hits" would prove nothing at all.
    c="$(grep -c socl_ "$OVR/$m" 2>/dev/null || echo 0)"
    if [ "$c" -eq 0 ]; then
        bad "$m" "CONTROL FAILED: grep found 0 socl_ in the FPGA twin too - dead grep"
    elif [ "$n" -eq 0 ]; then
        note "$m" "0 socl_ (control: FPGA twin has $c) -> TAPEOUT copy"
    else
        bad "$m" "$n socl_ hits -> this is the FPGA twin, NOT the tapeout copy"
    fi
done
echo ""

# --- (4) the substituted leaf, named out loud -----------------------------
echo "[5] declared substitutions"
if [ -f "$IPSRC/rf_16k_fpga.v" ]; then
    note "rf_16k" "SUBSTITUTED <- fpga/asic_fileset/rf_16k_fpga.v (hard macro, no ASIC RTL exists)"
else
    bad "rf_16k" "substitute absent from the packaged IP - what supplied the memory?"
fi
if grep -qF "cmsdk_fpga_sram" "$IPSRC"/tidelink_sram.sv 2>/dev/null; then
    bad "tidelink_sram.sv" "instantiates cmsdk_fpga_sram - this is the FPGA wrapper"
else
    note "tidelink_sram.sv" "instantiates rf_16k - ASIC wrapper, verbatim"
fi
echo ""

# --- (5) artefact identity ------------------------------------------------
echo "[6] artefact sha256 (pin by THIS, not by the manifest's git_dirty:"
echo "    tl_git_sha on this branch is still fail-open - df0f1f24 is not an ancestor)"
for f in "$OUT"/*.bit "$OUT"/*.bin "$OUT"/tidelink_manifest.json; do
    [ -f "$f" ] && printf '  %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
done
echo ""

echo "============================================================"
if [ "$FAIL" -eq 0 ]; then
    echo " RESULT: VERIFIED - every divergent module came from the ASIC file set."
    exit 0
fi
echo " RESULT: $FAIL CHECK(S) FAILED - this image is NOT proven to be the ASIC file set."
exit 1
