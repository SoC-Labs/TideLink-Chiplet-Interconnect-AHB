///////////////////////////////////////////////////////////////////////////////
// integration_tx_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: write a complete packet to the TX aperture.
//
// Packet format (same as unit-level ahb_packet_write_sequence):
//   Beat 0: Write packet_word_length to address 0x0000
//   Beat 1..N: Write data words to address 0x0004, 0x0008, ...
//   Beat N (address = length * 4): triggers write completion
//
// The FC adapter will convert each beat into a 48-bit FC word with
// pkt_type=FIFO_DATA and addr_offset matching the AHB address.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV
`define GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV

class integration_tx_write_sequence extends svt_ahb_master_transaction_base_sequence;

  // Packet data words (not including length header)
  bit [31:0] packet_data[];

  `uvm_object_utils(integration_tx_write_sequence)

  function new(string name = "integration_tx_write_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    int unsigned num_words;
    bit [31:0] addr;
    bit [31:0] data;

    num_words = packet_data.size();

    `uvm_info("SEQ", $sformatf("TX writing packet: %0d data words", num_words), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

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
      data = packet_data[i];

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

    `uvm_info("SEQ", "TX packet write complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV
