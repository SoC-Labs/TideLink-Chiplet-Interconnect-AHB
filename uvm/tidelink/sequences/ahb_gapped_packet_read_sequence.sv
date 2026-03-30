///////////////////////////////////////////////////////////////////////////////
// ahb_gapped_packet_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: read a packet with randomized idle gaps between beats.
// Uses the SVT AHB VIP's num_idle_cycles field to insert IDLE bus cycles
// before each transfer, testing non-back-to-back AHB read behaviour.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_GAPPED_PACKET_READ_SEQUENCE_SV
`define GUARD_AHB_GAPPED_PACKET_READ_SEQUENCE_SV

class ahb_gapped_packet_read_sequence extends svt_ahb_master_transaction_base_sequence;

  // Number of data words to read
  int unsigned num_words;

  // Gap control
  rand int unsigned min_gap;
  rand int unsigned max_gap;

  constraint c_default_gaps {
    min_gap inside {[1:3]};
    max_gap inside {[1:8]};
    max_gap >= min_gap;
  }

  `uvm_object_utils(ahb_gapped_packet_read_sequence)

  function new(string name = "ahb_gapped_packet_read_sequence");
    super.new(name);
    num_words = 0;
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    bit [31:0] addr;
    int unsigned gap;

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Beat 0: Read length word from address 0x0000 (no gap on first beat)
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB read transaction (length)")
    `uvm_send(req)

    `uvm_info("SEQ", $sformatf("Gapped packet read: %0d words, gaps [%0d:%0d]",
      num_words, min_gap, max_gap), UVM_MEDIUM)

    // Beats 1..N with random idle gaps before each beat
    for (int i = 0; i < num_words; i++) begin
      gap  = min_gap + ($urandom() % (max_gap - min_gap + 1));
      addr = (i + 1) * 4;

      `uvm_create(req)
      status = req.randomize() with {
        xact_type       == svt_ahb_transaction::READ;
        burst_type      == svt_ahb_transaction::SINGLE;
        burst_size      == svt_ahb_transaction::BURST_SIZE_32BIT;
        addr            == local::addr;
        data.size()     == 1;
        num_idle_cycles == local::gap;
      };
      if (!status)
        `uvm_fatal("body", "Unable to randomize AHB read transaction (data)")
      `uvm_send(req)
    end

    `uvm_info("SEQ", "Gapped packet read complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_AHB_GAPPED_PACKET_READ_SEQUENCE_SV
