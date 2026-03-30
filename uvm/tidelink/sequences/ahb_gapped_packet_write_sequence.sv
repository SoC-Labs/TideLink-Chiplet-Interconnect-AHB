///////////////////////////////////////////////////////////////////////////////
// ahb_gapped_packet_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: write a packet with randomized idle gaps between beats.
// Uses the SVT AHB VIP's num_idle_cycles field to insert IDLE bus cycles
// before each transfer, testing non-back-to-back AHB write behaviour.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_GAPPED_PACKET_WRITE_SEQUENCE_SV
`define GUARD_AHB_GAPPED_PACKET_WRITE_SEQUENCE_SV

class ahb_gapped_packet_write_sequence extends svt_ahb_master_transaction_base_sequence;

  // Packet data words (not including length header)
  bit [31:0] packet_data[];

  // Gap control: number of IDLE cycles to insert between beats
  rand int unsigned min_gap;
  rand int unsigned max_gap;

  constraint c_default_gaps {
    min_gap inside {[1:3]};
    max_gap inside {[1:8]};
    max_gap >= min_gap;
  }

  `uvm_object_utils(ahb_gapped_packet_write_sequence)

  function new(string name = "ahb_gapped_packet_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    int unsigned num_words;
    bit [31:0] addr;
    bit [31:0] data;
    int unsigned gap;

    num_words = packet_data.size();

    `uvm_info("SEQ", $sformatf("Gapped packet write: %0d words, gaps [%0d:%0d]",
      num_words, min_gap, max_gap), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Beat 0: Write length word to address 0x0000 (no gap on first beat)
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
      data[0]    == local::num_words;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB write transaction (length)")
    `uvm_send(req)

    // Beats 1..N with random idle gaps before each beat
    for (int i = 0; i < num_words; i++) begin
      gap  = min_gap + ($urandom() % (max_gap - min_gap + 1));
      addr = (i + 1) * 4;
      data = packet_data[i];

      `uvm_create(req)
      status = req.randomize() with {
        xact_type       == svt_ahb_transaction::WRITE;
        burst_type      == svt_ahb_transaction::SINGLE;
        burst_size      == svt_ahb_transaction::BURST_SIZE_32BIT;
        addr            == local::addr;
        data.size()     == 1;
        data[0]         == local::data;
        num_idle_cycles == local::gap;
      };
      if (!status)
        `uvm_fatal("body", "Unable to randomize AHB write transaction (data)")
      `uvm_send(req)
    end

    `uvm_info("SEQ", "Gapped packet write complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_AHB_GAPPED_PACKET_WRITE_SEQUENCE_SV
