///////////////////////////////////////////////////////////////////////////////
// sys_partial_packet_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Writes a partial packet to the TX aperture: writes the length header and
// only a subset of the declared data words, then stops without completing.
// Used by G32 (partial packet abandon) tests.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_SYS_PARTIAL_PACKET_SEQUENCE_SV
`define GUARD_SYS_PARTIAL_PACKET_SEQUENCE_SV

class sys_partial_packet_sequence extends svt_ahb_master_transaction_base_sequence;

  `uvm_object_utils(sys_partial_packet_sequence)

  // Declared total length (written to address 0)
  int unsigned declared_length = 10;

  // Actual words to write (< declared_length)
  int unsigned actual_words = 3;

  // Data to write (size must be >= actual_words)
  bit [31:0] partial_data[];

  string side_name = "?";

  function new(string name = "sys_partial_packet_sequence");
    super.new(name);
  endfunction

  virtual task body();
    integer status;
    svt_configuration get_cfg;

    `uvm_info("PARTIAL_PKT", $sformatf(
      "[%s] Writing partial packet: declared=%0d, actual=%0d words",
      side_name, declared_length, actual_words), UVM_LOW)

    p_sequencer.get_cfg(get_cfg);
    if (!$cast(cfg, get_cfg))
      `uvm_fatal("body", "Unable to $cast configuration to svt_ahb_port_configuration")

    // Beat 0: Write declared length to address 0x0000
    `uvm_create(req)
    status = req.randomize() with {
      xact_type  == svt_ahb_transaction::WRITE;
      burst_type == svt_ahb_transaction::SINGLE;
      burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
      addr       == 32'h0000_0000;
      data.size() == 1;
      data[0]    == local::declared_length;
    };
    if (!status) `uvm_fatal("PARTIAL_PKT", "Randomization failed for length beat")
    `uvm_send(req)
    get_response(rsp);

    // Beats 1..actual_words: Write partial data words
    for (int i = 0; i < actual_words; i++) begin
      bit [31:0] wdata;
      wdata = (i < partial_data.size()) ? partial_data[i] : 32'hDEAD_DEAD;
      `uvm_create(req)
      status = req.randomize() with {
        xact_type  == svt_ahb_transaction::WRITE;
        burst_type == svt_ahb_transaction::SINGLE;
        burst_size == svt_ahb_transaction::BURST_SIZE_32BIT;
        addr       == (local::i + 1) * 4;
        data.size() == 1;
        data[0]    == local::wdata;
      };
      if (!status) `uvm_fatal("PARTIAL_PKT", "Randomization failed for data beat")
      `uvm_send(req)
      get_response(rsp);
    end

    `uvm_info("PARTIAL_PKT", $sformatf(
      "[%s] Partial write complete: %0d of %0d words written",
      side_name, actual_words, declared_length), UVM_LOW)
  endtask

endclass

`endif // GUARD_SYS_PARTIAL_PACKET_SEQUENCE_SV
