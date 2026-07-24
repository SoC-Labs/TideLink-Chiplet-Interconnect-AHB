#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Pynq-Z2 Paired (FLIP) Source-Synchronous
# Timing Constraints
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Timing constraints for implementation only. Applying these during synthesis
# fires CRITICAL WARNING 12-4739 ("No valid object(s) found") because the
# clk_wiz output clocks and the internal pad-capture cells are not visible to
# the synthesis engine.
#
# Applied via build_design.tcl:
#   set_property USED_IN_SYNTHESIS false   [get_files *_timing.xdc]
#   set_property USED_IN_IMPLEMENTATION true [get_files *_timing.xdc]
# (Do NOT change how this file is loaded — it must stay impl-only.)
#
# This is the FLIP mirror of pynq-z2-pair-all. The constraint BODY is
# identical (every constraint is port-/cell-relative, not pin-relative);
# ONLY the pin-map COMMENTS differ, because the FLIP bitstream swaps the
# clock pins so a straight-through 1:1 ribbon connects TX-of-one-board to
# RX-of-the-other. See pynq_z2_tidelink.xdc in THIS target for the pin map.
#
# 2026-05-21 (fix/xdc-declarative): removed the runtime
#   set_property USED_IN_SYNTHESIS false [get_files [file normalize [info script]]]
# safety-net line. `file normalize`, `info script` and `get_files` are
# procedural Tcl commands that Vivado's XDC reader rejects with
# [Designutils 20-1307]. The build_design.tcl wrapper already applies the
# same property to this file (mirror of pair-all).
#-----------------------------------------------------------------------------

#=============================================================================
# WHY THIS FILE WAS REWRITTEN (2026-05-18, feat/td-xdc-source-sync)
#=============================================================================
# Symptom: per-lane Wlink GPIO-PHY lock is NON-DETERMINISTIC build-to-build.
# v5 locked both boards 7/7; v6/v7/v7-slow leave the slave RX ~0 at every
# calibrator phase. A 12.5 MHz build (2x margin) reproduced the v6/v7 failure
# byte-for-byte, so this is NOT a clock-rate / setup-margin problem.
#
# Root cause: this PHY is source-synchronous (pad_clk_rx is forwarded with
# pad_rx[*] from the peer; the local calibrator sweeps bit-slip x phase to
# find each lane's capture point) but the OLD constraint file:
#   (1) commented out set_input_delay  on pad_rx[*]    (no RX eye analysis)
#   (2) commented out set_output_delay on pad_tx[*]    (no TX eye analysis)
#   (3) set_clock_groups -asynchronous pad_clk_rx <-> hclk, which lumps the
#       pad_clk_rx -> pad_rx[*] capture relationship into "do no analysis".
# Net: Vivado had ZERO constraint on the skew between pad_clk_rx and each
# pad_rx[n] capture flop, so it placed/routed the 8 capture paths with
# arbitrary, build-varying delay. The calibrator's finite (bit-slip x phase)
# window only covered that skew by luck => the v5-vs-v6 coin flip.
#
# FLIP-SPECIFIC NOTE (slave-clock asymmetry — see rationale doc §4): on the
# FLIP bitstream pad_clk_rx lands on Y9 (IO_L14P_T2_SRCC_13, single-region
# clock-capable) instead of the straight target's Y7 (MRCC, multi-region).
# SRCC has weaker clock distribution than MRCC, so the FLIP board's RX
# capture is the more skew-sensitive of the pair ("slave is always the
# unlucky side"). The constraints below bound that skew by construction so
# the calibrator window is a guarantee on BOTH the MRCC and the SRCC side,
# not luck. A BUFG is still inferred on Y9; the residual MRCC-vs-SRCC
# insertion-delay difference is exactly what set_bus_skew [3c] equalises.
#
# The 2026-05-05 trap we must NOT reintroduce: a naive absolute
# `set_input_delay -min 1.0 -max 8.0` on pad_rx[*] made Vivado insert
# hold-fixing routing on every lane (134 hold-violating endpoints), so it
# was deleted entirely. The fix below bounds *relative* (lane-to-lane and
# clk-to-capture) skew and equalises lane delay, which attacks the
# build-to-build VARIANCE (the real defect) WITHOUT the absolute-window
# hold-pressure explosion. See docs/reference/ASIC_TIMING_CONSTRAINTS.md (Part B §3).
#=============================================================================

