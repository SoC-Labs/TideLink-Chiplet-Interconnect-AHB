// -----------------------------------------------------------------------------
// fc_crc_contract_sva -- "CRC-detected must mean replayed" contract for every
// WlinkGenericFCSM* RX side (FCSM AW/W/B/AR/R = FCSM,_1.._4 and sideband _6).
//
// Verification-only. Never in a synthesis or ASIC flist. Bound from
// fc_crc_contract_bind.sv, which is compiled only with +define+TL_FC_SVA.
//
// Contract (E = exp_pkt_num at the cycle a CRC error is detected = the "hole"):
//   C1  exp_pkt_num stays at E until a CRC-clean data packet numbered E is accepted.
//   C2  While a CRC replay is outstanding no NACK enqueue is suppressed: a data packet
//       that is not the expected one must be enqueued (as a NACK) into ack_nack_fifo.
//       (L9b suppresses exactly this enqueue.)  Also: L9b re-anchor never fires, and
//       L9c never swallows the replay of E.
//   C3  No out-of-order commit: while E is outstanding, the only data packet committed
//       to the L2A path is E itself.
//   C4  Liveness: a CRC error leads to send_nack_req within NACK_MAX rx_clk cycles.
//   Cover (non-vacuity): crc seen / follower while pending / replay accepted /
//       follower-then-replay (the L9b trigger shape).
//
// CRC_MODE selects when the *strong* (state-free) form applies:
//   0  follow the node's disable_crc flop (default; correct for any runtime config)
//   1  CRC is always on (TL-018/019 ASIC overrides, AXI nodes CRC-on at reset):
//      the L9b/L9c L9 terms must NEVER fire at all
//   2  CRC-off regime: only the dynamic contract (which needs a detected error) runs
// HAS_L9 = 0 on nodes without the SoC Labs L9b/L9c logic (socl_* ports are tied 0).
//
// Counters + a final summary line are printed so a log grep can prove the checker
// was alive (TL_FC_SVA lines): "TL_FC_SVA SUMMARY <inst> fails=N crc=.. follower=.. replay=..".
// -----------------------------------------------------------------------------
// Simulation: failures bump a counter and print a greppable line. Formal (TL_FC_FORMAL):
// the assertion has no action block, so the proof tool sees a pure property.
`ifdef TL_FC_FORMAL
 `define FC_SVA_FAIL(ARGS) ;
`else
 `define FC_SVA_FAIL(ARGS) else begin n_fail++; $error ARGS ; end
`endif
module fc_crc_contract_sva #(
  parameter int NACK_MAX = 64,
  parameter bit HAS_L9   = 1'b0,
  parameter int CRC_MODE = 0,
  // WAIVER W1 (known, see docs/FORMAL.md): the SoC Labs L9 one-shot resync accepts the first
  // data packet after reset/app-enable whatever its number. A CRC error on THAT packet is not
  // covered by the contract (formal CEX depth 3; sim: test_sideband_hit_first_after_bringup,
  // outcome is eventually exact after a NACK/revert burst).  1 = waived (default, main stays
  // clean), 0 = strict (+define+TL_FC_SVA_STRICT_FIRST): the SVA reports it.
  parameter bit WAIVE_FIRST_DATA = 1'b1
) (
  input logic       clk,                    // io_rx_clk
  input logic       rst,                    // io_rx_reset (active high, async in DUT)
  input logic       app_enable_n,           // _fe_tx_credit_max_in_T: ~app enable => exp_pkt_num re-zeroed
  input logic       first_data_seen,        // socl_l9_first_data_seen_rx (tie 1 on nodes without the L9 resync)
  input logic       disable_crc,            // out_prepend_swi_disable_crc (1 = receiver does not check CRC)
  input logic       valid_rx_pkt_crc_err,
  input logic       pkt_is_data_pkt,
  input logic [7:0] ll_rx_pktnum,
  input logic [7:0] exp_pkt_num,
  input logic       exp_pkt_not_seen,
  input logic       send_nack_req,
  input logic       commit,                 // l2a_fc_replay_app_valid
  input logic       nack_enq,               // ack_nack_fifo_io_winc
  input logic       socl_l9b_reanchor_now,  // tie 0 when !HAS_L9
  input logic       socl_l9c_backward       // tie 0 when !HAS_L9
);
`ifdef TL_FC_SVA
  default clocking cb @(posedge clk); endclocking
  wire clr = rst | app_enable_n;            // model state is dropped when the DUT re-zeros
  default disable iff (clr);

  wire crc_checked = (CRC_MODE == 1) || (CRC_MODE == 0 && !disable_crc);

  // ---- outstanding-error tracker (model state) ------------------------------
  logic       pend_q;
  logic [7:0] hole_q;
  wire        ok_replay_q = pkt_is_data_pkt && (ll_rx_pktnum == hole_q);
  // "effective" view includes the error cycle itself (no one-cycle blind spot)
  wire        arm  = valid_rx_pkt_crc_err && (first_data_seen || !WAIVE_FIRST_DATA);
  wire        pend = pend_q || arm;
  wire [7:0]  hole = pend_q ? hole_q : exp_pkt_num;
  wire        ok_replay = pkt_is_data_pkt && (ll_rx_pktnum == hole);

  always_ff @(posedge clk or posedge clr) begin
    if (clr) begin pend_q <= 1'b0; hole_q <= '0; end
    else if (!pend_q && arm) begin pend_q <= 1'b1; hole_q <= exp_pkt_num; end
    else if (pend_q && ok_replay_q)           pend_q <= 1'b0;
  end

