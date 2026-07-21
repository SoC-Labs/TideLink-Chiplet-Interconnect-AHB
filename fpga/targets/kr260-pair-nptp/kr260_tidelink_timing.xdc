#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 Paired (die_a / STRAIGHT ribbon)
# Source-Synchronous Timing Constraints
# (die_b uses the same file; only the pin XDC differs — see kr260-pair-flip-*)
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
# 2026-05-21 (fix/xdc-declarative): removed the runtime
#   set_property USED_IN_SYNTHESIS false [get_files [file normalize [info script]]]
# safety-net line. `file normalize`, `info script` and `get_files` are
# procedural Tcl commands that Vivado's XDC reader rejects with
# [Designutils 20-1307]. The build_design.tcl wrapper already applies the
# same property to this file, so the in-XDC line was a redundant belt-and-
# braces — promoting Designutils 20-1307 to ERROR (msg gate) makes the
# redundancy outright unsafe.
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
# The 2026-05-05 trap we must NOT reintroduce: a naive absolute
# `set_input_delay -min 1.0 -max 8.0` on pad_rx[*] made Vivado insert
# hold-fixing routing on every lane (134 hold-violating endpoints), so it
# was deleted entirely. The fix below bounds *relative* (lane-to-lane and
# clk-to-capture) skew and equalises lane delay, which attacks the
# build-to-build VARIANCE (the real defect) WITHOUT the absolute-window
# hold-pressure explosion. See docs/ASIC_TIMING_CONSTRAINTS.md (Part B §3).
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
# data path deterministic by bounding it as a relative-skew bus ([3b]/[3c])
# instead of relying on IOB packing.
#
# KR260 DIVERGENCE: the Z2 file additionally emits `IOB TRUE` on pad_rx[*] as a
# harmless best-effort request. Here it is `IOB FALSE`, and that is REQUIRED —
# on the V2 PHY it would otherwise pack gpiorx_*/g_word_pin_auto.wpa_shift_q_reg
# into the HDIO input flop and fail post-route DRC PDRC-248. See [3d] below.
# There is also NO IDELAYE2 stanza here: the RPi header is HDIO, which cannot
# host IDELAY at all (CONFIG.USE_IDELAY {0} in tidelink_design.tcl).
#=============================================================================

