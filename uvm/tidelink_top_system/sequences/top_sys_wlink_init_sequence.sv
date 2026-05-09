///////////////////////////////////////////////////////////////////////////////
// top_sys_wlink_init_sequence.sv
///////////////////////////////////////////////////////////////////////////////
// APB-based Wlink chiplet controller initialization sequence.
//
// Writes ROLE_CFG (offset 0x2080) with the per-side role and the lock bit:
//   bit[0] = role (0=master, 1=slave) — OVERRIDES the strap when locked
//   bit[1] = role_lock (W1S) — releases Wlink from POR
//
// IMPORTANT: bit[0] overrides the strap. Writing 0x02 ("accept strap default")
// is misleading — it actually FORCES role=master (0) regardless of strap.
// Each side must write its intended role explicitly. Setting both sides to
// master (the prior bug) leaves the link with no slave to grant credits, so
// the FC adapter stalls when traffic starts.
//
// Set `is_slave = 1` on the slave side before starting the sequence; default
// is_slave = 0 (master).
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
`define GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV

class top_sys_wlink_init_sequence extends uvm_sequence #(apb_master_transaction);

  `uvm_object_utils(top_sys_wlink_init_sequence)

  string side_name = "?";
  bit    is_slave  = 0;  // 0=master (default), 1=slave

  function new(string name = "top_sys_wlink_init_sequence");
    super.new(name);
  endfunction

  virtual task body();
    apb_master_transaction wr_txn;
    bit [31:0] role_cfg_value;
    bit [31:0] phy_ctrl_value;

    // bit[1]=lock, bit[0]=role override (0=master, 1=slave)
    role_cfg_value = is_slave ? 32'h0000_0003 : 32'h0000_0002;

    `uvm_info("WLINK_INIT", $sformatf(
      "[%s] Locking chiplet controller role (role=%s, ROLE_CFG=0x%08h).",
      side_name, is_slave ? "slave" : "master", role_cfg_value), UVM_LOW)

    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h2080;  // ROLE_CFG
    wr_txn.wdata = role_cfg_value;
    wr_txn.write = 1;
    `uvm_send(wr_txn)

    // SoC Labs (2026-05-08) SHORTCOMINGS-14b fix: AFTER role_lock releases
    // Wlink from POR, set per-side `swi_phase_offset` (bits[20:17] of PHY
    // ctrl reg WL+0x0000) to compensate for asymmetric deserialiser counter
    // init. The phase compensates for POR-release skew: whichever side
    // releases POR LATER needs phase=Δ (mod 16) where Δ is the gap (in
    // pad_clks) between the two PoR releases.
    //
    // In strap-based init_wlink, A (master) goes first, B (slave) goes
    // second by ~60 ns ≈ 3 pad_clks ⇒ slave phase=3.
    // In autoneg-based init, the phase write is done by the test directly
    // (see test_top_autoneg_basic).
    phy_ctrl_value = 32'h0000_0000; // both sides phase=0 (small POR Δ in init_wlink path)
    `uvm_create(wr_txn)
    wr_txn.addr  = 15'h0000;
    wr_txn.wdata = phy_ctrl_value;
    wr_txn.write = 1;
    `uvm_send(wr_txn)
    `uvm_info("WLINK_INIT", $sformatf(
      "[%s] PHY ctrl phase_offset=%0d written post-lock.",
      side_name, (phy_ctrl_value >> 17) & 4'hF), UVM_LOW)

    `uvm_info("WLINK_INIT", $sformatf("[%s] Role locked. Wlink link training in progress.",
      side_name), UVM_LOW)
  endtask

endclass

`endif // GUARD_TOP_SYS_WLINK_INIT_SEQUENCE_SV
