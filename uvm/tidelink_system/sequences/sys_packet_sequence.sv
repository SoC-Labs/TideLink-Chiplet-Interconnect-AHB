///////////////////////////////////////////////////////////////////////////////
// sys_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Write a complete descriptor packet (length + header + payload) to one
// side's TX aperture. This is a thin wrapper around integration_tx_write_sequence
// that adds system-level context (which side to target).
//
// Packet format (2-word header):
//   Beat 0: Write packed header word 0 to address 0x0000
//           {length[31:20], pkt_type[19:18], src_id[17:13], dest_id[12:8], tag[7:0]}
//   Beat 1: Write dest_addr to address 0x0004
//   Beat 2..N+1: Write data words to address 0x0008, 0x000C, ...
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_PACKET_SEQUENCE_SV
`define GUARD_SYS_PACKET_SEQUENCE_SV

class sys_packet_sequence extends svt_ahb_master_transaction_base_sequence;

  // Packet data words (not including 2-word header)
  bit [31:0] packet_data[];

  // Header fields
  bit [1:0]  pkt_type  = 2'b00;  // 00=RD_REQ, 01=WR_REQ, 10=RD_RSP, 11=WR_RSP
  bit [4:0]  src_id    = 5'b0;
  bit [4:0]  dest_id   = 5'b0;
  bit [7:0]  tag       = 8'b0;
  bit [31:0] dest_addr = 32'h0000_0000;

  // Side identifier for logging
  string side_name = "?";

  `uvm_object_utils(sys_packet_sequence)

  function new(string name = "sys_packet_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;
    int unsigned num_words;
    bit [31:0] addr;
    bit [31:0] data;
    bit [31:0] hdr_word0;

    num_words = packet_data.size();

    `uvm_info("SEQ", $sformatf("[%s] TX writing packet: %0d data words",
      side_name, num_words), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

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

    `uvm_info("SEQ", $sformatf("[%s] TX packet write complete.", side_name), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_SYS_PACKET_SEQUENCE_SV