#-----------------------------------------------------------------------------
# [1] GPIO PHY pad clocks (KR260 link runs at 3.125 MHz / 320 ns)
#-----------------------------------------------------------------------------
# The TideLink GPIO PHY is source-synchronous. On the KR260 the link clock is
# derived as clk_wiz clk_out1 (25 MHz) / 8 (tidelink_phy_clk_div2, which despite
# its name divides by 8, not 2) = 3.125 MHz -> 320 ns:
#   tidelink_design.tcl  -> CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000}
#   tidelink_phy_clk_div2.v -> 3-bit div_cnt, tap bit[2]  (= /8)
#   this file            -> create_clock -period 320.000
#                        -> create_generated_clock ... -divide_by 8  (x2)
# The Z2's 4.687 MHz clk_out1 is below the MPSoC MMCME4 input/VCO floor, hence
# 25 MHz + /8 rather than a slower clk_out1 + /1.
#
# NOTE: the Z2 lineage of this file documented a 6.25 MHz / 160 ns rate (v36
# LINK-RATE DROP) and Z2 ball names Y7/Y9. Both are IRRELEVANT here and have
# been removed — do not reintroduce those numbers when diffing against
# pynq_z2_tidelink_timing.xdc.
#
# Pin map (verify against kr260_tidelink.xdc in this same target):
#   pad_clk_rx -> AC14 (BCM8, HDGC bank 44) on die_a  — global-clock-capable in.
#   pad_clk_tx -> AD15 (BCM0, HDGC bank 44) on die_a  — forwarded WITH pad_tx[*].
#   die_b (flip) swaps the two. Both are true HDGC pins, so the received clock
#   lands on a clock-capable site on BOTH boards with no CLOCK_DEDICATED_ROUTE
#   override — the KR260 has no equivalent of the Z2's die_b SRCC weakness.
#
# Received clock from the peer chiplet on pad_clk_rx (KR260 HDGC ball AC14,
# BCM8). It clocks the pad_rx[*] sampling registers. KEEP this create_clock so
# the pad_rx[*] -> capture relationship stays analysed (constraint [3]/[4]).
# KR260: the peer forwards its user_ref_clk on pad_clk_rx = clk_wiz clk_out1
# (25 MHz) / 8 (tidelink_phy_clk_div2) = 3.125 MHz -> 320.000 ns. This is the
# single link-rate knob: change clk_out1 and/or the /8 divider together with
# this period (and the -divide_by below). Conservatively slow for first eye
# closure; the KR260 HDGC clocking has no Z2 SRCC weakness so it can likely run
# faster once the eye is characterised on the bench.
create_clock -period 320.000 -name pad_clk_rx [get_ports pad_clk_rx]

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
# therefore a clock FORWARDED from hclk out of an ordinary IOB.
#
# Define pad_clk_tx as a generated clock derived 1:1 from hclk at the output
# port, then constrain pad_tx[*] against THAT (true forwarded-clock
# methodology) instead of vs the internal MMCM pin or false-pathing it.
#
# 2026-05-21 (fix/xdc-declarative): pin filter narrowed to the explicit BD
# pin `tidelink_design_i/clk_wiz_0/clk_out1`. The old wildcard
# `*/clk_wiz_0*/clk_out1` matched >1 pin (the BD-level clk_wiz_0/clk_out1
# AND the inner inst/clk_out1 after BD synthesis), tripping
# [Constraints 18-359] "create_generated_clock can only specify one pin as
# master pin" and silently dropping the entire pad_clk_tx_fwd definition.
# That cascade left set_output_delay below referencing an undefined clock
# and fired [Vivado 12-4739] x2. `lindex ... 0` is a defensive belt; with
# the narrow filter we expect exactly one result.
# Declarative: inline the get_pins (no `lindex`/`set`, which Vivado rejects in
# XDC -> Designutils 20-1307 -> the whole pad_clk_tx_fwd stanza was silently
# dropped). The exact (wildcard-free) NAME filter resolves to exactly one pin.
# PHY /2 (2026-06-30): the GPIO-PHY TX serializer + the forwarded pad_clk_tx now
# run off user_ref_clk = clk_out1 / BUFGCE_DIV(2) = 2.343 MHz. Keep -source on
# clk_out1 (it is in pad_clk_tx's fanin through the BUFGCE_DIV) but -divide_by 2
# so pad_clk_tx_fwd is defined at 2.343 MHz / 426.666 ns (was -divide_by 1).
# KR260: pad_clk_tx = user_ref_clk = clk_out1 (25 MHz) / 8 = 3.125 MHz, so
# -divide_by 8 against the clk_out1 master (which is in pad_clk_tx's fanin).
create_generated_clock -name pad_clk_tx_fwd -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}] -divide_by 8 [get_ports pad_clk_tx]

# Transmit eye: source-synchronous SDR centred-edge forward. Budget +/-20 ns for
# board trace + peer setup/hold.
#
# These +/-20 ns are ABSOLUTE nanoseconds (ribbon flight time + the far die's
# setup/hold), NOT a fraction of the link period — do NOT rescale them if you
# change the rate knob. The Z2 lineage of this comment framed them as
# "12.5% of the 160 ns period"; that framing was a coincidence of its rate, and
# is what made it look period-dependent. At the KR260's 320 ns period the same
# +/-20 ns is simply a larger relative margin (6.25%), i.e. strictly more
# conservative. Only create_clock / -divide_by track the rate knob.
#
# SYMMETRIC window measured against the forwarded clock pad_clk_tx_fwd (NOT an
# asymmetric absolute window vs an internal clock), so it does not recreate the
# 2026-05-05 hold explosion: launch and capture reference are the same forwarded
# edge, so Vivado balances rather than hold-pads every lane. The far die samples
# MID-CELL (160 ns from either pad transition at 320 ns), so +/-20 ns leaves
# >=140 ns of true eye margin each side.
set_output_delay -clock [get_clocks pad_clk_tx_fwd] -max 20.000 [get_ports {pad_tx[*]}]
set_output_delay -clock [get_clocks pad_clk_tx_fwd] -min -20.000 [get_ports {pad_tx[*]}]

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
#      clock (which, for a 1:1 <10 cm ribbon at 6.25 MHz, it nominally is —
#      these +/-4 ns are ABSOLUTE board-trace skews and do not scale with the
#      link period; the Z2 BIST held the same +/-4 ns at its 160 ns period) and
#      lets the calibrator absorb the residual. The window is the analysis
#      reference for (3b)/(3c); it is intentionally generous (the calibrator
#      handles dynamic skew — constraints only need to bound the STATIC,
#      build-varying part).
set_input_delay -clock [get_clocks pad_clk_rx] -max 4.000 [get_ports {pad_rx[*]}]
set_input_delay -clock [get_clocks pad_clk_rx] -min -4.000 [get_ports {pad_rx[*]}]

