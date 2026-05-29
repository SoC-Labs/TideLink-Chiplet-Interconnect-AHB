# VC Formal X-propagation script for tidelink_apb_addr_ctrl
# Verifies that no X-state can propagate to seg_addr/base_offset or to
# CTRL_APB.prdata/pready/pslverr from valid reset through normal APB
# operation. APB4 sub-interface is sourced from the chiplet-controller
# deps tree.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog \
    ${TIDELINK_HOME}/deps/axi-chiplet-controller/logical/interfaces/apb4_if.sv \
    ${TIDELINK_HOME}/src/rtl/tidelink_apb_addr_ctrl.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_apb_addr_ctrl \
    -parameter ADDR_W    12 \
    -parameter DATA_W    32 \
    -parameter SEG_IDX_W 8 \
    -parameter NUM_SEGS  256

# ── Clock and reset ─────────────────────────────────────────────────────────
clock PCLK
reset -expression {!PRESETn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# APB4 protocol signals are produced by a compliant requester
assume -name apb_psel_valid    {CTRL_APB.psel    !== 1'bx}
assume -name apb_penable_valid {CTRL_APB.penable !== 1'bx}
assume -name apb_pwrite_valid  {CTRL_APB.pwrite  !== 1'bx}
assume -name apb_pstrb_valid   {(^CTRL_APB.pstrb) !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 600

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
