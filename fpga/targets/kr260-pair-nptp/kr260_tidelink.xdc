#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 Paired GPIO-Bridge Pin Constraints
#                           (die_a / straight — see kr260-pair-flip-* for die_b)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# TideLink GPIO-PHY link mapped onto the KR260 Raspberry-Pi 40-pin header (J21).
# All link + I2C signals are on the K26 SOM's HDIO bank 44 at LVCMOS33 (the RPi
# header is 3.3V on the KR260 carrier). Package balls verified against the K26
# SOM part pin database (xck26-sfvc784) and the nanosoc_tech pynq_kr260 pinmap;
# clock-capability (IS_GLOBAL_CLK / *_HDGC_44) verified in Vivado 2024.1.
#
# rpi_gpio index == Raspberry-Pi BCM GPIO number.  Ball / bank / GC:
#   BCM0  AD15  bank44  HDGC (clk-capable)   BCM1  AD14  bank44  HDGC
#   BCM2  AE15  bank44  (I2C1 SDA)           BCM3  AE14  bank44  (I2C1 SCL)
#   BCM4  AG14  BCM5 AH14  BCM6 AG13  BCM7 AH13   (bank44, plain IO)
#   BCM8  AC14  bank44  HDGC (clk-capable)   BCM9  AC13  bank44  HDGC
#   BCM10 AE13  BCM11 AF13  BCM12 AA13(HDGC) BCM13 AB13(HDGC)
#   BCM14 W14   BCM15 W13   BCM16 AB15(HDGC) BCM17 AB14(HDGC)
#   BCM18 Y14   BCM19 Y13   BCM20 W12   BCM21 W11   BCM22 Y12   BCM23 AA12
#
# RIBBON (straight-through, this die_a build pairs with a die_b flip build):
#   the two forwarded clocks land on the two HDGC balls AD15 (BCM0) and AC14
#   (BCM8) so that on BOTH boards the *received* clock (pad_clk_rx) arrives on a
#   global-clock-capable pin — no CLOCK_DEDICATED_ROUTE override needed. This is
#   the KR260 equivalent of the Z2 MRCC/SRCC clock-pin discipline, but with two
#   full HDGC pins it removes the die_b SRCC weakness entirely.
#   The ribbon must bridge ONLY the 18 link conductors + the 2 I2C conductors
#   (the BCM pins used below). LEDs are on PMOD0 (off-ribbon). See ribbon_wiring.md.
#-----------------------------------------------------------------------------

#-- TX side (outputs from TideLink) ------------------------------------------
# pad_clk_tx forwarded on HDGC ball AD15 (BCM0); becomes die_b's pad_clk_rx.
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx] ;# BCM0  HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[7]}] ;# BCM7

#-- RX side (inputs to TideLink) ---------------------------------------------
# pad_clk_rx received on HDGC ball AC14 (BCM8); driven by die_b's pad_clk_tx.
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx] ;# BCM8  HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx[7]}] ;# BCM19

#-- Inter-board I2C sideband (autoneg role-lock) -----------------------------
# KR260 RPi-header I2C1: BCM2 = SDA (AE15), BCM3 = SCL (AE14). Symmetric across
# the ribbon (SDA<->SDA, SCL<->SCL) — no flip. Open-drain via wrapper assigns.
# PULLTYPE PULLUP: in the KR260<->KR260 ribbon topology there is NO Raspberry-Pi
# carrier or HAT fitting the I2C bus pull-ups (the old "carrier provides them"
# comment was wrong for a straight ribbon between two SOMs). Without a pull the
# open-drain SDA/SCL float, and a floating bus can clock the on-die autoneg I2C
# slave into spurious transactions that hijack the Wlink APB port. The SOM's weak
# internal pull-up (~50 kOhm) holds both lines idle-high as a safety net.
# NB xck26 is UltraScale+ => the property is PULLTYPE, not the 7-series
# `PULLUP TRUE`. A bench 2.2 kOhm to 3V3 on ONE board is still preferred for
# signal integrity at speed; this weak pull only guarantees a safe idle.
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_sda_io] ;# BCM2 SDA1
set_property -dict { PACKAGE_PIN AE14 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_scl_io] ;# BCM3 SCL1

#-- Status LEDs on PMOD0 (OFF the RPi ribbon — avoids driver contention when a
#   straight ribbon bridges both boards' headers). Optional: drive an external
#   PMOD LED module, or just probe. Balls from the nanosoc KR260 pinmap.
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD0_0 — link_active
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD0_1 — role_is_master
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led2] ;# PMOD0_2 — wlink_irq
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led3] ;# PMOD0_3 — released_credits_irq
