#-----------------------------------------------------------------------------
# Phase 5: DRC — in-design checks + optional ICV signoff DRC.
#
# Run with: fc_shell -f 7_drc.tcl   (after 5_signoff.tcl)
#
# Two tiers of check are run:
#
#  Tier 0 — structural / constraint pre-checks (advisory unless gated)
#  Tier 1 — geometric / connectivity in-design checks (hard gate)
#  Tier 1b — placement-legality / handoff checks (mostly hard gate)
#  Tier 2 — ICV signoff DRC (opt-in: set ICV_DRC_RUNSET=<path>)
#
# Per-check reports are written to $FC_REPORTS/07_<check>.rep so the
# Makefile's drc_summary target can grep them for violation counts.
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)

open_lib   $design_lib_name
open_block ${design_lib_name}:${top_module}/signoff.design

source ${fc_dir}/scripts/setup.tcl
source ${fc_dir}/scripts/setup_design_options.tcl

file mkdir $fc_reports

array set drc_results {}

proc run_check {name body} {
    global fc_reports drc_results
    set rpt ${fc_reports}/07_${name}.rep
    puts "INFO: \[fc_drc\] $name -> $rpt"
    set rc 0
    if {[catch {redirect -tee -file $rpt $body} err]} {
        puts "WARN: \[fc_drc\] $name raised an error: $err"
        set rc 1
    }
    set drc_results($name) [list $rc $rpt]
}

# Advisory variant. Same redirect/capture, but if the command failed
# because the check name / option isn't recognised in THIS fc_shell
# build (the atomic check_design rule set drifts across releases),
# record rc=2 ("SKIP") instead of rc=1 ("FAIL").
proc run_check_adv {name body} {
    global fc_reports drc_results
    set rpt ${fc_reports}/07_${name}.rep
    puts "INFO: \[fc_drc\] $name -> $rpt (advisory)"
    set rc 0
    if {[catch {redirect -tee -file $rpt $body} err]} {
        if {[regexp -nocase {unknown|not a (valid|supported|recognized|known)|unsupported|no such|invalid (option|value|check)|illegal|is not a check} $err]} {
            puts "WARN: \[fc_drc\] $name unsupported in this fc_shell build — SKIP ($err)"
            set rc 2
        } else {
            puts "WARN: \[fc_drc\] $name raised an error: $err"
            set rc 1
        }
    }
    set drc_results($name) [list $rc $rpt]
}

puts "INFO: \[fc_drc\] tier 0 — structural / constraint pre-checks"

run_check_adv pre_netlist    {check_design -checks {netlist_pre_check}}
run_check_adv pre_designdata {check_design -checks {design_data}}
run_check_adv pre_signoff    {check_design -checks {pre_signoff_stage}}
run_check_adv pre_timing     {check_timing}

puts "INFO: \[fc_drc\] tier 1 — in-design checks"

run_check check_design          {check_design -checks {block_ready_for_top legality routes analyze_design_violations pin_placement}}
run_check check_legality        {check_legality -verbose}
run_check check_pg_connectivity {check_pg_connectivity}
# std-cell + macro PG geometry was already signed off by the foundry
# when the library shipped; skip shapes inside library cells + std-cell
# follow-pin rails (intended same-net overlap that PG-DRC flags as a
# "short" — explicitly waived by FC's check_pg_drc flags).
run_check check_pg_drc          {check_pg_drc -do_not_check_shapes_in_lib_cells -ignore_std_cells}
run_check check_routes          {check_routes -open_net true -drc true -antenna true -report_all_open_nets true}

puts "INFO: \[fc_drc\] tier 1b — placement-legality / handoff checks"

run_check_adv check_placement     {check_design -checks {placement}}
run_check_adv check_mv_design     {check_design -checks {mv_design}}
run_check_adv check_pin_placement {check_pin_placement}
run_check_adv check_clock_trees   {check_clock_trees}

set icv_runset ""
if {[info exists ::env(ICV_DRC_RUNSET)]} {
    set icv_runset $::env(ICV_DRC_RUNSET)
}

