#-----------------------------------------------------------------------------
# Common pre-elaborate setup — sourced at the start of every stage script,
# right after the design library is opened. ONLY global-scoped options go
# here; design-scoped app_options must wait until after elaborate (where a
# current block exists), and live in scripts/setup_design_options.tcl.
#-----------------------------------------------------------------------------

set_host_options -max_cores 8 -num_processes 8

#-----------------------------------------------------------------------------
# Canonical SoC-Labs tech-path TCL variables — sourced here so every FC
# stage script (and downstream pt_shell / fm_shell scripts that source
# setup.tcl directly) has standard_cell_db_file_*, io_*, RF_16K_*, etc.
# available by their project-wide names. The Make-side mirror in
# common.mk provides the same paths via env vars.
#-----------------------------------------------------------------------------
if {[info exists ::env(SHARED_SCRIPTS)]} {
    set _tech_paths_tcl $::env(SHARED_SCRIPTS)/tech_paths.tcl
    if {[file exists $_tech_paths_tcl]} { source $_tech_paths_tcl }
}

# ── Power-domain nets (single-domain partition; chip-top adds VDDIO/VDDACC)
set PG_NETS    [list VDD VSS]
set CORE_VOLTAGE 1.08

#-----------------------------------------------------------------------------
# ── Chisel/Wav → tcbn65lp ICG availability assertion (Gap A) ─────────────
#
# The Wlink chiplet controller's Chisel-generated `WavClockGate` +
# `wav_latch_model` cells rely on FC's clock-gating inference to land
# on the tcbn65lp 9-track latch-based ICG family `CKLNQD*` (latch
# negative-output Q, drive strengths 1-24). If those cells are absent
# from the linked library — wrong .db, missing fusion_lib, accidental
# dont_use earlier in the script chain — compile_fusion silently
# emits enable-fanout flops with no clock gate (huge dynamic-power
# regression that survives DRC, LEC, and timing checks). This
# assertion makes that mode FAIL LOUDLY instead of leaking silently.
#
# Tidelink builds production WITH gating enabled; the FC_CLOCK_GATING=off
# knob in setup_design_options.tcl is the supported off-switch — it
# applies set_dont_use AFTER this assertion, by design.
#-----------------------------------------------------------------------------
set _icg_cells [get_lib_cells -quiet "*/CKLNQD* */CKLHQD*"]
if {[sizeof_collection $_icg_cells] == 0} {
    puts "ERROR: \[setup\] no CKLNQD*/CKLHQD* lib_cells visible — Wav clock-gate"
    puts "ERROR: \[setup\]   substitution path is broken. Likely causes:"
    puts "ERROR: \[setup\]     * wrong TARGET_LIB / DB_SS / DB_FF in common.mk"
    puts "ERROR: \[setup\]     * tcbn65lp_220a NLDM .db files not at the expected path"
    puts "ERROR: \[setup\]     * fusion_lib was built without tcbn65lp Liberty"
    error "ICG library check failed"
}
puts "INFO: \[setup\] [sizeof_collection $_icg_cells] CKLNQD*/CKLHQD* ICG lib_cells visible"
# The clock-gating bitwidth threshold is design-scoped, applied
# post-elaborate in setup_design_options.tcl.