# (3b) Bound the pad_rx[n] -> first-stage capture flop path as a pure
#      datapath delay (NOT a clocked setup/hold check -> no hold-fix
#      insertion). This caps the ABSOLUTE clk-to-capture routing delay per
#      lane so it cannot wander build-to-build. 8.0 ns is now ~1/20 of the
#      320 ns period (KR260) — comfortably inside the calibrator window — and is
#      a ceiling, not a target, so P&R is not forced to pad short lanes. Kept
#      at 8.0 ns (absolute datapath ceiling, not period-scaled), matching the
#      silicon-validated BIST.
set _xlnx_shared_i0 [get_cells -hier -filter {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}]
set_max_delay -datapath_only -from [get_ports {pad_rx[*]}] -to $_xlnx_shared_i0 8.000

# (3c) THE key build-to-build determinism constraint. set_bus_skew forces
#      Vivado to EQUALISE the pad_rx[0..7] -> capture delays to within 2 ns
#      of each other. The defect is per-lane VARIANCE (some lanes land in
#      the calibrator window, others don't, and which is which changes every
#      build); bounding relative skew directly removes that variance without
#      any absolute hold pressure. Requires Vivado >= 2019.1 (2024.1 in use).
#
# !!! 2026-07-14 — THIS CONSTRAINT HAD NEVER APPLIED. NOT ON EITHER DIE. EVER. !!!
#
# It was written `-from [get_ports {pad_rx[*]}]`, and Vivado does NOT accept PORTS
# for set_bus_skew's -from (pin / cell / clock only). It rejected it every build:
#     CRITICAL WARNING: [Constraints 18-611] set_bus_skew: list of objects
#       specified for option 'from' contains '8' objects of types '(port)' ...
#     CRITICAL WARNING: [Constraints 18-612] ... does not contain any object of
#       type(s) '(pin,cell,clock)'
# and `report_bus_skew` on the routed KR260 design said, verbatim:
#     "No bus skew constraints"
#
# So the self-described "KEY build-to-build determinism constraint" was silently
# dropped for the entire life of the project, and inter-lane capture skew was
# bounded by NOTHING. That is exactly consistent with the observed placement
# lottery: nothing was holding the lanes together, so which lanes land inside the
# calibrator window is decided by placement luck and changes every rebuild.
# Measured on the shipped KR260 build: the 128 capture flops sprawl across FOUR
# clock regions (X0Y0, X0Y1, X1Y0, X1Y1) while every pad_rx pin sits in X0Y1.
#
# !!! AND IT CANNOT BE REPAIRED AS PROPOSED — MEASURED 2026-07-14 !!!
#
# The suggested fix ("-from must be the IBUF/IDELAY pins") DOES NOT WORK. Tried it
# against the routed KR260 design; Vivado rejects it outright:
#     ERROR: [Constraints 18-513] set_bus_skew: list of objects specified for
#       '-from' option contains no valid startpoints.
# An IBUF output pin is a combinational net, not a timing STARTPOINT (a startpoint
# is an input port or a sequential clock pin). And set_bus_skew's type check
# refuses ports. There is no object that satisfies both.
#
# The reason is that set_bus_skew is a CDC construct — it bounds skew on a bus
# going register-to-register ACROSS CLOCK DOMAINS. It was never applicable to a
# port -> register INPUT bus. This was a misconception, not a typo, and no
# -from selector will rescue it. THE CONSTRAINT IS THEREFORE DELETED, not "fixed".
#
# AND ON THIS DEVICE IT WOULD HAVE BEEN A NO-OP ANYWAY. Measured, per lane, on the
# shipped routed build (pad_rx[n] -> capture, max path):
#     lane 0 3.245   lane 1 3.385   lane 2 3.108   lane 3 2.756
#     lane 4 2.729   lane 5 2.976    lane 6 3.265   lane 7 3.290   (ns)
#     => INTER-LANE DATA SKEW = 0.656 ns
# At the KR260's 320 ns UI that is 0.2% of a bit period, and already ~3x TIGHTER
# than the 2 ns the constraint would have demanded. So on KR260 the inert
# set_bus_skew is NOT the bring-up-lottery mechanism: the data path is fine, and
# a working skew bound would have changed nothing. (It may still matter on the Z2 —
# different device, different UI, different placement — but that is not this file.)
#
# The residual root cause on KR260 is the capture CLOCK tree, not the data path.
# Every per-lane RX capture mux chain is lane-IDENTICAL by construction
# (io_pad_clk / io_pol=out_prepend_swi_polarity / scan are all common nets), so
# Vivado legally MERGES the 8 chains into ONE LUT (routed name
# `...g_word_pin_auto.wpa_gap_q[*]_i_*`, the pad_clk_inv_scan_mux) and drives all
# 8 lanes' capture flops from its output — a fanout-372 GENERAL-ROUTING net. That
# placement-varying inter-lane CLOCK skew, amplified by the all-lanes-AND commit
# gate, is the bring-up lottery (die_a 1/4 vs die_b 4/4 on KR260, 2026-07-17).
#
# THE PROVEN FIX IS RTL, NOT A CONSTRAINT — and it is NOT on this branch yet.
# phaseB's "parent hoist" (commit 2c32c2b; cherry-pick 84355b7 on wip/rate-ladder
# and on phaseB/attack): compute the mux chain ONCE in WavD2DGpio_v2 and buffer it
# through 2 shared BUFGs (new param USE_SHARED_CAP_BUFG, which DEFAULTS to
# USE_CLKBUF=1 — so an FPGA build gets it for free once the RTL/flist land). It was
# measured LUT2->BUFG on routed z2 DCPs: inter-lane capture skew 1.781 ns -> 0.244 ns
# (7.3x tighter). It touches ZERO xdc/tcl.
#
# A CONSTRAINT CANNOT REPLICATE IT. It can neither un-merge the lane-identical mux
# nor insert a BUFG on the LUT-output clock net; and bypassing the io_pol mux
# (USE_CAP_CLKBUF) INVERTS the deliberate mid-cell centre-sample and KILLS the link
# (out_prepend_swi_polarity resets to 1'b1 — see WavD2DGpio_v2.v). So DO NOT enable
# USE_CAP_CLKBUF here. Porting the real fix is an RTL/flist job: cherry-pick 2c32c2b
# onto integ, then re-run `make -C fpga package_ip` with TIDELINK_PHY_V2=1 (no BD or
# XDC change is needed on these kr260 targets — USE_SHARED_CAP_BUFG auto-tracks
# USE_CLKBUF). Until that lands, the pblock in (3c-ii) below plus the DORMANT
# co-location in (3c-iii) are PLACEMENT-only partial mitigations, not the fix.
#
# ACCEPTANCE / STRUCTURAL CHECK (post-route): run
# fpga/docs/verify_capture_clock_kr260.tcl on the routed design. It asserts the
# gpiorx capture flops are clocked through a global buffer (BUFG/BUFGCE) and reports
# the per-lane insertion-delay spread; a LUT/general-route driver means the RTL fix
# is still absent and the lottery persists. Full rationale + risk analysis:
# fpga/docs/KR260_CAPTURE_CLOCK_TREE.md.
#
# NOTE (verification method): never "check" a bus-skew fix by grepping for
# VIOLATED. An EMPTY report contains no violations and greps as a PASS — which is
# exactly how this hid for months. Check NUMERICALLY that > 0 paths were analyzed.

