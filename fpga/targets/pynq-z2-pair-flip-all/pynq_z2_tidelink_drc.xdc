###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 - DRC waivers
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###-----------------------------------------------------------------------------
### Sole purpose: contain DRC severity overrides + ALLOW_COMBINATORIAL_LOOPS
### waivers in a SEPARATE XDC file so they survive `save_constraints` round-trips
### (which rewrites *_timing.xdc and tends to drop these properties).
###
### Applied during BOTH synthesis and implementation (default).
###-----------------------------------------------------------------------------

# IP-Integrator AHB-Lite HSEL=1 + HREADY loopback creates an intentional
# combinatorial loop on the HREADY net. Downgrade the DRC severity globally
# AND apply per-net waiver — write_bitstream's pre-DRC has historically
# ignored the severity downgrade in Vivado 2024.1.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]

# ILA debug core (create_debug_core u_dbg_int + dbg_hub + 271 DONT_TOUCH probe-net
# keepers) REMOVED 2026-06-19 for the no-ILA headroom build. That stanza was being
# synthesised into EVERY build (build_design.tcl globs *_tidelink_drc.xdc and adds
# it unconditionally), consuming slices/BRAM; with mark_debug stripped it failed
# impl with Chipscope 16-213 (u_dbg_int/probe0 unconnected). Dropping it both fixes
# that and frees the ILA's resources + lets Vivado optimise the 271 DONT_TOUCH nets,
# adding headroom for phys_opt's pad_rx->capture placement. Regenerate via
# fpga/scripts/insert_debug_core.tcl (FPGA_INSERT_DEBUG_CORE=1) + save_constraints
# if a hardware ILA capture is needed (or restore from git commit 61ce19b).

# pad_clk_rx dedicated clock route (die_b A->B fix, 2026-06-23).
# REQUIRE the forwarded RX clock to use the dedicated clock network from the
# clock-capable pin (Y9 / IO_L14P_T2_SRCC_13) through the explicit top-level
# IBUFG+BUFG in tidelink_clk_rx_buf (see tidelink_design.tcl clk_rx_buf cell +
# the USE_CLKBUF=1'b0 IP override). TRUE is the Vivado default; we set it
# explicitly so a regression that pushes the BUFG off the dedicated network is
# a hard placer error rather than a silent LUT-routed clock (the diagnosed
# die_b flip-build root cause: WHS -21.7 ns). NOTE: this is the OPPOSITE of the
# legacy pynq-z2-single workaround (CLOCK_DEDICATED_ROUTE FALSE) — that target's
# pad_clk_rx was on a NON-clock-capable RPi pin (W18) where no dedicated route
# exists, so it had to fall back to fabric. Y9 here IS clock-capable (SRCC), so
# the dedicated route is available and is what we must force. Applied in synth +
# impl (this file is USED_IN_SYNTHESIS/IMPLEMENTATION true) so it survives the
# save_constraints round-trip during any debug-core insertion.
# Net selector mirrors pynq-z2-single: the net driven BY the top-level port.
set_property CLOCK_DEDICATED_ROUTE TRUE [get_nets -of_objects [get_ports pad_clk_rx]]
