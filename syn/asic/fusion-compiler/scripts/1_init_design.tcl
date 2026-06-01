#-----------------------------------------------------------------------------
# Phase 1: init_design — create design library, analyze RTL, elaborate,
#                        MCMM, parasitic, clocks, floorplan, pre-compile check.
#
# Run with: fc_shell -f 1_init_design.tcl
#
# Environment variables (exported by Makefile + common.mk):
#   MODULE, TOP, FLIST                - design ID + filelist
#   TIDELINK_HOME                     - repo root
#   FC_DIR, SHARED_SCRIPTS,
#   FC_LIBS, FC_LOGS, FC_REPORTS      - flow paths
#   TF_FILE                           - Milkyway technology file
#   FUSION_LIB                        - NDM ref-lib (stdcell_lib)
#   CLK_NAME, CLK_PERIOD, …           - top-level clock constraints
#   FC_ASPECT_RATIO,                  - partition floorplan target
#   FC_CORE_UTILIZATION,
#   FC_CORE_OFFSET
#-----------------------------------------------------------------------------

set module_name      $::env(MODULE)
set top_module       $::env(TOP)
set design_lib_name  "${module_name}.dlib"
set fusion_lib       $::env(FUSION_LIB)
set tf_file          $::env(TF_FILE)
set shared_scripts   $::env(SHARED_SCRIPTS)
set fc_dir           $::env(FC_DIR)
set fc_logs          $::env(FC_LOGS)
set fc_reports       $::env(FC_REPORTS)
set fc_outputs       $::env(FC_OUTPUTS)
set aspect_ratio     $::env(FC_ASPECT_RATIO)
set core_util        $::env(FC_CORE_UTILIZATION)
set core_offset      $::env(FC_CORE_OFFSET)

# Named SVF — Formality reads outputs/svf/<top>.<stage>.svf in stage order.
# Without this fc_shell drops a "default-DATE_HOST_PID.svf" in CWD per
# invocation, scattering guidance across dozens of files that fm_shell
# can't decode (FM-339).
file mkdir ${fc_outputs}/svf
set_svf ${fc_outputs}/svf/${top_module}.init.svf

#-----------------------------------------------------------------------------
# Bind Liberty .db files via link_library BEFORE create_lib. fc_shell's
# auto-CLIB process inspects link_library at create_lib time to decide
# whether to embed Liberty in the assembled CLIB. If link_library has no
# .db's at create_lib time, fc_shell falls back to a physical-only CLIB
# (LIB-081 warning) and synthesis can't find AND/OR/INV cells (DWS-0103).
#
# Drop the leading "*" — it confuses fc_shell's auto-CLIB inspection,
# which then emits LIB-081 "No db files from link_library" and falls
# back to building a physical-only EXPLORE CLIB.
#-----------------------------------------------------------------------------
set_app_var link_library [list \
    $::env(DB_SS) $::env(DB_FF) \
    {*}$::env(MEM_DBS_SS) {*}$::env(MEM_DBS_FF)]
puts "INFO: \[fc_init\] link_library = [get_app_var link_library]"

#-----------------------------------------------------------------------------
# Create the design library backed by per-library NDMs:
#   stdcell_lib   (tcbn65lp 9-track std cells, LEF + 3-corner Liberty)
#   mem_frame_lib (rf_16k LEF — frames only; Liberty via link_library
#                  set above)
#-----------------------------------------------------------------------------
set lib_dir [file dirname $fusion_lib]
set ref_libs [list]
foreach lib {stdcell_lib mem_frame_lib} {
    set p ${lib_dir}/${lib}
    if {[file isdirectory $p]} { lappend ref_libs $p }
}
puts "INFO: \[fc_init\] creating $design_lib_name -technology $tf_file"
puts "INFO: \[fc_init\]   ref_libs: $ref_libs"
# create_lib refuses to overwrite an existing dlib (LIB-009). Make may
# trigger a re-run of fc_init when the upstream FUSION_LIB directory is
# touched; nuke the old dlib first so the rebuild works idempotently.
file delete -force $design_lib_name
create_lib $design_lib_name -technology $tf_file -ref_libs $ref_libs

#-----------------------------------------------------------------------------
# Common host options, PG_NETS — needs ref_libs already loaded
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/setup.tcl

