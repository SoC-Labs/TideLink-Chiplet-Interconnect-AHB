///////////////////////////////////////////////////////////////////////////////
// sys_bidirectional_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Coordinated bidirectional traffic: sends packets A->B and B->A
// simultaneously using fork/join. Both sides must be initialized first.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_BIDIRECTIONAL_SEQUENCE_SV
`define GUARD_SYS_BIDIRECTIONAL_SEQUENCE_SV

class sys_bidirectional_sequence extends uvm_sequence;

  // Sequencer handles (must be set by caller)
  svt_ahb_master_transaction_sequencer a_tx_sqr;
  svt_ahb_master_transaction_sequencer b_tx_sqr;

  // Packet data for each direction
  bit [31:0] a_packet_data[];
  bit [31:0] b_packet_data[];

  `uvm_object_utils(sys_bidirectional_sequence)

  function new(string name = "sys_bidirectional_sequence");
    super.new(name);
  endfunction

  virtual task body();
    sys_packet_sequence a_wr_seq, b_wr_seq;

    `uvm_info("SEQ", $sformatf("Bidirectional TX: A=%0d words, B=%0d words",
      a_packet_data.size(), b_packet_data.size()), UVM_MEDIUM)

    a_wr_seq = sys_packet_sequence::type_id::create("a_wr_seq");
    a_wr_seq.packet_data = a_packet_data;
    a_wr_seq.side_name = "A";

    b_wr_seq = sys_packet_sequence::type_id::create("b_wr_seq");
    b_wr_seq.packet_data = b_packet_data;
    b_wr_seq.side_name = "B";

    // Launch both TX writes simultaneously
    fork
      a_wr_seq.start(a_tx_sqr);
      b_wr_seq.start(b_tx_sqr);
    join

    `uvm_info("SEQ", "Bidirectional TX complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_SYS_BIDIRECTIONAL_SEQUENCE_SV
