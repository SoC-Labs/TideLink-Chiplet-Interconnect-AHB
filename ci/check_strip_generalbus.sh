#!/usr/bin/env bash
# ============================================================================
# check_strip_generalbus.sh — regression guard for the TideLink GeneralBus
# strip (branch strip-generalbus-irq, 2026-04-13).
#
# Verifies that gb_in / gb_out have NOT been re-introduced at the TideLink
# boundary. The Wlink GeneralBus FC node itself stays in place inside
# axi_chiplet_controller (deps/), so we restrict the grep to TideLink-authored
# files. Cross-chiplet interrupt delivery is handled by the dedicated
# `ahb-chiplet-interrupt-controller` IP (Wlink FC data_id = 0xa3).
#
# Usage: bash ci/check_strip_generalbus.sh
# Exit 0 if the strip is intact; exit 1 if any banned reference appears.
# ============================================================================

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Files that must NOT contain gb_in / gb_out / external-port generalbus
# references after the strip. We list explicit paths (rather than a broad
# search) so a future legitimate reuse of `gb_in` as a local identifier in
# an unrelated file does not trip the regression.
FILES_TO_CHECK=(
    "src/rtl/tidelink_top.sv"
    "uvm/tidelink_top_system/tb/top.sv"
    "uvm/tidelink_ptp_chain/tb/top.sv"
    "cdc/tidelink_top.sgdc"
)

# Banned patterns — must match zero times in the files above.
BANNED_PATTERN='\bgb_in\b|\bgb_out\b'

fail=0
for f in "${FILES_TO_CHECK[@]}"; do
    if [ ! -f "$f" ]; then
        echo "  [skip] $f not present"
        continue
    fi
    matches=$(grep -nE "$BANNED_PATTERN" "$f" || true)
    if [ -n "$matches" ]; then
        echo "  [FAIL] $f re-introduces banned port references:"
        echo "$matches" | sed 's/^/         /'
        fail=1
    else
        echo "  [pass] $f"
    fi
done

# Also assert the TideLink Wlink instantiation ties generalbus_in to zero
# (it's allowed to mention generalbus_in / generalbus_out — they are Wlink-
# internal ports — but only as tied-off / unconnected forms).
TOP="src/rtl/tidelink_top.sv"
if [ -f "$TOP" ]; then
    if ! grep -q '\.generalbus_in\s*(\s*32.h0\s*)' "$TOP" \
       && ! grep -q '\.generalbus_in\s*(\s*32.b0\s*)' "$TOP" \
       && ! grep -q '\.generalbus_in\s*(\s*.0\s*)' "$TOP"; then
        echo "  [FAIL] $TOP: generalbus_in is not tied to a literal zero"
        echo "         (expected '.generalbus_in (32'h0)' or similar)"
        fail=1
    else
        echo "  [pass] $TOP: generalbus_in tied to literal zero"
    fi
fi

if [ $fail -ne 0 ]; then
    echo ""
    echo "ERROR: GeneralBus strip regression failed."
    echo "       See tidelink/docs/reference/FC_NODE_REGISTRY.md and"
    echo "       tidelink/docs/reference/TIDELINK_SPECIFICATION.md \xc2\xa75.14 for context."
    exit 1
fi

echo ""
echo "OK: GeneralBus strip is intact."
exit 0