#-----------------------------------------------------------------------------
# Read RTL via the shared filelist parser:
#   - parse_flist on $FLIST
#   - analyze + elaborate $top_module
#   - MCMM (scen_slow / scen_fast)
#   - read_parasitic_tech (TLU+)
#   - create_clock + I/O delays for $CLK_NAME
#   - set_scenario_status -setup true *
# After elaborate a current block exists; design-scoped app_options can be
# applied next.
#-----------------------------------------------------------------------------
puts "INFO: \[fc_init\] sourcing shared FC.read_design.tcl"
source ${shared_scripts}/tidelink.FC.read_design.tcl

source ${fc_dir}/scripts/setup_design_options.tcl

#-----------------------------------------------------------------------------
# Optional: overlay partition-specific constraints (multi-clock, CDC)
#-----------------------------------------------------------------------------
set extra_sdc ${fc_dir}/inputs/constraints.sdc
if {[file exists $extra_sdc]} {
    puts "INFO: \[fc_init\] overlaying $extra_sdc"
    foreach scen_name {scen_slow scen_fast} {
        if {[sizeof_collection [get_scenarios -quiet $scen_name]] > 0} {
            current_scenario $scen_name
            read_sdc $extra_sdc
        }
    }
}

#-----------------------------------------------------------------------------
# Gap C (ASIC_TSMC65) — false_path the explicit SDFFRPQ/SDFFSRPQ async
# reset pins. When the substitution is active these flops are
# instantiated as RTL primitives with R / SN as async-reset inputs, but
# the sc12 Liberty doesn't tag the reset arcs with `preset` so
# fc_shell's timer treats them as data inputs and hold-times the
# source-to-reset paths (caused a -4.71 ns scen_fast hold WNS on the
# first attempt). Apply false_path here in full-fc_shell Tcl, where
# get_pins -hier -filter / sizeof_collection are available (SDC mode
# rejects them, see inputs/constraints.sdc note).
foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name
    set _wav_async_pins [get_pins -hier -quiet \
        -filter "lib_pin_name == R || lib_pin_name == SN"]
    if {[sizeof_collection $_wav_async_pins] > 0} {
        set_false_path -to $_wav_async_pins
        puts "INFO: \[fc_init\] $scen_name: [sizeof_collection $_wav_async_pins] Wav R/SN async-reset endpoints false_path'd"
    } else {
        puts "INFO: \[fc_init\] $scen_name: no R/SN pins found (ASIC_TSMC65 not active or pre-elaborate)"
    }
}

