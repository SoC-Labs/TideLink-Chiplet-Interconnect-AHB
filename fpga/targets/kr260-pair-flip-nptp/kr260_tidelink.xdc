#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 Paired GPIO-Bridge Pin Constraints
#                           (die_b / FLIP — mirror of kr260-pair-* die_a)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# die_b mirror of the die_a pin map: the TX ball-set and RX ball-set are SWAPPED
# (and the two forwarded-clock balls swapped) so a plain STRAIGHT-THROUGH RPi
# ribbon connects die_a's TX conductors to die_b's RX conductors on the same
# physical header pins, and vice-versa. Lane index is preserved (die_a pad_tx[i]
# and die_b pad_rx[i] share a physical pin; and die_b pad_tx[i] / die_a pad_rx[i]).
#
# Both forwarded clocks are on HDGC balls (AD15 BCM0, AC14 BCM8) so that on this
# die too the RECEIVED clock (pad_clk_rx, here AD15) lands on a global-clock pin.
# I2C (BCM2/BCM3) and the PMOD0 LEDs are identical to die_a (no flip). All link +
# I2C signals on HDIO bank 44, LVCMOS33. See die_a XDC for the full ball table.
#-----------------------------------------------------------------------------

#-- TX side (outputs from TideLink) — die_b drives the die_a RX ball-set --------
# pad_clk_tx forwarded on HDGC ball AC14 (BCM8); becomes die_a's pad_clk_rx.
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx] ;# BCM8  HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[7]}] ;# BCM19

#-- RX side (inputs to TideLink) — die_b receives the die_a TX ball-set ---------
# pad_clk_rx received on HDGC ball AD15 (BCM0); driven by die_a's pad_clk_tx.
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx] ;# BCM0  HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[7]}] ;# BCM7

#-- Inter-board I2C sideband (symmetric — identical to die_a) -----------------
# PULLTYPE PULLUP holds the open-drain SDA/SCL idle-high: no RPi carrier/HAT fits
# bus pull-ups in the KR260<->KR260 ribbon topology, so the SOM's weak internal
# pull-ups stop the floating lines from clocking the autoneg I2C slave into
# spurious APB-hijacking transactions. xck26 is UltraScale+ => PULLTYPE, not the
# 7-series `PULLUP TRUE`. See die_a XDC for the full rationale.
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_sda_io] ;# BCM2 SDA1
set_property -dict { PACKAGE_PIN AE14 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_scl_io] ;# BCM3 SCL1

#-- Status LEDs on PMOD0 (off-ribbon — identical to die_a) --------------------
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD0_0 — link_active
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD0_1 — role_is_master
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led2] ;# PMOD0_2 — wlink_irq
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led3] ;# PMOD0_3 — released_credits_irq
