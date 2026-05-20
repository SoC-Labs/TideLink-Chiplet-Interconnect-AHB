#-----------------------------------------------------------------------------
# Common pre-elaborate setup — sourced at the start of every stage script,
# right after the design library is opened. ONLY global-scoped options go
# here; design-scoped app_options must wait until after elaborate (where a
# current block exists), and live in scripts/setup_design_options.tcl.
#-----------------------------------------------------------------------------

set_host_options -max_cores 8 -num_processes 8

# ── Power-domain nets (single-domain partition; chip-top adds VDDIO/VDDACC)
set PG_NETS    [list VDD VSS]
set CORE_VOLTAGE 1.08

#-----------------------------------------------------------------------------
# ── Chisel/Wav → TSMC sc12 ICG availability assertion ────────────────────
# (Gap A from docs/ASIC_HARD_IP_INVENTORY.md §4.2)
#
# The Wlink chiplet controller's Chisel-generated `WavClockGate` +
# `wav_latch_model` cells are not mapped at RTL — they rely on FC's
# clock-gating inference to land on the sc12 `PREICG_X*B_A12TR` ICG
# family (20 cells, sc12_base_rvt r0p0). If those cells are absent
# from the linked library — wrong .db, foreign rvt cut, accidental
# dont_use earlier in the script chain — compile_fusion silently
# emits enable-fanout flops with no clock gate (huge dynamic-power
# regression that survives DRC, LEC, and timing checks). This
# assertion makes that mode FAIL LOUDLY instead of leaking silently.
#
# Inverse of the ahb_qspi flow's BAN pattern (its setup.tcl globally
# dont_use's PREICG to avoid an LEC residual). Tidelink builds
# production WITH gating enabled; the FC_CLOCK_GATING=off knob in
# setup_design_options.tcl is the supported off-switch (it dont_use's
# them AFTER this assertion, by design).
#-----------------------------------------------------------------------------
set _icg_cells [get_lib_cells -quiet */PREICG_*_A12TR]
if {[sizeof_collection $_icg_cells] == 0} {
    puts "ERROR: \[setup\] no PREICG_*_A12TR lib_cells visible — Wav clock-gate"
    puts "ERROR: \[setup\]   substitution path is broken. Likely causes:"
    puts "ERROR: \[setup\]     * wrong TARGET_LIB / DB_SS / DB_FF in common.mk"
    puts "ERROR: \[setup\]     * sc12_base_rvt cut missing PREICG family"
    puts "ERROR: \[setup\]     * fusion_lib was built without sc12 Liberty"
    error "PREICG library check failed"
}
puts "INFO: \[setup\] [sizeof_collection $_icg_cells] PREICG_*_A12TR lib_cells visible"
# The clock-gating bitwidth threshold is design-scoped, applied
# post-elaborate in setup_design_options.tcl.
