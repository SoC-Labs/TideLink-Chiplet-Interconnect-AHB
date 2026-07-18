// TWIN 2 bench — UNFIXED config: sources the SHARED (current) RX-FIFO RTL.
// The tb instantiates fifo_mem with ENABLE_AHB_WRITE(0), which does NOT exist
// on this RTL -> VCS warns and ignores it -> AHB writes stay enabled -> the
// TWIN 2 defect reproduces and the gate test FAILS. This proves the test has
// teeth against the real, current, unguarded RTL.
+incdir+${TIDELINK_HOME}/src/rtl
+incdir+${TIDELINK_HOME}/src/rtl/fifo
${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
${CMSDK_FPGA_SRAM_V}
${TIDELINK_HOME}/src/rtl/fifo/fpga/tidelink_sram.sv
${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_ctrl.sv
${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_mem.sv
