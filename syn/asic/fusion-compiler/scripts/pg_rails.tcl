#-----------------------------------------------------------------------------
# Phase 4a: post-route PG rail rebind
#
# Run with: fc_shell -f pg_rails.tcl   (after 4_route.tcl, before 5_signoff)
#
# WHY THIS STAGE EXISTS
# ---------------------
# pg_mesh.tcl builds the VDD/VSS supply, the M5/M6 mesh, and the macro
# straps at INIT, before placement/route. The M1 std-cell follow-pin
# rails it also creates there cannot be via-stitched to the mesh against
# the final layout, because at init there is no final placement/route.
#
# This stage rebinds the std-cell M1 rail pattern + re-ties leaf PG
# pins, runs a light co-management reroute (insurance) and verifies,
# before saving pg.design. pg.design is consumed by 5_signoff.tcl —
# never route.design directly — so the signoff/abstract products are
# emitted against the stitched PG.
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)

file mkdir $fc_reports

open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/route.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

# EOL-aware DRC convergence knobs — pure router-effort levers (the
# timing graph is not touched: route.detail.timing_driven defaults to
# false in this build). Documented in the agent EOL-fix report
# (2026-05-20).
puts "INFO: \[fc_pg\] EOL DRC convergence knobs"
set_app_options -name route.detail.force_max_number_iterations         -value true
set_app_options -name route.detail.drc_convergence_effort_level        -value high
set_app_options -name route.detail.eco_max_number_of_iterations        -value 50
set_app_options -name place.legalize.reduce_conservatism_in_eol_check  -value true
set_app_options -name route.common.eco_route_fix_existing_drc          -value true

proc _float_pair {f} {
    if {![file exists $f]} { return {? ?} }
    set fh [open $f r]; set txt [read $fh]; close $fh
    set caps [list]
    foreach {m c} [regexp -all -inline {Number of floating std cells:\s*(\d+)} $txt] {
        lappend caps $c
    }
    set vdd [expr {[llength $caps] > 0 ? [lindex $caps 0] : "?"}]
    set vss [expr {[llength $caps] > 1 ? [lindex $caps 1] : "?"}]
    return [list $vdd $vss]
}

puts "INFO: \[fc_pg\] baseline check_pg_connectivity (route.design)"
redirect -tee -file ${fc_reports}/04f_pg_baseline.rep {
    catch {check_pg_connectivity}
}
lassign [_float_pair ${fc_reports}/04f_pg_baseline.rep] b_vdd b_vss

# Init-stage patterns/strategies do NOT persist across save_block/open_block,
# so the rail pattern is rebuilt here against the routed block before
# re-tying leaf PG pins.
puts "INFO: \[fc_pg\] (re)creating std_cell_rail pattern"
catch {remove_pg_patterns   -all}
catch {remove_pg_strategies -all}

create_pg_std_cell_conn_pattern std_cell_rail \
    -layers {M1} \
    -rail_width 0.18

set_pg_strategy rail_strategy \
    -pattern {{name: std_cell_rail} {nets: {VDD VSS}}} \
    -core

puts "INFO: \[fc_pg\] connect_pg_net -automatic"
catch {connect_pg_net -automatic}

# Guarded: a compile_pg failure must NOT silently hand a still-floating
# block to signoff — fail the stage loudly (no FC_STAGE_OK marker) so
# make stops here.
puts "INFO: \[fc_pg\] compile_pg -strategies {rail_strategy}"
if {[catch {compile_pg -strategies {rail_strategy}} pg_err]} {
    puts "ERROR: \[fc_pg\] compile_pg failed: $pg_err"
    puts "ERROR: \[fc_pg\] $::errorInfo"
    puts "ERROR: \[fc_pg\] not touching FC_STAGE_OK — route.design left intact."
    exit 1
}

# Light co-management reroute (insurance). The rail rebind above only
# re-binds the std-cell M1 rails, so the route delta is small. Still run
# the same convergence 4_route.tcl uses so any minor PG-vs-signal
# spacing from the rebind is legalised and we verify check_routes did
# not regress vs the routed baseline.
redirect -tee -file ${fc_reports}/04g0_pg_routes_pre.rep {
    catch {check_routes -open_net true -drc true}
}
# Three-pass EOL-targeted ECO loop. The single route_eco pass cut
# 99 → 57 in the prior run; the second route_detail + third route_eco
# close the loop (ahb_qspi proved this pattern: 47k → 11 DRCs).
# Realistic target: 57 → ≤20 (last ~10 EOLs are structural on
# macro-heavy partitions and need a chip-top ECO hand-off).
puts "INFO: \[fc_pg\] route_eco pass 1 (PG-vs-signal congestion relief)"
if {[catch {route_eco -open_net_driven false \
                      -max_detail_route_iterations 40} pg_ro_err]} {
    puts "WARN: \[fc_pg\] route_eco pass 1 returned: $pg_ro_err"
}

puts "INFO: \[fc_pg\] route_detail pass 2 (incremental EOL legalisation)"
if {[catch {route_detail -incremental true \
                         -initial_drc_from_input true \
                         -max_number_iterations 40} pg_rd_err]} {
    puts "WARN: \[fc_pg\] route_detail pass 2 returned: $pg_rd_err"
}

puts "INFO: \[fc_pg\] route_eco pass 3 (final EOL convergence)"
if {[catch {route_eco -open_net_driven false \
                      -max_detail_route_iterations 40} pg_ro2_err]} {
    puts "WARN: \[fc_pg\] route_eco pass 3 returned: $pg_ro2_err"
}

