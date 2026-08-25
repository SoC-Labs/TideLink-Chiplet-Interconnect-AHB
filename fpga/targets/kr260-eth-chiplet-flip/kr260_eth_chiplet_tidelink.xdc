#-----------------------------------------------------------------------------
# nanoSoC eth-chiplet - KR260 Pin Constraints (die_b / FLIP)
#                       (mirror of kr260-eth-chiplet die_a)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# die_b mirror of the die_a pin map: the TX and RX ball-sets are SWAPPED (and the
# two forwarded-clock balls swapped) so a plain STRAIGHT-THROUGH RPi ribbon
# connects die_a's TX conductors to die_b's RX conductors on the same physical
# header pins, and vice-versa. Lane index is preserved. LEDs/UART/SWD are
# off-ribbon and keep the SAME balls as die_a.
#-----------------------------------------------------------------------------

#-- TX side (die_b drives; lands on die_a's RX pins) --------------------------
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx]  ;# BCM8 HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx[7]}] ;# BCM19

#-- RX side (die_b receives; driven by die_a's TX pins) -----------------------
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx]  ;# BCM0 HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx[7]}] ;# BCM7

#-- Console UART on spare RPi pins (same balls as die_a) ----------------------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports uart_txd] ;# BCM20
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 }                    [get_ports uart_rxd] ;# BCM21

#-- Status LEDs on PMOD3 (moved off PMOD1 — the LAN8720 module takes it) -----
# LEDs: BOTH parked on PMOD2, and PMOD3.10 DELIBERATELY LEFT UNASSIGNED.
#
# WHY PMOD3.10 IS NOW EMPTY. The RP2350 HOSTIO debugger drives an EIGHTH signal
# the chiplet does not have: extio.py declares `XIOT_MODE = Pin(7, Pin.OUT)`,
# the FT1248-vs-EXTIO select. Our FT1248MODE is hardwired 1'b0 inside the SoC
# (nanosoc_multicore_soc.sv:1594) and is not a pad, so P1 is only [6:0].
# The operator's ribbon carries all 8 conductors (8 series resistors fitted), so
# GPIO7/MODE lands on PMOD3.10. Driving led0 there would put TWO push-pull
# outputs on one wire. Leaving the ball unassigned makes the FPGA hold it
# high-Z, so the RP2350 may drive MODE harmlessly into nothing -- which is
# exactly right, because the mode it selects is the only mode this chip has.
#
# WE LOSE NOTHING AS A CONTROL. led0 was placed on PMOD3 to give a plain
# always-driven bank-43 output to scope if HOSTIO looked dead. ioreq1/ioreq2 on
# PMOD3.1/3.2 already are that: P1_OUTEN[0]/[1] are constant 1, so the FPGA
# drives them unconditionally. Scope PMOD3.1.
#
# led0/led1 are pure observability (link_active / role_is_master, also readable
# over the eth_ss_0 backdoor). They are constrained rather than deleted only
# because an unconstrained port fails DRC UCIO-1. PMOD2 is bank 45, where
# nothing has ever worked -- so do NOT read anything into whether they light.
set_property -dict { PACKAGE_PIN H11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD2.7 — link_active (parked, bank 45)
set_property -dict { PACKAGE_PIN G10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD2.8 — role_is_master (parked, bank 45)

#-----------------------------------------------------------------------------
# CoreSight SWD on PMOD2 (3.3V HD bank, off the bank-44 ribbon).
# Moved off PMOD4: PMOD4 sits on HP banks 64/65 (1.8V) and rejected LVCMOS33
# (DRC BIVB-1), which would have required a 1.8V-only probe. PMOD2 is 3.3V so an
# ordinary ST-Link / DAPLink works directly.
#   PMOD2 pin1 = J11 -> SWCLK ; pin2 = J10 -> SWDIO ; pin3 = K13 -> SWD_NPORESETN
#   GND on pin5/11, 3V3 (probe VREF) on pin6/12.
# Drives the same OpenOCD flow as the Z2 build (transport=swd).
#-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLDOWN true } [get_ports SWCLK]
set_property -dict { PACKAGE_PIN J10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }   [get_ports SWDIO]
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }   [get_ports SWD_NPORESETN]

# SWCLK is a slow external debug clock and may land on a non-ideal (clock-capable)
# pin; waive dedicated clock-routing so the placer accepts it.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports SWCLK]]

#-----------------------------------------------------------------------------
# LAN8720 RMII PHY — Waveshare module plugs into PMOD1 (3.3V HD bank).
# Module pinout is FIXED by the board; ported from the working PYNQ-Z2 build
# (pynq/targets/pynq-z2/nanosoc_multicore.xdc, where it sits on PMODB):
#   pin1=RX1  pin2=TX0  pin3=CRS_DV  pin4=MDC
#   pin7=TX_EN pin8=RX0 pin9=MDIO    pin10=nINT/REF_CLK
# 9 signals vs 8 pins, so TX1 is the single overflow -> PMOD2 pin4 (K12),
# the nearest free pin (SWD occupies PMOD2 pins 1-3 only).
# No PHY reset pin: the Waveshare module self-resets (the Z2 drives none).
#-----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 } [get_ports {rmii_rxd[1]}]   ;# PMOD1.1  RX1
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports rmii_crs_dv]      ;# PMOD1.3  CRS_DV
set_property -dict { PACKAGE_PIN E12 IOSTANDARD LVCMOS33 } [get_ports {rmii_rxd[0]}]   ;# PMOD1.8  RX0
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 } [get_ports mdc_pad_o] ;# PMOD1.4 MDC
set_property -dict { PACKAGE_PIN D11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true } [get_ports MDIO] ;# PMOD1.9

