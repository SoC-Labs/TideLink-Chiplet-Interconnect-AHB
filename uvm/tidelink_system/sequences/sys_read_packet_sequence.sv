///////////////////////////////////////////////////////////////////////////////
// sys_read_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Read a complete packet from one side's RX FIFO.
//
// Packet format:
//   Beat 0: Read packet_word_length from address 0x0000
//   Beat 1..N: Read data words from address 0x0004, 0x0008, ...
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_READ_PACKET_SEQUENCE_SV
`define GUARD_SYS_READ_PACKET_SEQUENCE_SV

class sys_read_packet_sequence extends svt_ahb_master_transaction_base_sequence;

  // Number of data words to read (set before starting, or read from beat 0)
  int unsigned num_words;

  // Captured read data
  bit [31:0] read_data[];

  // Side identifier for logging
  string side_name = "?";

  `uvm_object_utils(sys_read_packet_sequence)

  function new(string name = "sys_read_packet_sequence");
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

    // Beat 0: Read length word from address 0x0000
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

    // If num_words not pre-set, use the read-back length
    if (num_words == 0 && req.data.size() > 0)
      num_words = req.data[0];

    `uvm_info("SEQ", $sformatf("[%s] FIFO reading packet: %0d data words",
      side_name, num_words), UVM_MEDIUM)

    read_data = new[num_words];

    // Beats 1..N: Read data words
    for (int i = 0; i < num_words; i++) begin
      addr = (i + 1) * 4;

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

    `uvm_info("SEQ", $sformatf("[%s] FIFO packet read complete.", side_name), UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_SYS_READ_PACKET_SEQUENCE_SV
