################################################################################
# TideLink Chiplet Bridge — ARM MPS3 Pin Constraints
#
# Target: Kintex UltraScale xcku115-flvb1760-1-c
#         (confirmed by ethernet-subsystem-ahb MPS3 bring-up in this SoCLabs
#          tree; the Makefile placeholder xcku115-flva1517-2-e is WRONG —
#          see README.md TODO item).
#
# Cross-reference:
#   Arm MPS3 FPGA Prototyping Board TRM 100765_0000_04_en
#   NanoSoC fpga_pinmap.xdc (nanosoc_m0_project tree)
#   ethernet-subsystem-ahb/fpga/targets/arm_mps3/ethernet_subsystem.xdc
#
# I/O Standards:
#   LVCMOS18 — on-board signals (LEDs, button, OSCCLK, UART)
#   LVCMOS33 — Shield/FPGA-IO connector (set IOREF link jumper to 3V3)
#
# Board user-link prerequisites (TRM §2.16):
#   Set the Shield-0 / Pmod-0-1 IOREF link to 3V3 for LVCMOS33 PHY pads.
#
# Vivado version target: 2025.2
# Last updated: April 2026
################################################################################

################################################################################
## Board oscillator — 24 MHz fixed reference
##
## OSCCLK[0] = AL15, pin-site IO_L11P_T1U_N8_GC_66 (GC-capable)
## Clocking Wizard uses this to generate 50 MHz hclk via MMCM.
## create_clock issued here; CLOCK_DEDICATED_ROUTE not needed (GC site).
################################################################################
set_property -dict {PACKAGE_PIN AL15 IOSTANDARD LVCMOS18} [get_ports OSCCLK]
create_clock -period 41.667 -name osc_24mhz -waveform {0.000 20.833} -add [get_ports OSCCLK]

################################################################################
## Push button — system reset (USER_nPB[0], active-low)
################################################################################
set_property -dict {PACKAGE_PIN AT30 IOSTANDARD LVCMOS18} [get_ports USER_nPB]

################################################################################
## User LEDs — active-low (USER_nLED[7:0], LVCMOS18)
##
## LED assignments (wrapper drives these active-low):
##   LED[0] link_active           AU32
##   LED[1] d2d_reset_o           AU30
##   LED[2] released_credits_irq  AU31
##   LED[3] doorbell_irq          AR32
##   LED[4] packet_committed_irq  AT33
##   LED[5] ptp_irq               AW30
##   LED[6] wlink_irq             AW31
##   LED[7] nego_error_irq        AR30
################################################################################
set_property -dict {PACKAGE_PIN AU32 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[0]}]
set_property -dict {PACKAGE_PIN AU30 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[1]}]
set_property -dict {PACKAGE_PIN AU31 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[2]}]
set_property -dict {PACKAGE_PIN AR32 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[3]}]
set_property -dict {PACKAGE_PIN AT33 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[4]}]
set_property -dict {PACKAGE_PIN AW30 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[5]}]
set_property -dict {PACKAGE_PIN AW31 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[6]}]
set_property -dict {PACKAGE_PIN AR30 IOSTANDARD LVCMOS18} [get_ports {USER_nLED[7]}]

