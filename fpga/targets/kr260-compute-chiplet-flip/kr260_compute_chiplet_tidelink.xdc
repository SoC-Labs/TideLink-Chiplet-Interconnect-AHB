#-----------------------------------------------------------------------------
# nanoSoC compute-chiplet - KR260 Pin Constraints (die_a / FLIP)
#                           (mirror of kr260-compute-chiplet die_b)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# FIRST-CUT scaffold (gap G1). die_a mirror of the die_b pin map in
# kr260-compute-chiplet: the TX and RX ball-sets are SWAPPED (and the two
# forwarded-clock balls swapped) so a plain STRAIGHT-THROUGH RPi ribbon connects
# this die's TX conductors to the peer die's RX conductors on the SAME physical
# header pins, and vice-versa (die_a TX ball == die_b RX ball). Lane index is
# preserved. I2C/UART/LEDs/SWJ-DP are off-ribbon (or symmetric) and keep the
# SAME balls as die_b.
#
# This "flip" build is the compute-side die_a. It exists so two COMPUTE boards
# (or a compute + any die_b peer) can share one straight ribbon: pair THIS
# (die_a) against kr260-compute-chiplet (die_b). The die_a ball-set here is
# identical to kr260-eth-chiplet's die_a map - by design, so an eth die_a and a
# compute die_a are drop-in swappable on the same board slot.
#
#   die_a ball map (compute link-0)          BCM  phys  HDGC
#   ---------------------------------------  ---  ----  ----
#   pad_clk_tx_0 -> AD15  (a->b fwd clock)    0    27    HDGC
#   pad_tx_0[0]  -> AD14                        1    28
#   pad_tx_0[1]  -> AC13                        9    21
#   pad_tx_0[2]  -> AA13                        12   32
#   pad_tx_0[3]  -> AB13                        13   33
#   pad_tx_0[4]  -> AG14                        4    7
#   pad_tx_0[5]  -> AH14                        5    29
#   pad_tx_0[6]  -> AG13                        6    31
#   pad_tx_0[7]  -> AH13                        7    26
#   pad_clk_rx_0 -> AC14  (b->a fwd clock)     8    24    HDGC
#   pad_rx_0[0]  -> AB15                        16   36
#   pad_rx_0[1]  -> AB14                        17   11
#   pad_rx_0[2]  -> AE13                        10   19
#   pad_rx_0[3]  -> AF13                        11   23
#   pad_rx_0[4]  -> W14                         14   8
#   pad_rx_0[5]  -> W13                         15   10
#   pad_rx_0[6]  -> Y14                         18   12
#   pad_rx_0[7]  -> Y13                         19   35
#
# Both forwarded clocks again land on the two HDGC balls AD15 (BCM0, phys 27)
# and AC14 (BCM8, phys 24) - here TX=AD15, RX=AC14 (the die_b swap) - so the
# received clock reaches a BUFG with NO CLOCK_DEDICATED_ROUTE override.
#-----------------------------------------------------------------------------

#-- TX side (die_a drives; lands on the peer's RX pins) -----------------------
# pad_clk_tx_0 forwarded on HDGC ball AD15 (BCM0); becomes the peer's pad_clk_rx.
set_property -dict { PACKAGE_PIN AD15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports pad_clk_tx_0]  ;# BCM0  HDGC
set_property -dict { PACKAGE_PIN AD14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[0]}] ;# BCM1
set_property -dict { PACKAGE_PIN AC13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[1]}] ;# BCM9
set_property -dict { PACKAGE_PIN AA13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[2]}] ;# BCM12
set_property -dict { PACKAGE_PIN AB13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[3]}] ;# BCM13
set_property -dict { PACKAGE_PIN AG14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[4]}] ;# BCM4
set_property -dict { PACKAGE_PIN AH14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[5]}] ;# BCM5
set_property -dict { PACKAGE_PIN AG13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[6]}] ;# BCM6
set_property -dict { PACKAGE_PIN AH13 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8 } [get_ports {pad_tx_0[7]}] ;# BCM7

