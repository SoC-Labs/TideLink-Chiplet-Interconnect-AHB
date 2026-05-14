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