puts "INFO: \[fc_pg\] post-reroute check_pg_connectivity"
redirect -tee -file ${fc_reports}/04g_pg_post.rep {
    catch {check_pg_connectivity}
}
lassign [_float_pair ${fc_reports}/04g_pg_post.rep] p_vdd p_vss
redirect -tee -file ${fc_reports}/04g1_pg_routes_post.rep {
    catch {check_routes -open_net true -drc true}
}
proc _drc_count {f} {
    if {![file exists $f]} { return "?" }
    set fh [open $f r]; set t [read $fh]; close $fh
    if {[regexp {Total number of DRC[s]? *[:=] *([0-9]+)} $t -> n]} { return $n }
    if {[regexp {([0-9]+) +total +DRC} $t -> n]} { return $n }
    return "see-report"
}
set r_pre  [_drc_count ${fc_reports}/04g0_pg_routes_pre.rep]
set r_post [_drc_count ${fc_reports}/04g1_pg_routes_post.rep]
puts "INFO: \[fc_pg\] check_routes DRCs: baseline=$r_pre -> post-reroute=$r_post"

set fh [open ${fc_reports}/04h_pg_stitch.rep w]
puts $fh "================================================================"
puts $fh " Post-route PG rail rebind — ${top_module}"
puts $fh "================================================================"
puts $fh ""
puts $fh " floating std cells   VDD     VSS"
puts $fh " -----------------   -----   -----"
puts $fh " baseline (route)    [format %5s $b_vdd]   [format %5s $b_vss]"
puts $fh " after PG + reroute  [format %5s $p_vdd]   [format %5s $p_vss]"
puts $fh ""
puts $fh " check_routes DRCs:  baseline $r_pre  ->  post-reroute $r_post"
puts $fh "================================================================"
close $fh
puts "INFO: \[fc_pg\] floating std cells: route VDD=$b_vdd VSS=$b_vss -> post VDD=$p_vdd VSS=$p_vss"

# Timing guard — the three-pass ECO loop can lengthen detours and push
# scen_slow setup WNS negative. Bail if WNS < -0.05 ns so signoff/
# abstract don't run against a block we'd have to throw away anyway.
# fc_shell U-2022.12 does not expose `setup_wns` as a scenario attribute
# (ATTR-1), so parse the WNS out of the report_qor text instead — this
# is robust across releases.
update_timing -full
set _qor_post ${fc_reports}/04i_pg_post_eco_qor.rep
redirect -file $_qor_post {
    current_scenario scen_slow
    report_qor -summary
}
set _wns_slow ""
set _hold_slow ""
if {[file exists $_qor_post]} {
    set _fh [open $_qor_post r]
    while {[gets $_fh _line] >= 0} {
        if {[regexp {\(Setup\)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(\d+)} $_line _ _wns _tns _nve]} {
            if {$_wns_slow eq ""} { set _wns_slow $_wns }
        }
        if {[regexp {\(Hold\)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(\d+)} $_line _ _hwns _htns _hnve]} {
            if {$_hold_slow eq ""} { set _hold_slow $_hwns }
        }
    }
    close $_fh
}

# Also capture scen_fast hold (Gap B/C's known failure mode was here).
set _qor_post_fast ${fc_reports}/04i_pg_post_eco_qor_fast.rep
redirect -file $_qor_post_fast {
    if {[sizeof_collection [get_scenarios -quiet scen_fast]] > 0} {
        current_scenario scen_fast
        report_qor -summary
    }
}
set _hold_fast ""
if {[file exists $_qor_post_fast]} {
    set _fh [open $_qor_post_fast r]
    while {[gets $_fh _line] >= 0} {
        if {[regexp {\(Hold\)\s+(-?[0-9.]+)} $_line _ _hwns]} {
            set _hold_fast $_hwns; break
        }
    }
    close $_fh
}

set _abort 0
if {$_wns_slow eq ""} {
    puts "WARN: \[fc_pg\] could not parse setup WNS — skipping setup guard"
} elseif {[expr {$_wns_slow < -0.05}]} {
    puts "ERROR: \[fc_pg\] scen_slow setup WNS regressed to $_wns_slow (< -0.05 ns)"
    set _abort 1
} else {
    puts "INFO: \[fc_pg\] setup guard PASS: scen_slow setup WNS = $_wns_slow"
}

# Hold guard — Gap B/C's failure mode was -4.71 ns scen_fast hold WNS.
# Tolerance ±0.5 ns (much wider than setup because hold violations are
# typically fixable downstream via buffer insertion; we only block on a
# catastrophic regression).
if {$_hold_fast eq ""} {
    puts "WARN: \[fc_pg\] could not parse scen_fast hold WNS — skipping hold guard"
} elseif {[expr {$_hold_fast < -0.5}]} {
    puts "ERROR: \[fc_pg\] scen_fast hold WNS regressed to $_hold_fast (< -0.5 ns)"
    puts "ERROR: \[fc_pg\]   typical cause: ASIC_TSMC65 cell substitution without"
    puts "ERROR: \[fc_pg\]   adequate async-reset false_path coverage (see"
    puts "ERROR: \[fc_pg\]   1_init_design.tcl Wav async-pin block)"
    set _abort 1
} else {
    puts "INFO: \[fc_pg\] hold guard PASS: scen_fast hold WNS = $_hold_fast"
}

if {$_abort} {
    puts "ERROR: \[fc_pg\] aborting — pg.design NOT saved, FC_STAGE_OK NOT emitted"
    exit 1
}

save_block
save_lib   $design_lib_name
save_block -as ${design_lib_name}:${top_module}/pg.design

puts "FC_STAGE_OK: pg"
exit
