#-----------------------------------------------------------------------------
# nanoSoC eth-chiplet - KR260 Pin Constraints (die_a / straight)
#                       (see kr260-eth-chiplet-flip for die_b)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# TideLink GPIO-PHY link mapped onto the KR260 Raspberry-Pi 40-pin header (J21),
# identical ball map to the bare-link kr260-pair targets (HDIO bank 44, 3.3V,
# straight-through ribbon; the flip build swaps TX/RX balls). Plus the SoC's
# CoreSight SWD on PMOD4 (SOM240_2, off bank 44) and a console UART on spare
# RPi pins. Balls verified against the xck26-sfvc784 SOM pin database.
#-----------------------------------------------------------------------------

#-- TX side (outputs from the chiplet's internal TideLink) --------------------
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx]  ;# BCM0 HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[7]}] ;# BCM7

#-- RX side (inputs to the chiplet's internal TideLink) -----------------------
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx]  ;# BCM8 HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[7]}] ;# BCM19

#-- Console UART on spare RPi pins (BCM20/21, plain IO, off the ribbon) -------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports uart_txd] ;# BCM20
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 }                    [get_ports uart_rxd] ;# BCM21

#-- Status LEDs on PMOD0 (off the RPi ribbon) --------------------------------
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD0_0 — link_active
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD0_1 — role_is_master

#-----------------------------------------------------------------------------
# CoreSight SWD on PMOD4 (SOM240_2; 3.3V, off the bank-44 ribbon).
# Balls resolved from the Vivado 2024.1 kr260_carrier/kr260_som board files:
#   PMOD4 pin1 = L2  -> SWCLK ; pin2 = T7 -> SWDIO ; pin3 = AF7 -> SWD_NPORESETN
# See the header of the companion note; drives the same OpenOCD flow as the Z2
# build (transport=swd). VREF/level-translator caveat: confirm the PMOD4 bank
# Vcco and that its translator passes a push-pull bidirectional SWDIO.
#-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8 PULLDOWN true } [get_ports SWCLK]
set_property -dict { PACKAGE_PIN T7  IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8 PULLUP true }   [get_ports SWDIO]
set_property -dict { PACKAGE_PIN AF7 IOSTANDARD LVCMOS18 SLEW SLOW DRIVE 8 PULLUP true }   [get_ports SWD_NPORESETN]

# SWCLK is a slow external debug clock on a non-ideal (N-type CCIO) pin;
# waive dedicated clock-routing so the placer accepts it.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_ports SWCLK]