#=============================================================================
# Capture-flop identification (how the IOB / max_delay / bus_skew targets
# below were derived — keep this in sync with the RTL)
#=============================================================================
# Hierarchy (parent BD wrapper -> packaged IP -> Wlink -> GPIO PHY):
#   tidelink_design_i / <ip>_tidelink_0 ... u_chiplet_controller
#     -> u_wlink (Wlink)
#       -> phy (WlinkGPIOPHY)
#         -> gpio (WavD2DGpio)
#           -> gpiorx_0 .. gpiorx_7 (WavD2DGpioRx)        <-- per RX lane
#
# Inside WavD2DGpioRx (deps/axi-chiplet-controller/logical/wlink/
# WavD2DGpioRx.v, from GPIO.scala):
#   reg [15:0] link_data_pad_clk;   // GPIO.scala 130 — FIRST-STAGE pad
#                                   //   capture register. Clocked by a
#                                   //   pad_clk_rx-derived net (through the
#                                   //   functional scan-mux + io_pol
#                                   //   WavClockInv). Its D-input selects
#                                   //   io_pad (= pad_rx[n]) when the bit
#                                   //   counter `adj_count` matches.
#   reg  [3:0] count;               // GPIO.scala 121 — bit-position counter,
#                                   //   also clocked by pad_clk_rx.
#   reg [15:0] link_data_reg;       // GPIO.scala 140 — 2nd stage, clocked by
#                                   //   the /16 io_link_clk (still pad_clk_rx
#                                   //   domain). NOT the pad-capture flop.
# Synthesised cell names: link_data_pad_clk_reg[*], count_reg[*].
# Build-robust selector (survives wrapper renames / IP-pack hierarchy):
#   [get_cells -hier -filter {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}]
#
# HONEST CAVEAT (documented, not hidden): link_data_pad_clk_reg[*] is NOT a
# clean IOB candidate. Its D pin is driven by a per-bit mux
# (adj_count==X ? io_pad : hold), so Vivado cannot legally pull it into the
# IOB input flop (an IOB FF needs D directly off the I pad). `set_property
# IOB TRUE` on it will be ignored/rejected. We therefore make the clk-to-
# data path deterministic by (a) bounding it as a relative-skew bus instead
# of relying on IOB packing, and (b) leaving a disabled IDELAYE2 stanza for
# the separate RTL-hook agent (the proper FPGA fix). The IOB request is
# still emitted (best-effort, harmless) and applied to the genuine IOB-able
# pad input where Vivado does infer one.
#=============================================================================

#-----------------------------------------------------------------------------
# [1] GPIO PHY pad clocks (link runs at 25 MHz / 40 ns — CORRECTED)
#-----------------------------------------------------------------------------
# The TideLink GPIO PHY is source-synchronous and runs at 25 MHz:
#   tidelink_design.tcl  -> CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000}
#   this file            -> create_clock -period 40.000
# (The "50 MHz / 20 ns" text that used to be in this header was STALE and
#  has been removed — there is no 50 MHz domain in this design.)
#
# FLIP pin map (verify against pynq_z2_tidelink.xdc in THIS target — the
# clock pins are SWAPPED vs the straight pynq-z2-pair-all target):
#   pad_clk_rx -> Y9  (IO_L14P_T2_SRCC_13)  — single-region clock-capable
#                                             in. Vivado still infers a BUFG;
#                                             SRCC distribution is weaker
#                                             than MRCC (see slave-asymmetry
#                                             note above) — bounded by [3c].
#   pad_clk_tx -> Y7  (IO_L13P_T2_MRCC_13)  — multi-region clock-capable
#                                             out; forwarded WITH pad_tx[*].
#   (Straight target is the mirror: pad_clk_rx=Y7 MRCC, pad_clk_tx=Y9 SRCC.)
#
# Received clock from the peer chiplet on pad_clk_rx. It clocks the
# pad_rx[*] sampling registers (gpiorx_*/link_data_pad_clk_reg). KEEP this
# create_clock — pad_clk_rx must remain a real, timed clock so the
# pad_rx[*] -> capture relationship can be analysed (constraint [3]/[4]).
create_clock -period 40.000 -name pad_clk_rx [get_ports pad_clk_rx]

