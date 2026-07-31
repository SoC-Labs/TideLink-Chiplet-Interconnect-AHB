#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 compute-chiplet (die_a AND die_b)
# Source-Synchronous Timing Constraints  -  LINK 0
# (die_a/flip and die_b/straight share this file byte-for-byte; only the pin
#  XDC differs - the TX/RX ball swap. Keep the two copies identical.)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# FIRST-CUT scaffold (gap G1). Ported from
#   kr260-eth-chiplet/kr260_eth_chiplet_tidelink_timing.xdc
# with (a) port names renamed to the compute link-0 pads (pad_clk_rx_0,
# pad_clk_tx_0, pad_tx_0[*], pad_rx_0[*], led0/led1) and (b) SCOPING-TODO
# markers everywhere a selector depends on the COMPUTE block design - which the
# BD/wrapper agent is still building. The methodology (why each constraint
# exists) is unchanged and correct; the get_pins/get_cells NAME filters below
# are eth-derived GUESSES and MUST be re-resolved against the compute BD before
# this file times anything. Every unresolved selector fires Vivado 12-4739
# ("No valid object(s) found"), which the message gate promotes to ERROR - so
# these are load-bearing TODOs, not cosmetic.
#-----------------------------------------------------------------------------
# Timing constraints for IMPLEMENTATION ONLY. Applying them during synthesis
# fires CRITICAL WARNING 12-4739 because the clk_wiz output clocks and the
# internal pad-capture cells are not visible to synthesis. build_design.tcl
# must apply:
#   set_property USED_IN_SYNTHESIS false     [get_files *_timing.xdc]
#   set_property USED_IN_IMPLEMENTATION true  [get_files *_timing.xdc]
# Do NOT add a runtime `set_property ... [info script]` line - `file normalize`
# / `info script` / `get_files` are procedural Tcl the XDC reader rejects
# (Designutils 20-1307). The wrapper already sets the property.
#-----------------------------------------------------------------------------

#=============================================================================
# COMPUTE DELTAS vs the eth chiplet (READ FIRST)
#=============================================================================
# (D1) TWO TideLinks. Compute bonds d2d0_* AND d2d1_*; the eth chiplet has one.
#      A KR260 has ONE J21, so only LINK 0 reaches the board (this file). LINK 1
#      is tied off - see the SCOPING-TODO block [L1] at the end. Do NOT copy
#      these link-0 constraints for link-1 pads: link-1 has no board clock.
#
# (D2) user_ref_clk is a BONDED PAD on compute (x2: user_ref_clk_0/1), whereas
#      on the eth chiplet it was NOT bonded (aliased onto sys_fclk). On this
#      FPGA build link-0's user_ref_clk_0 is still expected to be DRIVEN by the
#      clk_wiz (the BD ties it to clk_out1, as eth did), NOT by an external
#      pin - so it is treated as an internal generated clock below, same as eth.
#      SCOPING-TODO [URC]: if the compute BD instead brings user_ref_clk_0 out
#      to a real J21/PMOD pin, add a create_clock on that port and re-group it.
#
# (D3) SWJ-DP (SWD+JTAG) not SWD-only. swclk (=TCK) and any JTAG TCK are slow
#      external debug clocks; see [DBG].
#=============================================================================

#-----------------------------------------------------------------------------
# [1] GPIO PHY pad clocks (KR260 link runs at 3.125 MHz / 320 ns)
#-----------------------------------------------------------------------------
# The TideLink GPIO PHY is source-synchronous. On the KR260 the link clock is
# clk_wiz clk_out1 (25 MHz) / 8 = 3.125 MHz -> 320 ns:
#   tidelink_design.tcl  -> CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000}
#   tidelink_phy_clk_div2.v -> 3-bit div_cnt, tap bit[2]  (= /8, despite the name)
#   this file            -> create_clock -period 320.000  +  -divide_by 8 (x2)
# 25 MHz + /8 (not a slower clk_out1 + /1) because a ~4.7 MHz clk_out1 is below
# the MPSoC MMCME4 VCO floor.
#
# Received clock from the peer chiplet on pad_clk_rx_0. It clocks the pad_rx_0[*]
# sampling registers - KEEP this create_clock so the pad_rx_0[*] -> capture
# relationship stays analysed (constraints [3]/[4]). pad_clk_rx_0 lands on an
# HDGC ball on BOTH boards (die_a AC14 / die_b AD15), so no CLOCK_DEDICATED_ROUTE
# override is needed. Conservatively slow for first eye closure; can likely run
# faster once the eye is characterised on the bench.
create_clock -period 320.000 -name pad_clk_rx_0 [get_ports pad_clk_rx_0]

