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
# 2026-07-30: extended with a FOURTH, OPPOSITE-polarity check —
#
#   EPOCH_ANCHOR_EN  must stay 1'b0 (the "off" position, unlike the three
#                    above). This is a real netlist change (swaps which
#                    cross-lane deskew corrector V2 compiles in); flipping the
#                    DEFAULT to 1 would silently re-litigate every existing
#                    golden bitstream on its next rebuild. Boards that want it
#                    on set CONFIG.EPOCH_ANCHOR_EN=1 per BD instance instead.
#                    See docs/HANDOVER_Z2_PICKUP_2026_07_30.md §5.
#
# Same pass also fixed a real bug in the (until then silently blind)
# component.xml consistency check below — see the comment at that section.
#
# This script catches that exact class of regression BEFORE Vivado runs:
# greps the wrapper file for each required default and exits non-zero (with a
# clear pointer to the relevant root-cause doc) if any has drifted from its
# intended value.
#
# Usage:
#   check_wrapper_params.sh [tidelink_vivado_wrapper.v]
#   (default path: $TIDELINK_HOME/fpga/vivado_ip/tidelink_vivado_wrapper.v)
#
# Exit codes:
#   0  — all four defaults are at their intended value
#   1  — at least one default has drifted
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

Reference: docs/reference/LANE_LOCK_ROOT_CAUSE.md — Root cause section.
EOF
    exit 1
fi

# -----------------------------------------------------------------------------
# EPOCH_ANCHOR_EN (2026-07-30, docs/HANDOVER_Z2_PICKUP_2026_07_30.md §5) — the
# OPPOSITE polarity check from the three above. Its correct default is 1'b0:
# unlike USE_IDELAY/USE_CLKBUF/USE_T3A this is a real netlist change (swaps
# which cross-lane deskew corrector V2 compiles in), and per the wrapper's own
# comment, flipping the DEFAULT to 1 "would silently re-litigate every
# existing golden bitstream (KR260 included)" — every board that has never
# opted in would silently get a different corrector on its next rebuild. So
# this guard trips on the same-class mistake in the other direction: the
# default must stay 0, and boards that want it on set
# CONFIG.EPOCH_ANCHOR_EN=1 per-instance, never by editing this line.
if grep -qE "^\s*parameter\s+EPOCH_ANCHOR_EN\s*=\s*1'b0\b" "$WRAPPER"; then
    echo "  OK   EPOCH_ANCHOR_EN = 1'b0"
elif grep -qE "^\s*parameter\s+EPOCH_ANCHOR_EN\s*=\s*1'b1\b" "$WRAPPER"; then
    echo "  FAIL EPOCH_ANCHOR_EN = 1'b1   (default flipped ON — would silently" >&2
    echo "       change every existing golden bitstream's deskew corrector on" >&2
    echo "       its next rebuild; opt in via CONFIG.EPOCH_ANCHOR_EN per BD" >&2
    echo "       instance instead, never by editing this default)" >&2
    fail=1
else
    echo "  FAIL EPOCH_ANCHOR_EN — parameter default not found / unrecognised form" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'EOF'

check_wrapper_params: a wrapper default is not at its intended value.
See the messages above for which parameter and which direction. The build is
being aborted BEFORE Vivado runs.

Reference: docs/HANDOVER_Z2_PICKUP_2026_07_30.md §5 (EPOCH_ANCHOR_EN);
docs/reference/LANE_LOCK_ROOT_CAUSE.md (USE_IDELAY/USE_CLKBUF/USE_T3A).
EOF
    exit 1
fi

# Best-effort: also check the packaged component.xml if a prior package_ip
# run has produced it. The wrapper-parameter defaults are recorded into the
# component.xml at packaging time; if it disagrees with the wrapper file,
# a stale IP cache may be in use.
#
# BUG FOUND + FIXED 2026-07-30 (while extending this for EPOCH_ANCHOR_EN):
# this check had been SILENTLY BLIND since it was written. Vivado's actual
# IP-XACT bitString values are quote-wrapped and XML-escaped —
#   <spirit:value ...>&quot;1&quot;</spirit:value>
# — but the old pattern `<...:value[^>]*>1</` expects a BARE digit right after
# '>', which never matches `&quot;1&quot;`. So neither the "OK" nor the "FAIL
# value=0" branch ever fired for USE_IDELAY/USE_CLKBUF/USE_T3A; the loop fell
# through to "parameter isn't mentioned — that's fine" every single time, and
# the script printed a blanket "OK consistent with wrapper" regardless of what
# the XML actually said. Measured against imp/fpga/tidelink_ip/component.xml
# (2026-07-30 11:18): confirmed zero matches under the old pattern for a
# parameter known-present with value "1". This is the exact "instrument that
# looks like it checks something but doesn't" class this project keeps
# re-discovering (cf. feedback_verify_instrument_before_dut) — found here by
# trying to reuse the pattern for a new parameter and it not matching either.
COMP_XML="${TIDELINK_HOME:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}/imp/fpga/tidelink_ip/component.xml"
if [ -f "$COMP_XML" ]; then
    xml_fail=0
    # $1=param name, $2=expected bit ("0" or "1"). Checks the block for name
    # $1 with resolve="user" specifically — the customizable IP-face value,
    # which is what actually reaches per-instance OOC synth overrides; the
    # resolve="generated" block a few lines above it mirrors the same value
    # at packaging time and is not separately load-bearing here.
    check_xml_param() {
        p="$1"; want="$2"
        block=$(grep -A6 -E "<spirit:name>${p}</spirit:name>" "$COMP_XML" 2>/dev/null \
                | grep -A2 'spirit:resolve="user"' | head -3)
        if [ -z "$block" ]; then
            echo "  ..  $p not found under resolve=\"user\" in component.xml (package_ip may predate this parameter — not fatal, wrapper file is the source of truth)"
            return 0
        fi
        got=$(printf '%s\n' "$block" | grep -oE '&quot;[01]&quot;' | head -1 | tr -dc '01')
        if [ "$got" = "$want" ]; then
            echo "  OK   packaged component.xml: $p (resolve=user) = $want"
        elif [ -n "$got" ]; then
            echo "  FAIL packaged component.xml: $p (resolve=user) = $got, expected $want (stale IP — re-run package_ip)" >&2
            xml_fail=1
        else
            echo "  FAIL packaged component.xml: $p found but value unparseable — inspect $COMP_XML by hand" >&2
            xml_fail=1
        fi
    }
    for p in USE_IDELAY USE_CLKBUF USE_T3A; do check_xml_param "$p" 1; done
    check_xml_param EPOCH_ANCHOR_EN 0
    if [ "$xml_fail" -ne 0 ]; then
        echo "  packaged component.xml at $COMP_XML disagrees with wrapper -- re-run package_ip" >&2
        exit 1
    fi
fi

echo "check_wrapper_params: PASS (USE_IDELAY/USE_CLKBUF/USE_T3A on, EPOCH_ANCHOR_EN off — all intact)"
exit 0
