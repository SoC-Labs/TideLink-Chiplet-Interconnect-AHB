#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Pynq-Z2 Paired GPIO-Bridge Pin Constraints (Wave B2)
#
# NOTE: FPGA pin assignments are IDENTICAL to the single-instance target.
# The "cross-strap" between two paired boards is achieved by the physical
# ribbon cable wiring (see ribbon_wiring.md), not by the XDC. Both boards
# run the same bitstream; the ribbon physically wires Board-A pad_tx[n]
# (which leaves via RPi pin X) to Board-B pad_rx[n] (which arrives via
# RPi pin Y).
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# TideLink GPIO PHY pads mapped to the Pynq-Z2 Raspberry Pi GPIO header
# (40-pin connector, J13 on the Pynq-Z2 v1.0 board).
#
# All 18 lanes are on bank 35 (LVCMOS33). The FPGA-pin column is verified
# against the Vivado pynq-z2 A.0 board file
#   /apps/Xilinx/Vivado/2024.1/data/boards/pynq-z2/A.0/part0_pins.xml
# under the `raspberry_pi_tri_i_<idx>` indices.
#
# Vivado RPi index → FPGA pin (verified):
#   idx  0  pad_clk_tx  W18
#   idx  1  pad_tx[0]   W19
#   idx  2  pad_tx[1]   Y18
#   idx  3  pad_tx[2]   Y19
#   idx  4  pad_tx[3]   U18
#   idx  5  pad_tx[4]   U19
#   idx  6  pad_tx[5]   F19
#   idx  7  pad_tx[6]   V10
#   idx  8  pad_tx[7]   V8
#   idx  9  pad_clk_rx  W10
#   idx 10  pad_rx[0]   B20
#   idx 11  pad_rx[1]   W8
#   idx 12  pad_rx[2]   V6
#   idx 13  pad_rx[3]   Y6
#   idx 14  pad_rx[4]   B19
#   idx 15  pad_rx[5]   U7
#   idx 16  pad_rx[6]   C20
#   idx 17  pad_rx[7]   Y8
#
# Physical-pin numbers on the J13 header (e.g. "pin 3 = W18 = idx 0") still
# need cross-checking against Table 6.10 of the PYNQ-Z2 v1.0 Reference
# Manual — Vivado's index space is NOT the same as either the BCM GPIO
# number or the Pi-40 physical pin number. See ribbon_wiring.md for the
# inter-board cable convention (TX[idx i] -> RX[idx i+9]).
#-----------------------------------------------------------------------------

#-- TX side (outputs from TideLink) ------------------------------------------
# Pin map (2026-04-29): moved entirely off Vivado RPi indices 0..5
# (W18/W19/Y18/Y19/U18/U19) because those FPGA balls are physically wired
# to BOTH J13 and Pmod A on the Pynq-Z2 v1.0 board. The Pmod A connector
# adds parasitic capacitance, AND four of those balls have external pull-up
# resistors on the Pynq-Z2 PCB (for I2C0/I2C1 functionality on the Pi
# side). Together those make a 50 MHz LVCMOS edge much too slow — the
# eye closes and Wlink RX can't sync. See base.xdc lines 41-53.
#
# This XDC uses Vivado RPi indices 6..23 — all 18 RPi-only pins, no
# Pmod-shared balls, no external pull-ups.

# pad_clk_tx: TX clock forwarded to paired board.
#   Y9 is IO_L14P_T2_SRCC_13 — single-region clock-capable, P-side.
#   Vivado allows clock OUTPUTS on any pin, but keeping clock outputs on
#   clock-capable sites helps minimise insertion delay.
#   The reason this is on Y9 instead of the MRCC Y7 is that with a
#   straight-through ribbon, the slave's pad_clk_rx must land on the SAME
#   J13 pin as the master's pad_clk_tx. Vivado's PLIO-9 DRC rejects clock
#   INPUTS on N-side pins, so both clocks must be P-side. Y7 (MRCC P) is
#   used as master's pad_clk_rx; Y9 (SRCC P) carries master's pad_clk_tx
#   so that slave's pad_clk_rx (also Y9 via the cable) is also on a P-side
#   clock-capable site.
set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports pad_clk_tx]

