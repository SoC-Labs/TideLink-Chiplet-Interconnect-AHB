#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 ON-CHIP PAIR - Timing Constraints
#   (kr260-pair-onchip: TWO TideLink dies in ONE xck26 bitstream, PHY pads
#    cross-connected THROUGH THE FABRIC — no pin, no ribbon, no I/O delays.)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Timing constraints for IMPLEMENTATION only (build_design.tcl marks
# *_timing.xdc USED_IN_SYNTHESIS=false / USED_IN_IMPLEMENTATION=true). Applying
# them at synthesis fires CRITICAL WARNING 12-4739 because the clk_wiz output
# clocks and the internal divider/PHY cells are not visible pre-synthesis.
# (Do NOT change how this file is loaded.)
#
#=============================================================================
# WHY THIS FILE IS FUNDAMENTALLY DIFFERENT FROM THE SINGLE-DIE kr260 TARGETS
#=============================================================================
# The single-die kr260-pair-{ptp,nptp} timing XDC is a source-synchronous
# PAD-eye file: it create_clock's pad_clk_rx (an input PORT), forwards
# pad_clk_tx (an output PORT), and set_input/output_delay's the pad_rx/pad_tx
# BUSES against those forwarded clocks, plus IOB FALSE on the HDIO pads.
#
# NONE of that applies here, because on this target the four PHY channels never
# reach a pin — tidelink_0/pad_* is wired straight to tidelink_1/pad_* by
# connect_bd_net inside the BD (KR260_PAIR_ONCHIP_PLAN.md sec 3.7). There are
# therefore NO pad_* ports to constrain, NO I/O delays, and NO IOB property.
# The plan's W6 DoD makes this explicit:
#     grep -c 'get_ports pad_ | get_ports i2c | set_input_delay
#              | set_output_delay | IOB FALSE'  ==  0
# This file honours that: it contains none of those. The only get_ports here is
# the LED false-path in [4], and the LED LOCs live in kr260_tidelink.xdc.
#
# What DOES need constraining is entirely INTERNAL:
#   * the two /8 recovered/forwarded PHY clocks (one per die),
#   * the two /16 TX word clocks (one per die),
#   * the two RX-capture clocks (each die captures the OTHER die's forwarded
#     clock through its rxclk_buf BUFG),
# and the async isolation between the two source-synchronous channels and hclk.
#
# THE ONE-INSTANCE-BECOMES-TWO TRAP (why every filter below is instance-
# qualified). The single-die file uses wildcard filters like
# `*phy_clk_div*div_cnt_reg[2]/C` and `*gpiotx_0/count_reg[3]/C`. With TWO
# instances those match 2 pins each and create_generated_clock aborts with
# [Constraints 18-359] "> 1 master pin" (promoted to ERROR by the build_design
# message gate). Every -source / target filter here is therefore anchored on
# the BD instance name (phy_clk_div_0 / phy_clk_div_1, tidelink_0 / tidelink_1)
# so it resolves to EXACTLY ONE pin. Verified hierarchy (from a routed single-
# die kr260 build, with the _0/_1 instance suffix added):
#   tidelink_design_i/phy_clk_div_{0,1}/inst/div_cnt_reg[2]           (/8 FF)
#   tidelink_design_i/phy_clk_div_{0,1}/inst/u_div_bufg/O             (/8 BUFG)
#   tidelink_design_i/tidelink_{0,1}/inst/u_tidelink_top/u_chiplet_controller/
#       u_wlink/phy/gpio/gpiotx_0/count_reg[3]                        (/16 FF)
#       u_wlink/phy/gpio/gpiorx_*/link_data_pad_clk_reg[*]            (RX capture)
#     u_tidelink_top/u_chiplet_controller/u_rxclk_buf/g_bufg.u_rxclk_bufg/O
#                                                                     (RX BUFG)
# Filters intentionally start with `*<name>` (not `*/`) so cocotb/lint/
# xdc_lint.py's XDC_MULTI_PIN_FILTER rule (which flags `"*/...*"` globs) stays
# green, exactly as the single-die file does.
#=============================================================================

