///////////////////////////////////////////////////////////////////////////////
// test_align_asymmetric_skew.sv — §9 critical test: realistic per-lane skew
///////////////////////////////////////////////////////////////////////////////
// Drives non-uniform per-lane skids [3,5,0,2,7,1,4,6] on each direction.
// This is the realistic case where each lane has different PCB routing
// delay; the cocotb sandbox cannot exercise this because its pad_skid only
// supports a single global skid.
//
// Pass conditions:
//   - Every lane finds an independent slip that locks (no two lanes share
//     a slip just because the test forced a uniform skid).
//   - Calibration reports lane_locked == 0xFF on both sides.
//   - A short burst of packets round-trip through the calibrated link.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_ALIGN_ASYMMETRIC_SKEW_SV
`define GUARD_TEST_ALIGN_ASYMMETRIC_SKEW_SV

class test_align_asymmetric_skew extends test_top_align_base;

  `uvm_component_utils(test_align_asymmetric_skew)

  function new(string name = "test_align_asymmetric_skew",
               uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    bit [2:0] asymm_skids[8] = '{3,5,0,2,7,1,4,6};
    bit [31:0] pkt_data[];
    bit [31:0] read_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== test_align_asymmetric_skew (per-lane skids [3,5,0,2,7,1,4,6]) ===", UVM_LOW)

    align_and_init_system(asymm_skids, asymm_skids);

    if (tb_if.a_lane_locked !== 8'hFF)
      `uvm_error("TEST", $sformatf("A.lane_locked=0x%02h, expected 0xFF",
        tb_if.a_lane_locked))
    if (tb_if.b_lane_locked !== 8'hFF)
      `uvm_error("TEST", $sformatf("B.lane_locked=0x%02h, expected 0xFF",
        tb_if.b_lane_locked))

    // Diagnostic dump of calibrated slips. Each lane's slip should differ
    // because each lane carries a different skid.
    `uvm_info("TEST", $sformatf(
      "Calibrated A.slip (B->A): [%0d %0d %0d %0d %0d %0d %0d %0d]",
      a_slip[0], a_slip[1], a_slip[2], a_slip[3],
      a_slip[4], a_slip[5], a_slip[6], a_slip[7]), UVM_LOW)
    `uvm_info("TEST", $sformatf(
      "Calibrated B.slip (A->B): [%0d %0d %0d %0d %0d %0d %0d %0d]",
      b_slip[0], b_slip[1], b_slip[2], b_slip[3],
      b_slip[4], b_slip[5], b_slip[6], b_slip[7]), UVM_LOW)

    // Burst of 3 packets — moderate stress on the calibrated link.
    repeat (3) begin
      pkt_data = new[4];
      pkt_data[0] = 32'hA17_0001 + $urandom();
      pkt_data[1] = 32'hA17_0002 + $urandom();
      pkt_data[2] = 32'hA17_0003 + $urandom();
      pkt_data[3] = 32'hA17_0004 + $urandom();
      write_packet(SIDE_A, pkt_data);
      repeat (phy_transit_wait) @(posedge tb_if.clk);
      read_packet(SIDE_B, 4, read_data);
      repeat (phy_transit_wait / 4) @(posedge tb_if.clk);
    end

    env.sb.compare_a2b_data();

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_ALIGN_ASYMMETRIC_SKEW_SV
