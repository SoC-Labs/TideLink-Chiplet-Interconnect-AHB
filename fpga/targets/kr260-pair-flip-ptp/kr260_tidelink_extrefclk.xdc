#-----------------------------------------------------------------------------
# TideLink KR260 — COMMON EXTERNAL REFERENCE CLOCK (mesochronous) — die_b (flip)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# die_b twin of kr260-pair-ptp/kr260_tidelink_extrefclk.xdc. Read that file for
# the full rationale (frozen-phase PHY, no CDR/DLL/PI => only reliable when the
# two dies are frequency-locked; HDIO bank 44 has no MMCM so the reference feeds
# the BUFG-based /8 divider directly).
#
# INCLUSION-GATED by FPGA_TIDELINK_EXTREFCLK=1 in build_design.tcl. Never added
# on a default build (the pad_refclk_in port would not exist -> Vivado 12-1411).
#
# THE ONE DIFFERENCE FROM die_a: the flip build swaps TX and RX, so the HDGC ball
# being freed carries pad_rx[2] here, not pad_tx[2].
#
#   BCM12 / AA13 (HDGC)  : was pad_rx[2]      -> now pad_refclk_in   (common ref)
#   BCM20 / W12  (plain) : was unused         -> now pad_rx[2]       (relocated)
#
# The ribbon stays one-driver-against-one-receiver: die_a drives pad_tx[2] on
# BCM20, die_b receives pad_rx[2] on BCM20. BCM12 becomes the common-clock
# conductor — an INPUT on both boards under topology (b) (external generator, no
# contention), or die_a OUTPUT -> die_b INPUT under topology (a).
#-----------------------------------------------------------------------------

#-- Relocate lane 2 off the HDGC ball, onto a plain spare conductor -----------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}]   ;# BCM20 (plain) — relocated from AA13

#-- Common reference clock IN, on the freed HDGC ball -------------------------
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports pad_refclk_in] ;# BCM12 HDGC — drives a BUFG (NOT an MMCM)

#-- The reference is the only timed source of the PHY link domain -------------
create_clock -period 40.000 -name refclk [get_ports pad_refclk_in]

set_clock_groups -name async_refclk_vs_sys -asynchronous \
    -group [get_clocks -include_generated_clocks refclk] \
    -group [get_clocks -include_generated_clocks clk_pl_0]
