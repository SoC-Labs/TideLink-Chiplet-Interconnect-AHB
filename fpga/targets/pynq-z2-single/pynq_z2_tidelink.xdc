#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Pynq-Z2 Single-Instance Pin Constraints (Wave B1)
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
# Pin assignments are taken from the Digilent PYNQ-Z2 v1.0 Reference Manual,
# Table 6.10 — Raspberry Pi GPIO Connector (bank 35, LVCMOS33).
#
# Source: https://digilent.com/reference/programmable-logic/pynq-z2/reference-manual
#
# RPi physical pin numbering (BCM GPIO numbers in parentheses):
#   TX side — 9 pins, all driven by TideLink (output to pad):
#     RPi pin  4  (GPIO  2) = W18  -> pad_clk_tx  (TX clock)
#     RPi pin  6  (GPIO  3) = W19  -> pad_tx[0]   (TX data lane 0)
#     RPi pin  8  (GPIO  4) = W14  -> pad_tx[1]   (TX data lane 1)
#     RPi pin 10  (GPIO 14) = V17  -> pad_tx[2]   (TX data lane 2)
#     RPi pin 12  (GPIO 15) = V18  -> pad_tx[3]   (TX data lane 3)
#     RPi pin 16  (GPIO 23) = W10  -> pad_tx[4]   (TX data lane 4)
#     RPi pin 18  (GPIO 24) = V9   -> pad_tx[5]   (TX data lane 5)
#     RPi pin 22  (GPIO 25) = V13  -> pad_tx[6]   (TX data lane 6)
#     RPi pin 24  (GPIO  8) = T16  -> pad_tx[7]   (TX data lane 7)
#
#   RX side — 9 pins, all sampled by TideLink (input from pad):
#     RPi pin 26  (GPIO  7) = R16  -> pad_clk_rx  (RX clock)
#     RPi pin 36  (GPIO 16) = U17  -> pad_rx[0]   (RX data lane 0)
#     RPi pin 38  (GPIO 20) = T17  -> pad_rx[1]   (RX data lane 1)
#     RPi pin 40  (GPIO 21) = R17  -> pad_rx[2]   (RX data lane 2)
#     RPi pin 32  (GPIO 12) = P18  -> pad_rx[3]   (RX data lane 3)
#     RPi pin 33  (GPIO 13) = N17  -> pad_rx[4]   (RX data lane 4)
#     RPi pin 35  (GPIO 19) = V16  -> pad_rx[5]   (RX data lane 5)
#     RPi pin 37  (GPIO 26) = U16  -> pad_rx[6]   (RX data lane 6)
#     RPi pin 31  (GPIO  6) = T12  -> pad_rx[7]   (RX data lane 7)
#
# NOTE: These assignments use bank 35 (3.3V) pins as confirmed by the PYNQ-Z2
# schematic. Verify against the PYNQ-Z2 v1.0 XDC master file at:
#   https://reference.digilentinc.com/_media/reference/programmable-logic/pynq-z2/pynq-z2_v1.0.xdc
# Cross-check with Table 6.10 of the PYNQ-Z2 Reference Manual before first
# board bring-up — some RPi header pins are shared with Arduino IO (bank 34)
# and must not be driven if an Arduino shield is installed.
#
# RPi header pins 2, 4 (3V3) and 6, 9, 14, 20, 25, 30, 34, 39 (GND) have
# no FPGA connection and are omitted from this XDC.
#
# Wire chart for inter-board cabling (TX side <-> RX side of paired board):
#   pad_clk_tx  (W18, RPi pin  4) <-> (R16, RPi pin 26) pad_clk_rx
#   pad_tx[0]   (W19, RPi pin  6) <-> (U17, RPi pin 36) pad_rx[0]
#   pad_tx[1]   (W14, RPi pin  8) <-> (T17, RPi pin 38) pad_rx[1]
#   pad_tx[2]   (V17, RPi pin 10) <-> (R17, RPi pin 40) pad_rx[2]
#   pad_tx[3]   (V18, RPi pin 12) <-> (P18, RPi pin 32) pad_rx[3]
#   pad_tx[4]   (W10, RPi pin 16) <-> (N17, RPi pin 33) pad_rx[4]
#   pad_tx[5]   (V9,  RPi pin 18) <-> (V16, RPi pin 35) pad_rx[5]
#   pad_tx[6]   (V13, RPi pin 22) <-> (U16, RPi pin 37) pad_rx[6]
#   pad_tx[7]   (T16, RPi pin 24) <-> (T12, RPi pin 31) pad_rx[7]
#   GND                           <-> GND  (RPi pin  6 or any GND pin)
#-----------------------------------------------------------------------------

#-- TX side (outputs from TideLink) ------------------------------------------

# pad_clk_tx: TX clock forwarded to paired board
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports pad_clk_tx]   ;# RPi GPIO2  / pin 4

# pad_tx[7:0]: TX data lanes
set_property -dict { PACKAGE_PIN W19 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[0]}]  ;# RPi GPIO3  / pin 6
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[1]}]  ;# RPi GPIO4  / pin 8
set_property -dict { PACKAGE_PIN V17 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[2]}]  ;# RPi GPIO14 / pin 10
set_property -dict { PACKAGE_PIN V18 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[3]}]  ;# RPi GPIO15 / pin 12
set_property -dict { PACKAGE_PIN W10 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[4]}]  ;# RPi GPIO23 / pin 16
set_property -dict { PACKAGE_PIN V9  IOSTANDARD LVCMOS33 } [get_ports {pad_tx[5]}]  ;# RPi GPIO24 / pin 18
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[6]}]  ;# RPi GPIO25 / pin 22
set_property -dict { PACKAGE_PIN T16 IOSTANDARD LVCMOS33 } [get_ports {pad_tx[7]}]  ;# RPi GPIO8  / pin 24

#-- RX side (inputs to TideLink) ---------------------------------------------

# pad_clk_rx: TX clock received from paired board
set_property -dict { PACKAGE_PIN R16 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx]   ;# RPi GPIO7  / pin 26

# pad_rx[7:0]: RX data lanes
set_property -dict { PACKAGE_PIN U17 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[0]}]  ;# RPi GPIO16 / pin 36
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[1]}]  ;# RPi GPIO20 / pin 38
set_property -dict { PACKAGE_PIN R17 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}]  ;# RPi GPIO21 / pin 40
set_property -dict { PACKAGE_PIN P18 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[3]}]  ;# RPi GPIO12 / pin 32
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[4]}]  ;# RPi GPIO13 / pin 33
set_property -dict { PACKAGE_PIN V16 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[5]}]  ;# RPi GPIO19 / pin 35
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[6]}]  ;# RPi GPIO26 / pin 37
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[7]}]  ;# RPi GPIO6  / pin 31

#-- Board LEDs ----------------------------------------------------------------
# LD0 (R14) = link_active      — lit when the D2D link is established
# LD1 (P14) = role_is_master_o — lit when this node won the master role
# LD2 (N16) = wlink_irq        — strobes on Wlink PHY events
# LD3 (M14) = released_credits_irq — strobes on credit release events
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports led0]         ;# LD0 — link_active
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports led1]         ;# LD1 — role_is_master
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports led2]         ;# LD2 — wlink_irq
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports led3]         ;# LD3 — released_credits_irq

#-- Bitstream configuration ---------------------------------------------------
set_property CFGBVS         VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3  [current_design]