#-- RX side (die_a receives; driven by the peer's TX pins) --------------------
# pad_clk_rx_0 received on HDGC ball AC14 (BCM8); driven by the peer's pad_clk_tx.
set_property -dict { PACKAGE_PIN AC14 IOSTANDARD LVCMOS33 } [get_ports pad_clk_rx_0]  ;# BCM8  HDGC
set_property -dict { PACKAGE_PIN AB15 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[0]}] ;# BCM16
set_property -dict { PACKAGE_PIN AB14 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[1]}] ;# BCM17
set_property -dict { PACKAGE_PIN AE13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[2]}] ;# BCM10
set_property -dict { PACKAGE_PIN AF13 IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[3]}] ;# BCM11
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[4]}] ;# BCM14
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[5]}] ;# BCM15
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[6]}] ;# BCM18
set_property -dict { PACKAGE_PIN Y13  IOSTANDARD LVCMOS33 } [get_ports {pad_rx_0[7]}] ;# BCM19

#-- Inter-board I2C sideband (open-drain, ON the ribbon: BCM2/BCM3) -----------
# Symmetric across the straight ribbon (SDA<->SDA, SCL<->SCL) - SAME balls as
# die_b, NO swap. See kr260-compute-chiplet pin XDC for the pull-up rationale.
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c0_sda] ;# BCM2 SDA1
set_property -dict { PACKAGE_PIN AE14 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c0_scl] ;# BCM3 SCL1

#-- Console UART on spare RPi pins (same balls as die_b) ----------------------
set_property -dict { PACKAGE_PIN W12  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports uart_txd] ;# BCM20
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS33 }                    [get_ports uart_rxd] ;# BCM21

#-- Status LEDs on PMOD3 (off-ribbon, same balls as die_b) --------------------
set_property -dict { PACKAGE_PIN AG10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD3.3 - link0_active
set_property -dict { PACKAGE_PIN AH10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD3.4 - role_is_master

#=============================================================================
# CoreSight SWJ-DP debug on PMOD2 (identical to die_b - off-ribbon, no swap).
# See kr260-compute-chiplet pin XDC for the full SCOPING-TODO on the SWDIO/TDO
# tristate collapse (swdio_i/o/oe -> one IOBUF pad; jtag_tdo/tdoen -> one OBUFT
# pad). Placeholder split pins below keep the design agent's build free of
# unconstrained-port errors; they MUST be reconciled before a real probe.
#
# OBSERVED (2026-07-31): the design agent's wrapper already exposes COLLAPSED
# board pads - swclk, swdio (inout), jtag_tdi, jtag_tdo (inout), jtag_ntrst -
# and omits swd_nporesetn / swdio_{i,o,oe} / jtag_tdoen. The split-port lines
# below therefore do not match the current wrapper; reconcile the names at
# integration (adopt collapsed names here, or re-split in the wrapper).
#=============================================================================
# -- Debug pads: COLLAPSED to match tidelink_design_wrapper.v (RECONCILED 2026-07-31).
#    swdio + jtag_tdo are INOUT via the wrapper's IOBUF/OBUFT; *_o/*_oe/*_tdoen fold
#    into the .T inside the wrapper (not board pads). swd_nporesetn is not a board pad
#    (wrapper ties dap_npotrst internally). Collapse frees H11/G10/F11 -> jtag_ntrst on PMOD2.7.
set_property -dict { PACKAGE_PIN J11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLDOWN true } [get_ports swclk]     ;# PMOD2.1 SWCLK/TCK
set_property -dict { PACKAGE_PIN K12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports jtag_tdi]  ;# PMOD2.4 TDI
set_property -dict { PACKAGE_PIN H11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports jtag_ntrst];# PMOD2.7 nTRST
set_property -dict { PACKAGE_PIN J10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 PULLUP true }    [get_ports swdio]     ;# PMOD2.2 SWDIO (inout; IOBUF in wrapper)
set_property -dict { PACKAGE_PIN F12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 }                [get_ports jtag_tdo]  ;# PMOD2.9 TDO (inout; OBUFT in wrapper)

# SWCLK/TCK dedicated clock-routing waiver (on the NET, not the port).
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -of_objects [get_ports swclk]]