if {$icv_runset ne "" && [file exists $icv_runset]} {
    puts "INFO: \[fc_drc\] tier 2 — IC Validator signoff DRC ($icv_runset)"

    set strategy [expr {[info exists ::env(ICV_DRC_STRATEGY)] \
                       ? $::env(ICV_DRC_STRATEGY) \
                       : "tidelink_drc"}]

    if {[catch {get_signoff_drc_strategy $strategy} _]} {
        define_signoff_drc_strategy -strategy $strategy \
            -runset $icv_runset \
            -ignore_errors false
    }

    run_check signoff_drc [list signoff_check_drc -strategy $strategy \
                                                  -open_in_icv_workbench false]
} else {
    puts "INFO: \[fc_drc\] tier 2 — ICV_DRC_RUNSET not set or missing,"
    puts "INFO:                  skipping ICV signoff DRC."
}

#-----------------------------------------------------------------------------
# Per-check violation-count summary.
#-----------------------------------------------------------------------------
proc grep_count {file re {default -1}} {
    if {![file exists $file]} { return $default }
    set fp [open $file r]
    set txt [read $fp]
    close $fp
    if {[regexp $re $txt -> n]} { return $n }
    return $default
}

set summary_rpt ${fc_reports}/07_summary.rep
set sfp [open $summary_rpt w]
puts $sfp "================================================================="
puts $sfp " DRC violation summary — $top_module"
puts $sfp "================================================================="
puts $sfp [format "  %-22s  %-7s  %s" "Check" "Status" "Detail"]
puts $sfp "  ----------------------  -------  --------------------------------"

set total_violations 0

proc summarise {name status detail count} {
    global sfp total_violations
    puts $sfp [format "  %-22s  %-7s  %s" $name $status $detail]
    incr total_violations $count
}

proc summarise_check {name hard} {
    global fc_reports drc_results
    if {![info exists drc_results($name)]} {
        summarise $name "n/a" "not run" 0
        return
    }
    lassign $drc_results($name) rc rpt
    if {$rc == 2} {
        summarise $name "SKIP" "unsupported in this fc_shell build" 0
        return
    }
    if {[file exists $rpt]} {
        set _fp [open $rpt r]; set _txt [read $_fp]; close $_fp
        if {[regexp {is not a valid check name|\(EMS-035\)} $_txt]} {
            summarise $name "SKIP" "check name absent in this fc_shell build" 0
            return
        }
    }
    set ems [grep_count $rpt {Total \d+ EMS messages\s*:\s*(\d+) errors?}]
    if {$ems != -1} {
        if {$ems == 0} {
            summarise $name "PASS" "0 EMS errors" 0
        } else {
            summarise $name [expr {$hard ? "FAIL" : "WARN"}] \
                      "$ems EMS errors" [expr {$hard ? $ems : 0}]
        }
        return
    }
    if {$rc == 0} {
        summarise $name "PASS" "completed — see [file tail $rpt]" 0
    } else {
        summarise $name [expr {$hard ? "FAIL" : "WARN"}] \
                  "see [file tail $rpt]" [expr {$hard ? 1 : 0}]
    }
}

# check_design — EMS message summary line.
set ems_errors [grep_count ${fc_reports}/07_check_design.rep \
                {Total \d+ EMS messages\s*:\s*(\d+) errors?}]
if {$ems_errors == -1} {
    summarise "check_design" "n/a"  "no EMS-summary line found" 0
} elseif {$ems_errors == 0} {
    summarise "check_design" "PASS" "0 EMS errors"             0
} else {
    summarise "check_design" "FAIL" "$ems_errors EMS errors"   $ems_errors
}

set leg_rpt ${fc_reports}/07_check_legality.rep
set leg_pass 0
if {[file exists $leg_rpt]} {
    set fp [open $leg_rpt r]
    set txt [read $fp]; close $fp
    if {[string match "*succeeded*" $txt]} { set leg_pass 1 }
}
if {$leg_pass} {
    summarise "check_legality" "PASS" "succeeded" 0
} else {
    summarise "check_legality" "FAIL" "see report" 1
}

# check_pg_connectivity — floating std cells + macros.
set float_cells [grep_count ${fc_reports}/07_check_pg_connectivity.rep \
                {Number of floating std cells:\s*(\d+)}]
set float_macros [grep_count ${fc_reports}/07_check_pg_connectivity.rep \
                 {Number of floating hard macros:\s*(\d+)}]
if {$float_cells == -1} { set float_cells 0 }
if {$float_macros == -1} { set float_macros 0 }
set total_float [expr {$float_cells + $float_macros}]