`ifndef TL_FC_FORMAL
  int unsigned n_fail, n_crc, n_follower, n_replay, n_follow_replay, n_waived;
  initial begin n_waived = 0; n_fail = 0; n_crc = 0; n_follower = 0; n_replay = 0; n_follow_replay = 0; end
`endif

  // C1: expected number frozen on the hole until its replay is accepted.
  a_c1_exp_frozen: assert property (pend && !ok_replay |=> exp_pkt_num == hole)
    `FC_SVA_FAIL(("TL_FC_SVA FAIL C1 %m: exp_pkt_num advanced past CRC-dropped packet %0d before its replay", hole))

  // C2: no NACK-enqueue suppression while the replay is outstanding.
  a_c2_nack_enq: assert property (pend && exp_pkt_not_seen |-> nack_enq)
    `FC_SVA_FAIL(("TL_FC_SVA FAIL C2 %m: NACK enqueue suppressed with CRC replay outstanding"))
  if (HAS_L9) begin : g_l9
    a_c2_no_reanchor: assert property (pend |-> !socl_l9b_reanchor_now)
      `FC_SVA_FAIL(("TL_FC_SVA FAIL C2a %m: L9b forward re-anchor fired with CRC replay outstanding"))
    a_c2_no_l9c_on_replay: assert property (pend && pkt_is_data_pkt && ll_rx_pktnum == hole |-> !socl_l9c_backward)
      `FC_SVA_FAIL(("TL_FC_SVA FAIL C2b %m: L9c dropped the replay of the CRC-corrupted packet"))
    // Strong form: with the receiver CRC-checking, L9b/L9c are dead code by design (TL-059).
    a_c2_l9_dead_when_crc: assert property (crc_checked |-> !socl_l9b_reanchor_now && !socl_l9c_backward)
      `FC_SVA_FAIL(("TL_FC_SVA FAIL C2c %m: L9b/L9c active while CRC checking is on"))
  end

  // C3a: no out-of-order commit past the hole.
  a_c3_no_commit_past_hole: assert property (pend && commit |-> ok_replay)
    `FC_SVA_FAIL(("TL_FC_SVA FAIL C3 %m: commit of a packet other than the replay (%0d != hole %0d)", ll_rx_pktnum, hole))

`ifndef TL_FC_FORMAL_SKIP_C4   // needs TX-side fairness; sim-only unless the env provides it (docs/FORMAL.md)
  // C4: detection leads to a NACK within the bound.
  a_c4_nack_issued: assert property (valid_rx_pkt_crc_err |-> ##[0:NACK_MAX] send_nack_req)
    `FC_SVA_FAIL(("TL_FC_SVA FAIL C4 %m: CRC error not followed by send_nack_req within %0d cycles", NACK_MAX))
`endif

  // ---- covers: the proofs/sims are vacuous unless these are reached ---------
  c_crc_seen:  cover property (valid_rx_pkt_crc_err);
  c_waived_first_data_crc: cover property (valid_rx_pkt_crc_err && !first_data_seen);
  c_follower:  cover property (pend ##[1:$] (pkt_is_data_pkt && ll_rx_pktnum != hole));
  c_replay_ok: cover property (pend ##[1:$] ok_replay ##1 !pend_q);
  c_follower_then_replay: cover property
               (pend ##[1:$] (pkt_is_data_pkt && ll_rx_pktnum != hole) ##[1:$] ok_replay);

`ifndef TL_FC_FORMAL
  // plain counters (independent of the simulator's cover bookkeeping)
  logic saw_follower;
  always @(posedge clk) begin
    if (!clr) begin
      if (valid_rx_pkt_crc_err) n_crc++;
      if (valid_rx_pkt_crc_err && !first_data_seen) n_waived++;
      if (pend_q && pkt_is_data_pkt && ll_rx_pktnum != hole_q) begin n_follower++; saw_follower <= 1'b1; end
      if (pend_q && ok_replay_q) begin n_replay++; if (saw_follower) n_follow_replay++; saw_follower <= 1'b0; end
    end else saw_follower <= 1'b0;
  end
  initial saw_follower = 1'b0;

  final $display("TL_FC_SVA SUMMARY %m fails=%0d crc=%0d follower=%0d replay=%0d follower_then_replay=%0d waived_first_data=%0d crc_mode=%0d has_l9=%0d",
                 n_fail, n_crc, n_follower, n_replay, n_follow_replay, n_waived, CRC_MODE, HAS_L9);
`endif // !TL_FC_FORMAL
`endif
endmodule
