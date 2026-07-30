// -----------------------------------------------------------------------------
// TideLink forwarded-clock winscan / calibrator observability (silicon item I1)
//
// PURPOSE (I1 FCSM bring-up regression):
//   The I1 recovery-FCSM override breaks KR260 eth-chiplet bring-up with the
//   signature SWI_LANE_STATUS=0x00100000 (cal_done=0, fcsm=0, cr_seen=0) on both
//   dies, while the deps FCSM brings up (cal_done=1, fcsm=4). The leading
//   mechanism is that the override's added flop footprint (~51 flops in the
//   CR-capture region) perturbs the RUNTIME-calibrated forwarded-clock capture
//   phase, so the alignment calibrator's winscan (tidelink_phy_align_calibrator)
//   never finds a locking window -> cal_done never asserts -> the FCSM never
//   runs. cal_done is UPSTREAM of the FCSM: if cal_done=0 the FC emit/grant path
//   is moot. This block lets SW READ, over the PS backdoor, WHETHER the winscan
//   locked and WHERE it is stuck / with what eye — to CONFIRM or REFUTE the
//   capture-phase-shift hypothesis directly on silicon.
//
// WHAT IT TAPS (all pure fan-out reads of existing calibrator FSM registers that
// already surface at the chiplet-controller scope — it drives NOTHING back into
// the datapath, so it is behaviourally inert and cannot move the 0x00100000
// signature it observes):
//   * cal_state[3:0]  — the calibrator FSM state (S_IDLE..S_VALIDATE). In the
//                       failing "never locks" case the FSM THRASHES
//                       S_ARM->S_PROBE->S_SWEEP->S_FINALIZE->S_FINISH->S_ARM
//                       forever (retry_exhausted is hardwired 0 at MAX_RESWEEPS=0)
//                       and NEVER reaches S_HOLD/S_VALIDATE/S_DONE.
//   * cal_done / cal_val_timeout / cal_in_hold / cal_training_mode
//   * lane_fault[7:0] — per-lane "never found a locking window" (sticky in cal)
//   * lane_locked[7:0]— live per-lane training-pattern capture (the direct
//                       "is the forwarded-clock capture working at all" oracle)
//   * eye_best_run/phase/slip/passed — the SWI_EYE_LANE_SEL lane's matched-window
//                       WIDTH and its start (slip,phase) — the eye result.
//
// FOOTPRINT / "measurement must not perturb the measurement":
//   The bug's footprint sensitivity is in the rx-link-clk CR-capture region.
//   This block adds ZERO flops in that domain: every tap is a combinational read
//   of a register that already exists, and ALL detection + stickiness runs in the
//   apb_clk (register-read) domain AFTER a 2-flop synchroniser. On silicon
//   apb_clk (~50-100 MHz) is 30-60x FASTER than the calibrator's rx_link_clk
//   (pad_clk/16 ~= 1.5 MHz), so apb over-samples the slow FSM many times per
//   source cycle — the apb-domain "ever reached state X" stickies cannot miss
//   even a single-source-cycle state. A 2-sample stability guard on the CDC'd
//   state suppresses spurious "visited" bits from an incoherent multi-bit sample.
//   Net: no added load on the phase-critical capture path.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
// -----------------------------------------------------------------------------
`default_nettype none

module tidelink_winscan_obs (
    input  wire        apb_clk,   // register-read clock (obs output + detect domain)
    input  wire        resetn,    // active-low, synchronous-deassert async-assert

    // -- Calibrator taps (rx_link_clk domain, combinational reads) -----------
    // Encoded per tidelink_phy_align_calibrator_v2.sv typedef state_t:
    //   0 S_IDLE  1 S_ARM  2 S_SWEEP  3 S_FINISH  4 S_DONE  5 S_CANCEL
    //   6 S_HOLD  7 S_PROBE 8 S_FINALIZE 9 S_VALIDATE
    input  wire [3:0]  cal_state,          // <- cal_state_w
    input  wire        cal_done,           // <- cal_calibration_done_w  (== state S_DONE)
    input  wire        cal_val_timeout,    // <- calibrator validation_timed_out (sticky give-up)
    input  wire        cal_in_hold,        // <- cal_in_hold_w  (S_HOLD|S_VALIDATE|S_DONE)
    input  wire        cal_training_mode,  // <- cal_training_mode_w
    input  wire [7:0]  lane_fault,         // <- cal_lane_fault_w  (1=lane never found a window)
    input  wire [7:0]  lane_locked,        // <- lane_locked_w     (1=lane capturing training now)

    // Selected-lane eye read surface (SWI_EYE_LANE_SEL picks the lane)
    input  wire [2:0]  eye_lane_sel,       // <- eye_lane_sel_eff
    input  wire        eye_lane_passed,    // <- cal_eye_lane_passed_w (best_run >= LOCK_THRESH)
    input  wire [2:0]  eye_best_slip,      // <- cal_eye_best_slip_w
    input  wire [3:0]  eye_best_phase,     // <- cal_eye_best_phase_w
    input  wire [5:0]  eye_best_run,       // <- cal_eye_best_w  (matched-window WIDTH, taps)

    // -- Packed observability words (apb_clk domain) -------------------------
    // WINSCAN_STAT (0x2E03_21E4):
    //   [ 3:0] cal_state          resting FSM state (see encoding above)
    //   [ 4]   cal_done           1 = reached S_DONE (calibration_done)
    //   [ 5]   cal_val_timeout    1 = S_DONE reached via a validation give-up
    //   [ 6]   cal_in_hold        1 = FSM in S_HOLD|S_VALIDATE|S_DONE now
    //   [ 7]   cal_training_mode  1 = calibrator driving TX training pattern
    //   [ 8]   ever_swept         sticky: cal_state ever == S_SWEEP(2)
    //   [ 9]   ever_hold          sticky: cal_state ever == S_HOLD(6)
    //   [10]   ever_validate      sticky: cal_state ever == S_VALIDATE(9)
    //   [11]   ever_done          sticky: cal_state ever == S_DONE(4)
    //   [12]   any_lane_locked    |lane_locked  (some lane capturing now)
    //   [13]   all_lane_fault     &lane_fault   (winscan failed on ALL 8 lanes)
    //   [15:14] 0
    //   [23:16] lane_fault[7:0]
    //   [31:24] 0xC5 presence marker
    output wire [31:0] obs_winscan_stat,
    // WINSCAN_EYE (0x2E03_21E8):
    //   [ 5:0] eye_best_run[5:0]   matched-window WIDTH of selected lane (taps)
    //   [ 9:6] eye_best_phase[3:0] run start phase of selected lane
    //   [12:10] eye_best_slip[2:0] run slip of selected lane
    //   [13]   eye_lane_passed     best_run >= LOCK_THRESH for selected lane
    //   [16:14] eye_lane_sel[2:0]  which lane the eye fields above describe
    //   [17]   0
    //   [25:18] lane_locked[7:0]   live per-lane capture
    //   [31:26] 6'h25 presence marker
    output wire [31:0] obs_winscan_eye
);

    localparam [3:0] ST_SWEEP    = 4'd2;
    localparam [3:0] ST_DONE     = 4'd4;
    localparam [3:0] ST_HOLD     = 4'd6;
    localparam [3:0] ST_VALIDATE = 4'd9;

    // -- 2-flop CDC of the quasi-static calibrator fields into apb_clk --------
    // Same accepted treatment as the pre-existing sync_lane_locked / sync_eye_width
    // probes in axi_chiplet_controller.sv: the fields change on the (much slower)
    // rx_link_clk, so a rare incoherent multi-bit sample self-corrects next apb
    // cycle. The "visited" stickies below are additionally stability-guarded.
    reg  [3:0] state_s0, state_s1, state_s2;
    reg        done_s0,  done_s1;
    reg        valto_s0, valto_s1;
    reg        hold_s0,  hold_s1;
    reg        train_s0, train_s1;
    reg  [7:0] fault_s0, fault_s1;
    reg  [7:0] lock_s0,  lock_s1;
    reg  [2:0] esel_s0,  esel_s1;
    reg        epass_s0, epass_s1;
    reg  [2:0] eslip_s0, eslip_s1;
    reg  [3:0] ephase_s0,ephase_s1;
    reg  [5:0] erun_s0,  erun_s1;

    // apb-domain sticky "ever reached state X" witnesses
    reg        ever_swept_q, ever_hold_q, ever_validate_q, ever_done_q;

    // state considered valid for the visited-OR only when it has been stable for
    // two consecutive apb samples (suppresses a spurious visited bit from an
    // incoherent 4-bit CDC snapshot taken mid-transition).
    wire state_stable = (state_s1 == state_s2);

    always_ff @(posedge apb_clk or negedge resetn) begin
        if (!resetn) begin
            state_s0 <= 4'd0; state_s1 <= 4'd0; state_s2 <= 4'd0;
            done_s0  <= 1'b0; done_s1  <= 1'b0;
            valto_s0 <= 1'b0; valto_s1 <= 1'b0;
            hold_s0  <= 1'b0; hold_s1  <= 1'b0;
            train_s0 <= 1'b0; train_s1 <= 1'b0;
            fault_s0 <= 8'h0; fault_s1 <= 8'h0;
            lock_s0  <= 8'h0; lock_s1  <= 8'h0;
            esel_s0  <= 3'h0; esel_s1  <= 3'h0;
            epass_s0 <= 1'b0; epass_s1 <= 1'b0;
            eslip_s0 <= 3'h0; eslip_s1 <= 3'h0;
            ephase_s0<= 4'h0; ephase_s1<= 4'h0;
            erun_s0  <= 6'h0; erun_s1  <= 6'h0;
            ever_swept_q <= 1'b0; ever_hold_q <= 1'b0;
            ever_validate_q <= 1'b0; ever_done_q <= 1'b0;
        end else begin
            state_s0 <= cal_state;         state_s1 <= state_s0; state_s2 <= state_s1;
            done_s0  <= cal_done;          done_s1  <= done_s0;
            valto_s0 <= cal_val_timeout;   valto_s1 <= valto_s0;
            hold_s0  <= cal_in_hold;       hold_s1  <= hold_s0;
            train_s0 <= cal_training_mode; train_s1 <= train_s0;
            fault_s0 <= lane_fault;        fault_s1 <= fault_s0;
            lock_s0  <= lane_locked;       lock_s1  <= lock_s0;
            esel_s0  <= eye_lane_sel;      esel_s1  <= esel_s0;
            epass_s0 <= eye_lane_passed;   epass_s1 <= epass_s0;
            eslip_s0 <= eye_best_slip;     eslip_s1 <= eslip_s0;
            ephase_s0<= eye_best_phase;    ephase_s1<= ephase_s0;
            erun_s0  <= eye_best_run;      erun_s1  <= erun_s0;

            // Sticky visited witnesses (idempotent OR; survive until reset).
            if (state_stable && (state_s1 == ST_SWEEP))    ever_swept_q    <= 1'b1;
            if (state_stable && (state_s1 == ST_HOLD))     ever_hold_q     <= 1'b1;
            if (state_stable && (state_s1 == ST_VALIDATE)) ever_validate_q <= 1'b1;
            if ((state_stable && (state_s1 == ST_DONE)) || done_s1)
                                                           ever_done_q     <= 1'b1;
        end
    end

    wire any_lane_locked = |lock_s1;
    wire all_lane_fault  = &fault_s1;

    // -- Field-by-field packing (unambiguous bit positions) ------------------
    wire [31:0] winscan_stat_w;
    assign winscan_stat_w[ 3: 0] = state_s1;
    assign winscan_stat_w[ 4]    = done_s1;
    assign winscan_stat_w[ 5]    = valto_s1;
    assign winscan_stat_w[ 6]    = hold_s1;
    assign winscan_stat_w[ 7]    = train_s1;
    assign winscan_stat_w[ 8]    = ever_swept_q;
    assign winscan_stat_w[ 9]    = ever_hold_q;
    assign winscan_stat_w[10]    = ever_validate_q;
    assign winscan_stat_w[11]    = ever_done_q;
    assign winscan_stat_w[12]    = any_lane_locked;
    assign winscan_stat_w[13]    = all_lane_fault;
    assign winscan_stat_w[15:14] = 2'b00;
    assign winscan_stat_w[23:16] = fault_s1;
    assign winscan_stat_w[31:24] = 8'hC5;

    wire [31:0] winscan_eye_w;
    assign winscan_eye_w[ 5: 0] = erun_s1;
    assign winscan_eye_w[ 9: 6] = ephase_s1;
    assign winscan_eye_w[12:10] = eslip_s1;
    assign winscan_eye_w[13]    = epass_s1;
    assign winscan_eye_w[16:14] = esel_s1;
    assign winscan_eye_w[17]    = 1'b0;
    assign winscan_eye_w[25:18] = lock_s1;
    assign winscan_eye_w[31:26] = 6'h25;

    assign obs_winscan_stat = winscan_stat_w;
    assign obs_winscan_eye  = winscan_eye_w;

endmodule

`default_nettype wire
