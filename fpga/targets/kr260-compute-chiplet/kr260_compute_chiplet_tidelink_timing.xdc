#-----------------------------------------------------------------------------
# TideLink Chiplet Bridge - Kria KR260 compute-chiplet (die_a AND die_b)
# Source-Synchronous Timing Constraints  -  LINK 0
# (die_a/flip and die_b/straight share this file byte-for-byte; only the pin
#  XDC differs - the TX/RX ball swap. Keep the two copies identical.)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# FIRST-CUT scaffold (gap G1). Ported from
#   kr260-eth-chiplet/kr260_eth_chiplet_tidelink_timing.xdc
# with (a) port names renamed to the compute link-0 pads (pad_clk_rx_0,
# pad_clk_tx_0, pad_tx_0[*], pad_rx_0[*], led0/led1) and (b) SCOPING-TODO
# markers everywhere a selector depends on the COMPUTE block design.
#
# 2026-09-17 - SELECTORS RE-RESOLVED AGAINST THE REAL COMPUTE NETLIST.
# The eth-derived guesses are GONE. Every get_pins/get_cells NAME filter below
# was matched against the routed checkpoint
#   fpga/build/cwallow/outputs/nanosoc_compute_chiplet_routed.dcp
# (Design State: Physopt postRoute, top = tidelink_design_wrapper) and the match
# COUNT recorded beside it. A selector that matches the WRONG NUMBER of objects
# is as broken as one matching none, so the counts - not just "it resolved" -
# are the evidence.
#
# THE ROOT MISTAKE, for the record: the scaffold assumed a "d2d0" infix marked
# link 0. It does not. `*d2d0*` DOES match 920 cells in this design - but every
# one of them is in the AHB interconnect decode/arbiter tree
# (u_compute_matrix_decode_d2d0_m, compute_target_output_D2D0, ...), NOT in the
# PHY. The PHY hierarchy has no d2d0/d2d1 token anywhere. The real link
# discriminator is the TideLink instance name itself:
#   tidelink_design_i/nanosoc_compute_chiplet_0/inst/u_chiplet/u_tidelink_0   <- LINK 0 (this file)
#   tidelink_design_i/nanosoc_compute_chiplet_0/inst/u_chiplet/u_tidelink_1   <- LINK 1 (see [L1])
# and the PHY sits at <link>/u_chiplet_controller/u_wlink/phy/gpio/.
# The divider the old selectors hunted for is not inside either link at all -
# it is a BD-LEVEL cell, tidelink_design_i/phy_clk_div2_0, so NO `*d2d0*`
# pattern could ever have reached it.
#
# Every unresolved selector fires Vivado 12-4739 ("No valid object(s) found"),
# which the message gate promotes to ERROR - so these were load-bearing TODOs,
# not cosmetic. Measured damage on the shipped `cwallow` bitstream, which was
# built with all five dead: check_timing no_clock = 15956 register pins,
# unconstrained_internal_endpoints = 45002, ZERO occurrences of pad_tx_0 in
# timing_summary.rpt, and a green "WNS 11.519 / WHS 0.010 / 0 failing" that
# measured only the constraints that survived the parse.
#-----------------------------------------------------------------------------
# Timing constraints for IMPLEMENTATION ONLY. Applying them during synthesis
# fires CRITICAL WARNING 12-4739 because the clk_wiz output clocks and the
# internal pad-capture cells are not visible to synthesis. build_design.tcl
# must apply:
#   set_property USED_IN_SYNTHESIS false     [get_files *_timing.xdc]
#   set_property USED_IN_IMPLEMENTATION true  [get_files *_timing.xdc]
# Do NOT add a runtime `set_property ... [info script]` line - `file normalize`
# / `info script` / `get_files` are procedural Tcl the XDC reader rejects
# (Designutils 20-1307). The wrapper already sets the property.
#-----------------------------------------------------------------------------