# RMII TX: SLEW FAST + DRIVE 16 is the Z2-validated source-synchronous config.
# NOTE: the Z2 also sets IOB TRUE here; NOT replicated because TideLink's pad_rx
# needed IOB FALSE on this device — verify IOB packing on the KR260 HD bank
# before adding it.
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16 } [get_ports {rmii_txd[0]}] ;# PMOD1.2 TX0
set_property -dict { PACKAGE_PIN B10 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16 } [get_ports rmii_tx_en]     ;# PMOD1.7 TX_EN
set_property -dict { PACKAGE_PIN K12 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 16 } [get_ports {rmii_txd[1]}] ;# PMOD2.4 TX1 (overflow)

# 50 MHz REF_CLK from the PHY (REF_CLK_OUT mode) on a non-clock-capable pin —
# exactly as the Z2 does at V12. The create_clock is REQUIRED: without it any
# rmii_ref_clk-referencing timing constraint silently matches nothing.
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports rmii_ref_clk]     ;# PMOD1.10
create_clock -period 20.000 -name rmii_ref_clk -waveform {0.000 10.000} -add [get_ports rmii_ref_clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports rmii_ref_clk]]

#-----------------------------------------------------------------------------
# HOSTIO4 EXTIO host port — 7 bidirectional pads (M3).
#
# The SoC hardwires FT1248MODE = 1'b0 (nanosoc_multicore_soc.sv:1594), so the
# EXTIO personality is always active and the pin roles are fixed:
#   P1[0] ioreq1  OUT (permanent drive, P1_OUTEN[0] = 1'b1)
#   P1[1] ioreq2  OUT (permanent drive, P1_OUTEN[1] = 1'b1)
#   P1[2] ioack   IN  (permanent input,  P1_OUTEN[2] = 1'b0)
#   P1[6:3] iodata[3:0] BIDIR, common nibble OE
#
# Placement: the 4 iodata bits are kept together on PMOD2 pins 7-10 so a single
# ribbon carries the data nibble; the 3 handshake bits go to PMOD3. Balls are
# from docs/bringup/KR260_BOARD_WIRING.md (PMOD2 = som240_1, PMOD3 = som240_2;
# both are 3.3 V HD banks). PMOD3 pins 7/8 (AF11/AG11) are deliberately LEFT
# FREE — KR260_BOARD_WIRING.md "Option B" reserves them for a USB-UART dongle.
# PMOD4 is unusable here: HP bank 64/65 at 1.8 V, LVCMOS33 fails DRC BIVB-1.
#
# PULLUP on every bit MIRRORS THE ASIC, where all 7 pads are PDDW16DGZ_G with
# REN tied high (on-die pull-ups enabled). This matters functionally on P1[2]:
# ioack idles HIGH, and the controller's start condition is
# `start_xfer = cmd_req & !ioack_s` (hostio4_controller_fsm.v:313), so a pulled-
# up (or unattached) ioack holds the FSM idle. A floating ioack read as 0 could
# let it start transfers into a host that is not there.
#
# NOTE: these are the SAME balls on die_a and die_b — HOSTIO4 is off-ribbon, so
# unlike pad_tx/pad_rx it is NOT mirrored in the flip target.
#-----------------------------------------------------------------------------
# PLACEMENT: ALL SEVEN ON PMOD3, DELIBERATELY.
#   PMOD3 balls are MEASURED bank 43 (all eight, Vivado package DB, part
#   xck26-sfvc784-2LV-c; fourteen control balls on PMOD1/PMOD2/J21 reproduced
#   their known banks 45/45/44, so the method is validated, not asserted).
#   PMOD1 and PMOD2 are bank 45, where NOTHING has ever worked -- the fitted,
#   powered LAN8720's MDIO returns rotating garbage from all 32 addresses and
#   SWD has never returned a DPIDR. J21 (bank 44) works. Splitting the nibble
#   onto PMOD2 would put the data path on the suspect bank, need two ribbons
#   for a one-connector debugger, and make the result uninterpretable.
#   Keeping it whole on bank 43 also makes this a bank-45 DISCRIMINATOR: the
#   protocol is interlocked, so ONE transferred byte proves all seven pins
#   bidirectionally. It cannot half-work.
#
# PULLUP on ioack is FUNCTIONAL, not hygiene: the ioack synchroniser presets to
#   1 (hostio4_controller.v:55-57) and start_xfer = cmd_req & !ioack_s
#   (hostio4_controller_fsm.v:313), so ioack idling HIGH holds the FSM idle. A
#   floating ioack read as 0 could start transfers into a host that is not there.
#   RESOLVED 2026-08-24: the RP2350 board carries 330 ohm series resistors on all
#   8 PMOD signal lines (operator-measured). Against the FPGA weak pull-up that
#   gives an ioack low level of 204 mV worst case (5k pull-up), 105 mV typical
#   (10k) -- all well under the LVCMOS33 VIL of ~0.8 V, so the PULLUP STAYS.
#   For the record, the threshold this was checked against: at 4.7k or more the
#   pull-up would win the divider, ioack would never read low, and the FSM would
#   never start -- which looks exactly like dead wiring. 330R is nowhere near it.
#   Those resistors also cap ESD-diode current at ~10 mA during power sequencing,
#   which matters because the RP2350 PMOD has GROUND ONLY (3V3 not soldered), so
#   the two boards are independently powered with no shared rail.
#
# DRIVE 8 / SLEW SLOW, not the Z2's implicit 12: HOSTIO4 is a fully interlocked
#   4-phase handshake with no source-synchronous clock, so edge rate buys zero
#   timing margin and costs ringing on flying leads. Matches SWD and MDC/MDIO
#   here; FAST/16 is reserved for RMII TX, the one genuinely source-synchronous
#   port. No IOB TRUE: inputs land in 2-flop synchronisers and packing the first
#   stage into a pad site would defeat ASYNC_REG placement -- the RMII IOB
#   omission was a defect because RMII IS source-synchronous; copying it here
#   would be the same cargo-culting in reverse.
set_property -dict { PACKAGE_PIN AE12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 }             [get_ports hostio4_ioreq1]       ;# PMOD3.1  ioreq1  SoC drives (OE const 1)
set_property -dict { PACKAGE_PIN AF12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 }             [get_ports hostio4_ioreq2]       ;# PMOD3.2  ioreq2  SoC drives (OE const 1)
set_property -dict { PACKAGE_PIN AG10 IOSTANDARD LVCMOS33 PULLUP true }                   [get_ports hostio4_ioack]        ;# PMOD3.3  ioack   host drives (OE const 0)
set_property -dict { PACKAGE_PIN AH10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true } [get_ports {hostio4_iodata4[0]}] ;# PMOD3.4  iodata0 bidir
set_property -dict { PACKAGE_PIN AF11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true } [get_ports {hostio4_iodata4[1]}] ;# PMOD3.7  iodata1 bidir
set_property -dict { PACKAGE_PIN AG11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true } [get_ports {hostio4_iodata4[2]}] ;# PMOD3.8  iodata2 bidir
set_property -dict { PACKAGE_PIN AH12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true } [get_ports {hostio4_iodata4[3]}] ;# PMOD3.9  iodata3 bidir
