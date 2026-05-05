///////////////////////////////////////////////////////////////////////////////
// integration_fifo_read_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: read a complete packet from the RX FIFO.
//
// Packet format (matches src/rtl/fifo/tidelink_fifo_mem.sv & user_guide):
//   Beat 0   (addr 0x0000): word0 — length is in bits [31:20]
//   Beat 1   (addr 0x0004): dest_addr
//   Beat 2..N+1 (addr 0x0008..): N payload words
//   Last beat at addr (length+1)*4 triggers read completion in tidelink_fifo_ctrl
//
// `read_data` returned to the caller contains only the N payload words.
// `read_word0` and `read_dest_addr` capture the header for any test that
// needs them.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_INTEGRATION_FIFO_READ_SEQUENCE_SV
`define GUARD_INTEGRATION_FIFO_READ_SEQUENCE_SV

class integration_fifo_read_sequence extends svt_ahb_master_transaction_base_sequence;

  // Number of payload words to read (set before starting, or decoded from beat 0)
  int unsigned num_words;

  // Captured payload (excluding length word and dest_addr)
  bit [31:0] read_data[];

  // Captured header words
  bit [31:0] read_word0;
  bit [31:0] read_dest_addr;

  `uvm_object_utils(integration_fifo_read_sequence)

  function new(string name = "integration_fifo_read_sequence");
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

    // Beat 0: Read word0 (length packed in [31:20]) from address 0x0000
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::READ;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB read transaction (word0)")
    `uvm_send(req)

    if (req.data.size() > 0)
      read_word0 = req.data[0];

    // If num_words not pre-set, decode it from word0 [31:20]
    if (num_words == 0)
      num_words = (read_word0 >> 20) & 32'h0000_0FFF;

    `uvm_info("SEQ", $sformatf("FIFO reading packet: %0d payload words (word0=0x%08h)",
                                num_words, read_word0), UVM_MEDIUM)

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

    read_data = new[num_words];

    // Beats 2..N+1: Read payload from addrs 0x0008, 0x000C, ...
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

    `uvm_info("SEQ", "FIFO packet read complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_INTEGRATION_FIFO_READ_SEQUENCE_SV