#=============================================================================
# COMPUTE DELTAS vs the eth chiplet (READ FIRST)
#=============================================================================
# (D1) TWO TideLinks. Compute bonds two links; the eth chiplet has one.
#      A KR260 has ONE J21, so only LINK 0 reaches the board (this file). LINK 1
#      has no board pads - see [L1] at the end. Do NOT copy these link-0
#      constraints for link-1 pads: link-1 has no board clock.
#
#      MEASURED (routed dcp) - how the two links actually differ by name:
#        get_cells -hier -filter {NAME =~ "*/u_tidelink_?"}          -> 2
#            .../u_chiplet/u_tidelink_0        (link 0)
#            .../u_chiplet/u_tidelink_1        (link 1)
#        get_cells -hier -filter {NAME =~ "*/phy/gpio"}              -> 2
#            .../u_tidelink_0/u_chiplet_controller/u_wlink/phy/gpio
#            .../u_tidelink_1/u_chiplet_controller/u_wlink/phy/gpio
#        get_ports {pad_clk_tx_1 pad_clk_rx_1 pad_tx_1[*] pad_rx_1[*]} -> 0
#      So the links ARE distinguishable by name, via `u_tidelink_0` /
#      `u_tidelink_1`, and link 1 has no bonded pads at all. That is the scope
#      token used throughout this file.
#
#      REFINEMENT on "link-1's gpiorx cells are tied off and must be excluded":
#      link 1 has NO gpiorx cells at all - synthesis removed them outright.
#        get_cells -hier -filter {NAME =~ "*/gpiorx_?"}                    -> 8 (ALL under u_tidelink_0)
#        get_cells -hier -filter {NAME =~ "*u_tidelink_1*gpiorx_*/link_data_pad_clk_reg[*]"} -> 0
#      So for the RX selectors the u_tidelink_0 scope is currently REDUNDANT -
#      unscoped and scoped both return 128. It is written in anyway, because the
#      redundancy is a property of today's tie-off, not of the constraint's
#      intent; if link 1 is ever given a real RX path, an unscoped selector
#      would silently start sweeping it in.
#      For the TX word clock the scope is NOT redundant - it is load-bearing.
#      Link 1's gpiotx_0 SURVIVES (its hsclk is clk_out1, wired at
#      tidelink_design.tcl:219), so the unscoped eth selector matches 2 pins and
#      would trip Constraints 18-359 rather than 12-4739. See [4b].
#
# (D2) user_ref_clk is a BONDED PAD on compute (x2: user_ref_clk_0/1), whereas
#      on the eth chiplet it was NOT bonded (aliased onto sys_fclk). On this
#      FPGA build link-0's user_ref_clk_0 is still expected to be DRIVEN by the
#      clk_wiz (the BD ties it to clk_out1, as eth did), NOT by an external
#      pin - so it is treated as an internal generated clock below, same as eth.
#      SCOPING-TODO [URC]: if the compute BD instead brings user_ref_clk_0 out
#      to a real J21/PMOD pin, add a create_clock on that port and re-group it.
#
# (D3) SWJ-DP (SWD+JTAG) not SWD-only. swclk (=TCK) and any JTAG TCK are slow
#      external debug clocks; see [DBG].
#=============================================================================

#-----------------------------------------------------------------------------
# [1] GPIO PHY pad clocks (KR260 link runs at 3.125 MHz / 320 ns)
#-----------------------------------------------------------------------------
# The TideLink GPIO PHY is source-synchronous. On the KR260 the link clock is
# clk_wiz clk_out1 (25 MHz) / 8 = 3.125 MHz -> 320 ns:
#   tidelink_design.tcl  -> CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000}
#   tidelink_phy_clk_div2.v -> 3-bit div_cnt, tap bit[2]  (= /8, despite the name)
#   this file            -> create_clock -period 320.000  +  -divide_by 8 (x2)
# 25 MHz + /8 (not a slower clk_out1 + /1) because a ~4.7 MHz clk_out1 is below
# the MPSoC MMCME4 VCO floor.
#
# Received clock from the peer chiplet on pad_clk_rx_0. It clocks the pad_rx_0[*]
# sampling registers - KEEP this create_clock so the pad_rx_0[*] -> capture
# relationship stays analysed (constraints [3]/[4]). pad_clk_rx_0 lands on an
# HDGC ball on BOTH boards (die_a AC14 / die_b AD15), so no CLOCK_DEDICATED_ROUTE
# override is needed. Conservatively slow for first eye closure; can likely run
# faster once the eye is characterised on the bench.
create_clock -period 320.000 -name pad_clk_rx_0 [get_ports pad_clk_rx_0]

