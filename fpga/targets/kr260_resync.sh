#!/usr/bin/env bash
# Re-sync the 4 KR260 targets from the die_a source of truth (kr260-pair-ptp).
# Shared files (BD tcl, wrapper, /8 divider, BRAM terminus, timing+drc XDC) are
# identical across all 4; only the PIN XDC (die_a vs die_b flip) and the role-
# strap default (die_b = 0x1) differ. PTP on/off is decided at build time by the
# Makefile's FPGA_TIDELINK_PTP env, so the tcl is identical for -ptp / -nptp.
set -euo pipefail
cd "$(dirname "$0")"
SRC=kr260-pair-ptp
SHARED="tidelink_design.tcl tidelink_design_wrapper.v tidelink_phy_clk_div2.v \
        tidelink_ahb_mng_bram.v kr260_tidelink_timing.xdc kr260_tidelink_drc.xdc \
        ribbon_wiring.md"

# The extrefclk (mesochronous) XDC is NOT shared: it relocates the lane sitting on
# the HDGC ball being freed, and that lane is pad_tx[2] on die_a but pad_rx[2] on
# die_b (the flip build swaps TX/RX). So it is propagated per-ROLE, from the two
# role sources, not from the single die_a source.
EXTREF_A=kr260-pair-ptp/kr260_tidelink_extrefclk.xdc          # die_a
EXTREF_B=kr260-pair-flip-ptp/kr260_tidelink_extrefclk.xdc     # die_b
for d in kr260-pair-nptp kr260-pair-flip-ptp kr260-pair-flip-nptp; do
  for f in $SHARED; do cp "$SRC/$f" "$d/$f"; done
done
# extrefclk XDC per ROLE (see note above — the relocated lane differs by role).
# Safe against the loop: it is deliberately NOT in $SHARED, so flip-ptp (which is
# itself the die_b source) is never clobbered by the die_a copy.
cp "$EXTREF_A" kr260-pair-nptp/kr260_tidelink_extrefclk.xdc
cp "$EXTREF_B" kr260-pair-flip-nptp/kr260_tidelink_extrefclk.xdc
# die_b (flip) role-strap default 0x0 -> 0x1 (FIRST C_DOUT_DEFAULT only; the
# second is axi_gpio_debug_unlock which stays 0x0).
for d in kr260-pair-flip-ptp kr260-pair-flip-nptp; do
  awk '!done && /CONFIG.C_DOUT_DEFAULT  \{0x00000000\}/ {sub(/0x00000000/,"0x00000001"); done=1} {print}' \
      "$d/tidelink_design.tcl" > "$d/tidelink_design.tcl.tmp" && mv "$d/tidelink_design.tcl.tmp" "$d/tidelink_design.tcl"
done
echo "re-sync OK. strap defaults:"
grep -H -m1 'C_DOUT_DEFAULT' kr260-pair-ptp/tidelink_design.tcl kr260-pair-flip-ptp/tidelink_design.tcl
