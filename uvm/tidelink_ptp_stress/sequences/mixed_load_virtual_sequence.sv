///////////////////////////////////////////////////////////////////////////////
// mixed_load_virtual_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Virtual sequence that starts background traffic generators on AXI
// (via ahb_sub), FIFO_DATA (via ahb_tx), and general bus paths, runs
// N PTP exchanges, then stops background traffic.
//
// Traffic rate (0-100) controls the duty cycle: for each background
// iteration, the generator performs a write then waits (100-rate)
// idle cycles before the next, yielding proportional bus utilisation.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_MIXED_LOAD_VIRTUAL_SEQUENCE_SV
`define GUARD_MIXED_LOAD_VIRTUAL_SEQUENCE_SV

class mixed_load_virtual_sequence extends uvm_sequence;

  `uvm_object_utils(mixed_load_virtual_sequence)

  // Configuration
  ptp_config          cfg;
  ptp_stress_vseqr    vseqr;

  // TB interface for clock and IRQ
  virtual tidelink_ptp_stress_if tb_if;

  // Scoreboard analysis port (passed through to ptp_sync_sequence)
  uvm_analysis_port #(ptp_timestamp_tuple) ts_ap;

  // Coverage handle
  ptp_coverage cov;

  // Control flag for background traffic
  bit stop_traffic;

  function new(string name = "mixed_load_virtual_sequence");
    super.new(name);
  endfunction

  // -------------------------------------------------------------------
  // Background AXI traffic (ahb_sub port, both directions)
  // -------------------------------------------------------------------
  task run_axi_traffic();
    int unsigned idle_gap;
    int unsigned iter = 0;

    if (cfg.axi_traffic_rate == 0) return;

    idle_gap = (cfg.axi_traffic_rate >= 100) ? 0 :
               (100 - cfg.axi_traffic_rate);

    while (!stop_traffic) begin
      top_sys_ahb_sub_write_sequence wr_seq;

      // Side A -> B
      wr_seq = top_sys_ahb_sub_write_sequence::type_id::create("axi_wr_a");
      wr_seq.addr = 32'h0000_1000 + (iter * 4);
      wr_seq.data = 32'hAA00_0000 | iter;
      wr_seq.start(vseqr.a_sub_sqr, this);

      // Side B -> A
      wr_seq = top_sys_ahb_sub_write_sequence::type_id::create("axi_wr_b");
      wr_seq.addr = 32'h0000_2000 + (iter * 4);
      wr_seq.data = 32'hBB00_0000 | iter;
      wr_seq.start(vseqr.b_sub_sqr, this);

      repeat (idle_gap) @(posedge tb_if.clk);
      iter++;
    end
  endtask

  // -------------------------------------------------------------------
  // Background FIFO traffic (ahb_tx port, both directions)
  // -------------------------------------------------------------------
  task run_fifo_traffic();
    int unsigned idle_gap;
    int unsigned iter = 0;

    if (cfg.fifo_traffic_rate == 0) return;

    idle_gap = (cfg.fifo_traffic_rate >= 100) ? 0 :
               (100 - cfg.fifo_traffic_rate);

    while (!stop_traffic) begin
      integration_tx_write_sequence wr_seq;
      bit [31:0] pkt[];

      // Side A -> B: 4-word packet
      pkt = new[4];
      for (int w = 0; w < 4; w++)
        pkt[w] = 32'hF1F0_0000 | (iter << 8) | w;
      wr_seq = integration_tx_write_sequence::type_id::create("fifo_wr_a");
      wr_seq.packet_data = pkt;
      wr_seq.start(vseqr.a_tx_sqr, this);

      // Side B -> A: 4-word packet
      for (int w = 0; w < 4; w++)
        pkt[w] = 32'hF2F0_0000 | (iter << 8) | w;
      wr_seq = integration_tx_write_sequence::type_id::create("fifo_wr_b");
      wr_seq.packet_data = pkt;
      wr_seq.start(vseqr.b_tx_sqr, this);

      repeat (idle_gap) @(posedge tb_if.clk);
      iter++;
    end
  endtask

  // -------------------------------------------------------------------
  // Background general bus traffic (cfg port read/write churn)
  // -------------------------------------------------------------------
  task run_gb_traffic();
    int unsigned idle_gap;
    int unsigned iter = 0;

    if (cfg.gb_traffic_rate == 0) return;

    idle_gap = (cfg.gb_traffic_rate >= 100) ? 0 :
               (100 - cfg.gb_traffic_rate);

    while (!stop_traffic) begin
      integration_cfg_read_sequence rd_seq;

      // Read status register on both sides to generate bus activity.
      // integration_cfg_read_sequence is uvm_sequence #(apb_master_transaction)
      // so it must run on the APB master sequencer, not the AHB cfg sequencer.
      rd_seq = integration_cfg_read_sequence::type_id::create("gb_rd_a");
      rd_seq.addr = REG_STATUS;
      rd_seq.start(vseqr.a_apb_sqr, this);

      rd_seq = integration_cfg_read_sequence::type_id::create("gb_rd_b");
      rd_seq.addr = REG_STATUS;
      rd_seq.start(vseqr.b_apb_sqr, this);

      repeat (idle_gap) @(posedge tb_if.clk);
      iter++;
    end
  endtask

  // -------------------------------------------------------------------
  // PTP exchange loop
  // -------------------------------------------------------------------
  task run_ptp_exchanges();
    for (int i = 0; i < cfg.num_ptp_exchanges; i++) begin
      ptp_sync_sequence sync_seq;
      sync_seq = ptp_sync_sequence::type_id::create($sformatf("sync_%0d", i));
      sync_seq.a_ptp_sqr      = vseqr.a_ptp_sqr;
      sync_seq.a_phc_sqr      = vseqr.a_phc_sqr;
      sync_seq.a_cfg_sqr      = vseqr.a_cfg_sqr;
      sync_seq.b_ptp_sqr      = vseqr.b_ptp_sqr;
      sync_seq.b_phc_sqr      = vseqr.b_phc_sqr;
      sync_seq.b_cfg_sqr      = vseqr.b_cfg_sqr;
      sync_seq.tb_if           = tb_if;
      sync_seq.ts_ap           = ts_ap;
      sync_seq.timeout_cycles  = cfg.timeout_per_exchange;
      sync_seq.seq_num         = i;
      sync_seq.start(null, this);
    end
  endtask

  // -------------------------------------------------------------------
  // Main body
  // -------------------------------------------------------------------
  virtual task body();
    stop_traffic = 0;

    `uvm_info("MIXED_LOAD", $sformatf(
      "Starting mixed load: axi=%0d%%, fifo=%0d%%, gb=%0d%%, exchanges=%0d",
      cfg.axi_traffic_rate, cfg.fifo_traffic_rate, cfg.gb_traffic_rate,
      cfg.num_ptp_exchanges), UVM_LOW)

    // Sample traffic levels for coverage
    if (cov != null)
      cov.set_traffic_levels(cfg.axi_traffic_rate, cfg.fifo_traffic_rate,
                             cfg.gb_traffic_rate);

    // Fork background traffic and PTP exchanges
    fork
      run_axi_traffic();
      run_fifo_traffic();
      run_gb_traffic();
      begin
        run_ptp_exchanges();
        // All PTP exchanges done — stop background traffic
        stop_traffic = 1;
        `uvm_info("MIXED_LOAD", "All PTP exchanges complete, stopping background traffic.", UVM_LOW)
      end
    join_any

    // Wait for background tasks to notice stop_traffic flag
    repeat (200) @(posedge tb_if.clk);

    disable fork;

    `uvm_info("MIXED_LOAD", "Mixed load virtual sequence complete.", UVM_LOW)
  endtask

endclass

`endif // GUARD_MIXED_LOAD_VIRTUAL_SEQUENCE_SV