#-----------------------------------------------------------------------------
# [2] Forwarded TX clock as a real source-synchronous generated clock
#-----------------------------------------------------------------------------
# The GPIO-PHY TX serializer + the pad_clk_tx_0 forward both run off
# user_ref_clk_0 = clk_wiz clk_out1 (25 MHz) / 8 = 3.125 MHz. Define pad_clk_tx_0
# as a generated clock derived from clk_out1 at the output port, then constrain
# pad_tx_0[*] against THAT (true forwarded-clock methodology) rather than vs an
# internal MMCM pin or false-pathing it.
#
# RESOLVED [BD-CLK] 2026-09-17. The eth path happened to be RIGHT here: the
# compute BD names its clock wizard clk_wiz_0 too, at BD level. MEASURED:
#   get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"} -> 1
#       tidelink_design_i/clk_wiz_0/clk_out1
#   get_clocks -of_objects <that pin>                                       -> 1
#       clk_out1_tidelink_design_clk_wiz_0_0   (period 39.982 ns = 25.011 MHz)
# Wildcard-free and exactly one pin, as required (a wildcard matching >1 pin
# trips Constraints 18-359 and silently drops this whole stanza).
# This stanza was NEVER among the broken five - it already resolved on the
# shipped build, which is why pad_clk_tx_0_fwd exists in the routed dcp at
# period 319.857 ns (= 39.982 x 8). Left byte-for-byte unchanged.
create_generated_clock -name pad_clk_tx_0_fwd \
    -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}] \
    -divide_by 8 [get_ports pad_clk_tx_0]

# Transmit eye: source-synchronous SDR centred-edge forward.
#
# THE NUMBER BELOW IS A BUDGET. NOTHING HAS EVER MEASURED THIS INTERFACE.
# This paragraph used to call the +/-20 ns "an ABSOLUTE budget ... do NOT rescale
# it if you change the rate knob". Git says otherwise: 9aee1d39 records
# "+/-5 -> +/-20 ns (period-scaled 4x, same 12.5%-of-period fraction)", and the
# +/-5 entered at 5ad4b0c7 as a fraction of the 40 ns period. The fraction WAS
# the derivation method; the "absolute" framing was written after the fact.
# Symmetric window vs the forwarded clock (launch and capture share the forwarded
# edge) so Vivado BALANCES rather than hold-pads every lane. At 320 ns the far die
# samples mid-cell (160 ns), leaving >=140 ns of true eye each side.
#
# -clock_fall IS THE LOAD-BEARING WORD BELOW. The far die captures on the
# FALLING edge of the forwarded clock. Two independent pieces of evidence:
# the PHY's reset default selects the INVERTED pad clock
# (out_prepend_swi_polarity <= 1'h1 - WavD2DGpio.v:1154, WavD2DGpio_v2.v:2190),
# and every shipped routed netlist names the capture cells' clock pad_clk_rx' -
# 82 endpoints on kr260-pair-nptp, 86 on kr260-pair-flip-nptp, 69 on
# pynq-z2-pair-all.
#
# Vivado infers the capture edge from the capture flop on the RX side, which is
# why pad_rx_0[*] shows no phantom violation. On TX the capture flop is OFF-CHIP
# and invisible, so the edge has to be DECLARED.
#
# MEASURED ON THIS TARGET, NOT INHERITED. Run 'xdcfix', 2026-09-17, the first
# build in which the five re-resolved selectors made user_ref_clk_0_div8 exist
# and so gave the pad_tx_0[*] check a launch clock at all:
#
#     WHS -22.363    THS -178.767    8 failing hold endpoints, all pad_tx_0[*]
#
# That is the same signature the eth twin carried before 4d87846 (-22.145, 8 EP),
# on a design that is not wrong - the constraint was checking an edge nothing
# captures on. design.mk:710-737 predicted the phantom "will not even show" until
# both fixes were on this lineage; the selector half landed in 63cfbfd and the
# phantom duly showed. This is the other half.
#
# THE BUDGET IS DELIBERATELY UNCHANGED. 4d87846 added this word upstream on
# kr260-eth-chiplet and ALSO cut +/-20 to +/-8 without saying why. Only the word
# is derived, so only the word is carried here. What would replace the number is
# the DUTY CYCLE of pad_clk_tx_0 at the connector, which nothing here measures.
set_output_delay -clock [get_clocks pad_clk_tx_0_fwd] -clock_fall -max  20.000 [get_ports {pad_tx_0[*]}]
set_output_delay -clock [get_clocks pad_clk_tx_0_fwd] -clock_fall -min -20.000 [get_ports {pad_tx_0[*]}]