#-----------------------------------------------------------------------------
# [2] Forwarded TX clock as a real source-synchronous generated clock
#-----------------------------------------------------------------------------
# The GPIO-PHY TX serializer + the pad_clk_tx_0 forward both run off
# user_ref_clk_0 = clk_wiz clk_out1 (25 MHz) / 8 = 3.125 MHz. Define pad_clk_tx_0
# as a generated clock derived from clk_out1 at the output port, then constrain
# pad_tx_0[*] against THAT (true forwarded-clock methodology) rather than vs an
# internal MMCM pin or false-pathing it.
#
# SCOPING-TODO [BD-CLK]: the -source pin filter below is the ETH BD path
# (tidelink_design_i/clk_wiz_0/clk_out1). The compute BD is a different design
# (two links, dual user_ref_clk); confirm the exact clk_wiz instance name and
# that clk_out1 is in pad_clk_tx_0's fanin. Use a WILDCARD-FREE NAME filter that
# resolves to EXACTLY ONE pin (a wildcard that matches >1 pin trips
# Constraints 18-359 and silently drops this whole stanza).
create_generated_clock -name pad_clk_tx_0_fwd \
    -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}] \
    -divide_by 8 [get_ports pad_clk_tx_0]

# Transmit eye: source-synchronous SDR centred-edge forward. +/-20 ns is an
# ABSOLUTE budget (ribbon flight time + the far die's setup/hold); do NOT rescale
# it if you change the rate knob - only create_clock / -divide_by track the rate.
# Symmetric window vs the forwarded clock (launch and capture share the forwarded
# edge) so Vivado BALANCES rather than hold-pads every lane. At 320 ns the far die
# samples mid-cell (160 ns), leaving >=140 ns of true eye each side.
set_output_delay -clock [get_clocks pad_clk_tx_0_fwd] -max  20.000 [get_ports {pad_tx_0[*]}]
set_output_delay -clock [get_clocks pad_clk_tx_0_fwd] -min -20.000 [get_ports {pad_tx_0[*]}]

#-----------------------------------------------------------------------------
# [3] RX pad capture: TIMED source-synchronous group, RELATIVE skew bounded
#-----------------------------------------------------------------------------
# Give Vivado a timed pad_rx_0[*] -> capture relationship (so it stops routing
# the 8 lanes with arbitrary delay) WITHOUT a naive absolute set_input_delay
# -min/-max (the hold-violation trap that inserts hold-fixing on every lane).
#
# (3a) Receive eye RELATIVE to pad_clk_rx_0, SYMMETRIC window. +/-4 ns are
#      ABSOLUTE board-trace skews (do not scale with the link period). Generous
#      by design - the calibrator absorbs dynamic skew; constraints only bound
#      the STATIC, build-varying part.
set_input_delay -clock [get_clocks pad_clk_rx_0] -max  4.000 [get_ports {pad_rx_0[*]}]
set_input_delay -clock [get_clocks pad_clk_rx_0] -min -4.000 [get_ports {pad_rx_0[*]}]

# (3b)/(3c) Bound the pad_rx_0[n] -> first-stage capture flop path as a pure
#      datapath delay (8 ns ceiling, NOT a clocked check -> no hold-fix
#      insertion) and EQUALISE the 8 lanes to within 2 ns (set_bus_skew). The
#      build-to-build defect is per-lane VARIANCE; bounding relative skew removes
#      it with no absolute hold pressure.
#
# SCOPING-TODO [BD-RX]: the capture-flop selector is eth-derived and matches
# ALL gpiorx cells. On compute it MUST be scoped to LINK 0's PHY only (e.g. the
# d2d0 / *_tidelink_0 hierarchy) so link-1's (tied-off) gpiorx cells are not
# swept in. Confirm the WavD2DGpioRx first-stage register name in the compute
# netlist (eth: link_data_pad_clk_reg[*]) - IP-pack/wrapper renames can change
# the hierarchy prefix. As written this matches nothing on compute -> 12-4739.
set _xlnx_shared_i0 [get_cells -hier -filter {NAME =~ "*d2d0*gpiorx_*/link_data_pad_clk_reg[*]"}]
set_max_delay -datapath_only -from [get_ports {pad_rx_0[*]}] -to $_xlnx_shared_i0 8.000
set_bus_skew -from [get_ports {pad_rx_0[*]}] -to $_xlnx_shared_i0 2.000

