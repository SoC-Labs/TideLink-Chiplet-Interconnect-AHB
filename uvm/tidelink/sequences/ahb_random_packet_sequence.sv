///////////////////////////////////////////////////////////////////////////////
// ahb_random_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: write a packet with randomized data to the FIFO.
// Generates a random-length packet with random payload.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_RANDOM_PACKET_SEQUENCE_SV
`define GUARD_AHB_RANDOM_PACKET_SEQUENCE_SV

class ahb_random_packet_sequence extends svt_ahb_master_transaction_base_sequence;

  rand int unsigned num_words;

  constraint c_reasonable {
    num_words inside {[1:64]};
  }

  // Generated packet data (available after body completes)
  bit [31:0] generated_data[];

  `uvm_object_utils(ahb_random_packet_sequence)

  function new(string name = "ahb_random_packet_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    bit [31:0] addr;
    bit [31:0] data;

    `uvm_info("SEQ", $sformatf("Random packet write: %0d data words", num_words), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Generate random data
    generated_data = new[num_words];
    for (int i = 0; i < num_words; i++) begin
      generated_data[i] = $urandom();
    end

    // Beat 0: Write length word to address 0x0000
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

    // Beats 1..N: Write data words
    for (int i = 0; i < num_words; i++) begin
      addr = (i + 1) * 4;
      data = generated_data[i];

      `uvm_create(req)
      status = req.randomize() with {
        xact_type  == svt_ahb_transaction::WRITE;
        burst_type == svt_ahb_transaction::SINGLE;
        burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
        addr       == local::addr;
        data.size() == 1;
        data[0]    == local::data;
      };
      if (!status)
        `uvm_fatal("body", "Unable to randomize AHB write transaction (data)")
      `uvm_send(req)
    end

    `uvm_info("SEQ", "Random packet write complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_AHB_RANDOM_PACKET_SEQUENCE_SV
