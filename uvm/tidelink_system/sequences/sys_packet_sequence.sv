///////////////////////////////////////////////////////////////////////////////
// sys_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Write a complete descriptor packet (length + header + payload) to one
// side's TX aperture. This is a thin wrapper around integration_tx_write_sequence
// that adds system-level context (which side to target).
//
// Packet format:
//   Beat 0: Write packet_word_length to address 0x0000
//   Beat 1..N: Write data words to address 0x0004, 0x0008, ...
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_PACKET_SEQUENCE_SV
`define GUARD_SYS_PACKET_SEQUENCE_SV

class sys_packet_sequence extends svt_ahb_master_transaction_base_sequence;

  // Packet data words (not including length header)
  bit [31:0] packet_data[];

  // Optional descriptor header fields (placed in packet_data[0])
  bit [1:0]  pkt_type;    // 00=RD_REQ, 01=WR_REQ, 10=RD_RSP, 11=WR_RSP
  bit [31:0] descriptor;  // Full 32-bit descriptor word

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

    num_words = packet_data.size();

    `uvm_info("SEQ", $sformatf("[%s] TX writing packet: %0d data words",
      side_name, num_words), UVM_MEDIUM)

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

    `uvm_info("SEQ", $sformatf("[%s] TX packet write complete.", side_name), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_SYS_PACKET_SEQUENCE_SV