#-----------------------------------------------------------------------------
# [2] Forwarded TX clock as a real source-synchronous generated clock
#-----------------------------------------------------------------------------
# OLD behaviour: `set_false_path -to [get_ports pad_clk_tx]` plus NO
# set_output_delay. That left the entire transmit eye (pad_tx[*] launch vs
# the forwarded pad_clk_tx) completely unconstrained — the TX side of the
# same source-sync nondeterminism.
#
# In this FPGA build the GPIO-PHY TX serializer clock is effectively the
# clk_wiz hclk (clk_out1, 25 MHz): WavD2DSerdesPLL/WavD2DGpio's PLL is a
# behavioural sim-only model (uses $realtime / # delays — non-synthesisable),
# so on silicon-fabric the serializer + the pad_clk_tx forward
# (WavD2DGpioTx: `assign pad_clk = clk`) both run off user_ref_clk, and in
# the BD user_ref_clk is tied to clk_wiz_0/clk_out1 (== hclk). pad_clk_tx is
# therefore a clock FORWARDED from hclk out of an ordinary IOB (here Y7 MRCC
# on the FLIP target).
#
# Define pad_clk_tx as a generated clock derived 1:1 from hclk at the output
# port, then constrain pad_tx[*] against THAT (true forwarded-clock
# methodology) instead of vs the internal MMCM pin or false-pathing it.
#
# 2026-05-21 (fix/xdc-declarative): pin filter narrowed to the explicit BD
# pin `tidelink_design_i/clk_wiz_0/clk_out1`. Old wildcard
# `*/clk_wiz_0*/clk_out1` matched >1 pin -> [Constraints 18-359]. Mirror
# of the pair-all fix.
# Declarative: inline the get_pins (no `lindex`/`set`, which Vivado rejects in
# XDC -> Designutils 20-1307 -> the whole pad_clk_tx_fwd stanza was silently
# dropped). The exact (wildcard-free) NAME filter resolves to exactly one pin.
create_generated_clock -name pad_clk_tx_fwd \
    -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}] \
    -divide_by 1 \
    [get_ports pad_clk_tx]

# Transmit eye: source-synchronous SDR centred-edge forward. Budget +/-5 ns
# of the 40 ns period for board trace + peer setup/hold. This is a SYMMETRIC
# window measured against the forwarded clock pad_clk_tx_fwd (NOT an
# asymmetric absolute window vs an internal clock), so it does not recreate
# the 2026-05-05 hold explosion: launch and capture reference are the same
# forwarded edge, so Vivado balances rather than hold-pads every lane.
set_output_delay -clock [get_clocks pad_clk_tx_fwd] -max  5.000 [get_ports {pad_tx[*]}]
set_output_delay -clock [get_clocks pad_clk_tx_fwd] -min -5.000 [get_ports {pad_tx[*]}]

#-----------------------------------------------------------------------------
# [3] RX pad capture: TIMED source-synchronous group, RELATIVE skew bounded
#-----------------------------------------------------------------------------
# We must give Vivado a timed pad_rx[*] -> capture relationship (so it stops
# routing the 8 lanes with arbitrary delay) WITHOUT a naive absolute
# set_input_delay -min/-max (the 2026-05-05 hold-violation trap).
#
# (3a) Declare the receive eye RELATIVE to pad_clk_rx using a SYMMETRIC
#      window. Symmetric -min/-max about the launch edge does NOT create the
#      one-sided hold pressure that the old asymmetric `-min 1.0 -max 8.0`
#      did; it tells Vivado the data is centre-aligned to the forwarded
#      clock (which, for a 1:1 <10 cm ribbon at 25 MHz, it nominally is) and
#      lets the calibrator absorb the residual. The window is the analysis
#      reference for (3b)/(3c); it is intentionally generous (the calibrator
#      handles dynamic skew — constraints only need to bound the STATIC,
#      build-varying part).
set_input_delay -clock [get_clocks pad_clk_rx] -max  4.000 [get_ports {pad_rx[*]}]
set_input_delay -clock [get_clocks pad_clk_rx] -min -4.000 [get_ports {pad_rx[*]}]

