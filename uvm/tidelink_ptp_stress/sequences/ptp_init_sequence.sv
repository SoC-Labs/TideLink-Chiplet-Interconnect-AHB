///////////////////////////////////////////////////////////////////////////////
// ptp_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Configures both PHC (enable, NS_INCR) and PTP_CTRL (enable=1, clear=1)
// on a single side. Run on both sides during test setup.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_INIT_SEQUENCE_SV
`define GUARD_PTP_INIT_SEQUENCE_SV

class ptp_init_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(ptp_init_sequence)

  string     side_name = "?";
  bit [31:0] phc_ns_incr = 32'd4;

  function new(string name = "ptp_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;

    `uvm_info("PTP_INIT", $sformatf(
      "[%s] Configuring PHC (NS_INCR=%0d) and PTP (enable+clear)...",
      side_name, phc_ns_incr), UVM_LOW)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("PTP_INIT", "Failed to cast SVT configuration")

    // -------------------------------------------------------------------
    // PHC: Write NS_INCR register (nanosecond increment per clock)
    // -------------------------------------------------------------------
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == REG_PHC_NS_INCR;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == local::phc_ns_incr;
    });
    `uvm_send(txn)

    // -------------------------------------------------------------------
    // PHC: Enable PHC (bit 0 = enable)
    // -------------------------------------------------------------------
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == REG_PHC_CTRL;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == 32'h0000_0001;
    });
    `uvm_send(txn)

    // -------------------------------------------------------------------
    // PTP_CTRL: enable=1, clear=1 (bits [1:0])
    // This enables PTP and clears any stale RX state
    // -------------------------------------------------------------------
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == REG_PTP_CTRL;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == 32'h0000_0003;
    });
    `uvm_send(txn)

    // -------------------------------------------------------------------
    // PTP_CTRL: enable=1, clear=0 (release clear bit)
    // -------------------------------------------------------------------
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == REG_PTP_CTRL;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == 32'h0000_0001;
    });
    `uvm_send(txn)

    // -------------------------------------------------------------------
    // PHC SERVO_CTRL: Select TideLink as hardware servo source (SRC_SEL=0)
    // -------------------------------------------------------------------
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      addr       == REG_PHC_SERVO_CTRL;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]    == 32'h0000_0000;
    });
    `uvm_send(txn)

    `uvm_info("PTP_INIT", $sformatf("[%s] PHC + PTP initialization complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_PTP_INIT_SEQUENCE_SV
