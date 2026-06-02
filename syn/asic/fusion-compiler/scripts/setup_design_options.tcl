#-----------------------------------------------------------------------------
# Post-elaborate, design-scoped app_options. Sourced after a current block
# exists (i.e. after elaborate or open_block).
#
# This partition is area-constrained, so the knobs below trade some
# routing/timing margin for tighter packing:
#   - place.coarse.congestion_driven_max_util raised to match the 0.85
#     core utilisation target (default 0.7 is what FC will plan toward,
#     leaving holes if the floorplan is denser).
#   - placement_congestion_effort kept at medium so the placer still
#     spreads cells when local congestion would force detours; "low"
#     packs harder but tends to lose timing in route_opt.
#   - compile.area_recovery enabled so synthesis substitutes lower-drive
#     gates wherever slack permits.
#-----------------------------------------------------------------------------

# Match the dense floorplan target (FC_CORE_UTILIZATION = 0.85 in Makefile).
set_app_options -name place.coarse.congestion_driven_max_util -value 0.85

# Keep placement effort up so the dense pack doesn't strand routing.
set_app_options -name compile.final_place.placement_congestion_effort   -value medium
set_app_options -name compile.initial_opto.placement_congestion_effort -value medium

# Area is squeezed primarily by FC_CORE_UTILIZATION (Makefile-level),
# clock-gating insertion (FC default), and the dense floorplan with the
# rf_16k pinned to one corner. We deliberately do NOT set_max_area 0
# here: the first bring-up run hit setup -1.08ns / hold -0.39ns at
# route_opt because the area constraint kept route_opt swapping in
# smaller cells while a long PTP/PHC combinational path was already
# starved for drive. set_qor_strategy in U-2022.12 only accepts
# {timing, leakage_power, total_power} so there is no documented "area"
# strategy — leaning on default timing-first opto and letting the
# packed floorplan supply the area savings closes timing without
# sacrificing the area win.

#-----------------------------------------------------------------------------
# Area-reduction levers — validated option names for fc_shell U-2022.12.
#-----------------------------------------------------------------------------

# 1. Cross-boundary optimisation — let synth fold redundant logic across
#    u_xhb_mng / u_tidelink_fifo / u_chiplet_controller boundaries.
set_app_options -name compile.flow.boundary_optimization -value true

# 2. Multi-bit register banking — packs per-bit DFFs into multi-bit cells
#    where the library provides them. The right option name in U-2022.12
#    is `place_opt.flow.enable_multibit_banking` (NOT compile.seqmap.* —
#    that one is from a different DC release).
set_app_options -name place_opt.flow.enable_multibit_banking -value true

# 3. Lower clock-gating threshold — synth's default ICG-insertion minimum
#    bitwidth misses smaller register banks (2-3 bit counters, state vectors).
#    Dropping to 2 catches them; each gated bank saves N flop clock-input
#    loads. Disabled when FC_CLOCK_GATING=off (Makefile-level).
if {!([info exists ::env(FC_CLOCK_GATING)] && $::env(FC_CLOCK_GATING) eq "off")} {
    set_clock_gating_options -minimum_bitwidth 2
}

# Clock-gate insertion toggle. The Makefile exports FC_CLOCK_GATING
# (default "on"); when "off" we mark every PREICG_* library cell as
# do-not-use and disable the power-driven CG pass. The legacy
# `compile.flow.gate_clock` app_option doesn't exist in U-2022.12
# (Invalid option name); set_dont_use on the library is the reliable
# cross-version path. Production builds keep CG on for the area win.
#-----------------------------------------------------------------------------
# Optional: preserve Wlink Chisel FCSM modules through synthesis.
#
#   make fc FC_PRESERVE_WLINK_FCSM=on   # uses work_preserve/ tree
#
# EMPIRICAL FINDING (this build): the knob is INEFFECTIVE for reducing
# LEC don't-verify residuals on this design. Measured both production
# and preserve variants:
#   production: 18,542 / 0 / 0 / 256 don't-verify  (area 477,768 μm²)
#   preserve:   18,542 / 0 / 0 / 256 don't-verify  (area 477,711 μm²)
# Identical LEC counts, ~0 area cost.
#
# Why: the 256 residuals are dominated by registers OUTSIDE
# WlinkGenericFCSM_* — 128 of them in lltx/link_data_reg_reg
# (WlinkTxLinkLayer), 16 in txpstate/count_reg (WlinkTxPstateCtrl),
# 12 in lltx/byte_count_reg. set_dont_touch on FCSM_* eliminates
# residuals in 3 of the 4 axi*FC instances but the net total is
# unchanged.
#
# To actually shift the residual count, the preserve list would need
# to include WlinkTxLinkLayer, WlinkTxPstateCtrl, WlinkRxLinkLayer,
# etc. — costlier and probably still leaves residuals elsewhere.
# Keeping the knob in place for future investigation but not a
# recommended default.
#-----------------------------------------------------------------------------
if {[info exists ::env(FC_PRESERVE_WLINK_FCSM)] && $::env(FC_PRESERVE_WLINK_FCSM) eq "on"} {
    puts "INFO: \[setup\] FC_PRESERVE_WLINK_FCSM=on — set_dont_touch on WlinkGenericFCSM_*"
    set preserved 0
    foreach mod {WlinkGenericFCSM WlinkGenericFCSM_1 WlinkGenericFCSM_2 \
                 WlinkGenericFCSM_3 WlinkGenericFCSM_4 WlinkGenericFCSM_5 \
                 WlinkGenericFCSM_6} {
        set cells [get_cells -quiet -hier -filter "ref_name == $mod"]
        if {[sizeof_collection $cells] > 0} {
            set_dont_touch $cells true
            incr preserved [sizeof_collection $cells]
        }
    }
    puts "INFO: \[setup\]   $preserved Wlink FCSM instances preserved"
}

