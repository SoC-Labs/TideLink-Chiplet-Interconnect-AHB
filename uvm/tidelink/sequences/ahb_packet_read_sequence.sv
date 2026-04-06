///////////////////////////////////////////////////////////////////////////////
// ahb_packet_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: read a complete packet from the TideLink FIFO.
//
// Packet format (2-word header):
//   Beat 0: Read packed header word 0 from address 0x0000
//           {length[31:20], pkt_type[19:18], src_id[17:13], dest_id[12:8], tag[7:0]}
//   Beat 1: Read dest_addr from address 0x0004
//   Beat 2..N+1: Read data words from address 0x0008, 0x000C, ...
//   Beat N+1 (address = (length+1) * 4): triggers read completion
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_AHB_PACKET_READ_SEQUENCE_SV
`define GUARD_AHB_PACKET_READ_SEQUENCE_SV

class ahb_packet_read_sequence extends svt_ahb_master_transaction_base_sequence;

  // Number of data words to read (set before starting, or read from beat 0)
  int unsigned num_words;

  // Captured read data
  bit [31:0] read_data[];

  // Captured header fields
  bit [31:0] read_dest_addr;

  `uvm_object_utils(ahb_packet_read_sequence)

  function new(string name = "ahb_packet_read_sequence");
    super.new(name);
    num_words = 0;
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    bit [31:0] addr;

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Beat 0: Read packed header word 0 from address 0x0000
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB read transaction (header word 0)")
    `uvm_send(req)

    // If num_words not pre-set, extract length from bits [31:20]
    if (num_words == 0 && req.data.size() > 0)
      num_words = req.data[0][31:20];

    // Beat 1: Read dest_addr from address 0x0004
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0004;
      data.size() == 1;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB read transaction (dest_addr)")
    `uvm_send(req)

    if (req.data.size() > 0)
      read_dest_addr = req.data[0];

    `uvm_info("SEQ", $sformatf("Reading packet: %0d data words", num_words), UVM_MEDIUM)

    read_data = new[num_words];

    // Beats 2..N+1: Read data words
    for (int i = 0; i < num_words; i++) begin
      addr = (i + 2) * 4;

      `uvm_create(req)
      status = req.randomize() with {
        xact_type  == svt_ahb_transaction::READ;
        burst_type == svt_ahb_transaction::SINGLE;
        burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
        addr       == local::addr;
        data.size() == 1;
      };
      if (!status)
        `uvm_fatal("body", "Unable to randomize AHB read transaction (data)")
      `uvm_send(req)

      if (req.data.size() > 0)
        read_data[i] = req.data[0];
    end

    `uvm_info("SEQ", "Packet read complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_AHB_PACKET_READ_SEQUENCE_SV
