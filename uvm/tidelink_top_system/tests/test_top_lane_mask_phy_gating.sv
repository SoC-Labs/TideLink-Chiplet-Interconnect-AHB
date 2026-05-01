///////////////////////////////////////////////////////////////////////////////
// test_top_lane_mask_phy_gating.sv — Masked TX pads stay at 0 (E1)
///////////////////////////////////////////////////////////////////////////////
// Hierarchical probe: with mask=0x7F (lane 7 disabled), the GPIO PHY
// gating in WavD2DGpio should drive the lane-7 pad output to constant 0.
// This test sets up the link with the mask, runs traffic for a window,
// and samples top.a_pad_tx[7] every cycle. Any non-zero sample is a fail.
//
// Combined with the regular TX traffic test, this proves both:
//   - LinkLayer drives 0 into the masked lane's data slice
//   - GPIO PHY honours the mask bit in its serializer mux
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_LANE_MASK_PHY_GATING_SV
`define GUARD_TEST_TOP_LANE_MASK_PHY_GATING_SV

class test_top_lane_mask_phy_gating extends test_top_lane_mask_base;

  `uvm_component_utils(test_top_lane_mask_phy_gating)

  function new(string name = "test_top_lane_mask_phy_gating",
               uvm_component parent = null);
    super.new(name, parent);
    a_tx_mask = 16'h007F;
    a_rx_mask = 16'h007F;
    b_tx_mask = 16'h007F;
    b_rx_mask = 16'h007F;
  endfunction

  // Probe the masked TX pad over the entire sample window. Reports any
  // non-zero observation. Runs forked alongside run_traffic.
  virtual task probe_masked_pad();
    int unsigned violations = 0;
    int unsigned samples    = 0;
    forever begin
      @(posedge tb_if.clk);
      samples++;
      if (tb_if.a_pad_tx_obs[7] !== 1'b0) begin
        violations++;
        if (violations <= 5) begin
          `uvm_error("TEST", $sformatf(
            "[%0t] a_pad_tx_obs[7] = %0b but lane 7 is masked off",
            $time, tb_if.a_pad_tx_obs[7]))
        end
      end
    end
  endtask

  virtual task run_traffic();
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    // Spawn the probe in parallel with the traffic.
    fork
      probe_masked_pad();
    join_none

    pkt_data = new[8];
    pkt_data[0] = 32'hAA00_0011;
    pkt_data[1] = 32'hBB00_0022;
    pkt_data[2] = 32'hCC00_0033;
    pkt_data[3] = 32'hDD00_0044;
    pkt_data[4] = 32'hEE00_0055;
    pkt_data[5] = 32'hFF00_0066;
    pkt_data[6] = 32'h1100_0077;
    pkt_data[7] = 32'h2200_0088;

    write_packet(SIDE_A, pkt_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);
    read_packet(SIDE_B, 8, read_data);
    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();
  endtask

endclass

`endif // GUARD_TEST_TOP_LANE_MASK_PHY_GATING_SV