# (3c-ii) PLACEMENT: give the bus-skew constraint room to be satisfiable.
# The capture flops were spread over four clock regions while the pad_rx IO all
# land in X0Y1 — so even a WORKING skew constraint would be fighting the placer.
# Confine the RX capture logic to the IO's own clock-region column (X0Y0:X0Y1),
# co-locating all 8 lanes' capture with their pads.
#
# This mirrors `pblock_rx_act` on wip/phase2-pblock (die_b has had it since
# 2026-06-20 and consistently out-performs die_a, which had none). The REGIONS,
# however, are re-derived for xck26 — the Z2's region names are meaningless on
# this device. Verified from the routed KR260 design:
#     pad_rx[*] IO      -> clock region X0Y1
#     capture flops     -> X0Y0, X0Y1, X1Y0, X1Y1  (the sprawl being fixed)
#     device grid       -> X0Y0..X2Y3
# IS_SOFT false = a hard constraint; the placer must honour it.
create_pblock pblock_rx_act
add_cells_to_pblock pblock_rx_act [get_cells -quiet -hier -filter {NAME =~ "*gpiorx_*/link_data_pad_clk_reg[*]"}]
resize_pblock pblock_rx_act -add {CLOCKREGION_X0Y0:CLOCKREGION_X0Y1}
set_property IS_SOFT false [get_pblocks pblock_rx_act]

