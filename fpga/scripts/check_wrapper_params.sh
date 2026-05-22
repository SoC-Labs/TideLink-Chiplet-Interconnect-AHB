#!/usr/bin/env bash
# =============================================================================
# check_wrapper_params.sh — guard against the 51b5169-class regression
#
# The TideLink FPGA build depends on three parameter defaults in the IP wrapper
# being set to 1'b1 (the "FPGA-on" position):
#
#   USE_IDELAY  (per-lane IDELAYE2 + IDELAYCTRL hook)
#   USE_CLKBUF  (BUFG on the recovered RX capture/word clocks)
#   USE_T3A     (self-aligning RX comma-hunt)
#
# Commit 51b5169 ("fpga: align BD scripts + IP packaging ... no idelay_*/USE_*")
# stripped these wrapper defaults and caused the multi-day 0/16 lane-lock
# regression — the GPIO-PHY recovered clock landed on a LUT-driven net
# (Place 30-568) and the hold check failed silently. Vivado treated the
# CRITICAL WARNINGs as soft, so the failure was invisible until silicon.
#
# This script catches that exact class of regression BEFORE Vivado runs:
# greps the wrapper file for each required default == 1'b1 and exits non-zero
# (with a clear pointer to 51b5169 / docs/LANE_LOCK_ROOT_CAUSE.md) if any has
# been flipped back to 1'b0 or removed.
#
# Usage:
#   check_wrapper_params.sh [tidelink_vivado_wrapper.v]
#   (default path: $TIDELINK_HOME/fpga/vivado_ip/tidelink_vivado_wrapper.v)
#
# Exit codes:
#   0  — all three defaults are 1'b1
#   1  — at least one default has been stripped/flipped
#   2  — usage / file-not-found
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access.
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

WRAPPER="${1:-${TIDELINK_HOME:-$(dirname "$(dirname "$(readlink -f "$0")")")/..}/fpga/vivado_ip/tidelink_vivado_wrapper.v}"
# Normalise (handle the default expansion path)
if [ ! -f "$WRAPPER" ]; then
    # Try the canonical relative path from the repo root
    alt="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/fpga/vivado_ip/tidelink_vivado_wrapper.v"
    [ -f "$alt" ] && WRAPPER="$alt"
fi
if [ ! -f "$WRAPPER" ]; then
    echo "check_wrapper_params: wrapper file not found: $WRAPPER" >&2
    echo "  set TIDELINK_HOME or pass the path explicitly" >&2
    exit 2
fi

echo "check_wrapper_params: verifying $WRAPPER"

# Required: each must appear EXACTLY as `parameter <NAME> = 1'b1` (with any
# whitespace). A flip to 1'b0 or removal trips the guard.
fail=0
for p in USE_IDELAY USE_CLKBUF USE_T3A; do
    if grep -qE "^\s*parameter\s+${p}\s*=\s*1'b1\b" "$WRAPPER"; then
        echo "  OK   $p = 1'b1"
    elif grep -qE "^\s*parameter\s+${p}\s*=\s*1'b0\b" "$WRAPPER"; then
        echo "  FAIL $p = 1'b0   (flipped back to OFF)" >&2
        fail=1
    else
        echo "  FAIL $p — parameter default not found / unrecognised form" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

check_wrapper_params: at least one FPGA-on default has been stripped or flipped.
This is the same regression class as commit 51b5169, which caused multi-day
0/16 lane-lock by stripping USE_CLKBUF/USE_IDELAY. The build is being aborted
BEFORE Vivado runs so the silent-XDC-drop / LUT-on-clock cascade cannot occur.

To fix:
  1. Restore the wrapper defaults to 1'b1 (see fpga/vivado_ip/tidelink_vivado_wrapper.v).
  2. Re-package the IP (`make -C fpga package_ip`).
  3. Rebuild.

Reference: docs/LANE_LOCK_ROOT_CAUSE.md — Root cause section.
EOF
    exit 1
fi

# Best-effort: also check the packaged component.xml if a prior package_ip
# run has produced it. The wrapper-parameter defaults are recorded into the
# component.xml at packaging time; if it disagrees with the wrapper file,
# a stale IP cache may be in use.
COMP_XML="${TIDELINK_HOME:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}/imp/fpga/tidelink_ip/component.xml"
if [ -f "$COMP_XML" ]; then
    xml_fail=0
    for p in USE_IDELAY USE_CLKBUF USE_T3A; do
        # The packaged XML records defaults under <spirit:moduleParameter>... or
        # <ipxact:moduleParameter>...; the value is in <spirit:value> typically as
        # "1" (just the digit) for a 1-bit param default of 1'b1.
        if grep -A2 -E "<(spirit|ipxact):name>${p}</" "$COMP_XML" 2>/dev/null | \
           grep -qE "<(spirit|ipxact):value[^>]*>1</"; then
            : # OK
        elif grep -A2 -E "<(spirit|ipxact):name>${p}</" "$COMP_XML" 2>/dev/null | \
             grep -qE "<(spirit|ipxact):value[^>]*>0</"; then
            echo "  FAIL packaged component.xml: $p default = 0 (stale IP — re-run package_ip)" >&2
            xml_fail=1
        fi
        # If the parameter isn't mentioned at all, package_ip simply didn't
        # record it — that is fine; the source-of-truth is the wrapper file.
    done
    if [ "$xml_fail" -ne 0 ]; then
        echo "  packaged component.xml at $COMP_XML disagrees with wrapper -- re-run package_ip" >&2
        exit 1
    fi
    echo "  OK   packaged component.xml consistent with wrapper"
fi

echo "check_wrapper_params: PASS (all three FPGA-on defaults intact)"
exit 0
