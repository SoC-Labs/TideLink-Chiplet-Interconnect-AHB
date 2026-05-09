///////////////////////////////////////////////////////////////////////////////
// test_top_autoneg_basic.sv — Auto-negotiation basic role resolution
///////////////////////////////////////////////////////////////////////////////
// Runs auto-negotiation on both sides with different priorities:
//   Side A: priority = 0x0001 (low = wins master)
//   Side B: priority = 0x1000 (high = becomes slave)
// After negotiation, verifies correct role assignment, initializes TideLink,
// and sends a packet A->B.
///////////////////////////////////////////////////////////////////////////////

`ifndef GUARD_TEST_TOP_AUTONEG_BASIC_SV
`define GUARD_TEST_TOP_AUTONEG_BASIC_SV

class test_top_autoneg_basic extends tidelink_top_system_base_test;

  `uvm_component_utils(test_top_autoneg_basic)

  function new(string name = "test_top_autoneg_basic", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual task main_phase(uvm_phase phase);
    top_sys_autoneg_sequence a_autoneg, b_autoneg;
    bit [31:0] read_data[];
    bit [31:0] pkt_data[];

    phase.raise_objection(this);
    timeout_watchdog(phase);

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Basic ===", UVM_LOW)

    // ---------------------------------------------------------------
    // Step 1: Run auto-negotiation on both sides (fork/join)
    // ---------------------------------------------------------------
    `uvm_info("TEST", "Starting auto-negotiation on both sides...", UVM_LOW)

    a_autoneg = top_sys_autoneg_sequence::type_id::create("a_autoneg");
    a_autoneg.side_name    = "A";
    a_autoneg.priority_val = 32'h0000_0001;  // low priority -> wins master
    a_autoneg.force_lock   = 1;

    b_autoneg = top_sys_autoneg_sequence::type_id::create("b_autoneg");
    b_autoneg.side_name    = "B";
    b_autoneg.priority_val = 32'h0000_1000;  // high priority -> becomes slave
    b_autoneg.force_lock   = 1;

    fork
      a_autoneg.start(env.a_apb_agt.sequencer);
      b_autoneg.start(env.b_apb_agt.sequencer);
    join

    // ---------------------------------------------------------------
    // Step 2: Verify negotiation outcome
    // ---------------------------------------------------------------
    if (!a_autoneg.nego_done)
      `uvm_error("TEST", "[A] Negotiation did not complete successfully")

    if (!b_autoneg.nego_done)
      `uvm_error("TEST", "[B] Negotiation did not complete successfully")

    if (!a_autoneg.nego_won)
      `uvm_error("TEST", "[A] Expected to win negotiation (lower priority) but did not")

    if (!b_autoneg.nego_lost)
      `uvm_error("TEST", "[B] Expected to lose negotiation (higher priority) but did not")

    `uvm_info("TEST", $sformatf("Side A: won=%0b lost=%0b | Side B: won=%0b lost=%0b",
      a_autoneg.nego_won, a_autoneg.nego_lost,
      b_autoneg.nego_won, b_autoneg.nego_lost), UVM_LOW)

    // ---------------------------------------------------------------
    // Step 3: Write swi_phase_offset on the side that won master.
    // Master's POR releases later than slave's (autoneg arbitration:
    // master locks last). Per PROBE_GPIO_COUNT histogram, master's RX
    // counter is 11 ticks ahead of slave's TX counter (mod 16) when the
    // first bits arrive ⇒ slide A's sample point back by setting
    // swi_phase_offset = (16 - 11) % 16 = 5. Slave's RX counter is
    // already aligned because slave was waiting for master's pad_clk_rx,
    // which only starts at master's POR release — so slave samples from
    // its very first pad_clk and naturally aligns to count=0.
    //
    // ORDER MATTERS: write phase IMMEDIATELY after autoneg completes,
    // BEFORE the link-train wait. Once the deserialiser locks at the
    // wrong phase, subsequent swi_phase_offset writes only shift the
    // bit-select — they don't re-sync the counter. PHY ctrl reg
    // WL+0x0000 bits[20:17] = swi_phase_offset.
    begin
      integration_cfg_write_sequence phase_wr;
      phase_wr = integration_cfg_write_sequence::type_id::create("phase_wr");
      phase_wr.addr = 15'h0000;
      phase_wr.data = 32'h000A_0000;  // bits[20:17] = 4'h5
      phase_wr.start(env.a_apb_agt.sequencer);
      `uvm_info("TEST", "[A] phase_offset=5 written (master, late POR) — pre link-train",
                UVM_LOW)
      // B keeps phase=0 (default) — already aligned.
    end

    // ---------------------------------------------------------------
    // Step 4: Wait for Wlink link training
    // ---------------------------------------------------------------
    // 50000 cycles (5x default) — A's role_lock asserts ~13ms after B's
    // (B sees SDA-START first; A finishes its claim/POLL later), so by
    // the time A's Wlink leaves POR, B's Wlink has been driving alone
    // for ms-scale time. Give the resync handshake plenty of slack.
    `uvm_info("TEST", "Waiting for Wlink link-up after role lock...", UVM_LOW)
    repeat (wlink_link_up_wait) @(posedge tb_if.clk);
    `uvm_info("TEST", "Wlink link-up complete.", UVM_LOW)

    // Diag: read ROLE_CFG and Wlink link_status / link_capabilities on
    // both sides. Use raw integration_cfg_read_sequence calls so we can
    // hit Wlink space (0x0xxx) and chiplet-controller space (0x2xxx)
    // alike — the base read_cfg_reg helper only addresses 0x2xxx.
    begin
      integration_cfg_read_sequence rd;
      bit [31:0] role_a, role_b, status_a, status_b, capab_a, capab_b;
      bit [14:0] addrs[$] = '{15'h2080, 15'h0234, 15'h0200};
      bit [31:0] vals_a[3], vals_b[3];
      foreach (addrs[i]) begin
        rd = integration_cfg_read_sequence::type_id::create("rd");
        rd.addr = addrs[i];
        rd.start(env.a_apb_agt.sequencer);
        vals_a[i] = rd.rdata;

        rd = integration_cfg_read_sequence::type_id::create("rd");
        rd.addr = addrs[i];
        rd.start(env.b_apb_agt.sequencer);
        vals_b[i] = rd.rdata;
      end
      `uvm_info("TEST", $sformatf(
        "DIAG ROLE_CFG: A=0x%08h B=0x%08h | link_status: A=0x%08h B=0x%08h | link_capab: A=0x%08h B=0x%08h",
        vals_a[0], vals_b[0], vals_a[1], vals_b[1], vals_a[2], vals_b[2]), UVM_LOW)
    end

    // ---------------------------------------------------------------
    // Step 4: Initialize TideLink (pair base, credits, doorbell)
    // ---------------------------------------------------------------
    init_both_sides();

    // ---------------------------------------------------------------
    // Step 5: Send packet A->B and verify
    // ---------------------------------------------------------------
    pkt_data = new[4];
    pkt_data[0] = 32'hDEAD_BEEF;
    pkt_data[1] = 32'hCAFE_BABE;
    pkt_data[2] = 32'h1234_5678;
    pkt_data[3] = 32'h9ABC_DEF0;
    write_packet(SIDE_A, pkt_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    read_packet(SIDE_B, 4, read_data);

    repeat (phy_transit_wait) @(posedge tb_if.clk);

    env.sb.compare_a2b_data();

    `uvm_info("TEST", "=== Test Top Auto-Negotiation Basic COMPLETE ===", UVM_LOW)

    repeat (20) @(posedge tb_if.clk);
    phase.drop_objection(this);
  endtask

endclass

`endif // GUARD_TEST_TOP_AUTONEG_BASIC_SV
