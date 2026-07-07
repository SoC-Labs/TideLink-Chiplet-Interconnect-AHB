// ---------------------------------------------------------------------------
// tb_cdc_tear.sv  --  silicon-FAITHFUL CDC-tear reproduction bench for the
// TideLink a2l/l2a replay-FIFO ACK-pointer mailbox self-heal bug class.
//
// WHAT THIS REPRODUCES
// --------------------
// The campaign's single biggest fidelity gap: die_b's RX replay buffer
// (WlinkGenericFCReplayV2_12 / _13) false-FULLs after ~6 words on silicon and
// drops A->B data.  Root cause: the synced ACK pointer lives in a 2-deep
// ping-pong mailbox (WavMultibitSync_18) whose app-clk accumulator register
// (WlinkGenericFCReplayAddrSync_18.raddr) is only re-latched when the mailbox
// PUSHES a new value.  The push-enable  w_inc  is EDGE-TRIGGERED:
//
//     assign link_addr_to_app_clk_w_inc = a2l_link_addr != a2l_link_addr_in;
//
// so the mailbox only ever pushes when the *link-domain* ACK pointer CHANGES.
// Once the ACK stream goes quiescent (steady state after a burst) a single
// metastable multibit mis-capture of the 5-bit synced ACK pointer NEVER heals:
// no new ACK => w_inc stays 0 => no push => raddr keeps the torn value forever.
// If the torn value happens to sit a lap ahead of the write pointer,
//     a2l_full = (wptr[4] != ack[4]) & (wptr[3:0] == ack[3:0])
// latches 1 => app_ready=0 => winc(FIFO write) never fires => data dropped.
//
// THE FIX under test is  w_inc = 1'b1  (continuous resend / self-heal): the
// mailbox re-pushes the *current* (correct) a2l_link_addr every handshake, so
// even a torn capture is overwritten within a couple of link clocks.
//
// WHY A PLAIN RTL SIM CANNOT SEE THIS
// -----------------------------------
// A coherent RTL sim latches the whole 5-bit pointer atomically through the
// mailbox; it never produces the multibit metastable tear the silicon does.
// So both the edge-triggered (unfixed) and the w_inc=1 (fixed) RTL pass an
// idealized sim identically.  To turn the bug class into a red check we INJECT
// the one event RTL sim can't generate -- a one-shot torn capture of the
// synced ACK register -- via a SIM-ONLY hierarchical force (NOT synthesizable),
// then observe whether the RTL self-heals.  Edge-triggered => stuck => FAIL;
// w_inc=1 => heals => PASS.
//
// SIM-ONLY HOOKS (all driven from cocotb top-level ports; NONE synthesizable)
//   tear_arm / tear_val : while tear_arm=1 the synced-ACK accumulator register
//                         u_dut.link_addr_to_app_clk.raddr is FORCED to tear_val
//                         (models a multibit metastable mis-capture).  Dropping
//                         tear_arm RELEASEs the register so the RTL governs it
//                         again -- and the register RETAINS the torn value until
//                         the RTL next writes it (which only happens if the
//                         mailbox re-pushes: the self-heal we are testing).
//   winc_force1         : while 1, FORCE the mailbox push-enable
//                         u_dut.link_addr_to_app_clk_w_inc = 1'b1.  This MODELS
//                         the RTL fix (assign ... w_inc = 1'b1;) WITHOUT editing
//                         the read-only deps module or the production override,
//                         so the same test binary proves BOTH polarities.
//
// The DUT itself (WlinkGenericFCReplayV2_13) is the REAL production module,
// selected between the local_override and the pristine deps source by the
// Makefile -- both currently ship the edge-triggered w_inc, so both FAIL the
// tear test unless winc_force1 models the fix.  Only the common 18 ports are
// connected so the identical bench compiles against deps (which lacks the
// override's read-only obs_* fan-out ports).
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_cdc_tear (
    // Clocks (driven by cocotb) -- INDEPENDENT app_clk and link_clk
    input  logic        app_clk,
    input  logic        link_clk,

    // Independently controllable resets (active HIGH, like the DUT)
    input  logic        app_reset,
    input  logic        link_reset,

    // App-side (write) interface
    input  logic        app_enable,
    input  logic [47:0] app_data,
    input  logic        app_valid,
    output logic        app_ready,

    // Link-side (read/ack/revert) interface
    input  logic        link_ack_update,
    input  logic [4:0]  link_ack_addr,
    input  logic        link_revert,
    input  logic [4:0]  link_revert_addr,
    input  logic        link_advance,
    output logic [4:0]  link_cur_addr,
    output logic [47:0] link_data,
    output logic        link_valid,
    output logic        link_empty,

    // ── SIM-ONLY control ports (NOT part of the DUT) ──────────────────────
    input  logic        tear_arm,      // 1 => force synced-ACK reg to tear_val
    input  logic [4:0]  tear_val,      // torn value to inject
    input  logic        winc_force1,   // 1 => model the w_inc=1 self-heal fix

    // ── Debug observables (top-level so cocotb reads them port-cleanly) ───
    output logic [4:0]  dbg_wbin_ptr,    // app-clk write bin ptr
    output logic [4:0]  dbg_synced_ack,  // ACK ptr synced into app_clk (raddr)
    output logic        dbg_a2l_full,    // the (false-)FULL flag
    output logic [4:0]  dbg_link_ack,    // link-domain ACK accumulator
    output logic        dbg_w_inc        // effective mailbox push-enable
);

    // ── The REAL production DUT (common 18 ports only) ────────────────────
    WlinkGenericFCReplayV2_13 u_dut (
        .app_clk          (app_clk),
        .app_reset        (app_reset),
        .app_enable       (app_enable),
        .app_data         (app_data),
        .app_valid        (app_valid),
        .app_ready        (app_ready),
        .link_clk         (link_clk),
        .link_reset       (link_reset),
        .link_ack_update  (link_ack_update),
        .link_ack_addr    (link_ack_addr),
        .link_revert      (link_revert),
        .link_revert_addr (link_revert_addr),
        .link_cur_addr    (link_cur_addr),
        .link_data        (link_data),
        .link_valid       (link_valid),
        .link_advance     (link_advance),
        .link_empty       (link_empty)
        // NOTE: the local_override adds read-only obs_* outputs; they are left
        //       unconnected here so the same bench compiles against deps too.
    );

    // ── Debug fan-out (read-only) ─────────────────────────────────────────
    assign dbg_wbin_ptr   = u_dut.fifo_io_wbin_ptr;
    assign dbg_synced_ack  = u_dut.a2l_link_addr_app_clk;   // == raddr
    assign dbg_a2l_full    = u_dut.a2l_full;
    assign dbg_link_ack    = u_dut.a2l_link_addr;           // link-domain accum
    assign dbg_w_inc       = u_dut.link_addr_to_app_clk_w_inc;

    // ── SIM-ONLY: model the w_inc=1 self-heal fix by forcing the push-enable.
    //    Toggling winc_force1 force/releases the internal net.  This is a sim
    //    model of a one-line RTL change; it is NOT synthesized.
    always @(winc_force1) begin
        if (winc_force1)
            force u_dut.link_addr_to_app_clk_w_inc = 1'b1;
        else
            release u_dut.link_addr_to_app_clk_w_inc;
    end

    // ── SIM-ONLY: inject a torn multibit capture into the synced-ACK register.
    //    While tear_arm=1 the register tracks tear_val; releasing it leaves the
    //    torn value in place until the RTL next drives the register (self-heal).
    always @(tear_arm) begin
        if (tear_arm)
            force u_dut.link_addr_to_app_clk.raddr = tear_val;
        else
            release u_dut.link_addr_to_app_clk.raddr;
    end

    initial begin
        if ($test$plusargs("TL_DUMP")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_cdc_tear);
        end
    end

endmodule
