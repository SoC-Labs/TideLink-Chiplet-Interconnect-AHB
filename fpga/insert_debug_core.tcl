###-----------------------------------------------------------------------------
### TideLink ILA Debug Core Insertion (post-synth, pre-impl)
###
### Sourced from build_design.tcl after launch_runs synth_1. Opens the synth
### design, gathers all nets marked (* mark_debug = "true" *), groups them by
### base register name, creates an ILA debug core with one probe per register
### (multi-bit registers map to one wide probe), and runs implement_debug_core.
###-----------------------------------------------------------------------------

if { [llength [get_runs synth_1]] == 0 } {
    puts "INSTRUMENT: synth_1 run not found, skipping"
    return
}

set synth_status [get_property STATUS [get_runs synth_1]]
if { ![string match "*Complete*" $synth_status] } {
    puts "INSTRUMENT: synth_1 not complete (status=$synth_status), skipping"
    return
}

open_run synth_1 -name synth_1

# Find nets marked for debug
set debug_nets [get_nets -hierarchical -filter {MARK_DEBUG == 1 && TYPE == SIGNAL}]
puts "INSTRUMENT: found [llength $debug_nets] marked debug nets"

if { [llength $debug_nets] == 0 } {
    puts "INSTRUMENT: no marked nets, skipping"
    return
}

# Group nets by base name (strip [N] suffix). Each base becomes one probe.
# Store net objects (not names) so we don't have to re-lookup with get_nets
# later — bracketed names like foo[0] would otherwise trip Tcl command
# substitution when interpolated.
array set probe_groups {}
array set probe_group_names {}
foreach net $debug_nets {
    set net_name [get_property NAME $net]
    # Skip pad_rx_1 (already probed by existing ila_rx in pair-all)
    if {[regexp {pad_rx_1} $net_name]} {
        continue
    }
    # Extract base name without [N] suffix
    set base $net_name
    regsub {\[\d+\]$} $base {} base
    lappend probe_groups($base) $net
    lappend probe_group_names($base) $net_name
}

# Identify the clock net to attach the ILA to.
# Exclude u_dbg_int* / u_ila_int* / dbg_hub* — these are debug-core internal
# scopes (existing ila_rx_0 IP uses u_ila_int) and not connectable from outside.
set clk_candidates [get_nets -hierarchical -filter {(NAME =~ "*clk_wiz_0*clk_out1*" || NAME =~ "*clk_wiz_0_clk_out1*") && NAME !~ "*u_ila_int*" && NAME !~ "*u_dbg_int*" && NAME !~ "*dbg_hub*"}]
puts "INSTRUMENT: clock candidates ([llength $clk_candidates]):"
foreach c $clk_candidates {
    puts "INSTRUMENT:   - [get_property NAME $c]"
}
if { [llength $clk_candidates] == 0 } {
    puts "INSTRUMENT: no candidate clock net found - skipping"
    return
}
# Prefer the BD-level top-port net (exactly one `/` in name — e.g.
# tidelink_design_i/clk_wiz_0_clk_out1). Falls back to first candidate.
set ila_clk [lindex $clk_candidates 0]
set ila_clk_name [get_property NAME $ila_clk]
foreach c $clk_candidates {
    set n [get_property NAME $c]
    set num_slashes [llength [split $n "/"]]
    set cur_slashes [llength [split $ila_clk_name "/"]]
    if { $num_slashes < $cur_slashes } {
        set ila_clk $c
        set ila_clk_name $n
    }
}
puts "INSTRUMENT: using clock net $ila_clk_name"

# Drop any stale u_dbg_int left in the synth_1 DCP from a prior failed
# attempt (write_checkpoint may have persisted it before impl failed).
if { [llength [get_debug_cores -quiet u_dbg_int]] > 0 } {
    puts "INSTRUMENT: deleting stale u_dbg_int from prior run"
    delete_debug_core [get_debug_cores u_dbg_int]
}

# Create the ILA core
create_debug_core u_dbg_int ila
set_property C_DATA_DEPTH         4096 [get_debug_cores u_dbg_int]
set_property C_TRIGIN_EN          false [get_debug_cores u_dbg_int]
set_property C_TRIGOUT_EN         false [get_debug_cores u_dbg_int]
set_property C_ADV_TRIGGER        false [get_debug_cores u_dbg_int]
set_property C_INPUT_PIPE_STAGES  1 [get_debug_cores u_dbg_int]
set_property port_width 1 [get_debug_ports u_dbg_int/clk]
connect_debug_port u_dbg_int/clk [list $ila_clk]

# Iterate probe groups, creating one probe per base
set probe_idx 0
foreach base [array names probe_groups] {
    # Sort by name so bit[0] comes first, bit[N] last. We sort the parallel
    # name list and apply the resulting permutation to the net-object list.
    set names $probe_group_names($base)
    set nets  $probe_groups($base)
    set order [lsort -dictionary -indices $names]
    set sorted_nets [list]
    foreach i $order { lappend sorted_nets [lindex $nets $i] }
    set width [llength $sorted_nets]
    if { $probe_idx > 0 } {
        create_debug_port u_dbg_int probe
    }
    set_property port_width $width [get_debug_ports u_dbg_int/probe$probe_idx]
    set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe$probe_idx]
    connect_debug_port u_dbg_int/probe$probe_idx $sorted_nets
    puts "INSTRUMENT: probe$probe_idx = $base (width $width)"
    incr probe_idx
}

puts "INSTRUMENT: implementing debug core with $probe_idx probes..."
# Save the design (with the new debug core nets) before implement_debug_core,
# which requires a saved-design state.
if {[catch {save_constraints -force} err]} {
    puts "INSTRUMENT: save_constraints failed: $err"
}
# Vivado also wants a checkpoint written before implement_debug_core. Write
# to synth_1's existing checkpoint location so impl_1 picks it up.
set synth_dcp [glob -nocomplain $project_dir/tidelink_project.runs/synth_1/*_wrapper.dcp]
if { [llength $synth_dcp] > 0 } {
    set target_dcp [lindex $synth_dcp 0]
    write_checkpoint -force $target_dcp
    puts "INSTRUMENT: wrote pre-implement checkpoint to $target_dcp"
}

if {[catch {implement_debug_core} err]} {
    puts "INSTRUMENT: implement_debug_core FAILED: $err"
    puts "INSTRUMENT: continuing build without debug core"
    return
}
puts "INSTRUMENT: debug core successfully implemented"

# Save back to synth_1's checkpoint after debug-core implementation so impl_1 picks it up
set synth_dcp_post [glob -nocomplain $project_dir/tidelink_project.runs/synth_1/*_wrapper.dcp]
if { [llength $synth_dcp_post] > 0 } {
    set target_dcp_post [lindex $synth_dcp_post 0]
    write_checkpoint -force $target_dcp_post
    puts "INSTRUMENT: wrote post-implement checkpoint to $target_dcp_post"
} else {
    puts "INSTRUMENT: WARNING - couldn't find synth_1 checkpoint to overwrite"
}

# Also write the .ltx probes file for HW Manager
set ltx_path $output_dir
file mkdir $ltx_path
write_debug_probes -force [file join $ltx_path tidelink_design_wrapper.ltx]
puts "INSTRUMENT: wrote probes file"
