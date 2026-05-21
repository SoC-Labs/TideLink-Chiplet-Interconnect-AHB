###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 Paired (FLIP) Pin Constraints
###
### Mirror image of pynq-z2-pair: pad_tx[*] and pad_rx[*] are swapped on
### the RPi header so a STRAIGHT-THROUGH 40-pin ribbon cable correctly
### delivers TX-of-one-board to RX-of-the-other (and vice versa).
###
### How to use:
###   - Build BOTH targets:
###       make TARGET=pynq-z2-pair      build_design   # for die_a (z2_02)
###       make TARGET=pynq-z2-pair-flip build_design   # for die_b (z2_03)
###   - Deploy the standard bitstream (pynq-z2-pair) to die_a, and the
###     FLIP bitstream (pynq-z2-pair-flip) to die_b.
###   - Use any standard 1:1 RPi GPIO ribbon cable between the headers
###     (e.g. The Pi Hut 40-pin ribbon).
###
### Why two bitstreams instead of one + cross-strap cable?
###   The "same bitstream both sides + cross-strap cable" approach in
###   pynq-z2-pair requires a CUSTOM ribbon (off-the-shelf cables are
###   1:1). With two bitstreams the pin-direction mirroring lives in
###   the FPGA, not the cable — any standard 40-pin ribbon works.
###   Trade-off: build twice, deploy two artefacts, but cabling is
###   trivial.
###
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------

#-- TX side (outputs from this board → straight-through ribbon → peer's RX) --
# Pin map (2026-04-29): rebased to use only RPi-only pins (idx 6..23). The
# original mapping put pad_clk_rx on W18 (a Pmod-A-shared, I2C-pulled-up
# ball), which couldn't carry the 50 MHz forwarded clock cleanly. See the
# pynq-z2-pair XDC header for the full justification.
#
# This XDC takes the upper half (idx 15..23) for TX so a 1:1 ribbon
# carries the signals onto the peer pair board's RX (idx 15..23).
# TX side: same J13 pins as pynq-z2-pair's RX side (straight-through cable).
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports pad_clk_tx]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[0]}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[1]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[2]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[3]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[4]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[5]}]
set_property -dict {PACKAGE_PIN Y6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[6]}]
set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[7]}]

#-- RX side (inputs to this board ← straight-through ribbon ← peer's TX) -----
# Mirror of pynq-z2-pair: clocks on Y7/Y9 (both P-side clock-capable).
set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33} [get_ports pad_clk_rx]
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} [get_ports {pad_rx[0]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33} [get_ports {pad_rx[1]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports {pad_rx[2]}]
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS33} [get_ports {pad_rx[3]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports {pad_rx[4]}]
set_property -dict {PACKAGE_PIN W8 IOSTANDARD LVCMOS33} [get_ports {pad_rx[5]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33} [get_ports {pad_rx[6]}]
set_property -dict {PACKAGE_PIN B19 IOSTANDARD LVCMOS33} [get_ports {pad_rx[7]}]

#-- Board LEDs (unchanged from pynq-z2-pair) ----------------------------------
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led3]








