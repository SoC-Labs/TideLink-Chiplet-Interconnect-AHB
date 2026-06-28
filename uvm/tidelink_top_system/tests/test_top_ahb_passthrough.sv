///////////////////////////////////////////////////////////////////////////////
// test_top_ahb_passthrough.sv — AHB regular access path via XHB500 + Wlink
///////////////////////////////////////////////////////////////////////////////
// Exercises the ahb_sub -> XHB500 AHB→AXI -> Wlink AXI FC -> PHY ->
// remote Wlink AXI FC -> XHB500 AXI→AHB -> ahb_mng path.
//
// END-TO-END ROUND-TRIP VALUE CHECK
// ---------------------------------
// The remote ahb_mng port (the far side of the transparent AHB bridge) is an
// ACTIVE SVT AHB slave VIP backed by built-in memory. So a write issued on
// side A's ahb_sub lands in side B's ahb_mng slave memory, and a subsequent
// read of the SAME remote address returns the value that crossed the link —
// the full round trip A.ahb_sub → A.XHB500 (AHB→AXI) → A.Wlink AXI FC → PHY →
// B.Wlink AXI FC → B.XHB500 (AXI→AHB) → B.ahb_mng slave memory, and back.
//
// Previously this test wrote one address and read a DIFFERENT one and asserted
// NOTHING on the returned data, so a remote read/write was never actually
// verified. This version writes known patterns and ASSERTS byte-exact readback
// through the peer's XHB500, proving the bridge channel delivers data both
// ways.
//
// Requires full system init (Wlink link up + TideLink/AXI FC active).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AHB_PASSTHROUGH_SV
`define GUARD_TEST_TOP_AHB_PASSTHROUGH_SV

class test_top_ahb_passthrough extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_ahb_passthrough)

  // Round-trip scoreboarding (local to this test).
  int unsigned rt_pass_count;
  int unsigned rt_fail_count;

  function new(string name = "test_top_ahb_passthrough", uvm_component parent = null);
    super.new(name, parent);
    // The remote AHB bridge path is slow (GPIO PHY + AXI FC credit exchange in
    // both directions for every beat). Give the watchdog generous headroom so a
    // legitimately-slow-but-correct round trip is not killed as a timeout.
    test_timeout_cycles = 10_000_000;
  endfunction

  // ---------------------------------------------------------------
  // Helper: write a known value to a remote address via A's ahb_sub,
  // then read the SAME remote address back and assert byte-exact.
  // The remote address lands in B's ahb_mng slave-VIP memory.
  // ---------------------------------------------------------------
  task automatic remote_write_read_check(bit [31:0] addr, bit [31:0] data);
    top_sys_ahb_sub_write_sequence wr_seq;
    top_sys_ahb_sub_read_sequence  rd_seq;
    bit [31:0] got;

    // --- Write across the link ---
    `uvm_info("TEST", $sformatf(
      "A.ahb_sub WRITE  addr=0x%08h data=0x%08h (-> peer ahb_mng)", addr, data),
      UVM_LOW)
    wr_seq = top_sys_ahb_sub_write_sequence::type_id::create("rt_wr");
    wr_seq.addr = addr;
    wr_seq.data = data;
    wr_seq.start(env.a_sub_ahb_sys_env.master[0].sequencer);

    // Let the write fully cross the link (both AXI FC directions) and settle in
    // the peer's ahb_mng slave memory before the read chases it.
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    // --- Read the same address back across the link ---
    rd_seq = top_sys_ahb_sub_read_sequence::type_id::create("rt_rd");
    rd_seq.addr = addr;
    rd_seq.start(env.a_sub_ahb_sys_env.master[0].sequencer);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    got = rd_seq.rdata;

    // --- Byte-exact assertion ---
    if (got === data) begin
      rt_pass_count++;
      `uvm_info("TEST", $sformatf(
        "ROUND-TRIP PASS addr=0x%08h wrote=0x%08h read=0x%08h", addr, data, got),
        UVM_LOW)
    end else begin
      rt_fail_count++;
      `uvm_error("TEST", $sformatf(
        "ROUND-TRIP FAIL addr=0x%08h wrote=0x%08h read=0x%08h (mismatch)",
        addr, data, got))
    end
  endtask

  virtual task main_phase(uvm_phase phase);
    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top AHB Passthrough A->B round-trip ===", UVM_LOW)

    // Full system init needed — Wlink AXI FC must be active
    init_system();

    // A handful of distinct address/data pairs across the transparent bridge.
    // Addresses are in A's ahb_sub aperture; they pass through the identity
    // address translator and land in B's ahb_mng slave-VIP memory.
    remote_write_read_check(32'h0000_1000, 32'hCAFE_F00D);
    remote_write_read_check(32'h0000_2000, 32'hDEAD_BEEF);
    remote_write_read_check(32'h0000_3004, 32'h1234_5678);
    remote_write_read_check(32'h0000_4008, 32'hA5A5_5A5A);

    repeat (20) @(posedge tb_if.clk);

    // --- Verdict ---
    if (rt_pass_count == 0)
      `uvm_error("TEST", "No round-trip checks passed — bridge channel did not deliver any data")
    if (rt_fail_count != 0)
      `uvm_error("TEST", $sformatf("%0d round-trip mismatches", rt_fail_count))

    `uvm_info("TEST", $sformatf(
      "AHB passthrough round-trip summary: %0d passed, %0d failed",
      rt_pass_count, rt_fail_count), UVM_LOW)

    phase.drop_objection(this);
  endtask

endclass

`endif
