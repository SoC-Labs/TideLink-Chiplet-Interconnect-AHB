# VC Formal X-propagation script for tidelink (top-level)
# Verifies that no X-state can propagate to any external output
# (AHB slave, AHB master, APB slave, IRQs) from valid reset.
#
# Full hierarchy including all submodules and CMSDK IP.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]
set CMSDK_DIR     $::env(CMSDK_DIR)

analyze -format verilog \
    ${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v \
    ${CMSDK_DIR}/logical/models/memories/cmsdk_fpga_sram.v

analyze -format sverilog \
    ${TIDELINK_HOME}/src/rtl/fifo/fpga/tidelink_sram.sv \
    ${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_ctrl.sv \
    ${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_mem.sv \
    ${TIDELINK_HOME}/src/rtl/fifo/tidelink_returner.sv \
    ${TIDELINK_HOME}/src/rtl/fifo/tidelink_apb_regs.sv \
    ${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_fifo \
    -parameter SYS_ADDR_W 32 \
    -parameter SYS_DATA_W 32 \
    -parameter RAM_ADDR_W 14 \
    -parameter RAM_DATA_W 32 \
    -parameter APB_ADDR_W 12

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Assume AHB slave inputs are well-formed
assume -name ahbs_htrans_valid {ahbs_htrans inside {2'b00, 2'b10}}
assume -name ahbs_hsel_valid   {ahbs_hsel   !== 1'bx}
assume -name ahbs_hready_valid {ahbs_hready !== 1'bx}

# Assume AHB master slave-side responses are valid
assume -name ahbm_hready_valid {ahbm_hready !== 1'bx}
assume -name ahbm_hresp_valid  {ahbm_hresp  !== 1'bx}

# Assume APB inputs are valid
assume -name apbs_psel_valid    {apbs_psel    !== 1'bx}
assume -name apbs_penable_valid {apbs_penable !== 1'bx}
assume -name apbs_pwrite_valid  {apbs_pwrite  !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 900

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