if {[info exists ::env(FC_CLOCK_GATING)] && $::env(FC_CLOCK_GATING) eq "off"} {
    puts "INFO: \[setup\] FC_CLOCK_GATING=off — banning CKLNQD*/CKLHQD* (incl. BWP12T variants) cells"
    set icg_cells [get_lib_cells -quiet \
        "*/CKLNQD* */CKLHQD* */CKLNQ*BWP12T* */CKLHQ*BWP12T*"]
    if {[sizeof_collection $icg_cells] > 0} {
        set_dont_use $icg_cells
        puts "INFO: \[setup\]   set_dont_use on [sizeof_collection $icg_cells] ICG cells"
    } else {
        puts "WARN: \[setup\]   no CKLNQD*/CKLHQD* cells matched — check the library"
    }
    # `power.clock_gating.enable` and `compile.flow.gate_clock` are both
    # invalid app_option names in U-2022.12 — set_dont_use on the ICG
    # library cells is the only reliable knob in this version. With no
    # ICG cells available, compile_fusion's CG inserter has nothing to
    # instantiate and silently skips the pass.
}

#-----------------------------------------------------------------------------
# CTS cell purpose — force clock_opt to use CK-prefixed clock-characterized
# cells for the clock fanin.
#
# Why: under aspect-2.0 floorplan, compile_fusion/clock_opt picked regular
# signal cells (MUX2D*, BUFFD*) for the pad_clk_inv_scan_mux + driver chain
# in u_wlink/phy/gpio/gpiorx_*/, producing 0.41 ns of OCV-asymmetric hold
# uncertainty that breaks the -1.00 ns input_delay -min source-sync budget
# (-0.59 ns scen_fast hold WNS, 130 NVEs at PG gate). FC2 aspect-1.0 closed
# clean because clock_opt happened to swap to CK cells (CKBD4, CKMUX2D1) for
# the same path.
#
# Verified via /tmp/td_struct_compare2.tcl on the worst-hold path
#   u_chiplet_controller/u_wlink/phy/gpio/gpiorx_5/link_data_pad_clk_reg[13]/CP:
#     FC2 fanin (7 cells):
#       CKBD4 + CKLNQD1 + CKMUX2D1 + CKND16 + MUX2D0 + SDFSNQD2 + SEDFCNQD0
#     build #8 fanin (8 cells):
#       BUFFD12 + BUFFD8 + CKLNQD1 + CKND16 + MUX2D2 + MUX2D4 + SDFSNQD2 + SEDFCNQD0
#
# Mechanism: set_lib_cell_purpose -exclude cts on the regular signal
# variants stops clock_opt from picking them as clock-tree cells. The same
# cells stay available for normal signal paths (the exclusion is purpose-
# scoped, not a global set_dont_use). CK-prefixed clock cells already
# carry the default 'cts' purpose, so no -include is needed for them.
#
# fc_shell U-2022.12: probed via `help -verbose set_lib_cell_purpose` —
# -exclude values are {all, cts, hold, none, optimization, power}.
# 12-track tcbn65lpbwp12t cell names carry a BWP12T suffix
# (MUX2D1 -> MU2D1BWP12T, BUFFD8 -> BUFFD8BWP12T etc.). Patterns
# below match both the legacy 9-track unsuffixed names and the
# 12-track BWP12T-suffixed names so the same restriction works
# under either STANDARD_CELL_BASE_PATH.
set _non_ck_signal_cells [get_lib_cells -quiet \
    "*/MUX2D* */BUFFD* */INVD* */MU2D*BWP12T* */BUFFD*BWP12T* */INVD*BWP12T*"]
if {[sizeof_collection $_non_ck_signal_cells] > 0} {
    set_lib_cell_purpose -exclude cts $_non_ck_signal_cells
    puts [format "INFO: \[setup\] excluded %d non-CK signal cells (MUX2D*/BUFFD*/INVD* +BWP12T) from cts purpose — clock_opt restricted to CK cells" \
            [sizeof_collection $_non_ck_signal_cells]]
} else {
    puts "WARN: \[setup\] no MUX2D*/BUFFD*/INVD* cells found in libs — CK-only CTS restriction not applied"
}
