// TWIN 2 bench — PATCHED config: sources LOCAL patched COPIES of the two RX-FIFO
// files (the shared files are NEVER modified). ENABLE_AHB_WRITE(0) from the tb is
// honoured -> the AHB write path to the RX FIFO is a NO-OP -> a genuine
// FC-committed packet is never corrupted -> the gate test PASSES.
// The proposal diff is docs/proposals/twin2_fix.patch.
+incdir+${TIDELINK_HOME}/src/rtl
+incdir+${TIDELINK_HOME}/src/rtl/fifo
${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
${CMSDK_FPGA_SRAM_V}
${TIDELINK_HOME}/src/rtl/fifo/fpga/tidelink_sram.sv
${TIDELINK_HOME}/cocotb/fifo_rx_twin2/tidelink_fifo_ctrl.PATCHED.sv
${TIDELINK_HOME}/cocotb/fifo_rx_twin2/tidelink_fifo_mem.PATCHED.sv
