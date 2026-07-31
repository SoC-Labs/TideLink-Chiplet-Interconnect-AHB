#-----------------------------------------------------------------------------
# nanoSoC compute-chiplet - KR260 Pin Constraints (die_b / STRAIGHT)
#                           (see kr260-compute-chiplet-flip for die_a)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# FIRST-CUT scaffold (gap G1 - the compute chiplet had NO fpga/ pinout at all).
# Ported 1:1 from kr260-eth-chiplet, but mapped onto the **die_b column** of
# NanoSoC-Hetrogeneous-Chiplet-Testing/docs/BOARD_WIRING.md S3.2 so the SAME
# straight-through J21 ribbon, strip list (phys 1/2/4/17) and >=4 interleaved
# grounds carry over UNCHANGED from the eth<->compute bench. A compute board
# running THIS build pairs against an eth-chiplet die_a (straight) board, or
# against a compute-chiplet-flip (die_a) board, on one plain straight ribbon.
#
# Link-0 board pads only. Compute has NO ethernet (no RMII/LAN8720/MDIO here).
# Compute has a SECOND TideLink (link-1); a KR260 has ONE J21, so link-1's pads
# are NOT bonded to the header - see the SCOPING-TODO in the timing XDC.
#
# TideLink GPIO-PHY link on the KR260 Raspberry-Pi 40-pin header (J21), HDIO
# bank 44, LVCMOS33 (3.3V). Balls per BOARD_WIRING S3.2 die_b column, which is
# the mirror of the eth die_a map (kr260-eth-chiplet). SWJ-DP debug + UART are
# off the ribbon. Balls verified against the xck26-sfvc784 SOM pin database and
# the nanosoc_tech pynq_kr260 pinmap.
#
#   die_b ball map (compute link-0)          BCM  phys  HDGC
#   ---------------------------------------  ---  ----  ----
#   pad_clk_tx_0 -> AC14  (b->a fwd clock)    8    24    HDGC
#   pad_tx_0[0]  -> AB15                       16   36
#   pad_tx_0[1]  -> AB14                       17   11
#   pad_tx_0[2]  -> AE13                       10   19
#   pad_tx_0[3]  -> AF13                       11   23
#   pad_tx_0[4]  -> W14                        14   8
#   pad_tx_0[5]  -> W13                        15   10
#   pad_tx_0[6]  -> Y14                        18   12
#   pad_tx_0[7]  -> Y13                        19   35
#   pad_clk_rx_0 -> AD15  (a->b fwd clock)     0    27    HDGC
#   pad_rx_0[0]  -> AD14                        1    28
#   pad_rx_0[1]  -> AC13                        9    21
#   pad_rx_0[2]  -> AA13                        12   32
#   pad_rx_0[3]  -> AB13                        13   33
#   pad_rx_0[4]  -> AG14                        4    7
#   pad_rx_0[5]  -> AH14                        5    29
#   pad_rx_0[6]  -> AG13                        6    31
#   pad_rx_0[7]  -> AH13                        7    26
#
# Both forwarded clocks land on the two HDGC (global-clock-capable) balls
# AD15 (BCM0, phys 27) and AC14 (BCM8, phys 24) so the received clock reaches a
# BUFG with NO CLOCK_DEDICATED_ROUTE override on either board.
#-----------------------------------------------------------------------------

#-- TX side (outputs from the chiplet's link-0 TideLink) ----------------------
# pad_clk_tx_0 forwarded on HDGC ball AC14 (BCM8); becomes the peer's pad_clk_rx.
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx_0]  ;# BCM8  HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[7]}] ;# BCM19

#-- RX side (inputs to the chiplet's link-0 TideLink) -------------------------
# pad_clk_rx_0 received on HDGC ball AD15 (BCM0); driven by the peer's pad_clk_tx.
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx_0]  ;# BCM0  HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[7]}] ;# BCM7

#-- Inter-board I2C sideband (open-drain, ON the ribbon: BCM2/BCM3) -----------
# KR260 RPi-header I2C1: BCM2 = SDA (AE15), BCM3 = SCL (AE14). Symmetric across
# the straight ribbon (SDA<->SDA, SCL<->SCL) - NO flip needed on these two.
# PULL CONTEXT: in a KR260<->KR260 ribbon topology there is NO Raspberry-Pi
# carrier/HAT fitting the bus pull-ups, so the open-drain lines would float and
# a floating bus can clock a sideband I2C slave into spurious transactions.
# PULLTYPE PULLUP (xck26 is UltraScale+, so PULLTYPE - not the 7-series
# `PULLUP TRUE`) gives the SOM's weak (~50k) internal pull as a safe-idle net.
# A bench 2.2k to 3V3 on ONE board only is still preferred for SI at speed
# (BOARD_WIRING S3.2). The BD/wrapper drives these as bidir IOBUF (i/o/t).
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c0_sda] ;# BCM2 SDA1
set_property -dict { PACKAGE_PIN AE14 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c0_scl] ;# BCM3 SCL1

#-- Console UART on spare RPi pins (BCM20/21, plain IO, off the ribbon) -------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports uart_txd] ;# BCM20
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 }                    [get_ports uart_rxd] ;# BCM21