# (3c-iii) DORMANT capture-CLOCK-driver co-location — a PLACEMENT-only PARTIAL
#      mitigation, DISABLED by default. Mirrors the disabled-block convention of
#      section [5] below (the future IDELAY hook): the constraint is co-located
#      with its rationale but not active.
#
# WHAT IT DOES: the pblock in (3c-ii) confines the capture FLOPS (the loads). It
# does NOT constrain the merged capture-clock LUT (the DRIVER of the fanout-372
# net — see the root-cause note above). Adding that LUT to the same clock-region
# column shortens the general-routing clock net and reduces its placement-varying
# inter-lane skew. It is additive placement only: it changes NO logic and does NOT
# bypass the io_pol mux, so it is NOT USE_CAP_CLKBUF and cannot kill the link.
#
# WHY IT IS DISABLED (do not blindly enable):
#   1. It is a PARTIAL mitigation, not the fix. The net is still general routing
#      with no global buffer; only the RTL shared-BUFG (2c32c2b) removes the LUT.
#      Prefer landing that RTL fix over enabling this.
#   2. The exact driver cell name is only reliable from a ROUTED report (the
#      merged mux is named at implementation, e.g. `...wpa_gap_q[3]_i_2__0`). A
#      guessed `-quiet` filter that matches nothing would SILENTLY no-op — the
#      exact self-validating trap this project keeps hitting — and the xdc_lint
#      no-procedural-Tcl rule forbids an inline llength fail-loud guard here.
#   3. Pinning a fanout-372 clock-driver LUT into a narrow 2-region column can
#      route WORSE; it MUST be validated before/after with
#      fpga/docs/verify_capture_clock_kr260.tcl (per-lane skew) on real silicon,
#      not enabled on faith.
#
# TO ENABLE (only with a routed-report cell name in hand + a measured before/after):
#   1. From the routed design, find the driver cell of the net on the gpiorx
#      link_data_pad_clk_reg[*] C pins (the verify script prints it).
#   2. Replace <DRIVER_CELL_NAME> below with that cell's exact name, uncomment,
#      and re-run xdc_lint (cocotb/lint/xdc_lint.py) — no wildcard-without-lindex,
#      no procedural Tcl.
#   3. Rebuild and re-run the verify script; keep it ONLY if per-lane skew improves.
#
# add_cells_to_pblock pblock_rx_act [get_cells -hier -filter {NAME =~ "*<DRIVER_CELL_NAME>*"}]

