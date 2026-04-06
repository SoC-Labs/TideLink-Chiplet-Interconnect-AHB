///////////////////////////////////////////////////////////////////////////////
// ahb_random_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: write a packet with randomized data to the FIFO.
// Generates a random-length packet with random payload.
// Uses 2-word packed header format.
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

  // Header fields (default to 0)
  bit [31:0] dest_addr = 32'h0000_0000;
  bit [1:0]  pkt_type  = 2'b00;
  bit [4:0]  src_id    = 5'b0;
  bit [4:0]  dest_id   = 5'b0;
  bit [7:0]  tag       = 8'b0;

  `uvm_object_utils(ahb_random_packet_sequence)

  function new(string name = "ahb_random_packet_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    bit [31:0] addr;
    bit [31:0] data;
    bit [31:0] hdr_word0;

    `uvm_info("SEQ", $sformatf("Random packet write: %0d data words", num_words), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Generate random data
    generated_data = new[num_words];
    for (int i = 0; i < num_words; i++) begin
      generated_data[i] = $urandom();
    end

    // Build packed header word 0
    hdr_word0 = {num_words[11:0], pkt_type, src_id, dest_id, tag};

    // Beat 0: Write packed header word 0 to address 0x0000
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
      data[0]    == local::hdr_word0;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB write transaction (header word 0)")
    `uvm_send(req)

    // Beat 1: Write dest_addr to address 0x0004
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0004;
      data.size() == 1;
      data[0]    == local::dest_addr;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB write transaction (dest_addr)")
    `uvm_send(req)

    // Beats 2..N+1: Write data words
    for (int i = 0; i < num_words; i++) begin
      addr = (i + 2) * 4;
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