# (3b) Bound the pad_rx[n] -> first-stage capture flop path as a pure
#      datapath delay (NOT a clocked setup/hold check -> no hold-fix
#      insertion). This caps the ABSOLUTE clk-to-capture routing delay per
#      lane so it cannot wander build-to-build. 8.0 ns is ~1/5 of the 40 ns
#      period — comfortably inside the calibrator window — and is a ceiling,
#      not a target, so P&R is not forced to pad short lanes.
set rx_cap_cells [get_cells -hier -filter {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}]
set_max_delay -datapath_only 8.000 \
    -from [get_ports {pad_rx[*]}] \
    -to   $rx_cap_cells

# (3c) THE key build-to-build determinism constraint. set_bus_skew forces
#      Vivado to EQUALISE the pad_rx[0..7] -> capture delays to within 2 ns
#      of each other. The defect is per-lane VARIANCE (some lanes land in
#      the calibrator window, others don't, and which is which changes every
#      build); bounding relative skew directly removes that variance without
#      any absolute hold pressure. On the FLIP target this is also what
#      compensates the SRCC (Y9) vs MRCC clock-insertion difference noted in
#      the header. Requires Vivado >= 2019.1 (2024.1 in use).
set_bus_skew -from [get_ports {pad_rx[*]}] -to $rx_cap_cells 2.000

# (3d) Best-effort IOB request. link_data_pad_clk_reg[*] itself cannot pack
#      into the IOB (input mux on D — see caveat above) so this is applied
#      to the pad_rx[*] input chain where Vivado DOES infer an IOB input
#      flop/buffer; it makes whatever IOB-able element exists deterministic
#      and is harmless where it cannot apply. NOT the primary fix — (3b)/(3c)
#      are.
#
# 2026-05-21 (fix/xdc-declarative): `catch { ... }` wrapper removed —
# Vivado XDC rejects `catch` with [Designutils 20-1307] (gate ERROR).
# Mirror of pair-all fix.
set_property IOB TRUE [get_ports {pad_rx[*]}]

#-----------------------------------------------------------------------------
# [4] Async clock group: isolate ONLY the genuine recovered-RX -> core CDC,
#     and KEEP the pad_rx[*] -> capture analysis timed.
#-----------------------------------------------------------------------------
# OLD: a blanket `set_clock_groups -asynchronous {pad_clk_rx} {hclk}`. That
# is correct for the recovered-RX -> core/hclk crossing (Wlink internally
# 2-flop synchronises it), but as written it ALSO erased the pad_clk_rx ->
# pad_rx[*] capture timing — exactly the analysis we need.
#
# set_clock_groups -asynchronous between pad_clk_rx and hclk does NOT
# actually disable the pad_rx[*] -> capture paths (those are launched by the
# input_delay virtual source on pad_clk_rx and captured on pad_clk_rx — same
# group, still timed by [3]); it only cuts pad_clk_rx<->hclk. So the genuine
# CDC stays cut while [3] keeps the source-sync group timed. This is the
# correct, narrow async declaration.
#
# Vivado automatically propagates pad_clk_rx through the BUFG + the io_pol
# WavClockInv + functional scan-mux to the gpiorx_*/link_data_pad_clk_reg
# clock pins, so referencing the master clock [get_clocks pad_clk_rx] in [3]
# covers the (possibly inverted) capture clock too.
set_clock_groups -asynchronous \
    -group [get_clocks pad_clk_rx] \
    -group [get_clocks -of_objects $hclk_pin]

