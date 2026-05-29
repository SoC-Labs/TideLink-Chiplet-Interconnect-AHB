# VC Formal X-propagation script for tl_addr_trans_cam
# Pure-combinational priority-encoded address remapper. Verifies that no
# X-state can propagate to addr_o under valid (non-X) input addresses
# and a well-formed rule table.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tl_addr_trans_cam.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tl_addr_trans_cam \
    -parameter NUM_RULES 8

# ── No clock/reset ──────────────────────────────────────────────────────────
# Module is purely combinational — VC Formal still runs xprop using the
# default tick; no clock/reset declarations are needed.

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Driver of addr_i / base_offset / rule table is the APB regfile —
# all bits must resolve to defined values for the CAM result to be defined.
assume -name addr_i_valid        {(^addr_i)         !== 1'bx}
assume -name base_offset_valid   {(^base_offset)    !== 1'bx}
assume -name global_enable_valid {global_enable     !== 1'bx}
assume -name rule_enable_valid   {(^rule_enable)    !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