################################################################################
## TideLink GPIO PHY Pads — FPGA-IO expansion connector
##
## 18 signals routed to the MPS3 Shield/FPGA-IO connector:
##   1  pad_clk_tx   TX clock output
##   8  pad_tx[7:0]  TX data lanes (output)
##   1  pad_clk_rx   RX clock input
##   8  pad_rx[7:0]  RX data lanes (input)
##
## I/O standard: LVCMOS33 (Shield connector, 3V3 IOREF link required)
##
## TODO: ALL PHY PAD PIN ASSIGNMENTS BELOW ARE PLACEHOLDER.
## The actual FPGA-IO connector pinout for the TideLink PHY expansion board
## has not been confirmed against the MPS3 TRM Table A-12/A-13 (SH0/SH1).
##
## To complete this XDC:
##   1. Identify the shield connector column used by the TideLink PHY breakout.
##   2. Cross-reference with TRM Table A-12 (SH0_IO) or A-13 (SH1_IO) to get
##      the FPGA package pin for each connector position.
##   3. Replace the TODO_PIN_xx placeholders below with the correct values.
##   4. Note parasitic SH0_IO[16:17] / SH1_IO[16:17] (4K7 to IO[14:15]) and
##      add Hi-Z declarations for any bank where IO[14:15] are used by PHY pads.
##
## Reference pin examples from the MPS3 SH0 bank (from eth-ss XDC):
##   SH0_IO[0]  = AW14    SH0_IO[4]  = AY13    SH0_IO[9]  = BB12
##   SH0_IO[1]  = AW13    SH0_IO[5]  = AY12    SH0_IO[14] = AV12
##   SH0_IO[2]  = AW15    SH0_IO[6]  = TODO     SH0_IO[15] = AV17
##   SH0_IO[3]  = AY15    SH0_IO[7]  = TODO
## Use remaining unassigned SH0 or SH1 pins for the 18 TideLink PHY signals.
################################################################################

## TX clock output (1 pin)
# TODO: Replace TODO_PIN_CLK_TX with confirmed FPGA package pin
# set_property -dict {PACKAGE_PIN TODO_PIN_CLK_TX IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports pad_clk_tx]

## TX data lanes [7:0] (8 pins)
# TODO: Replace TODO_PIN_TX_x with confirmed FPGA package pins
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_0 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[0]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_1 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[1]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_2 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[2]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_3 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[3]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_4 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[4]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_5 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[5]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_6 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[6]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_TX_7 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {pad_tx[7]}]

## RX clock input (1 pin)
# TODO: Replace TODO_PIN_CLK_RX with confirmed FPGA package pin
# Note: preferably a GC or CCIO site so the RX clock reaches BUFG/MMCM cleanly
# set_property -dict {PACKAGE_PIN TODO_PIN_CLK_RX IOSTANDARD LVCMOS33} [get_ports pad_clk_rx]

## RX data lanes [7:0] (8 pins)
# TODO: Replace TODO_PIN_RX_x with confirmed FPGA package pins
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_0 IOSTANDARD LVCMOS33} [get_ports {pad_rx[0]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_1 IOSTANDARD LVCMOS33} [get_ports {pad_rx[1]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_2 IOSTANDARD LVCMOS33} [get_ports {pad_rx[2]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_3 IOSTANDARD LVCMOS33} [get_ports {pad_rx[3]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_4 IOSTANDARD LVCMOS33} [get_ports {pad_rx[4]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_5 IOSTANDARD LVCMOS33} [get_ports {pad_rx[5]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_6 IOSTANDARD LVCMOS33} [get_ports {pad_rx[6]}]
# set_property -dict {PACKAGE_PIN TODO_PIN_RX_7 IOSTANDARD LVCMOS33} [get_ports {pad_rx[7]}]

################################################################################
## I2C sideband — open-drain (optional, no confirmed pin assignment)
## TODO: Assign to a free MPS3 FPGA-IO pin pair if sideband I2C is needed.
## For first bring-up, these ports are tied off in the BD and can be omitted.
################################################################################
# set_property -dict {PACKAGE_PIN TODO_I2C_SCL IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_scl]
# set_property -dict {PACKAGE_PIN TODO_I2C_SDA IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_sda]

################################################################################
## Shield bus switch reset (SH_nRST — drive HIGH to enable pass transistors)
## TODO: Confirm whether AU14 (used in eth-ss design) is appropriate here.
## If no shield bus switches are in the signal path, this pin is optional.
################################################################################
# set_property -dict {PACKAGE_PIN AU14 IOSTANDARD LVCMOS33} [get_ports SH_nRST_n]

################################################################################
## PHY RX clock — link clock constraint
## NOTE: Uncomment and complete after confirming the pad_clk_rx pin assignment.
## The TideLink link clock is nominally 50 MHz (20 ns period).
################################################################################
# create_clock -period 20.000 -name tl_phy_clk_rx -waveform {0.000 10.000} \
#     -add [get_ports pad_clk_rx]
