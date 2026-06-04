# =============================================================================
# strip_mark_debug.tcl — opt_design TCL.PRE hook for NO-ILA builds.
#
# Runs inside impl_1, after the synth checkpoint is loaded, immediately before
# opt_design. Clears MARK_DEBUG from every net so Vivado's automatic debug
# processing does not run.
#
# Why: the RTL carries (* mark_debug = "true" *) attrs (used by the dedicated
# ILA targets via insert_debug_core.tcl when FPGA_INSERT_DEBUG_CORE=1). On a
# NO-ILA target these attrs survive into the synth DCP, and opt_design then
# auto-processes them. When a marked net is constant-foldable (e.g. after the
# 2026-06-03 cross-lane deskew rewire folded an FC-word path), opt_design
# strips it and aborts with Chipscope 16-213 ("probeN has K unconnected
# channels") -> impl_1 fails. Removing MARK_DEBUG before opt_design avoids the
# auto-debug entirely. Scoped to no-ILA builds only (set as a hook from
# build_design.tcl's else-branch), so ILA targets are unaffected.
# =============================================================================
set _md_nets [get_nets -quiet -hierarchical -filter {MARK_DEBUG}]
if { [llength $_md_nets] > 0 } {
    set_property MARK_DEBUG false $_md_nets
    puts "STRIP_MARK_DEBUG: cleared MARK_DEBUG on [llength $_md_nets] net(s) (no-ILA build; pre-opt_design)"
} else {
    puts "STRIP_MARK_DEBUG: no MARK_DEBUG nets found"
}
