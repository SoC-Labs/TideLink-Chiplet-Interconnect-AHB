// TWIN 2 bench — 'unfixed' config: THE NEGATIVE CONTROL. Expected to FAIL.
//
// Sources FROZEN local copies of the two RX-FIFO files as they stood
// IMMEDIATELY BEFORE the TWIN 2 fix was applied (commit 9c157851, 2026-07-19).
// Those copies have no ENABLE_AHB_WRITE parameter, so tb_top's
// ENABLE_AHB_WRITE(0) is warned-about-and-ignored by VCS, AHB writes stay
// enabled, and the TWIN 2 defect reproduces -> the test FAILS.
//
// That failure is the POINT. It is the standing proof that the test has teeth:
// without it, the PASS on the real tree (flist_tree.f) would be unfalsifiable.
// Run both with `make ab`.
//
// NOTE the polarity flip vs. the pre-2026-07-19 version of this file: back then
// 'unfixed' meant the SHARED RTL (which was buggy) and 'patched' meant local
// copies. Now the shared RTL is FIXED, so the roles are reversed — the local
// copies are the buggy ones.
+incdir+${TIDELINK_HOME}/src/rtl
+incdir+${TIDELINK_HOME}/src/rtl/fifo
${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
${CMSDK_FPGA_SRAM_V}
${TIDELINK_HOME}/src/rtl/fifo/fpga/tidelink_sram.sv
${TIDELINK_HOME}/cocotb/fifo_rx_twin2/tidelink_fifo_ctrl.UNFIXED.sv
${TIDELINK_HOME}/cocotb/fifo_rx_twin2/tidelink_fifo_mem.UNFIXED.sv
