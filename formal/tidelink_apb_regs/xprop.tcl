# VC Formal X-propagation script for tidelink_apb_regs
# Verifies that no X-state can propagate to APB outputs, IRQs, or
# returner control outputs from valid reset through normal operation.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_apb_regs.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_apb_regs \
    -parameter SYS_ADDR_W 32 \
    -parameter SYS_DATA_W 32 \
    -parameter RAM_ADDR_W 14 \
    -parameter APB_ADDR_W 12

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Assume APB protocol signals are valid (no X after reset)
assume -name apb_psel_valid    {psel    !== 1'bx}
assume -name apb_penable_valid {penable !== 1'bx}
assume -name apb_pwrite_valid  {pwrite  !== 1'bx}

# Assume FIFO sideband inputs are valid
assume -name read_complete_valid {read_complete !== 1'bx}
assume -name returner_busy_valid {returner_busy !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