#-----------------------------------------------------------------------------
# [3] RX pad capture: TIMED source-synchronous group, RELATIVE skew bounded
#-----------------------------------------------------------------------------
# Give Vivado a timed pad_rx_0[*] -> capture relationship (so it stops routing
# the 8 lanes with arbitrary delay) WITHOUT a naive absolute set_input_delay
# -min/-max (the hold-violation trap that inserts hold-fixing on every lane).
#
# (3a) Receive eye RELATIVE to pad_clk_rx_0, SYMMETRIC window. +/-4 ns are
#      ABSOLUTE board-trace skews (do not scale with the link period). Generous
#      by design - the calibrator absorbs dynamic skew; constraints only bound
#      the STATIC, build-varying part.
set_input_delay -clock [get_clocks pad_clk_rx_0] -max  4.000 [get_ports {pad_rx_0[*]}]
set_input_delay -clock [get_clocks pad_clk_rx_0] -min -4.000 [get_ports {pad_rx_0[*]}]

# (3b)/(3c) Bound the pad_rx_0[n] -> first-stage capture flop path as a pure
#      datapath delay (8 ns ceiling, NOT a clocked check -> no hold-fix
#      insertion) and EQUALISE the 8 lanes to within 2 ns (set_bus_skew). The
#      build-to-build defect is per-lane VARIANCE; bounding relative skew removes
#      it with no absolute hold pressure.
#
# RESOLVED [BD-RX] 2026-09-17. This fixes BOTH the set_max_delay (3b) and the
# set_bus_skew (3c) below - they share $_xlnx_shared_i0, so one dead selector
# cost two constraints (build_design.log:4562,4564 - two 12-4739 ERRORs).
#
# The WavD2DGpioRx first-stage register name did NOT change under IP-pack: it is
# still link_data_pad_clk_reg[*]. Only the hierarchy prefix was wrong.
#
# BEFORE (dead):  *d2d0*gpiorx_*/link_data_pad_clk_reg[*]                  -> 0
# AFTER  (live):  *u_tidelink_0*gpiorx_*/link_data_pad_clk_reg[*]          -> 128
#
# MEASURED on the routed dcp:
#   get_cells -hier -filter {NAME =~ "*u_tidelink_0*gpiorx_*/link_data_pad_clk_reg[*]"}
#     COUNT = 128   = 8 lanes (gpiorx_0 .. gpiorx_7) x 16 bits ([0] .. [15])
#     e.g. tidelink_design_i/nanosoc_compute_chiplet_0/inst/u_chiplet/u_tidelink_0/
#            u_chiplet_controller/u_wlink/phy/gpio/gpiorx_0/link_data_pad_clk_reg[0]
# 128 is the RIGHT number: 8 pad_rx_0[*] lanes, one 16-bit pad-clock capture
# register per lane. An unscoped "*gpiorx_*/..." also returns 128 today (link 1
# has no gpiorx at all) - the scope is defensive, see (D1).
set _xlnx_shared_i0 [get_cells -hier -filter {NAME =~ "*u_tidelink_0*gpiorx_*/link_data_pad_clk_reg[*]"}]
set_max_delay -datapath_only -from [get_ports {pad_rx_0[*]}] -to $_xlnx_shared_i0 8.000
set_bus_skew -from [get_ports {pad_rx_0[*]}] -to $_xlnx_shared_i0 2.000

# (3d) IOB packing FORCED OFF on KR260 (deliberate inversion of the Z2 IOB TRUE).
#      REQUIRED: the HDIO bank-44 pins + the V2 PHY's per-lane wpa_shift_q_reg
#      (a legal IOB candidate whose D fans out further) otherwise pack into the
#      HDIO input flop and fail post-route DRC PDRC-248 (8x). set_max_delay/
#      set_bus_skew - not IOB packing - are what make capture deterministic here.
set_property IOB FALSE [get_ports {pad_rx_0[*]}]

