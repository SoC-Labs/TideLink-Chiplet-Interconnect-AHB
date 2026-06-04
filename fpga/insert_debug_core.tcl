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

# Tell the auto-inserted dbg_hub the TRUE clock frequency. The default that
# Vivado picks for create_debug_core is 300 MHz; if our hclk (clk_wiz_0/
# clk_out1) is actually 25 MHz, the 12x mismatch corrupts dbg_hub's
# BSCAN frame counter at waveform readback time:
#     ERROR: [Xicom 50-38] No trigger mark in any sample in window: 0
#     ERROR: [Xicom 50-41] Waveform data ... is corrupted
# and the subsequent wait_on_hw_ila hangs (observed in b22 build). The
# clk_wiz CLKOUT1_REQUESTED_OUT_FREQ is the source of truth — for the
# pynq-z2-pair-flip-all target it is 25 MHz. The pynq-z2-loopback target
# is 50 MHz. We probe the actual generated clock period so the value is
# always right regardless of target.
set ila_clk_freq_hz 25000000
if {[catch {
    set clk_obj [get_clocks -quiet -of_objects $ila_clk]
    if {[llength $clk_obj] > 0} {
        set period_ns [get_property PERIOD [lindex $clk_obj 0]]
        # PERIOD is in ns; convert to Hz, round to nearest integer
        set ila_clk_freq_hz [expr {int(round(1.0e9 / $period_ns))}]
    }
} probe_err]} {
    puts "INSTRUMENT: WARN — could not auto-detect clk freq ($probe_err); defaulting to ${ila_clk_freq_hz} Hz"
}
puts "INSTRUMENT: setting C_CLK_INPUT_FREQ_HZ = $ila_clk_freq_hz on u_dbg_int"
# C_CLK_INPUT_FREQ_HZ on the ILA propagates to the dbg_hub that Vivado
# auto-instantiates during implement_debug_core.
catch { set_property C_CLK_INPUT_FREQ_HZ $ila_clk_freq_hz [get_debug_cores u_dbg_int] }
# Also belt-and-braces: if an existing dbg_hub is already present in the
# netlist, override its property directly.
if {[llength [get_debug_cores -quiet dbg_hub]] > 0} {
    catch { set_property C_CLK_INPUT_FREQ_HZ $ila_clk_freq_hz [get_debug_cores dbg_hub] }
}

# Guard against Chipscope 16-213 ("debug port probeN has K unconnected
# channels"). implement_debug_core connects the probe pins to the marked
# nets while open_run synth_1 is loaded, but impl_1 runs opt_design AFTER
# that — and opt_design's constant-propagation / sweep can collapse a marked
# net (replace its bits with <const0>/GND), which disconnects the ILA probe
# input pins and hard-fails opt_design. This first bit us on 2026-06-03 after
# the tidelink_lane_deskew rewire in WavD2DGpio.v reshuffled the LL_RX data
# path: the FC-word nets (tl_fc_a2l_data / tl_fc_l2a_data, 48b = FC_DATA_W)
# became constant-foldable on the training-mode path, so a 48-bit probe ended
# up with all 48 channels unconnected. Pinning every probed net DONT_TOUCH
# forbids opt_design from optimizing it away, so the probe stays connected.
# (DONT_TOUCH is the Xilinx-recommended guard for exactly this Chipscope class.)
# Pin only the nets we actually intend to probe (the grouped set), not the raw
# marked list — keeps the guard scoped to the probe pins we are about to wire.
set pinned 0
foreach base [array names probe_groups] {
    foreach net $probe_groups($base) {
        if { ![catch { set_property DONT_TOUCH true $net }] } { incr pinned }
    }
}
puts "INSTRUMENT: pinned $pinned probed nets DONT_TOUCH (opt_design strip guard)"

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
    # Belt-and-braces: never build a probe whose net has no source at all. A
    # truly source-less net here would survive into impl as unconnected
    # channels (Chipscope 16-213) and hard-fail opt_design, so skip the whole
    # group with a loud warning instead. Conservative on purpose: we only skip
    # when the net has NEITHER a driver pin NOR any connected pin/port (i.e.
    # it is genuinely dangling). Any net with real connectivity is kept so no
    # probe intent is lost — the DONT_TOUCH pin above is the primary guard;
    # this is only a fallback for nets that vanished entirely.
    set driverless 0
    foreach n $sorted_nets {
        set drv  [get_pins  -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]
        set port [get_ports -quiet            -of_objects $n]
        set anypin [get_pins -quiet -of_objects $n]
        if { [llength $drv] == 0 && [llength $port] == 0 && [llength $anypin] == 0 } {
            set driverless 1
            break
        }
    }
    if { $driverless } {
        puts "INSTRUMENT: WARN — skipping probe group '$base' (width $width): a net in this group is dangling (no driver/pin/port) — would cause Chipscope 16-213 unconnected channels"
        continue
    }
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