#-----------------------------------------------------------------------------
# [1] The two forwarded/recovered PHY clocks (clk_wiz clk_out1 25 MHz / 8 =
#     3.125 MHz / 320 ns), one per die. Each die's tidelink_phy_clk_div2(_b)
#     free-running /8 counter feeds its own BUFG (u_div_bufg). This is the
#     KR260 rate knob: change clk_out1 and/or -divide_by together.
#
#     die_a (tidelink_0) is fed by phy_clk_div_0 (INIT_PHASE 3'b000).
#     die_b (tidelink_1) is fed by phy_clk_div_1 (INIT_PHASE 3'b011 -> a static
#     120 ns / 0.375 UI phase offset; the zero-skew-trap mitigation, sec 4).
#     Vivado models both as a plain /8 of clk_out1 (it does not see the INIT
#     phase); the phase offset is a real silicon fact that decorrelates the two
#     clock domains without changing the timing arcs.
#-----------------------------------------------------------------------------
create_generated_clock -name phy_clk_i0 \
    -source [get_pins -hier -filter {NAME =~ "*phy_clk_div_0*div_cnt_reg[2]/C"}] \
    -divide_by 8 [get_pins -hier -filter {NAME =~ "*phy_clk_div_0*u_div_bufg/O"}]

create_generated_clock -name phy_clk_i1 \
    -source [get_pins -hier -filter {NAME =~ "*phy_clk_div_1*div_cnt_reg[2]/C"}] \
    -divide_by 8 [get_pins -hier -filter {NAME =~ "*phy_clk_div_1*u_div_bufg/O"}]

#-----------------------------------------------------------------------------
# [2] The two TX word clocks (local hsclk /16 in each gpiotx_0). PORTED from the
#     single-die file [4b]: WITHOUT a create_generated_clock the /16 TX word
#     clock is an unconstrained, ungated fabric net and the deep Wlink a2l-read
#     FIFO pointers + their WavResetSync never get a clean edge -> io_rreset
#     never sync-deasserts -> link_empty=1 forever -> no V2 data TX. Declaring
#     the clock makes Vivado TIME the domain and route the high-fanout net on a
#     global clock buffer. One per die, instance-qualified.
#-----------------------------------------------------------------------------
create_generated_clock -name word_clk_i0 \
    -source [get_pins -hier -filter {NAME =~ "*tidelink_0/inst*gpiotx_0/count_reg[3]/C"}] \
    -divide_by 16 [get_pins -hier -filter {NAME =~ "*tidelink_0/inst*gpiotx_0/count_reg[3]/Q"}]

create_generated_clock -name word_clk_i1 \
    -source [get_pins -hier -filter {NAME =~ "*tidelink_1/inst*gpiotx_0/count_reg[3]/C"}] \
    -divide_by 16 [get_pins -hier -filter {NAME =~ "*tidelink_1/inst*gpiotx_0/count_reg[3]/Q"}]

#-----------------------------------------------------------------------------
# [3] The two RX-capture clocks, defined EXPLICITLY on each die's rxclk_buf BUFG
#     output (plan M4: relying on auto-propagation risks leaving the RX capture
#     flops unconstrained = a vacuous-green timing sign-off).
#
#     Each die captures the OTHER die's forwarded clock: the cross-connect wires
#       tidelink_0/pad_clk_tx (= phy_clk_i0) -> tidelink_1/pad_clk_rx, and
#       tidelink_1/pad_clk_tx (= phy_clk_i1) -> tidelink_0/pad_clk_rx.
#     WavD2DGpioTx forwards the clock combinationally (`assign pad_clk = clk`),
#     so on-chip the forwarded clock IS the source die's /8 BUFG output; each
#     rx clock is that same net re-buffered through the receiving die's
#     tidelink_rxclk_buf BUFG (USE_CLKBUF=1). -divide_by 1 (a pure re-buffer).
#
#     rxcap_clk_i0 = die_a captures die_b's forward  -> source phy_clk_div_1 BUFG
#     rxcap_clk_i1 = die_b captures die_a's forward  -> source phy_clk_div_0 BUFG
#-----------------------------------------------------------------------------
create_generated_clock -name rxcap_clk_i0 \
    -source [get_pins -hier -filter {NAME =~ "*phy_clk_div_1*u_div_bufg/O"}] \
    -divide_by 1 [get_pins -hier -filter {NAME =~ "*tidelink_0/inst*u_rxclk_buf/*u_rxclk_bufg/O"}]