# (3d) IOB packing is FORCED OFF on KR260. This is a deliberate inversion of
#      the Z2 constraint (which requests `IOB TRUE` here), and it is required —
#      not a preference.
#
# On the Z2 the `IOB TRUE` request is harmless best-effort: the intended target
# link_data_pad_clk_reg[*] cannot pack (input mux on D — see the caveat above),
# and nothing else on the pad_rx[*] chain is an IOB-able candidate, so the
# request quietly does nothing.
#
# On the KR260 (a) the pad_rx[*] pins are in HDIO bank 44 and (b) the V2 PHY
# adds a per-lane register `gpiorx_N/g_word_pin_auto.wpa_shift_q_reg[0]` that
# the V1 PHY does not have. That register IS a legal IOB candidate, so the
# `IOB TRUE` property propagates onto it and Vivado packs it into the HDIO
# input flop (IPFF). HDIO's IPFF requires its D pin to drive the flop and
# NOTHING else; this register's D fans out further, so post-route DRC fails,
# 8x (one per RX lane):
#
#   ERROR: [DRC PDRC-248] HDIOLOGIC_IPFF_unsupported_D_fanout: The IPFF in
#   HDIOLOGIC_M_X0Y15 (from cell .../gpiorx_2/g_word_pin_auto.wpa_shift_q_reg[0],
#   IOB=TRUE ...)
#
# This is the same HDIO-restriction family as the IDELAY problem (see
# CONFIG.USE_IDELAY {0} in tidelink_design.tcl): HDIO banks are cheap IO, not
# full HP/HR IO, and they refuse structures the Z2's HR banks accept.
#
# Nothing is lost by forcing it off. IOB packing was never the mechanism that
# made the capture deterministic here — (3b) set_max_delay and (3c)
# set_bus_skew are, and both are unaffected. FALSE (rather than deleting the
# line) is explicit: it also prevents the placer from opportunistically
# packing the register on its own.
set_property IOB FALSE [get_ports {pad_rx[*]}]

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
# SoC Labs 2026-06-21: $hclk_pin was UNDEFINED here -> this whole set_clock_groups threw
# "can't read hclk_pin" and was SILENTLY DROPPED. Define it (= clk_wiz hclk/clk_out1).
set hclk_pin [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}]

#-----------------------------------------------------------------------------
# [4a] PHY /2 clock (user_ref_clk = clk_out1 / 2 = 2.343 MHz). PHY /2 (2026-06-30).
#   The phy_clk_div module is a toggle flip-flop (div_q_reg) clocked by clk_out1
#   feeding a BUFG (u_div_bufg) — a clean /2 onto a global clock net that drives
#   user_ref_clk + scan_clk. Declare the divided clock EXPLICITLY (rather than
#   relying on Vivado auto-derivation) so it has a stable name (user_ref_clk_div2)
#   for the async clock_groups below. Pattern mirrors gpiotx0_word_clk [4b]:
#   -source = the toggle-FF CLOCK pin (carries the clk_out1 master), the generated
#   clock is defined on the BUFG OUTPUT pin, -divide_by 2 -> 426.666 ns. The exact
#   (wildcard) NAME filters resolve to exactly one pin each (the single divider).
# KR260: tidelink_phy_clk_div2 is a /8 free-running counter (div_cnt_reg[2:0])
# feeding u_div_bufg -> 3.125 MHz. Source on the [2] bit's C pin (a SINGLE pin;
# matching div_cnt_reg[*] would hit 3 pins and trip Constraints 18-359).
create_generated_clock -name user_ref_clk_div2 \
    -source [get_pins -hier -filter {NAME =~ "*phy_clk_div*div_cnt_reg[2]/C"}] \
    -divide_by 8 [get_pins -hier -filter {NAME =~ "*phy_clk_div*u_div_bufg*/O"}]

#-----------------------------------------------------------------------------
# [4b] TX WORD CLOCK (gpiotx_0 = local hsclk/16). PORTED from the PHY-BIST
#   word_handoff.xdc (NEVER carried into the integrated build — build_design.tcl
#   only globs *_tidelink_timing.xdc). WITHOUT a create_generated_clock the /16
#   TX word clock is an unconstrained, ungated fabric net: the nearby SYNC-insert
#   counter toggles, but the DEEP Wlink a2l-read FIFO pointers + their WavResetSync
#   (async-set / sync-RELEASE -> deassert needs a clean edge at those flops) sit
#   far away on the high-fanout LUT route and never get a clean edge -> io_rreset
#   never sync-deasserts -> a2l read side held in reset -> link_empty=1 ALWAYS ->
#   FCSM never drains -> NO V2 DATA TX. Declaring the clock makes Vivado TIME the
#   domain and route the 285-fanout net on a global clock buffer.
#-----------------------------------------------------------------------------
create_generated_clock -name gpiotx0_word_clk \
    -source [get_pins -hier -filter {NAME =~ "*gpiotx_0/count_reg[3]/C"}] \
    -divide_by 16 [get_pins -hier -filter {NAME =~ "*gpiotx_0/count_reg[3]/Q"}]
