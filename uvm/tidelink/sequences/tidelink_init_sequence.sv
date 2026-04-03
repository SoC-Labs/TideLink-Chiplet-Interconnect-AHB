///////////////////////////////////////////////////////////////////////////////
// tidelink_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB sequence to initialize TideLink:
//   1. Set pair base address
//   2. Set release threshold
//   3. Enable pair credit counter
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TIDELINK_INIT_SEQUENCE_SV
`define GUARD_TIDELINK_INIT_SEQUENCE_SV

class tidelink_init_sequence extends uvm_sequence #(apb_master_transaction);

  bit [31:0] pair_base_addr  = 32'h4000_0000;
  bit [31:0] rel_threshold   = 32'd0;  // 0 = immediate release

  `uvm_object_utils(tidelink_init_sequence)

  function new(string name = "tidelink_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_write_sequence wr_seq;

    `uvm_info("SEQ", $sformatf("Initializing TideLink: pair_base=0x%08h threshold=%0d",
      pair_base_addr, rel_threshold), UVM_LOW)

    // Set pair base address
    wr_seq = apb_write_sequence::type_id::create("wr_pair_base");
    wr_seq.addr = REG_PAIR_BASE;
    wr_seq.data = pair_base_addr;
    wr_seq.start(m_sequencer);

    // Set release threshold
    wr_seq = apb_write_sequence::type_id::create("wr_threshold");
    wr_seq.addr = REG_REL_THRESHOLD;
    wr_seq.data = rel_threshold;
    wr_seq.start(m_sequencer);

    // Enable pair credit counter
    wr_seq = apb_write_sequence::type_id::create("wr_ptc_en");
    wr_seq.addr = REG_PAIR_CREDIT_ENABLE;
    wr_seq.data = 32'h1;
    wr_seq.start(m_sequencer);

    `uvm_info("SEQ", "TideLink initialization complete.", UVM_LOW)
  endtask

endclass

`endif // GUARD_TIDELINK_INIT_SEQUENCE_SV
