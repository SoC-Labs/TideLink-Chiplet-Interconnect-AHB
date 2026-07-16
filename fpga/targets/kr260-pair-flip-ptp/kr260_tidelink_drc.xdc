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
