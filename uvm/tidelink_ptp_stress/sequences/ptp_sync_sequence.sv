///////////////////////////////////////////////////////////////////////////////
// ptp_sync_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Performs one complete SYNC + DELAY_REQ PTP exchange between Side A
// (grandmaster) and Side B (subordinate).
//
// Protocol:
//   1. Side A writes PTP AHB slave with msg_type=0 (SYNC)
//   2. Wait for Side B ptp_irq
//   3. Side B reads PTP_RX_PAYLOAD and PHC HW_CAP registers for t2
//   4. Side A reads PHC HW_CAP registers for t1
//   5. Side B writes PTP AHB slave with msg_type=1 (DELAY_REQ)
//   6. Wait for Side A ptp_irq
//   7. Side A reads PHC HW_CAP registers for t4
//   8. Side B reads PHC HW_CAP registers for t3
//   9. Send (t1, t2, t3, t4) tuple to scoreboard
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_SYNC_SEQUENCE_SV
`define GUARD_PTP_SYNC_SEQUENCE_SV

class ptp_sync_sequence extends uvm_sequence;

  `uvm_object_utils(ptp_sync_sequence)

  // Virtual sequencer handles (set by caller)
  svt_ahb_master_transaction_sequencer a_ptp_sqr;
  svt_ahb_master_transaction_sequencer a_phc_sqr;
  svt_ahb_master_transaction_sequencer a_cfg_sqr;
  svt_ahb_master_transaction_sequencer b_ptp_sqr;
  svt_ahb_master_transaction_sequencer b_phc_sqr;
  svt_ahb_master_transaction_sequencer b_cfg_sqr;

  // TB interface for IRQ polling and clock
  virtual tidelink_ptp_stress_if tb_if;

  // Scoreboard analysis port
  uvm_analysis_port #(ptp_timestamp_tuple) ts_ap;

  // Timeout
  int unsigned timeout_cycles = 50000;

  // Sequence number (payload)
  int unsigned seq_num = 0;

  function new(string name = "ptp_sync_sequence");
    super.new(name);
  endfunction

  // -------------------------------------------------------------------
  // Helper: AHB single-beat write
  // -------------------------------------------------------------------
  task ahb_write(svt_ahb_master_transaction_sequencer sqr,
                 bit [31:0] addr, bit [31:0] data);
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;
    sqr.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("PTP_SYNC", "Failed to cast SVT configuration")
    txn = svt_ahb_master_transaction::type_id::create("txn");
    txn.cfg = cfg;
    txn.set_sequencer(sqr);
    start_item(txn, -1, sqr);
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == local::addr;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == local::data;
    });
    finish_item(txn);
  endtask

  // -------------------------------------------------------------------
  // Helper: AHB single-beat read
  // -------------------------------------------------------------------
  task ahb_read(svt_ahb_master_transaction_sequencer sqr,
                bit [31:0] addr, output bit [31:0] rdata);
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;
    sqr.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("PTP_SYNC", "Failed to cast SVT configuration")
    txn = svt_ahb_master_transaction::type_id::create("txn");
    txn.cfg = cfg;
    txn.set_sequencer(sqr);
    start_item(txn, -1, sqr);
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      addr       == local::addr;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
    });
    finish_item(txn);
    rdata = (txn.data.size() > 0) ? txn.data[0] : 32'h0;
  endtask

  // -------------------------------------------------------------------
  // Helper: Read PHC HW_CAP timestamp as 64-bit nanoseconds
  // -------------------------------------------------------------------
  task read_phc_timestamp(svt_ahb_master_transaction_sequencer phc_sqr,
                          output bit [63:0] timestamp_ns);
    bit [31:0] sec_lo, sec_hi, ns;
    ahb_read(phc_sqr, REG_PHC_HW_CAP_SECONDS_LO, sec_lo);
    ahb_read(phc_sqr, REG_PHC_HW_CAP_SECONDS_HI, sec_hi);
    ahb_read(phc_sqr, REG_PHC_HW_CAP_NANOSECONDS, ns);
    timestamp_ns = ({sec_hi, sec_lo} * 64'd1_000_000_000) + {32'b0, ns};
  endtask

  // -------------------------------------------------------------------
  // Helper: Wait for IRQ with timeout
  // -------------------------------------------------------------------
  task wait_for_irq(logic irq_signal, string irq_name);
    int unsigned cycles = 0;
    while (!irq_signal && cycles < timeout_cycles) begin
      @(posedge tb_if.clk);
      cycles++;
    end
    if (cycles >= timeout_cycles)
      `uvm_error("PTP_SYNC", $sformatf("Timeout waiting for %s after %0d cycles",
        irq_name, timeout_cycles))
  endtask

  // -------------------------------------------------------------------
  // Main body
  // -------------------------------------------------------------------
  virtual task body();
    ptp_timestamp_tuple ts;
    bit [63:0] t1, t2, t3, t4;
    bit [31:0] rx_payload;
    bit [31:0] ptp_ctrl_rd;

    `uvm_info("PTP_SYNC", $sformatf("Starting PTP exchange #%0d", seq_num), UVM_HIGH)

    // Step 1: Side A writes PTP AHB slave — msg_type=0 (SYNC), payload=seq_num
    // PTP AHB addr[3:0] = msg_type = 4'h0
    ahb_write(a_ptp_sqr, 32'h0000_0000, seq_num);

    // Step 2: Wait for Side B ptp_irq
    wait_for_irq(tb_if.b_ptp_irq, "b_ptp_irq");

    // Step 3: Side B reads PTP_RX_PAYLOAD (via cfg port) and PHC for t2
    ahb_read(b_cfg_sqr, REG_PTP_RX_PAYLOAD, rx_payload);
    read_phc_timestamp(b_phc_sqr, t2);

    // Step 4: Side A reads PHC for t1 (captured at TX handshake)
    read_phc_timestamp(a_phc_sqr, t1);

    // Step 4b: Clear PTP RX on Side B (write PTP_CTRL enable=1, clear=1)
    ahb_write(b_cfg_sqr, REG_PTP_CTRL, 32'h0000_0003);
    ahb_write(b_cfg_sqr, REG_PTP_CTRL, 32'h0000_0001);

    // Step 5: Side B writes PTP AHB slave — msg_type=1 (DELAY_REQ)
    ahb_write(b_ptp_sqr, 32'h0000_0004, seq_num);

    // Step 6: Wait for Side A ptp_irq
    wait_for_irq(tb_if.a_ptp_irq, "a_ptp_irq");

    // Step 7: Side A reads PHC for t4 (captured at RX accept)
    read_phc_timestamp(a_phc_sqr, t4);

    // Step 8: Side B reads PHC for t3 (captured at TX handshake)
    read_phc_timestamp(b_phc_sqr, t3);

    // Step 8b: Clear PTP RX on Side A
    ahb_write(a_cfg_sqr, REG_PTP_CTRL, 32'h0000_0003);
    ahb_write(a_cfg_sqr, REG_PTP_CTRL, 32'h0000_0001);

    // Step 9: Send timestamp tuple to scoreboard
    ts = ptp_timestamp_tuple::type_id::create("ts");
    ts.t1 = t1;
    ts.t2 = t2;
    ts.t3 = t3;
    ts.t4 = t4;

    if (ts_ap != null)
      ts_ap.write(ts);

    `uvm_info("PTP_SYNC", $sformatf(
      "Exchange #%0d complete: t1=%0d t2=%0d t3=%0d t4=%0d (fwd=%0d rev=%0d)",
      seq_num, t1, t2, t3, t4, t2-t1, t4-t3), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_PTP_SYNC_SEQUENCE_SV
