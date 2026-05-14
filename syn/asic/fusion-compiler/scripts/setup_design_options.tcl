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
if {[info exists ::env(FC_CLOCK_GATING)] && $::env(FC_CLOCK_GATING) eq "off"} {
    puts "INFO: \[setup\] FC_CLOCK_GATING=off — banning PREICG_* cells"
    set icg_cells [get_lib_cells -quiet */PREICG_*]
    if {[sizeof_collection $icg_cells] > 0} {
        set_dont_use $icg_cells
        puts "INFO: \[setup\]   set_dont_use on [sizeof_collection $icg_cells] ICG cells"
    } else {
        puts "WARN: \[setup\]   no PREICG_* cells matched — check the library"
    }
    # `power.clock_gating.enable` and `compile.flow.gate_clock` are both
    # invalid app_option names in U-2022.12 — set_dont_use on the ICG
    # library cells is the only reliable knob in this version. With no
    # ICG cells available, compile_fusion's CG inserter has nothing to
    # instantiate and silently skips the pass.
}
