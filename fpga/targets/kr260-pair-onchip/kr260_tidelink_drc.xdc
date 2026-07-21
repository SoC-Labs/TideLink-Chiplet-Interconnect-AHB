###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Kria KR260 ON-CHIP PAIR - DRC waivers
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###-----------------------------------------------------------------------------
### Sole purpose: contain DRC severity overrides + ALLOW_COMBINATORIAL_LOOPS
### waivers in a SEPARATE XDC file so they survive `save_constraints` round-trips
### (which rewrites *_timing.xdc and tends to drop these properties).
###
### Applied during BOTH synthesis and implementation (default).
###
### NOTE (on-chip pair): there are TWO complete TideLink instances in this
### design (tidelink_0 + tidelink_1), so the -hierarchical net filter below
### matches the intentional AHB-Lite HREADY combinational loop in BOTH the
### die_a and die_b XHB sub-cores. That is correct and intended — one waiver
### line covers both dies because the filter is a NAME wildcard, not an
### instance-specific path.
###-----------------------------------------------------------------------------

# IP-Integrator AHB-Lite HSEL=1 + HREADY loopback creates an intentional
# combinatorial loop on the HREADY net. Downgrade the DRC severity globally
# AND apply per-net waiver (matches both tidelink_0 and tidelink_1) — write_
# bitstream's pre-DRC has historically ignored the severity downgrade in
# Vivado 2024.1.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]