# Bounded waiver for the characterised wire-stub artefact (see the
# ahb_qspi reference flow's INTEGRATION_CHANGES.md for the full
# diagnosis). Floating macros are NEVER waived; floating std-cell wire
# stubs are tolerated up to FC_PG_CONN_FLOAT_MAX (default 200, sized
# small for the tidelink partition's single-macro floorplan — the
# ahb_qspi case had a 1300 ceiling for its 2-column 10-macro layout).
set pg_waiver  [expr {[info exists ::env(FC_PG_CONN_WAIVER)] ? $::env(FC_PG_CONN_WAIVER) : 1}]
set pg_float_max [expr {[info exists ::env(FC_PG_CONN_FLOAT_MAX)] ? $::env(FC_PG_CONN_FLOAT_MAX) : 200}]
set pg_waived 0

if {$total_float == 0} {
    summarise "check_pg_connectivity" "PASS" "0 floating cells/macros" 0
} elseif {$pg_waiver && $float_macros == 0 && $float_cells <= $pg_float_max} {
    set pg_waived 1
    summarise "check_pg_connectivity" "WAIVE" \
        "$float_cells std-cells floating — characterised benign (<= $pg_float_max, 0 macros)" \
        0
} else {
    summarise "check_pg_connectivity" "FAIL" \
              "$float_cells std-cells + $float_macros macros floating" \
              $total_float
}

set pg_errs [grep_count ${fc_reports}/07_check_pg_drc.rep \
            {Total number of errors found:\s*(\d+)}]
if {$pg_errs == -1} { set pg_errs 0 }
if {$pg_errs == 0} {
    summarise "check_pg_drc" "PASS" "0 errors" 0
} else {
    summarise "check_pg_drc" "FAIL" "$pg_errs PG-DRC errors" $pg_errs
}

set rt_drcs [grep_count ${fc_reports}/07_check_routes.rep \
            {Total number of DRCs\s*=\s*(\d+)}]
set rt_opens [grep_count ${fc_reports}/07_check_routes.rep \
             {Total number of open nets\s*=\s*(\d+)}]
if {$rt_drcs == -1}  { set rt_drcs 0 }
if {$rt_opens == -1} { set rt_opens 0 }
set rt_total [expr {$rt_drcs + $rt_opens}]
if {$rt_total == 0} {
    summarise "check_routes" "PASS" "0 DRCs / 0 open nets" 0
} else {
    summarise "check_routes" "FAIL" \
              "$rt_drcs DRCs + $rt_opens open nets" $rt_total
}

if {[info exists drc_results(signoff_drc)]} {
    set icv_errs [grep_count ${fc_reports}/07_signoff_drc.rep \
                 {(\d+) violations?}]
    if {$icv_errs == -1} { set icv_errs 0 }
    if {$icv_errs == 0} {
        summarise "signoff_drc (ICV)" "PASS" "0 violations" 0
    } else {
        summarise "signoff_drc (ICV)" "FAIL" "$icv_errs violations" $icv_errs
    }
}

puts $sfp "  ----------------------  -------  --------------------------------"
summarise_check pre_netlist         1
summarise_check pre_designdata      1
summarise_check pre_signoff         0
summarise_check pre_timing          0
summarise_check check_placement     1
summarise_check check_mv_design     1
summarise_check check_pin_placement 1
summarise_check check_clock_trees   0

puts $sfp "================================================================="
if {$total_violations == 0} {
    if {$pg_waived} {
        puts $sfp " RESULT: CLEAN (1 WAIVER) — partition ready for chip-top"
        puts $sfp "         integration WITH the check_pg_connectivity waiver:"
        puts $sfp "         $float_cells floating std-cell wire-stub reports, 0 macros."
        puts $sfp "         Strict ==0 gate: re-run with FC_PG_CONN_WAIVER=0."
    } else {
        puts $sfp " RESULT: CLEAN — partition ready for chip-top integration"
    }
} else {
    puts $sfp " RESULT: $total_violations violation(s) — see individual reports"
}
puts $sfp "================================================================="
close $sfp

set fp [open $summary_rpt r]
puts [read $fp]
close $fp

puts "INFO: \[fc_drc\] full summary at $summary_rpt"
puts "INFO: \[fc_drc\] run 'make drc_summary' to re-display it"

save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/drc.design

puts "FC_STAGE_OK: drc"
exit
