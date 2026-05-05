###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 Single-Board Loopback Pin Constraints
###
### The PHY pads (pad_clk_tx, pad_tx[*], pad_clk_rx, pad_rx[*]) are NOT
### exposed at the FPGA pins in this build — the wrapper ties them as
### internal wires (pad_clk_tx → pad_clk_rx, pad_tx[*] → pad_rx[*]). This
### bypasses both the ribbon cable AND the fabric-routed pad_clk_rx
### timing issues, letting a single board run a self-test of the
### Wlink/TideLink link layer with no peer.
###
### Only the LED pins (and Zynq's auto-managed DDR + Fixed IO) need
### physical pin constraints in this target.
###
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------

#-- Board LEDs ----------------------------------------------------------------
# LD0 (R14) = link_active      — lit when role is locked & Wlink runs
# LD1 (P14) = role_is_master_o — strap-controlled (this build always
#                                runs as master since there's no peer)
# LD2 (N16) = wlink_irq        — strobes on Wlink events (link state,
#                                CRC, frame received). With loopback
#                                working, expect brief flicker, NOT
#                                solid-on (solid = continuous errors).
# LD3 (M14) = released_credits_irq — fires when peer (= self) releases
#                                credits back over the FC sideband.
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports led0]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports led1]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports led2]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports led3]
