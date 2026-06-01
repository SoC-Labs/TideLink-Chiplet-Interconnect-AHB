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

# After RTL bump to tidelink-gpio-phy @ 32e8d38, lane_checker_single
# decodes a training_mode_rise pulse from training_mode_w_q and fans it
# out to ~8 reset endpoints per instance. Cut the rise-pulse hold mass.
foreach scen_name {scen_slow scen_fast} {
    if {[sizeof_collection [get_scenarios -quiet $scen_name]] == 0} { continue }
    current_scenario $scen_name
    set _tm_q_cells [get_cells -hier -quiet \
        -filter "full_name =~ *u_lane_checker*training_mode_w_q_reg"]
    if {[sizeof_collection $_tm_q_cells] > 0} {
        set_false_path -hold -from $_tm_q_cells
        puts "INFO: \[fc_init\] $scen_name: [sizeof_collection $_tm_q_cells] training_mode_w_q register(s) hold-cut"
    } else {
        puts "WARN: \[fc_init\] $scen_name: no training_mode_w_q register(s) found — fanout hold-cut not applied"
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
# Logic region constraints — hard-anchor the source-sync RX capture flops
# (gpiorx_*/link_data_pad_clk_reg*) to a 9% strip at the LEFT edge so
# pad_clk_rx → capture clock latency fits the input_delay -min budget.
# See place_logic.tcl header for the full diagnosis and the build-#6
# soft-bound experiment that motivated the surgical/hard upgrade.
#-----------------------------------------------------------------------------
source ${fc_dir}/scripts/place_logic.tcl

#-----------------------------------------------------------------------------
# Port-to-edge assignment — see place_pins.tcl header for edge convention.
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