# FIX-O handoff margin: word-domain regs -> count==7 mid-word capture (link_data_stage)
# is a half-word-period datapath transfer, not edge-aligned.
# SoC Labs 2026-07-05: FIX-O DISABLED. When synth prunes link_data_stage_reg[*]
# the empty -to match raises ERROR [Vivado 12-4739] and aborts constraint
# processing (fired in some builds, incl. die_a logs). An if/llength empty-match
# guard is NOT an option here: procedural Tcl in an XDC is rejected
# ([Designutils 20-1307] -- see cocotb/lint/xdc_lint.py bug #6.a and the prior
# if/else abort documented in deps/tidelink-phy/.../pynq_z2_tidelink_word_handoff.xdc).
# Prior timing analysis proved the gpiotx0_word_clk group closes with +6811 ns
# slack -- the bound is orthogonal to closure, so disabling it is safe.
# set _fixo_stage_regs [get_cells -hier -filter {NAME =~ "*gpiotx_*/link_data_stage_reg[*]"}]
# set_max_delay -datapath_only -from [get_clocks gpiotx0_word_clk] -to $_fixo_stage_regs 70.000

# Four-group async isolation: recovered-RX, core hclk, TX word clock, and the
# PHY /2 user_ref_clk (2026-06-30) — mutually asynchronous (each crossing is
# 2-flop synchronised in RTL). user_ref_clk_div2 MUST be its own group vs hclk so
# the hclk(4.687)<->PHY(2.343) CDC paths are NOT timed as a related 2:1 crossing
# (they are async-synchronised, not balanced). gpiotx0_word_clk is itself derived
# from user_ref_clk_div2 (/16 of it); keeping both grouped is consistent — they
# are all in the asynchronous PHY/link timing island relative to hclk.
set_clock_groups -asynchronous \
    -group [get_clocks pad_clk_rx] \
    -group [get_clocks -of_objects $hclk_pin] \
    -group [get_clocks gpiotx0_word_clk] \
    -group [get_clocks user_ref_clk_div2]

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
# # set_property IODELAY_GROUP tl_rx_idly [get_cells -hier -filter # #     {NAME =~ "*gpiorx_*/*IDELAYE2*"}]
# # set_property IODELAY_GROUP tl_rx_idly [get_cells -hier -filter # #     {REF_NAME == IDELAYCTRL}]
# # (IDELAYCTRL ref clock: a 200 MHz source is required; the current BD has
# #  no 200 MHz net — adding one is part of the RTL-hook agent's scope.)

#-----------------------------------------------------------------------------
# [6] False paths (unchanged — keep intact)
#-----------------------------------------------------------------------------
# Board LEDs are human-visible; no functional timing path needed.
set_false_path -to [get_ports {led0 led1 led2 led3}]

# KR260: no IDELAYE2 CNTVALUEIN false_path. These targets build with USE_IDELAY=0
# (no per-lane delay lines), and on UltraScale+ the 7-series IDELAYE2 primitive
# does not exist anyway (it would be IDELAYE3). The Z2 version's
# get_cells {REF_NAME == IDELAYE2} would return EMPTY here, and the empty
# set_false_path -to is exactly the silent-drop class the Vivado message gate
# promotes to a hard ERROR (Vivado 12-1411). Intentionally omitted.

#-----------------------------------------------------------------------------
# [7] Combinational loop waiver (unchanged — keep intact)
#-----------------------------------------------------------------------------
# The IP wrapper hard-wires HSEL=1 and loops HREADYOUT back to HREADY_IN on
# the AHB slaves (ahblite:2.0 sub-signal pattern). This is the standard
# Vivado IP-Integrator AHB-Lite slave style and creates an intentional,
# functionally-correct combinational loop on the HREADY net inside the IP.
# Per-net waiver as backup — write_bitstream's pre-DRC sometimes ignores the
# severity downgrade in Vivado 2024.1. Match all u_xhb_sub/u_resp nets.
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





