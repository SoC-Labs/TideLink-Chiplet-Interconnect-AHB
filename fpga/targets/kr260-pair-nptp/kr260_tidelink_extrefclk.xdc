#-----------------------------------------------------------------------------
# TideLink KR260 — COMMON EXTERNAL REFERENCE CLOCK (mesochronous) — die_a
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# INCLUSION-GATED: build_design.tcl adds this file ONLY when
# FPGA_TIDELINK_EXTREFCLK=1 (the same pattern as *_tidelink_idelay.xdc). It MUST
# NOT be added otherwise: the `pad_refclk_in` port does not exist in the default
# BD, so get_ports would return empty -> [Vivado 12-1411] -> hard ERROR under the
# message gate. XDC cannot guard itself (procedural Tcl in an XDC is rejected with
# [Designutils 20-1307], also promoted to ERROR), hence the gate lives in the
# build script, not here.
#
# WHY: the PHY is forwarded-clock with NO CDR/DLL/PI — the calibrator latches
# (slip,phase) once at S_DONE and freezes. A frozen-phase link is only reliable
# when the two dies are FREQUENCY-LOCKED. Two boards on their own PS oscillators
# are plesiochronous (a rig artifact the ASIC will not have). This file moves the
# PHY link clock onto a shared reference => mesochronous.
# See fpga/docs/KR260_NEXT_WEEK_PLAN.md.
#-----------------------------------------------------------------------------
# PIN BUDGET
#
# The common reference MUST land on an HDGC (global-clock-capable) ball so it can
# drive a BUFG. All 8 HDGC balls on the RPi header are already used by the link
# (2 forwarded clocks + 6 data lanes), and the spare conductors (BCM20-27) are
# NOT clock-capable. So we free ONE HDGC ball by relocating a DATA lane — data
# lanes have no clock-capability requirement.
#
#   BCM12 / AA13 (HDGC)  : was pad_tx[2]      -> now pad_refclk_in   (common ref)
#   BCM20 / W12  (plain) : was unused         -> now pad_tx[2]       (relocated)
#
# set_property PACKAGE_PIN overrides the earlier assignment in kr260_tidelink.xdc
# (last one wins), so the relocation is expressed here rather than by editing the
# base pin map — that keeps the default (plesiochronous) build byte-identical.
#
# RIBBON: BCM12 becomes the common-clock conductor and BCM20 must now be bridged
# (one extra conductor -> 21 signals). BCM12 carries:
#   topology (b), external generator : an INPUT on BOTH boards (no contention)
#   topology (a), die_a sources      : die_a OUTPUT -> die_b INPUT
# Lane 2 on BCM20 remains one-driver-against-one-receiver. See ribbon_wiring.md.
#-----------------------------------------------------------------------------

#-- Relocate lane 2 off the HDGC ball, onto a plain spare conductor -----------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[2]}]      ;# BCM20 (plain) — relocated from AA13

#-- Common reference clock IN, on the freed HDGC ball -------------------------
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports pad_refclk_in]                      ;# BCM12 HDGC — drives a BUFG (NOT an MMCM: HDIO bank 44 has no CMT)

#-- The reference is the ONLY timed source of the PHY link domain -------------
# 25 MHz to match clk_wiz clk_out1, which the default build divides by 8 to reach
# the 3.125 MHz / 320 ns link rate. If you change the generator frequency, change
# this period AND the create_clock in kr260_tidelink_timing.xdc together — the /8
# divider is the single link-rate knob.
create_clock -period 40.000 -name refclk [get_ports pad_refclk_in]

# The external reference and the PS-derived clk_wiz output are unrelated: hclk/AXI
# stay on pl_clk0 so the host always boots even with no peer clock. Declare them
# asynchronous so the tools do not try to time between the two domains. The RX
# capture path (pad_clk_rx -> pad_rx[*]) is NOT covered by this and remains timed
# as a forwarded-clock relationship in kr260_tidelink_timing.xdc.
set_clock_groups -name async_refclk_vs_sys -asynchronous \
    -group [get_clocks -include_generated_clocks refclk] \
    -group [get_clocks -include_generated_clocks clk_pl_0]
