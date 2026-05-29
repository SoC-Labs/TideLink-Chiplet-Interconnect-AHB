# VC Formal X-propagation script for tidelink_phc_cdc
# Verifies that no X-state can propagate to either-domain outputs from a
# valid reset under normal operation. Two-clock module (hclk + phc_clk)
# with independent active-low resets; both are modelled explicitly.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_phc_cdc.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_phc_cdc \
    -parameter SYS_DATA_W  32 \
    -parameter SYNC_STAGES 2 \
    -parameter BYPASS_CDC  0

# ── Clocks and resets (dual-domain) ─────────────────────────────────────────
clock hclk
clock phc_clk
reset -expression {!hresetn || !phc_resetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Assume DFT scan_mode is held to a defined value during functional operation
assume -name scan_mode_valid {scan_mode !== 1'bx}

# hclk-domain controls — protocol owners drive defined values
assume -name h_hw_capture_valid    {h_hw_capture    !== 1'bx}
assume -name h_hw_set_time_valid   {h_hw_set_time   !== 1'bx}
assume -name h_hw_adj_valid_valid  {h_hw_adj_valid  !== 1'bx}

# phc-domain inputs come from the external PHC and must be valid
# (reduction XOR returns x if any bit is x, otherwise 0/1).
assume -name p_hw_cap_seconds_valid    {(^p_hw_cap_seconds)         !== 1'bx}
assume -name p_hw_cap_ns_valid         {(^p_hw_cap_nanoseconds)     !== 1'bx}
assume -name p_hw_cap_sub_ns_valid     {(^p_hw_cap_sub_nanoseconds) !== 1'bx}
assume -name p_phc_seconds_valid       {(^p_phc_seconds)            !== 1'bx}
assume -name p_phc_ns_valid            {(^p_phc_nanoseconds)        !== 1'bx}
assume -name p_phc_pps_valid           {p_phc_pps                   !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 600

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