#-----------------------------------------------------------------------------
# [4a] PHY /8 clock (user_ref_clk_0 = clk_out1 / 8 = 3.125 MHz)
#-----------------------------------------------------------------------------
# tidelink_phy_clk_div2 is a /8 free-running counter (div_cnt_reg[2:0]) feeding
# u_div_bufg (a global clock buffer). Declare the divided clock EXPLICITLY so it
# has a stable name for the async clock_groups below. -source = the [2] bit's C
# pin (a SINGLE pin; matching div_cnt_reg[*] would hit 3 pins -> Constraints
# 18-359); generated clock defined on the BUFG output.
#
# RESOLVED [BD-DIV] 2026-09-17 - and the SCOPING-TODO's PREMISE WAS FALSE.
# Compute does NOT have two phy_clk_div instances. It has exactly ONE, and it is
# not inside either link: it is a BD-LEVEL cell, tidelink_design_i/phy_clk_div2_0.
# That is why no amount of link scoping could have rescued the old selector -
# there is no link hierarchy above this cell to scope to.
#
# MEASURED on the routed dcp:
#   get_cells -hier -filter {NAME =~ "*phy_clk_div*"}                 -> 12 objects,
#     ALL under the single tidelink_design_i/phy_clk_div2_0 (wrapper, inst, GND,
#     VCC, VCC_1, div_cnt[0..2]_i_1, div_cnt_reg[0..2], u_div_bufg)
#   get_pins -hier -filter {NAME =~ "*phy_clk_div*div_cnt_reg[*]/C"}  -> 3   (bits 0,1,2 - one divider)
#
# Only ONE divider exists because only LINK 0 is divided. tidelink_design.tcl:216
# wires phy_clk_div2_0/clk_out -> user_ref_clk_0, while :219 wires link 1's
# user_ref_clk_1 straight to clk_wiz_0/clk_out1 (undivided 25 MHz). So link 1
# has no /8 island and needs no second divider.
#
# Both filters below are WILDCARD-FREE full paths resolving to EXACTLY ONE pin
# (Constraints 18-359 safety - see [BD-CLK]).
#
# BEFORE (dead):  *d2d0*phy_clk_div*div_cnt_reg[2]/C                   -> 0
# AFTER  (live):  tidelink_design_i/phy_clk_div2_0/inst/div_cnt_reg[2]/C -> 1
# BEFORE (dead):  *d2d0*phy_clk_div*u_div_bufg*/O                      -> 0
# AFTER  (live):  tidelink_design_i/phy_clk_div2_0/inst/u_div_bufg/O     -> 1
#
# Sanity-checked the source pin really carries the master clock:
#   get_clocks -of_objects [get_pins .../div_cnt_reg[2]/C]
#     -> clk_out1_tidelink_design_clk_wiz_0_0   (39.982 ns), so -divide_by 8
#        gives 319.857 ns = the same 3.125 MHz the pad_clk_tx_0_fwd stanza uses.
# The BUFG instance kept its RTL name u_div_bufg through the UltraScale+
# BUFG->BUFGCE transform (get_cells -hier {NAME =~ "*phy_clk_div*bufg*"} -> 1).
#
# This one selector is why the ENTIRE user_ref_clk_0 /8 island was untimed:
# check_timing on the shipped build listed
#   tidelink_design_i/phy_clk_div2_0/inst/div_cnt_reg[2]/Q
# as a root clock pin with 300 register/latch pins having NO CLOCK.
create_generated_clock -name user_ref_clk_0_div8 \
    -source [get_pins -hier -filter {NAME =~ "tidelink_design_i/phy_clk_div2_0/inst/div_cnt_reg[2]/C"}] \
    -divide_by 8 [get_pins -hier -filter {NAME =~ "tidelink_design_i/phy_clk_div2_0/inst/u_div_bufg/O"}]

