///////////////////////////////////////////////////////////////////////////////
// top_sys_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Full initialization sequence for one tidelink_top side.
// Configures TideLink FIFO registers (pair base, threshold, enable)
// via the AHB config port (same as integration init).
//
// Wlink initialization is handled separately via top_sys_wlink_init_sequence
// on the APB agent.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_INIT_SEQUENCE_SV
`define GUARD_TOP_SYS_INIT_SEQUENCE_SV

class top_sys_init_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(top_sys_init_sequence)

  bit [31:0] pair_base_addr = 32'h4000_0000;
  bit [31:0] rel_threshold  = 32'd0;
  string     side_name      = "?";

  function new(string name = "top_sys_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    svt_ahb_master_transaction txn;
    svt_configuration get_cfg;
    svt_ahb_master_configuration cfg;

    `uvm_info("TL_INIT", $sformatf("[%s] Initializing TideLink (pair_base=0x%08h, threshold=%0d)...",
      side_name, pair_base_addr, rel_threshold), UVM_LOW)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("TL_INIT", "Failed to cast SVT configuration")

    // Write pair base address
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type == svt_ahb_transaction::WRITE;
      addr      == REG_PAIR_BASE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]   == pair_base_addr;
    });
    `uvm_send(txn)

    // Write release threshold
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type == svt_ahb_transaction::WRITE;
      addr      == REG_REL_THRESHOLD;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]   == rel_threshold;
    });
    `uvm_send(txn)

    // Enable pair credit counter
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type == svt_ahb_transaction::WRITE;
      addr      == REG_PAIR_CREDIT_ENABLE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]   == 32'h0000_0001;
    });
    `uvm_send(txn)

    // Ring doorbell to send initial credits to peer
    `uvm_create(txn)
    txn.cfg = cfg;
    assert(txn.randomize() with {
      xact_type == svt_ahb_transaction::WRITE;
      addr      == REG_DOORBELL;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      data.size() == 1;
      data[0]   == 32'h0000_0001;
    });
    `uvm_send(txn)

    `uvm_info("TL_INIT", $sformatf("[%s] TideLink initialization complete.", side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_TOP_SYS_INIT_SEQUENCE_SV
