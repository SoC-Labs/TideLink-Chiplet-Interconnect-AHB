# VC Formal X-propagation script for tidelink_fifo
# Verifies that no X-state can propagate to AHB outputs or sideband
# signals from valid reset through normal operation.
#
# This module depends on cmsdk_ahb_to_sram and tidelink_sram (FPGA variant).

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]
set CMSDK_DIR     $::env(CMSDK_DIR)

analyze -format verilog \
    ${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v \
    ${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v

analyze -format sverilog \
    ${TIDELINK_HOME}/src/rtl/fpga/tidelink_sram.sv \
    ${TIDELINK_HOME}/src/rtl/tidelink_fifo_ctrl.sv \
    ${TIDELINK_HOME}/src/rtl/tidelink_fifo.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_fifo \
    -parameter SYS_DATA_W 32 \
    -parameter RAM_ADDR_W 14 \
    -parameter RAM_DATA_W 32

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Assume AHB inputs are well-formed after reset
assume -name ahb_htrans_valid {htrans inside {2'b00, 2'b10}}
assume -name ahb_hsel_valid   {hsel   !== 1'bx}
assume -name ahb_hready_valid {hready !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 600

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