#-----------------------------------------------------------------------------
# [4b] TX WORD CLOCK (gpiotx_0 = local hsclk/16)
#-----------------------------------------------------------------------------
# Without a create_generated_clock the /16 TX word clock is an unconstrained,
# ungated fabric net and the deep Wlink a2l-read FIFO pointers + their
# WavResetSync never get a clean edge -> read side held in reset -> no TX data.
# Declaring it makes Vivado TIME the domain and route the high-fanout net on a
# global buffer.
#
# RESOLVED [BD-TXW] 2026-09-17.
#
# (a) count_reg[3] IS STILL THE /16 TAP - CONFIRMED, not assumed.
#     RTL: WavD2DGpioTx.v declares `reg [3:0] count;` with
#          `wire [3:0] count_in = count + 4'h1;` - a free-running mod-16
#          counter (the file's own header: "bit-by-bit using an internal 4-bit
#          `count` register that wraps mod-16"). The top bit of a mod-16
#          counter toggles every 8 cycles, i.e. full period 16 -> -divide_by 16
#          at count_reg[3]/Q is correct.
#     NETLIST: get_cells -hier -filter {NAME =~ "*u_tidelink_0*gpiotx_0/count_reg[*]"}
#          -> 4   (count_reg[0], [1], [2], [3] - exactly 4 bits, nothing wider,
#                  so [3] is the top bit and there is no [4] to prefer)
#     CORROBORATION: the shipped build's check_timing names
#          .../u_tidelink_0/.../gpiotx_0/count_reg[3]/Q as a root clock pin
#          driving 1813 register/latch pins with NO CLOCK - i.e. the netlist
#          agrees this pin is the root of a real, and previously untimed, clock
#          domain. VERDICT: the [BD-TXW] question is CONFIRMED, not refuted.
#
# (b) The link scope here is LOAD-BEARING, unlike [BD-RX]. Link 1's gpiotx_0
#     survives synthesis (its hsclk is the undivided clk_out1), so an UNSCOPED
#     eth-style selector matches TWO pins and would trip Constraints 18-359
#     instead of 12-4739 - a different, quieter failure. MEASURED:
#       get_pins -hier -filter {NAME =~ "*gpiotx_0/count_reg[3]/C"}              -> 2
#           .../u_tidelink_0/.../gpiotx_0/count_reg[3]/C
#           .../u_tidelink_1/.../gpiotx_0/count_reg[3]/C
#       get_pins -hier -filter {NAME =~ "*u_tidelink_0*gpiotx_0/count_reg[3]/C"} -> 1
#       get_pins -hier -filter {NAME =~ "*u_tidelink_0*gpiotx_0/count_reg[3]/Q"} -> 1
#
# BEFORE (dead):  *d2d0*gpiotx_0/count_reg[3]/C                 -> 0
# AFTER  (live):  *u_tidelink_0*gpiotx_0/count_reg[3]/C         -> 1
# BEFORE (dead):  *d2d0*gpiotx_0/count_reg[3]/Q                 -> 0
# AFTER  (live):  *u_tidelink_0*gpiotx_0/count_reg[3]/Q         -> 1
#
# ORDERING: the -source pin only carries a clock once [4a] above has declared
# user_ref_clk_0_div8, so this stanza MUST stay below [4a].
#
# NOT CONSTRAINED, DELIBERATELY: link 1's own /16 word clock
# (.../u_tidelink_1/.../gpiotx_0/count_reg[3]/Q) is still an undeclared clock
# root with 540 register pins and no clock. Declaring it is a LINK-1 constraint,
# which [L1] intentionally defers, and it is outside this change's remit. It is
# a known, measured residue - see [L1].
create_generated_clock -name gpiotx0_word_clk \
    -source [get_pins -hier -filter {NAME =~ "*u_tidelink_0*gpiotx_0/count_reg[3]/C"}] \
    -divide_by 16 [get_pins -hier -filter {NAME =~ "*u_tidelink_0*gpiotx_0/count_reg[3]/Q"}]

