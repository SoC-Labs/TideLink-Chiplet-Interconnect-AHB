///////////////////////////////////////////////////////////////////////////////
// top_sys_autoneg_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB-based auto-negotiation initialization sequence.
//
// Configures the negotiation registers on ONE side of the chiplet controller,
// then polls NEGO_STATUS until negotiation completes (nego_done) or fails
// (nego_error).
//
// The caller is responsible for running this sequence on both sides with
// appropriate priority values so that role arbitration can proceed.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_AUTONEG_SEQUENCE_SV
`define GUARD_TOP_SYS_AUTONEG_SEQUENCE_SV

class top_sys_autoneg_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_autoneg_sequence)

  string side_name = "?";

  // Negotiation parameters (set by caller before start)
  bit [31:0] priority_val  = 32'h0000_0001;
  bit [31:0] timeout_val   = 32'h0003_0D40;  // 200_000 cycles
  bit [31:0] i2c_prescale  = 32'h0000_0010;  // reasonable default
  bit        nego_en       = 1;
  bit [1:0]  pri_sel       = 2'b00;           // 0=register, 1=strap, 2=PUF
  bit        fallback_role = 1;               // 1=slave on timeout
  bit        force_lock    = 1;               // 1=auto-lock role after nego

  // Poll limits
  int unsigned max_poll_cycles = 500_000;
  int unsigned poll_interval   = 500;

  // Results (available after body completes)
  bit nego_done;
  bit nego_error;
  bit nego_won;
  bit nego_lost;
  bit [31:0] final_status;

  function new(string name = "top_sys_autoneg_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction wr_txn, rd_txn;
    bit [31:0] nego_cfg_val;
    int unsigned poll_count;

    `uvm_info("AUTONEG", $sformatf("[%s] Starting auto-negotiation sequence.", side_name), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Write NEGO_PRIORITY
    // ---------------------------------------------------------------
    `uvm_info("AUTONEG", $sformatf("[%s] Setting NEGO_PRIORITY = 0x%08h", side_name, priority_val), UVM_LOW)
    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2000 + REG_NEGO_PRIORITY[14:0];
    wr_txn.wdata = priority_val;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    // ---------------------------------------------------------------
    // Step 2: Write NEGO_TIMEOUT
    // ---------------------------------------------------------------
    `uvm_info("AUTONEG", $sformatf("[%s] Setting NEGO_TIMEOUT = 0x%08h", side_name, timeout_val), UVM_LOW)
    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2000 + REG_NEGO_TIMEOUT[14:0];
    wr_txn.wdata = timeout_val;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    // ---------------------------------------------------------------
    // Step 3: Write I2C_PRESCALE
    // ---------------------------------------------------------------
    `uvm_info("AUTONEG", $sformatf("[%s] Setting I2C_PRESCALE = 0x%08h", side_name, i2c_prescale), UVM_LOW)
    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2000 + REG_I2C_PRESCALE[14:0];
    wr_txn.wdata = i2c_prescale;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    // ---------------------------------------------------------------
    // Step 4: Write NEGO_CFG (enables negotiation)
    // ---------------------------------------------------------------
    nego_cfg_val = {24'b0,
                    1'b0,            // [7] reserved
                    1'b0,            // [6] reserved
                    1'b0,            // [5] reserved
                    force_lock,      // [4] force_lock
                    fallback_role,   // [3] fallback
                    pri_sel,         // [2:1] pri_sel
                    nego_en};        // [0] nego_en

    `uvm_info("AUTONEG", $sformatf("[%s] Setting NEGO_CFG = 0x%08h (nego_en=%0b, pri_sel=%0b, fallback=%0b, force_lock=%0b)",
      side_name, nego_cfg_val, nego_en, pri_sel, fallback_role, force_lock), UVM_LOW)
    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2000 + REG_NEGO_CFG[14:0];
    wr_txn.wdata = nego_cfg_val;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    // ---------------------------------------------------------------
    // Step 5: Poll NEGO_STATUS until done or error
    // ---------------------------------------------------------------
    `uvm_info("AUTONEG", $sformatf("[%s] Polling NEGO_STATUS...", side_name), UVM_LOW)

    nego_done  = 0;
    nego_error = 0;
    poll_count = 0;

    while (!nego_done && !nego_error && (poll_count < max_poll_cycles)) begin
      // Wait between polls
      repeat (poll_interval) @(posedge p_sequencer.vif.pclk);

      `uvm_create(rd_txn)
      rd_txn.addr  = 15'h2000 + REG_NEGO_STATUS[14:0];
      rd_txn.write = 0;
      `uvm_send(rd_txn)

      final_status = rd_txn.rdata;
      nego_done    = final_status[NEGO_STATUS_DONE];
      nego_error   = final_status[NEGO_STATUS_ERROR];
      nego_won     = final_status[NEGO_STATUS_WON];
      nego_lost    = final_status[NEGO_STATUS_LOST];

      poll_count += poll_interval;
    end

    if (nego_done) begin
      `uvm_info("AUTONEG", $sformatf("[%s] Negotiation complete. STATUS=0x%08h won=%0b lost=%0b",
        side_name, final_status, nego_won, nego_lost), UVM_LOW)
    end else if (nego_error) begin
      `uvm_info("AUTONEG", $sformatf("[%s] Negotiation error/timeout. STATUS=0x%08h",
        side_name, final_status), UVM_LOW)
    end else begin
      `uvm_error("AUTONEG", $sformatf("[%s] Negotiation poll timed out after %0d cycles. STATUS=0x%08h",
        side_name, max_poll_cycles, final_status))
    end
  endtask

endclass

`endif // GUARD_TOP_SYS_AUTONEG_SEQUENCE_SV
