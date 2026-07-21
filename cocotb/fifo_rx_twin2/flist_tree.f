// TWIN 2 bench — 'tree' config (the DEFAULT, and the one the gate runs).
//
// Sources the REAL, SHARED RX-FIFO RTL out of src/rtl/fifo. Since the TWIN 2 fix
// landed (2026-07-19, docs/proposals/twin2_fix.patch), that shared RTL CARRIES
// the ENABLE_AHB_WRITE guard, so tb_top's ENABLE_AHB_WRITE(0) is honoured -> the
// AHB write path into the RX FIFO is a NO-OP -> a genuine FC-committed packet is
// never corrupted -> this config PASSES.
//
// This config used to be called 'patched' and pointed at local *.PATCHED.sv
// copies, because the fix was an unapplied proposal. Those copies are GONE: the
// gate must test what actually ships, not a private copy of it. Anything that
// re-introduces a local copy on this path re-creates exactly the blindness this
// bench exists to prevent.
//
// The negative control lives in flist_unfixed.f (frozen pre-fix copies).
+incdir+${TIDELINK_HOME}/src/rtl
+incdir+${TIDELINK_HOME}/src/rtl/fifo
${CMSDK_DIR}/logical/cmsdk_ahb_to_sram/verilog/cmsdk_ahb_to_sram.v
${CMSDK_FPGA_SRAM_V}
${TIDELINK_HOME}/src/rtl/fifo/fpga/tidelink_sram.sv
${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_ctrl.sv
${TIDELINK_HOME}/src/rtl/fifo/tidelink_fifo_mem.sv