#-----------------------------------------------------------------------------
# [4] Async clock groups: isolate the genuine recovered-RX -> core CDC, keep the
#     pad_rx_0[*] -> capture analysis timed.
#-----------------------------------------------------------------------------
# set_clock_groups -asynchronous between pad_clk_rx_0 and hclk does NOT disable
# the pad_rx_0[*] -> capture paths (those are launched/captured on pad_clk_rx_0,
# same group, still timed by [3]); it only cuts pad_clk_rx_0<->hclk. Each domain
# crossing is 2-flop synchronised in RTL. user_ref_clk_0_div8 MUST be its own
# group vs hclk so the hclk<->PHY paths are NOT timed as a related integer
# crossing (BEAT-FREQUENCY WARNING: hclk 25 MHz and user_ref_clk_0 3.125 MHz are
# a clean 8:1 on paper, but the crossing is async-SYNCHRONISED, not phase-
# balanced - if Vivado times it as a related 8:1 it will report false setup/hold
# on a path the RTL never uses coherently. Grouping it async is REQUIRED, not an
# optimisation). gpiotx0_word_clk is /16 of the same island - kept grouped.
#
# RESOLVED [BD-HCLK] 2026-09-17: the eth clk_wiz path is correct on compute too
# - same BD-level instance as [2]. MEASURED -> exactly 1 pin, carrying exactly 1
# clock (clk_out1_tidelink_design_clk_wiz_0_0). See [BD-CLK] for the output.
#
# This line itself never failed. The set_clock_groups BELOW it did, and it took
# the WHOLE command with it: because [4a]/[4b] had died, two of the four -group
# arguments resolved to nothing, and Vivado aborted the command outright
# (build_design.log: "Common 17-39 'set_clock_groups' failed due to earlier
# errors"). So the shipped build ALSO lost the pad_clk_rx_0 <-> hclk async
# isolation, which had nothing wrong with it - one dead selector three stanzas
# up silently deleted a working constraint. With [4a]/[4b] live, all four groups
# resolve and the command runs.
#
# GROUPING UNCHANGED, deliberately: four separate -group clauses, byte-for-byte
# the same shape as the FPGA-proven eth file
# (kr260-eth-chiplet/kr260_eth_chiplet_tidelink_timing.xdc:346). Note the prose
# above says gpiotx0_word_clk is "kept grouped" with the /8 island while the
# command actually puts it in its OWN group (= async to user_ref_clk_0_div8).
# The command, not the comment, matches eth. NOT changed here: re-grouping is a
# timing-methodology decision, not a selector fix, and this change deliberately
# alters nothing but the dead selectors.
#
# pad_clk_tx_0_fwd is intentionally in NO group, so the
# user_ref_clk_0_div8 -> pad_tx_0[*] output paths from [2] stay TIMED.
set hclk_pin [get_pins -hier -filter {NAME =~ "tidelink_design_i/clk_wiz_0/clk_out1"}]

set_clock_groups -asynchronous \
    -group [get_clocks pad_clk_rx_0] \
    -group [get_clocks -of_objects $hclk_pin] \
    -group [get_clocks gpiotx0_word_clk] \
    -group [get_clocks user_ref_clk_0_div8]

#-----------------------------------------------------------------------------
# [6] False paths
#-----------------------------------------------------------------------------
# Board LEDs are human-visible; no functional timing path.
set_false_path -to [get_ports {led0 led1}]

# NOTE: no IDELAYE2 CNTVALUEIN false_path and no IDELAYE2 stanza - these targets
# build with USE_IDELAY=0, and the RPi header is HDIO (cannot host IDELAY). An
# empty set_false_path -to would be the silent-drop class the message gate
# promotes to ERROR (Vivado 12-1411), so it is intentionally omitted.

#-----------------------------------------------------------------------------
# [7] Combinational loop waiver (AHB-Lite HSEL=1 + HREADY loopback in the IP)
#-----------------------------------------------------------------------------
# Standard Vivado IP-Integrator AHB-Lite slave style: an intentional,
# functionally-correct combinational loop on the HREADY net. Per-net waiver as
# backup (the primary severity downgrade lives in *_tidelink_drc.xdc so it
# survives save_constraints round-trips).
# RESOLVED [BD-AHB] 2026-09-17: the eth net path resolves on compute unchanged.
# MEASURED: get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}
#   -> 161 nets. Non-empty, so no 12-1411 silent-drop. This line never appeared
# in build_design.log's error block and was never one of the broken five;
# recorded here only so the TODO is closed with a number behind it.
# NOT verified: whether 161 is the RIGHT number, i.e. whether both D2D AHB subs
# are represented or only one. The selector is a severity waiver, not a timing
# constraint, so an over- or under-match does not silently mistime anything -
# left as-is rather than narrowed on a guess.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]

