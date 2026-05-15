///////////////////////////////////////////////////////////////////////////////
// test_align_uniform_skew.sv — §9 sanity baseline (all lanes skid = 3)
///////////////////////////////////////////////////////////////////////////////
// Mirrors the cocotb test_pair_align.py uniform case but exercises the full
// TideLink stack stimulus on top: after calibration converges and the link
// trains, a 4-word packet round-trips A->B through the TideLink FIFO.
//
// Pass conditions:
//   - All 8 lanes lock on each side after calibration.
//   - init_system() returns cleanly (Wlink trains, doorbells exchanged).
//   - A 4-word packet is written and read back, scoreboard A2B matches.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_ALIGN_UNIFORM_SKEW_SV
`define GUARD_TEST_ALIGN_UNIFORM_SKEW_SV

class test_align_uniform_skew extends test_top_align_base;

  `uvm_component_utils(test_align_uniform_skew)

  function new(string name = "test_align_uniform_skew",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [2:0] uniform_skids[8] = '{3,3,3,3,3,3,3,3};
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_align_uniform_skew (all lanes skid=3) ===", UVM_LOW)

    align_and_init_system(uniform_skids, uniform_skids);

    // Sanity: both sides should be fully locked.
    if (tb_if.a_lane_locked !== 8'hFF)
      `uvm_error("TEST", $sformatf("A.lane_locked=0x%02h, expected 0xFF",
        tb_if.a_lane_locked))
    if (tb_if.b_lane_locked !== 8'hFF)
      `uvm_error("TEST", $sformatf("B.lane_locked=0x%02h, expected 0xFF",
        tb_if.b_lane_locked))

    // Send a packet end-to-end and confirm the link is live.
    pkt_data = new[4];
    pkt_data[0] = 32'hABCD_0001;
    pkt_data[1] = 32'hABCD_0002;
    pkt_data[2] = 32'hABCD_0003;
    pkt_data[3] = 32'hABCD_0004;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 4, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_ALIGN_UNIFORM_SKEW_SV