#-- Status LEDs on PMOD3 (off-ribbon). Mirrors kr260-eth-chiplet. Compute has
#   no LAN8720, so PMOD1 is entirely free here - LEDs kept on PMOD3 only for
#   parity with the eth build (bench muscle-memory). -----------------------
set_property -dict { PACKAGE_PIN AG10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD3.3 - link0_active
set_property -dict { PACKAGE_PIN AH10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD3.4 - role_is_master

#=============================================================================
# CoreSight SWJ-DP debug on PMOD2 (3.3V HD bank, off the bank-44 ribbon).
#=============================================================================
# The compute SoC is a FULL SWJ-DP (SWD + JTAG), unlike the eth chiplet which
# is SWD-only. That is 9 debug signals; PMOD2 has only 8 signal pins (1-4,7-10),
# so one input (jtag_ntrst) overflows to a free PMOD3 pin.
#
# PMOD2 balls (BOARD_WIRING S2):  pin1 J11  pin2 J10  pin3 K13  pin4 K12
#                                 pin7 H11  pin8 G10  pin9 F12  pin10 F11
# Moved off PMOD4: PMOD4 is HP banks 64/65 (1.8V) and rejects LVCMOS33
# (DRC BIVB-1). PMOD2 is 3.3V so an ordinary ST-Link/DAPLink works directly.
#
# ###########################################################################
# # SCOPING-TODO (G1-debug) - TRISTATE COLLAPSE REQUIRED BEFORE REAL PROBE  #
# ###########################################################################
# swdio_i/swdio_o/swdio_oe are the PRE-IOBUF split of ONE physical SWDIO wire,
# and jtag_tdo/jtag_tdoen are the PRE-OBUFT split of ONE physical TDO wire
# (the BD exposes the chiplet's raw pad-ring signals, exactly as it does the
# i2c *_i/*_o/*_t trio). An ST-Link has ONE SWDIO conductor and ONE TDO
# conductor - you CANNOT wire three/two separate FPGA pins to them.
#
# To keep the design agent's first BD build free of unconstrained-port errors,
# EVERY named port is given a PACKAGE_PIN below. THIS IS A PLACEHOLDER. The real
# build MUST collapse the trios in the wrapper (as kr260-eth-chiplet's wrapper
# IOBUFs i2c_scl_i/o/t -> one inout i2c_scl_io):
#     IOBUF  swdio: .IO(<J10 pad>) .I(swdio_o) .O(swdio_i) .T(~swdio_oe)
#     OBUFT  tdo:   .O (<F12 pad>) .I(jtag_tdo) .T(~jtag_tdoen)
# After collapse: swdio_io -> J10 (pin2), tdo -> F12 (pin9); H11/G10/F11 free up
# and jtag_ntrst can move back onto PMOD2 (pin7), retiring the PMOD3 overflow.
#
# OBSERVED (2026-07-31): the design agent's tidelink_design_wrapper.v in this
# same target dir ALREADY exposes the collapsed board pads - top ports are
# `swclk`, `swdio` (inout), `jtag_tdi`, `jtag_tdo` (inout, "output w/ enable ->
# IOBUF"), `jtag_ntrst` - and does NOT bond `swd_nporesetn`, `swdio_{i,o,oe}` or
# `jtag_tdoen`. So the split-port lines below reference nets that the current
# wrapper does not have (they will 12-4739 against it), and the wrapper's
# `swdio`/`jtag_tdo` pads are conversely unconstrained. RECONCILE at integration:
# either this XDC adopts the collapsed names (swdio inout -> J10, jtag_tdo inout
# -> F12, drop swdio_oe/jtag_tdoen, add swd_nporesetn only if the wrapper re-adds
# it), OR the wrapper re-splits to these names. Kept as the task-specified split
# set for now; flagged so whichever side moves, moves deliberately.
# ###########################################################################

# -- Debug pads: COLLAPSED to match tidelink_design_wrapper.v (RECONCILED 2026-07-31).
#    The wrapper bonds swdio + jtag_tdo as INOUT via its IOBUF/OBUFT; the *_o/*_oe/
#    *_tdoen legs fold into the .T inside the wrapper, so they are NOT board pads.
#    swd_nporesetn is NOT a board pad (the wrapper ties dap_npotrst internally per the
#    chip-boundary spec). Collapsing frees H11/G10/F11, so jtag_ntrst returns to PMOD2.7.
set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLDOWN true } [get_ports swclk]     ;# PMOD2.1 SWCLK/TCK
set_property -dict { PACKAGE_PIN K12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports jtag_tdi]  ;# PMOD2.4 TDI
set_property -dict { PACKAGE_PIN H11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports jtag_ntrst];# PMOD2.7 nTRST
set_property -dict { PACKAGE_PIN J10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports swdio]     ;# PMOD2.2 SWDIO (inout; IOBUF in wrapper)
set_property -dict { PACKAGE_PIN F12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 }                [get_ports jtag_tdo]  ;# PMOD2.9 TDO (inout; OBUFT in wrapper)

# SWCLK/TCK is a slow external debug clock and may land on a non-ideal
# (clock-capable) pin; waive dedicated clock-routing so the placer accepts it.
# Applied to the NET (a *port* throws Netlist 29-69 and fails the message gate).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports swclk]]