# (3d) IOB packing FORCED OFF on KR260 (deliberate inversion of the Z2 IOB TRUE).
#      REQUIRED: the HDIO bank-44 pins + the V2 PHY's per-lane wpa_shift_q_reg
#      (a legal IOB candidate whose D fans out further) otherwise pack into the
#      HDIO input flop and fail post-route DRC PDRC-248 (8x). set_max_delay/
#      set_bus_skew - not IOB packing - are what make capture deterministic here.
set_property IOB FALSE [get_ports {pad_rx_0[*]}]

#-----------------------------------------------------------------------------
# [4a] PHY /8 clock (user_ref_clk_0 = clk_out1 / 8 = 3.125 MHz)
#-----------------------------------------------------------------------------
# tidelink_phy_clk_div2 is a /8 free-running counter (div_cnt_reg[2:0]) feeding
# u_div_bufg (a global clock buffer). Declare the divided clock EXPLICITLY so it
# has a stable name for the async clock_groups below. -source = the [2] bit's C
# pin (a SINGLE pin; matching div_cnt_reg[*] would hit 3 pins -> Constraints
# 18-359); generated clock defined on the BUFG output.
#
# SCOPING-TODO [BD-DIV]: compute has TWO phy_clk_div instances (one per link).
# Scope this to LINK 0's divider (d2d0) so it does not collide with link-1's.
create_generated_clock -name user_ref_clk_0_div8 \
    -source [get_pins -hier -filter {NAME =~ "*d2d0*phy_clk_div*div_cnt_reg[2]/C"}] \
    -divide_by 8 [get_pins -hier -filter {NAME =~ "*d2d0*phy_clk_div*u_div_bufg*/O"}]

#-----------------------------------------------------------------------------
# [4b] TX WORD CLOCK (gpiotx_0 = local hsclk/16)
#-----------------------------------------------------------------------------
# Without a create_generated_clock the /16 TX word clock is an unconstrained,
# ungated fabric net and the deep Wlink a2l-read FIFO pointers + their
# WavResetSync never get a clean edge -> read side held in reset -> no TX data.
# Declaring it makes Vivado TIME the domain and route the high-fanout net on a
# global buffer.
#
# SCOPING-TODO [BD-TXW]: scope to LINK 0's gpiotx (d2d0). Confirm count_reg[3]
# is still the /16 tap in the compute PHY.
create_generated_clock -name gpiotx0_word_clk \
    -source [get_pins -hier -filter {NAME =~ "*d2d0*gpiotx_0/count_reg[3]/C"}] \
    -divide_by 16 [get_pins -hier -filter {NAME =~ "*d2d0*gpiotx_0/count_reg[3]/Q"}]

#-----------------------------------------------------------------------------
# [4] Async clock groups: isolate the genuine recovered-RX -> core CDC, keep the
#     pad_rx_0[*] -> capture analysis timed.
#-----------------------------------------------------------------------------
# set_clock_groups -asynchronous between pad_clk_rx_0 and hclk does NOT disable
# the pad_rx_0[*] -> capture paths (those are launched/captured on pad_clk_rx_0,
# same group, still timed by [3]); it only cuts pad_clk_rx_0<->hclk. Each domain
# crossing is 2-flop synchronised in RTL. user_ref_clk_0_div8 MUST be its own
# group vs hclk so the hclk<->PHY paths are NOT timed as a related integer
# crossing (BEAT-FREQUENCY WARNING: hclk 25 MHz and user_ref_clk_0 3.125 MHz are
# a clean 8:1 on paper, but the crossing is async-SYNCHRONISED, not phase-
# balanced - if Vivado times it as a related 8:1 it will report false setup/hold
# on a path the RTL never uses coherently. Grouping it async is REQUIRED, not an
# optimisation). gpiotx0_word_clk is /16 of the same island - kept grouped.
#
# SCOPING-TODO [BD-HCLK]: hclk pin filter is the eth clk_wiz path - re-resolve
# against the compute BD (same clk_wiz instance as [2]).
set hclk_pin [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}]