# pad_rx[*] -> gpiorx_*/link_data_pad_clk_reg* — bounded datapath delay.
#
# Moved out of constraints.sdc (line 158 in older revisions) because the
# SDC parser rejects `get_cells -hier -filter` syntax with CMD-010
# "unknown option -filter", and when the parse failed it silently stopped
# the rest of constraints.sdc (§3 set_data_check, §4 TX eye, §5 PHC
# output delay) too — producing the -0.59 ns scen_fast hold WNS / 130 NVE
# failure in 9 aspect-2.0 builds. See ASIC_TIMING_CONSTRAINTS Part B §3.2
# for the rationale.
#
# fc_shell U-2022.12 NOTES (probed via `help -verbose set_max_delay`):
#   - The PrimeTime-style `-datapath_only` flag is REJECTED here (CMD-010
#     "unknown option"). The closest fc_shell equivalent is
#     `-ignore_clock_latency`, which excludes clock-tree latency from the
#     bound — same intent as -datapath_only's "no clock skew, no hold
#     component" behaviour.
#   - Falls back to a CRITICAL WARNING if a future Wlink/Chisel regen
#     renames link_data_pad_clk_reg — fail-safe, not a wrong constraint.
foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name
    set _rx_caps [get_cells -hier -quiet \
        -filter "full_name =~ *gpiorx_*/link_data_pad_clk_reg*"]
    if {[sizeof_collection $_rx_caps] > 0} {
        # RX_DATAPATH_MAX_NS = T_UI_NS/5 (see constraints.sdc). T_UI_NS is
        # the user_ref_clk period, defined in the shared FC.read_design.tcl
        # as CLK_PERIOD/CLK_DIV (typically 4.0). Re-derive here so this
        # block does not depend on a Tcl variable set by constraints.sdc.
        set _rx_dp_max 0.8
        set_max_delay -ignore_clock_latency $_rx_dp_max \
            -from [get_ports {pad_rx[*]}] \
            -to   $_rx_caps
        puts [format "INFO: \[fc_init\] %s: set_max_delay -ignore_clock_latency %.2f ns from pad_rx -> %d link_data_pad_clk_reg caps" \
                $scen_name $_rx_dp_max [sizeof_collection $_rx_caps]]
    } else {
        puts "CRITICAL WARNING: \[fc_init\] $scen_name: pad_rx capture flop selector matched 0 cells — set_max_delay skipped"
    }

    # §3 lane-bundle skew (set_data_check) was at constraints.sdc:180-181
    # but fc_shell's set_data_check `-to` takes a SINGLE pin/port — the
    # bus collection `[get_ports {pad_rx[*]}]` returns multiple objects
    # and trips "bad value specified for option -to". Iterate per bit
    # instead. RX_BUS_SKEW_NS = T_UI_NS/20 per constraints.sdc:76, ~0.2 ns
    # at the canonical 4 ns user_ref_clk period. Hard-coded here to keep
    # this block independent of the SDC's Tcl variables (the SDC may abort
    # earlier and never set them).
    set _rx_bus_skew 0.2
    set _rx_pad_clk  [get_ports pad_clk_rx -quiet]
    set _rx_pad_bits [get_ports {pad_rx[*]} -quiet]
    if {[sizeof_collection $_rx_pad_clk] > 0 && [sizeof_collection $_rx_pad_bits] > 0} {
        set _n_skew 0
        foreach_in_collection _p $_rx_pad_bits {
            set_data_check -from $_rx_pad_clk -to $_p -setup $_rx_bus_skew
            set_data_check -from $_rx_pad_clk -to $_p -hold  $_rx_bus_skew
            incr _n_skew
        }
        puts [format "INFO: \[fc_init\] %s: set_data_check (setup+hold) %.2f ns on %d pad_rx bits vs pad_clk_rx" \
                $scen_name $_rx_bus_skew $_n_skew]
    } else {
        puts "CRITICAL WARNING: \[fc_init\] $scen_name: pad_clk_rx or pad_rx[*] not resolved — set_data_check skipped"
    }
}

#-----------------------------------------------------------------------------
# Initialise floorplan — partition target: aspect 1.0, util 0.85
#-----------------------------------------------------------------------------
puts "INFO: \[fc_init\] initialize_floorplan aspect=$aspect_ratio util=$core_util offset=$core_offset"
# fc_shell U-2022.12 initialize_floorplan options:
#   -control_type   core | die  (not "aspect_ratio")
#   -shape          R | L | T | U  (R = rectangle = aspect-1.0 default)
#   -side_ratio     {a b}        — aspect ratio = a/b
#   -core_utilization ratio
initialize_floorplan \
    -control_type core \
    -shape R \
    -side_ratio [list $aspect_ratio 1.0] \
    -core_utilization $core_util \
    -core_offset $core_offset

#-----------------------------------------------------------------------------
# Macro placement — pin the rf_16k FIFO RAM to a die corner.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/place_memories.tcl

#-----------------------------------------------------------------------------
# Port-to-edge assignment — Wlink PHY on TOP, AHB busses on BOTTOM,
# APB + PHC time on LEFT, clocks/resets/DFT on RIGHT.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/place_pins.tcl

#-----------------------------------------------------------------------------
# Power-ground mesh — VDD/VSS supply nets, M1 std-cell rails, M5/M6
# mesh, and macro long-pin straps. Built BEFORE compile_fusion runs
# std-cell placement so the placer dodges the straps.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/pg_mesh.tcl

#-----------------------------------------------------------------------------
# Pre-compile sanity checks
#-----------------------------------------------------------------------------
file mkdir $fc_reports
redirect -tee -file ${fc_logs}/init_check_lib.log {
    report_design
    report_clocks
    report_scenarios
}

redirect -tee -file ${fc_logs}/precompile_checks.log {
    compile_fusion -check_only
}

#-----------------------------------------------------------------------------
# Save block: ${design_lib}/${top}/init.design
#-----------------------------------------------------------------------------
save_block
save_lib $design_lib_name
save_block -as ${design_lib_name}:${top_module}/init.design

puts "FC_STAGE_OK: init"
exit
