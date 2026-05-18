###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 pair-all - IDELAYE2 RX delay constraints
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###   David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### SoC Labs §9 structural fix (2026-05-18) — IDELAY-specific constraints ONLY.
###
### This is a SEPARATE XDC (NOT *_timing.xdc — that file is owned by another
### agent and must not be touched). Wired into build_design.tcl exactly like
### *_drc.xdc (USED_IN_SYNTHESIS false, USED_IN_IMPLEMENTATION true).
###
### Purpose: tie every per-lane IDELAYE2 (in tidelink_idelay_rx, USE_IDELAY=1)
### to its bank IDELAYCTRL via a shared IODELAY_GROUP, and document the
### 200 MHz IDELAYCTRL reference-clock requirement.
###
### Hierarchy (verified vs pynq_z2_tidelink_drc.xdc probe paths):
###   tidelink_design_i/tidelink_0/inst/u_tidelink_top/
###       u_chiplet_controller/u_idelay_rx/g_idelay.g_lane[N].g_lane.u_idelaye2
###       u_chiplet_controller/u_idelay_rx/g_idelay.u_idelayctrl
###
### Applied during BOTH synthesis and implementation so the IODELAY_GROUP
### string attribute on the cells is honoured by placer/router (it must match
### the IODELAY_GROUP="tidelink_rx_idelay" parameter in tidelink_idelay_rx.sv).
###-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 1. IODELAY_GROUP — bind the 8 per-lane IDELAYE2 + the single IDELAYCTRL into
#    one group so Vivado places the IDELAYCTRL in the same I/O bank/column as
#    the pad_rx[*] IDELAYE2s and uses it to calibrate their taps.
#
#    The string attribute is ALREADY set in RTL (the (* IODELAY_GROUP *)
#    attribute on each IDELAYE2/IDELAYCTRL instance). These XDC lines are the
#    belt-and-braces equivalent so the group survives if synthesis drops the
#    RTL attribute (it has, historically, on some Vivado versions). The wildcard
#    matches the generate-block instance names; if synthesis flattens the
#    names differently the get_cells returns empty and these are harmless
#    no-ops (the RTL attribute still carries the group).
#-----------------------------------------------------------------------------
set _idelay_grp "tidelink_rx_idelay"

set _idelaye2_cells [get_cells -hierarchical -quiet \
    -filter {REF_NAME == IDELAYE2 || PRIMITIVE_TYPE =~ IO.*.IDELAYE2}]
if { [llength $_idelaye2_cells] > 0 } {
    set_property IODELAY_GROUP $_idelay_grp $_idelaye2_cells
    puts "tidelink_idelay.xdc: IODELAY_GROUP set on [llength $_idelaye2_cells] IDELAYE2 cell(s)"
} else {
    puts "tidelink_idelay.xdc: no IDELAYE2 cells found (USE_IDELAY=0 build?) — skipping"
}

set _idelayctrl_cells [get_cells -hierarchical -quiet \
    -filter {REF_NAME == IDELAYCTRL || PRIMITIVE_TYPE =~ IO.*.IDELAYCTRL}]
if { [llength $_idelayctrl_cells] > 0 } {
    set_property IODELAY_GROUP $_idelay_grp $_idelayctrl_cells
    puts "tidelink_idelay.xdc: IODELAY_GROUP set on [llength $_idelayctrl_cells] IDELAYCTRL cell(s)"
}

#-----------------------------------------------------------------------------
# 2. IDELAYCTRL reference clock.
#
#    IDELAYCTRL.REFCLK requires a stable 200 MHz clock (REFCLK_FREQUENCY=200.0
#    in the RTL). It is sourced from a NEW clk_wiz output (see
#    tidelink_design.tcl change in the agent report: add CLKOUT3 = 200 MHz,
#    CLKOUT3_USED true, wire clk_wiz_0/clk_out3 -> tidelink_0/idelay_ref_clk).
#
#    Because that 200 MHz net originates inside the BD's clk_wiz MMCM, Vivado
#    AUTO-CREATES the clock object from the MMCM (create_generated_clock is
#    emitted by the clk_wiz IP's own constraints). DO NOT add a manual
#    create_clock here — that would double-define and over-constrain it.
#
#    If (and only if) the supervising session instead feeds idelay_ref_clk
#    from a free-running top-level input pin (no MMCM), uncomment:
#       # create_clock -name idelay_ref_clk -period 5.000 \
#       #     [get_ports idelay_ref_clk]
#    5.000 ns = 200 MHz. The RTL REFCLK_FREQUENCY parameter (200.0) MUST
#    equal the actual frequency or the IDELAY tap calibration is wrong.
#
#    The IDELAYCTRL→core relationship is asynchronous (the calibrated taps are
#    static w.r.t. the recovered RX clock); the BD clk_wiz already groups its
#    outputs. No extra clock-group statement is added here so this file stays
#    strictly IDELAY-scoped and never collides with *_timing.xdc.
#-----------------------------------------------------------------------------
# (intentionally no create_clock — see rationale above)

#-----------------------------------------------------------------------------
# 3. Keep the pad_rx[*] IBUF -> IDELAYE2 path as the deterministic IOB path.
#    The IDELAYE2 IDATAIN must be driven directly by the input buffer (the
#    delay line lives in the IOB). Forbid the input FF being pulled into the
#    IOB on these pins (the IDELAYE2 occupies the IOB input-delay resource;
#    an IOB input FF would conflict / defeat the explicit delay line).
#-----------------------------------------------------------------------------
set _padrx_ports [get_ports -quiet {pad_rx[*]}]
if { [llength $_padrx_ports] > 0 } {
    set_property IOB FALSE $_padrx_ports
}