set_clock_groups -asynchronous \
    -group [get_clocks pad_clk_rx_0] \
    -group [get_clocks -of_objects $hclk_pin] \
    -group [get_clocks gpiotx0_word_clk] \
    -group [get_clocks user_ref_clk_0_div8]

#-----------------------------------------------------------------------------
# [6] False paths
#-----------------------------------------------------------------------------
# Board LEDs are human-visible; no functional timing path.
set_false_path -to [get_ports {led0 led1}]

# NOTE: no IDELAYE2 CNTVALUEIN false_path and no IDELAYE2 stanza - these targets
# build with USE_IDELAY=0, and the RPi header is HDIO (cannot host IDELAY). An
# empty set_false_path -to would be the silent-drop class the message gate
# promotes to ERROR (Vivado 12-1411), so it is intentionally omitted.

#-----------------------------------------------------------------------------
# [7] Combinational loop waiver (AHB-Lite HSEL=1 + HREADY loopback in the IP)
#-----------------------------------------------------------------------------
# Standard Vivado IP-Integrator AHB-Lite slave style: an intentional,
# functionally-correct combinational loop on the HREADY net. Per-net waiver as
# backup (the primary severity downgrade lives in *_tidelink_drc.xdc so it
# survives save_constraints round-trips).
# SCOPING-TODO [BD-AHB]: confirm the compute IP's response-mux net path
# (eth: *u_xhb_sub/u_core/u_resp/*). Compute may expose two D2D AHB subs.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]

#=============================================================================
# [DBG] SWJ-DP external debug clocks (compute is SWD+JTAG, not SWD-only)
#=============================================================================
# swclk (=SWD SWCLK / JTAG TCK) is a slow external debug clock. Its
# CLOCK_DEDICATED_ROUTE FALSE waiver is in the PIN XDC (on the NET). The KR260
# eth build closes with the dbg_hub/BSCAN(TCK) WHS "noise" present and does NOT
# waive it (those TCK paths are inactive outside a ChipScope session).
#
# SCOPING-TODO [DBG]: if the compute build wants clean intent on the debug
# clock, add here once the BD is built:
#   create_clock -period <slow, e.g. 100.000> -name swclk [get_ports swclk]
#   set_clock_groups -asynchronous -group [get_clocks swclk] -group ... (core)
# Not added now: create_clock on an unconstrained scaffold port with no BD
# behind it would itself 12-4739 during impl. Add it WITH the wrapper.

#=============================================================================
# [L1] SCOPING-TODO - LINK 1 (d2d1) IS TIED OFF ON THE KR260
#=============================================================================
# A KR260 has ONE J21 header, already fully consumed by link-0 above. Link-1's
# pads (pad_clk_tx_1, pad_tx_1[*], pad_clk_rx_1, pad_rx_1[*], i2c1_*) therefore
# have NO board pins and NO forwarded board clock. The BD/wrapper agent must tie
# link-1 off inside the wrapper (drive pad_rx_1[*]/pad_clk_rx_1 to idle
# constants, leave pad_tx_1[*] unconnected) - mirror the eth wrapper's
# rmii_*_idle tie-off pattern. With link-1 tied off:
#   - Do NOT create_clock pad_clk_rx_1 (no toggling source -> unconstrained/
#     dropped). If the tie-off leaves internal link-1 PHY logic clocked, its
#     clock comes from user_ref_clk_1.
#   - user_ref_clk_1: unlike link-0, this is expected to come from a PL clock
#     (a clk_wiz output or a divided fabric clock), NOT a board pin. Add its
#     create_generated_clock + async group here once the BD wires it. Until
#     then link-1 timing is INTENTIONALLY absent from this file.
#=============================================================================
