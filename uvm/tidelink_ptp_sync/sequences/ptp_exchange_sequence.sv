///////////////////////////////////////////////////////////////////////////////
// ptp_exchange_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// Perform a single PTP SYNC + DELAY_REQ round-trip and capture all four
// timestamps (t1, t2, t3, t4):
//
//   1. Master (A) sends SYNC message          -> PHC_A captures t1
//   2. Slave  (B) receives SYNC               -> PHC_B captures t2
//   3. Slave  (B) sends DELAY_REQ             -> PHC_B captures t3
//   4. Master (A) receives DELAY_REQ          -> PHC_A captures t4
//
// After the round-trip, this sequence reads the HW_CAP registers on
// both sides to retrieve the four timestamps and computes:
//   offset = ((t2 - t1) - (t4 - t3)) / 2
//   delay  = ((t2 - t1) + (t4 - t3)) / 2
//
// The caller can read the computed offset_ns and delay_ns fields.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_PTP_EXCHANGE_SEQUENCE_SV
`define GUARD_PTP_EXCHANGE_SEQUENCE_SV

class ptp_exchange_sequence extends uvm_sequence;

  `uvm_object_utils(ptp_exchange_sequence)

  // Sequencer handles (set by caller from virtual sequencer)
  svt_ahb_master_transaction_sequencer a_phc_sqr;
  svt_ahb_master_transaction_sequencer a_ptp_sqr;
  svt_ahb_master_transaction_sequencer b_phc_sqr;
  svt_ahb_master_transaction_sequencer b_ptp_sqr;

  // Output: computed PTP offset and delay in nanoseconds
  real offset_ns;
  real delay_ns;

  // Output: raw timestamps (seconds_lo * 1e9 + nanoseconds)
  real t1_ns, t2_ns, t3_ns, t4_ns;

  function new(string name = "ptp_exchange_sequence");
    super.new(name);
  endfunction

  virtual task body();
    ahb_reg_write_sequence wr_seq;
    ahb_reg_read_sequence  rd_seq;
    bit [31:0] sec_lo, nsec;
    real diff_21, diff_43;

    // ---------------------------------------------------------------
    // Step 1: Master (A) sends SYNC message via PTP AHB
    // Writing to PTP address with msg_type=SYNC triggers hw_capture on A
    // ---------------------------------------------------------------
    wr_seq = ahb_reg_write_sequence::type_id::create("sync_msg");
    wr_seq.addr = {8'h0, PTP_MSG_SYNC};
    wr_seq.data = 32'h0000_0001;  // payload (SYNC marker)
    wr_seq.start(a_ptp_sqr);

    // ---------------------------------------------------------------
    // Step 2: Read t1 from PHC_A (HW capture timestamp)
    // ---------------------------------------------------------------
    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t1_sec");
    rd_seq.addr = PHC_REG_HW_CAP_SECONDS_LO;
    rd_seq.start(a_phc_sqr);
    sec_lo = rd_seq.rdata;

    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t1_nsec");
    rd_seq.addr = PHC_REG_HW_CAP_NANOSECONDS;
    rd_seq.start(a_phc_sqr);
    nsec = rd_seq.rdata;
    t1_ns = $itor(sec_lo) * 1.0e9 + $itor(nsec);

    // ---------------------------------------------------------------
    // Step 3: Read t2 from PHC_B (HW capture timestamp from received SYNC)
    // ---------------------------------------------------------------
    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t2_sec");
    rd_seq.addr = PHC_REG_HW_CAP_SECONDS_LO;
    rd_seq.start(b_phc_sqr);
    sec_lo = rd_seq.rdata;

    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t2_nsec");
    rd_seq.addr = PHC_REG_HW_CAP_NANOSECONDS;
    rd_seq.start(b_phc_sqr);
    nsec = rd_seq.rdata;
    t2_ns = $itor(sec_lo) * 1.0e9 + $itor(nsec);

    // ---------------------------------------------------------------
    // Step 4: Slave (B) sends DELAY_REQ via PTP AHB
    // Writing to PTP address with msg_type=DELAY_REQ triggers hw_capture on B
    // ---------------------------------------------------------------
    wr_seq = ahb_reg_write_sequence::type_id::create("delay_req_msg");
    wr_seq.addr = {8'h0, PTP_MSG_DELAY_REQ};
    wr_seq.data = 32'h0000_0002;  // payload (DELAY_REQ marker)
    wr_seq.start(b_ptp_sqr);

    // ---------------------------------------------------------------
    // Step 5: Read t3 from PHC_B (HW capture from DELAY_REQ send)
    // ---------------------------------------------------------------
    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t3_sec");
    rd_seq.addr = PHC_REG_HW_CAP_SECONDS_LO;
    rd_seq.start(b_phc_sqr);
    sec_lo = rd_seq.rdata;

    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t3_nsec");
    rd_seq.addr = PHC_REG_HW_CAP_NANOSECONDS;
    rd_seq.start(b_phc_sqr);
    nsec = rd_seq.rdata;
    t3_ns = $itor(sec_lo) * 1.0e9 + $itor(nsec);

    // ---------------------------------------------------------------
    // Step 6: Read t4 from PHC_A (HW capture from received DELAY_REQ)
    // ---------------------------------------------------------------
    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t4_sec");
    rd_seq.addr = PHC_REG_HW_CAP_SECONDS_LO;
    rd_seq.start(a_phc_sqr);
    sec_lo = rd_seq.rdata;

    rd_seq = ahb_reg_read_sequence::type_id::create("rd_t4_nsec");
    rd_seq.addr = PHC_REG_HW_CAP_NANOSECONDS;
    rd_seq.start(a_phc_sqr);
    nsec = rd_seq.rdata;
    t4_ns = $itor(sec_lo) * 1.0e9 + $itor(nsec);

    // ---------------------------------------------------------------
    // Compute offset and delay
    // ---------------------------------------------------------------
    diff_21 = t2_ns - t1_ns;
    diff_43 = t4_ns - t3_ns;

    offset_ns = (diff_21 - diff_43) / 2.0;
    delay_ns  = (diff_21 + diff_43) / 2.0;

    `uvm_info("PTP_EXCH", $sformatf(
      "t1=%.0f t2=%.0f t3=%.0f t4=%.0f => offset=%.3f ns, delay=%.3f ns",
      t1_ns, t2_ns, t3_ns, t4_ns, offset_ns, delay_ns), UVM_HIGH)
  endtask

endclass

`endif // GUARD_PTP_EXCHANGE_SEQUENCE_SV