#-----------------------------------------------------------------------------
# [5] (DISABLED) Future IDELAYE2 per-lane delay line — separate agent's job
#-----------------------------------------------------------------------------
# The proper FPGA analogue of the ASIC per-lane programmable delay cell is an
# IDELAYE2 on each pad_rx[*] driven by the calibrator tap (mirroring the
# existing swi_phase_offset / swi_bit_slip per-lane plumbing), with an
# IDELAYCTRL + IDELAY_GROUP. That is an RTL hook owned by a DIFFERENT agent.
# This block is INTENTIONALLY DISABLED — do not enable it here. It is left
# only so the constraint that would accompany the RTL hook is co-located and
# reviewed alongside the rest of the source-sync set. When the RTL lands,
# the owning agent enables this and removes the catch'd IOB request in [3d].
#
# # set_property IODELAY_GROUP tl_rx_idly [get_cells -hier -filter \
# #     {NAME =~ "*gpiorx_*/*IDELAYE2*"}]
# # set_property IODELAY_GROUP tl_rx_idly [get_cells -hier -filter \
# #     {REF_NAME == IDELAYCTRL}]
# # (IDELAYCTRL ref clock: a 200 MHz source is required; the current BD has
# #  no 200 MHz net — adding one is part of the RTL-hook agent's scope.)

#-----------------------------------------------------------------------------
# [6] False paths (unchanged — keep intact)
#-----------------------------------------------------------------------------
# Board LEDs are human-visible; no functional timing path needed.
set_false_path -to [get_ports {led0 led1 led2 led3}]

#-----------------------------------------------------------------------------
# [7] Combinational loop waiver (unchanged — keep intact)
#-----------------------------------------------------------------------------
# The IP wrapper hard-wires HSEL=1 and loops HREADYOUT back to HREADY_IN on
# the AHB slaves (ahblite:2.0 sub-signal pattern). This is the standard
# Vivado IP-Integrator AHB-Lite slave style and creates an intentional,
# functionally-correct combinational loop on the HREADY net inside the IP.
# Per-net waiver as backup — write_bitstream's pre-DRC sometimes ignores the
# severity downgrade in Vivado 2024.1. The flip target historically used a
# narrower per-net match; widened to the u_xhb_sub/u_resp subtree to match
# the straight target and survive auto-generated net-name drift.
# (The primary severity downgrade lives in *_tidelink_drc.xdc so it survives
#  save_constraints round-trips during debug-core insertion.)
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]
#-----------------------------------------------------------------------------
# dbg_hub (BSCAN/JTAG) WHS noise — known non-issue, no waiver.
#
# Vivado auto-inserts the dbg_hub when the design contains any
# (* mark_debug = "true" *) net. The Wlink IP (deps/.../WlinkRxLinkLayer.v)
# carries ~30 such attrs on its observability nets. Even without explicit
# ILA / probe wiring, the empty dbg_hub still includes BSCAN-clocked (TCK)
# shift registers + FIFOs that Vivado tries to timing-close against TCK's
# worst-case 33 ns period. Result: WHS ~= -7.94 ns / 8 hold + WNS ~= -0.83 ns
# / 3 setup endpoints in routed Design Timing Summary. None of those paths
# are functionally active during normal operation — TCK is the external
# JTAG clock, only toggled during ChipScope sessions.
#
# Build #7 + #8 HW result: bridge1 link converges 16/16 on iteration 1
# with the WHS noise present. Two prior waiver attempts (d46412e
# ila_rx-named, build #5 get_clocks form, build #8 BSCAN_X0Y0/TCK form)
# all targeted cell/pin names that do not resolve at constraint-load time
# and only generated Vivado 12-4739 "No valid object(s) found" errors of
# their own. The dbg_hub names are auto-generated post-synthesis from the
# inserted debug-core hierarchy and there is no stable XDC pattern that
# Vivado will resolve against the un-elaborated netlist.
#
# Long-term fix (Agent E §1-A track): remove the mark_debug attrs from
# Wlink RTL — the SoC Labs ILA observability story has been replaced by
# RO APB observability (Region 8 SWI_LANE_STATUS, submodule 250f1cf).
# With no mark_debug attrs, no dbg_hub is auto-inserted and the noise
# disappears at source.
#-----------------------------------------------------------------------------
