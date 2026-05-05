///////////////////////////////////////////////////////////////////////////////
// integration_tx_write_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// AHB master sequence: write a complete packet to the TX aperture.
//
// Packet format (matches src/rtl/fifo/tidelink_fifo_mem.sv & user_guide):
//   Beat 0   (addr 0x0000): word0 = length << 20  (length in bits [31:20])
//   Beat 1   (addr 0x0004): dest_addr (interpreted by RX side; here a placeholder)
//   Beat 2..N+1 (addr 0x0008..): N payload words
//   Last beat at addr (length+1)*4 triggers write_complete in tidelink_fifo_ctrl
//   (fifo_ctrl extracts length from bits [31:20] of the addr-0 word).
//
// The FC adapter converts each beat into a 48-bit FC word with
// pkt_type=FIFO_DATA and addr_offset matching the AHB address.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV
`define GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV

class integration_tx_write_sequence extends svt_ahb_master_transaction_base_sequence;

  // Packet payload words (not including the length header or the dest_addr word)
  bit [31:0] packet_data[];

  // Optional dest_addr written at beat 1. Defaults to 0; tests that exercise the
  // remote AHB-bridge path can override.
  bit [31:0] dest_addr = 32'h0000_0000;

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
    bit [31:0] word0;

    num_words = packet_data.size();
    word0     = num_words << 20;  // length packed into [31:20]

    `uvm_info("SEQ", $sformatf("TX writing packet: %0d payload words (word0=0x%08h, dest_addr=0x%08h)",
                                num_words, word0, dest_addr), UVM_MEDIUM)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Beat 0: word0 (length packed into [31:20]) at address 0x0000
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
      data[0]    == local::word0;
    };
    if (!status)
      `uvm_fatal("body", "Unable to randomize AHB write transaction (word0)")
    `uvm_send(req)

    // Beat 1: dest_addr at address 0x0004
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

    // Beats 2..N+1: payload words at addrs 0x0008, 0x000C, ...
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

    `uvm_info("SEQ", "TX packet write complete.", UVM_MEDIUM)
  endtask

endclass

`endif // GUARD_INTEGRATION_TX_WRITE_SEQUENCE_SV