create_generated_clock -name rxcap_clk_i1 \
    -source [get_pins -hier -filter {NAME =~ "*phy_clk_div_0*u_div_bufg/O"}] \
    -divide_by 1 [get_pins -hier -filter {NAME =~ "*tidelink_1/inst*u_rxclk_buf/*u_rxclk_bufg/O"}]

#-----------------------------------------------------------------------------
# [4] Async clock groups — isolate the two source-synchronous channels from each
#     other and from hclk, WITHOUT cutting the intra-channel launch<->capture
#     analysis. (Plan M3.) set_max_delay -datapath_only does NOT survive a
#     clock-group cut, so we group by NET-CHANNEL rather than blanket-async:
#
#       A->B channel : { phy_clk_i0 (die_a TX), word_clk_i0 (die_a /16),
#                        rxcap_clk_i1 (die_b capture) }   -- one timed island
#       B->A channel : { phy_clk_i1, word_clk_i1, rxcap_clk_i0 }
#       hclk         : clk_wiz clk_out1 (core / AXI / APB / I2C-autoneg domain)
#
#   Each channel's launch and capture clocks are the SAME re-buffered /8 net, so
#   keeping them in ONE group leaves the mesochronous source-sync path TIMED
#   (the on-chip eye). Cross-channel and channel<->hclk crossings are all 2-flop
#   synchronised in RTL, so they are correctly declared asynchronous here. This
#   is what deletes the -22 ns source-sync WHS-hold class the pinned kr260 pair
#   carried: there are no pads, and the only remaining pad-class paths are cut.
#
#   clk_out2 (25 MHz, phc — PTP off) and clk_out3 (200 MHz, idelay — USE_IDELAY=0)
#   drive no active loads on this target, so they carry no timed paths and are
#   intentionally not referenced here (referencing get_clocks on a load-less
#   clock buys nothing and only adds a name to maintain).
#-----------------------------------------------------------------------------
set hclk_pin [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}]
set_clock_groups -asynchronous \
    -group [get_clocks {phy_clk_i0 word_clk_i0 rxcap_clk_i1}] \
    -group [get_clocks {phy_clk_i1 word_clk_i1 rxcap_clk_i0}] \
    -group [get_clocks -of_objects $hclk_pin]

#-----------------------------------------------------------------------------
# [5] LED false paths — the four status LEDs are human-visible, no timed path.
#     (LOCs are in kr260_tidelink.xdc; these are the only get_ports in this file.)
#-----------------------------------------------------------------------------
set_false_path -to [get_ports {led0 led1 led2 led3}]

#-----------------------------------------------------------------------------
# [6] Combinational-loop waiver (belt-and-braces; primary copy is in
#     kr260_tidelink_drc.xdc). The IP wrapper hard-wires HSEL=1 and loops
#     HREADYOUT back to HREADY_IN on the AHB slaves — the standard Vivado IP-
#     Integrator AHB-Lite slave style, an intentional functionally-correct
#     combinational loop. The -hierarchical wildcard matches the loop in BOTH
#     tidelink_0 and tidelink_1.
#-----------------------------------------------------------------------------
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]

#-----------------------------------------------------------------------------
# [7] set_bus_skew — DELIBERATELY OMITTED on this target (documented decision,
#     not an oversight). The single-die kr260 file's own [3c] section proves at
#     length that set_bus_skew was inapplicable there (a port->register input
#     bus has no valid startpoint; measured inter-lane data skew was 0.2% of the
#     UI, ~3x tighter than the 2 ns a constraint would demand). On THIS target
#     the case for omitting it is even stronger: the eight lanes cross the fabric
#     as pure register-to-register nets with a single clean 120 ns static phase
#     and no channel/ribbon skew at all, so the capture eye is wide open by
#     construction. Adding a set_bus_skew here would require naming the peer die's
#     eight TX launch registers as -from; a filter that silently matched nothing
#     would be promoted to a hard ERROR by the [Vivado 12-1411] message gate —
#     i.e. it would trade a real, self-closing eye for build fragility. The
#     zero-skew-trap mitigation that DOES matter (distinct divider INIT_PHASE) is
#     an RTL fact, proven in sim + the post-synth netlist, not an XDC bound.
#     If eye characterisation later needs it, add it in the phase-2 skew-injector
#     workstream (W11) where a routed cell name is in hand.
#-----------------------------------------------------------------------------