#=============================================================================
# [DBG] SWJ-DP external debug clocks (compute is SWD+JTAG, not SWD-only)
#=============================================================================
# swclk (=SWD SWCLK / JTAG TCK) is a slow external debug clock. Its
# CLOCK_DEDICATED_ROUTE FALSE waiver is in the PIN XDC (on the NET). The KR260
# eth build closes with the dbg_hub/BSCAN(TCK) WHS "noise" present and does NOT
# waive it (those TCK paths are inactive outside a ChipScope session).
#
# SCOPING-TODO [DBG]: if the compute build wants clean intent on the debug
# clock, add here once the BD is built:
#   create_clock -period <slow, e.g. 100.000> -name swclk [get_ports swclk]
#   set_clock_groups -asynchronous -group [get_clocks swclk] -group ... (core)
# Not added now: create_clock on an unconstrained scaffold port with no BD
# behind it would itself 12-4739 during impl. Add it WITH the wrapper.

#=============================================================================
# [L1] SCOPING-TODO - LINK 1 (d2d1) IS TIED OFF ON THE KR260
#=============================================================================
# A KR260 has ONE J21 header, already fully consumed by link-0 above. Link-1's
# pads (pad_clk_tx_1, pad_tx_1[*], pad_clk_rx_1, pad_rx_1[*], i2c1_*) therefore
# have NO board pins and NO forwarded board clock. The BD/wrapper agent must tie
# link-1 off inside the wrapper (drive pad_rx_1[*]/pad_clk_rx_1 to idle
# constants, leave pad_tx_1[*] unconnected) - mirror the eth wrapper's
# rmii_*_idle tie-off pattern. With link-1 tied off:
#   - Do NOT create_clock pad_clk_rx_1 (no toggling source -> unconstrained/
#     dropped). If the tie-off leaves internal link-1 PHY logic clocked, its
#     clock comes from user_ref_clk_1.
#   - user_ref_clk_1: CONFIRMED 2026-09-17 - the BD already wires it, to
#     clk_wiz_0/clk_out1 UNDIVIDED (tidelink_design.tcl:219), not to a divider.
#     So link 1's hsclk is the 25 MHz core clock and is ALREADY a constrained
#     clock; it needs no create_generated_clock of its own.
#=============================================================================
# [RESIDUE] KNOWN-UNCONSTRAINED CLOCK ROOTS THIS CHANGE DOES NOT TOUCH
#=============================================================================
# Measured from the shipped build's check_timing (fpga/build/cwallow/reports/
# timing_summary.rpt, "1. checking no_clock (15956)"). Fixing the five dead
# selectors above declares the user_ref_clk_0 /8 island and link-0's TX word
# clock. These roots remain undeclared AFTERWARDS, on purpose - each would be a
# NEW constraint, not a re-resolution of a broken one:
#
#   (R1) link-0 RX WORD CLOCKS, 8 of them - the largest single residue.
#        .../u_tidelink_0/.../gpio/gpiorx_<n>/g_t3a_passthru.count_reg[3]/Q
#        MEASURED: get_pins -hier -filter
#          {NAME =~ "*u_tidelink_0*gpiorx_*/g_t3a_passthru.count_reg[3]/Q"} -> 8
#        check_timing attributes 8990 (gpiorx_0) + 569 x 7 (gpiorx_1..7)
#        = 12973 no-clock register pins to these eight roots. They are the RX
#        mirror of [4b]'s TX word clock and would plausibly take the same
#        create_generated_clock -divide_by 16 treatment. NOT ADDED: the eth file
#        does not declare them either, so adding them here would be new,
#        unproven methodology on a target that has never had a timed build.
#        Declare them as a deliberate follow-up, with their own before/after.
#
#   (R2) link-1 TX word clock, 540 no-clock pins - see [4b](b).
#
#   (R3) swclk, 330 no-clock pins - already covered by the [DBG] TODO above.
#=============================================================================