# pad_tx[7:0]: TX data lanes
set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[0]}]
set_property -dict {PACKAGE_PIN V10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[1]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[2]}]
set_property -dict {PACKAGE_PIN W10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[3]}]
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[4]}]
set_property -dict {PACKAGE_PIN W8 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[5]}]
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[6]}]
# LANE-7 REMAP: v4 diag-swap proved B19/F20 physically bad (fault followed
# pin F20, not lane index). Moved to spare W9/V7 = J13 pins 13/37 — carried
# by the 1:1 ribbon, NOT in the 12 cut conductors, driven by no other XDC.
# Mirror preserved with pynq-z2-pair-flip-all.
set_property -dict {PACKAGE_PIN W9 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports {pad_tx[7]}]  ;# was B19 (bad)

#-- RX side (inputs to TideLink) ---------------------------------------------

# pad_clk_rx: clock received from paired board.
#   Y7 is IO_L13P_T2_MRCC_13 — multi-region clock-capable P-side. Best
#   available input clock pin on the J13 RPi header. Vivado infers a BUFG
#   automatically and the dedicated clock network distributes the recovered
#   clock to all pad_rx[*] sample registers.
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS33} [get_ports pad_clk_rx]

# pad_rx[7:0]: RX data lanes
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {pad_rx[0]}]
set_property -dict {PACKAGE_PIN C20 IOSTANDARD LVCMOS33} [get_ports {pad_rx[1]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS33} [get_ports {pad_rx[2]}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {pad_rx[3]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {pad_rx[4]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33} [get_ports {pad_rx[5]}]
set_property -dict {PACKAGE_PIN Y6 IOSTANDARD LVCMOS33} [get_ports {pad_rx[6]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports {pad_rx[7]}]  ;# was F20 (bad) — LANE-7 REMAP

#-- Inter-board I2C (autonomous lane-mask coordination) ----------------------
# SHORTCOMINGS-14a/14b: the autonomous cross-board lane-lock flow needs a
# real inter-board I2C channel (autoneg master -> peer 0x21C verdict).
#
# NOTE: On feat/td-combined the lane-7 remap already claims W9/V7 (above)
# for pad_tx[7]/pad_rx[7], so the original on-ribbon W9/V7 I2C map cannot
# coexist. The I2C channel is therefore moved to the Arduino dedicated
# I2C pads (P15/P16, on-board pull-ups) by the immediately-following
# repin commit (3de5ebe). The I2C PACKAGE_PIN lines themselves are NOT
# defined here — they're added by 3de5ebe directly on P15/P16.
#
# UNCONDITIONAL (no Tcl guard): Vivado's XDC reader is a restricted
# dialect that does NOT support the Tcl `if` command — an earlier
# `if {[llength [get_ports -quiet ...]]}` guard was silently skipped
# (CRITICAL WARNING [Designutils 20-1307]), so pin constraints never
# applied and place_design failed with "[Place 30-58] unplaced IO Ports:
# i2c_scl_io i2c_sda_io". BD Edit 1 is committed in BOTH pynq-z2-pair-all
# and -flip-all, so these ports ALWAYS exist in these targets — the
# constraints can (and must) be unconditional like every other pin.


#-- Board LEDs ----------------------------------------------------------------
# LD0 (R14) = link_active      — lit when the D2D link is established
# LD1 (P14) = role_is_master_o — lit when this node won the master role
# LD2 (N16) = wlink_irq        — strobes on Wlink PHY events
# LD3 (M14) = released_credits_irq — strobes on credit release events
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports led3]

#-- Bitstream configuration ---------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]











