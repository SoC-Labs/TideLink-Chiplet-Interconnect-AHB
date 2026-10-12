###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - KR260 compute-chiplet - DRC waivers  (LINK 0)
### (die_a/flip and die_b/straight share this file byte-for-byte.)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###   David Mapstone (d.a.mapstone@soton.ac.uk)
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### FIRST-CUT scaffold (gap G1). Ported from kr260-eth-chiplet drc waivers.
###
### Sole purpose: contain DRC severity overrides + ALLOW_COMBINATORIAL_LOOPS
### waivers in a SEPARATE XDC file so they survive `save_constraints` round-trips
### (which rewrites *_timing.xdc and tends to drop these properties).
###
### Applied during BOTH synthesis and implementation (default).
###-----------------------------------------------------------------------------

# IP-Integrator AHB-Lite HSEL=1 + HREADY loopback creates an intentional
# combinatorial loop on the HREADY net. Downgrade the DRC severity globally
# AND apply the per-net waiver - write_bitstream's pre-DRC has historically
# ignored the severity downgrade in Vivado 2024.1.
#
# SCOPING-TODO [BD-AHB]: confirm the compute IP response-mux net path once the
# BD is built (eth: *u_xhb_sub/u_core/u_resp/*). Compute may expose two D2D AHB
# subs (link-0 and link-1); widen the filter if link-1's sub is also present.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]

# NOTE: no ILA/debug-core stanza here (no-ILA headroom build, as kr260-eth-chiplet).
# Regenerate via fpga/scripts/insert_debug_core.tcl (FPGA_INSERT_DEBUG_CORE=1) +
# save_constraints only if a hardware ILA capture is ever needed.
