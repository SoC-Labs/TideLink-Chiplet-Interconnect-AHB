#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 ON-CHIP PAIR - Pin Constraints
#   (kr260-pair-onchip: TWO TideLink dies in ONE xck26 bitstream, cross-
#    connected ENTIRELY through the PL fabric — NO PHY / I2C signal on any pin.)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# UNLIKE every other kr260 target, this build has NO link pins and NO I2C pins:
#   * the TX->RX data + forwarded-clock cross-connect is connect_bd_net INSIDE
#     the block design (tidelink_0/pad_* <-> tidelink_1/pad_*), and
#   * the autoneg I2C sideband is a fabric util_vector_logic wired-AND,
# so the ONLY bonded PL IO on this design is the four status LEDs. There is
# therefore NO pad_clk_tx / pad_clk_rx / pad_tx[*] / pad_rx[*] / i2c_*_io
# stanza here (they do not exist as ports — see tidelink_design_wrapper.v and
# KR260_PAIR_ONCHIP_PLAN.md sec 3.1 / 3.7). The PS DDR4 + MIO are bonded to the
# K26 SOM and configured by the board preset inside the BD (not PL ports).
#
# These four LED LOC+IOSTANDARD assignments are LOAD-BEARING for buildability:
# without them write_bitstream fails the default DRC (UCIO-1 unconstrained IO /
# NSTD-1 unspecified IOSTANDARD) on led0..led3. That is exactly the "late,
# expensive" failure the fpga/Makefile guard warned about while this file was
# absent.
#-----------------------------------------------------------------------------

#-- Status LEDs on PMOD0 (the same off-ribbon PMOD0 balls the single-die kr260
#   targets use; here there is no ribbon at all so there is no contention to
#   avoid — the choice is simply "a real bonded PL IO exists to satisfy DRC").
#   LED map (see tidelink_design_wrapper.v):
#     led0 = tidelink_0 (die_a) link_active
#     led1 = tidelink_0 (die_a) role_is_master   (expect 1 = master)
#     led2 = tidelink_1 (die_b) link_active
#     led3 = tidelink_1 (die_b) role_is_master   (expect 0 = slave)
#   Bench read: led0 & led2 lit => both links up; led1 XOR led3 => exactly one
#   master (complementary roles) => genuine on-chip autoneg.
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led0] ;# PMOD0_0 — die_a link_active
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led1] ;# PMOD0_1 — die_a role_is_master
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led2] ;# PMOD0_2 — die_b link_active
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports led3] ;# PMOD0_3 — die_b role_is_master
