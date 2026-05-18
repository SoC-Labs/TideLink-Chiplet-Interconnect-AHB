//-----------------------------------------------------------------------------
// TideLink Autoneg — Training-Mode State Extension (REFERENCE SKETCH)
//
// **Design only — not for direct compilation.** This file is an annotated
// reference showing the additions the integrator must merge into
// `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` to add
// I²C-coordinated training-mode entry/exit (Layer 2 per
// docs/PHY_ALIGN_NEXT_STEPS.md §2.3).
//
// Every block carries a comment indicating WHERE in `tidelink_autoneg.sv`
// it plugs in. Search for "EXISTING:" tags below to locate the host file
// line numbers (line numbers as of 2026-05-14).
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//   Claude Code (design draft for David Mapstone, d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
//
// CONVENTION:
//   This file is NOT a standalone module. It is a fragment that overlays
//   onto `tidelink_autoneg.sv`. Each section is labelled with the host
//   region it modifies. Compiling this file alone WILL fail — it is a
//   conceptual diff.
//
// HOW TO USE:
//   1. Read this file alongside `tidelink_autoneg.sv` open in the other
//      window.
//   2. For each "EXISTING:" tag, find the corresponding region in the
//      host file and merge the additions.
//   3. The new state machine reuses the existing AXL_* / TXN_* sub-FSMs.
//      Do not duplicate them.
//
//-----------------------------------------------------------------------------

// =============================================================================
// SECTION A — New module-level inputs and outputs
// EXISTING: insert after the `mask_hs_auto_en` input declaration at
//           tidelink_autoneg.sv:108 (last line of the existing port list).
// =============================================================================

/*
    // ─── Training-mode coordination (Layer 2) ────────────────────────────────
    // Mirror of NEGO_TRAIN_CFG (see staging/i2c_train/I2C_TRAIN_PROTOCOL.md §3.1)
    input  wire        train_auto_en,        // NEGO_TRAIN_CFG[0]
    input  wire        train_sw_step,        // NEGO_TRAIN_CFG[1]
    input  wire        train_retrain_req,    // NEGO_TRAIN_CFG[2] (W1P, debounced upstream)
    input  wire  [3:0] train_poll_timeout,   // NEGO_TRAIN_CFG[7:4]; 0 → use default
    input  wire  [7:0] train_fsm_wait_hi,    // NEGO_TRAIN_CFG[15:8]; full wait = {train_fsm_wait_hi, 4'h0}

    // SW step (one-shot, advances FSM one state when train_sw_step=1)
    input  wire        train_step_pulse,     // pulse from NEGO_TRAIN_STEP write

    // ─── Local Wlink PHY observation (drives the local training side) ─────────
    input  wire  [7:0] local_swi_lane_locked_i,    // from local Wlink GPIO PHY
    input  wire  [7:0] local_swi_lane_fault_i,
    input  wire        local_calibration_done_i,

    // ─── Drive outputs to local Wlink PHY (via APB write logic in wrapper) ───
    // These feed the local SWI_TRAINING_MODE register at 0x098. The wrapper
    // OR-merges this strobe with the AXIL-bridge writes so peer-I²C and
    // FSM-local writes both land in the same register bit.
    output wire        local_training_mode_set,   // pulse: write SWI_TRAINING_MODE := 1
    output wire        local_training_mode_clr,   // pulse: write SWI_TRAINING_MODE := 0

    // Local swreset pulse — drives a one-shot into the chiplet controller's
    // existing swreset path (which fans out to all Wlink internal reset
    // synchronisers).
    output wire        local_swreset_pulse,

    // ─── Status to NEGO_TRAIN_STATUS ─────────────────────────────────────────
    output wire  [3:0] train_state,
    output wire        train_ok,
    output wire        train_fail,
    output wire        train_in_progress,
    output wire        train_peer_nack,
    output wire  [7:0] train_peer_lane_locked_o,
    output wire  [7:0] train_peer_lane_fault_o,
    output wire  [7:0] train_local_lane_fault_o,
    output wire        train_fail_irq
*/

// =============================================================================
// SECTION B — State encoding extensions
// EXISTING: add to localparam block at tidelink_autoneg.sv:115-134.
// =============================================================================

/*
    // Phase 3 — Training-mode coordination states. Master-only (slave's
    // training mode is enabled by the master's I²C write to its
    // SWI_TRAINING_MODE register at 0x098 and exits the same way).
    //
    // Encoding starts at 4'd11, immediately above the existing
    // ST_NEGO_MASK_RD_DATA = 4'd10. NEGO_TRAIN_STATUS.train_state in the
    // chiplet controller register block re-encodes to 0..6 for SW
    // readability (see I2C_TRAIN_PROTOCOL.md §3.4).
    //
    // ST_NEGO_DONE_PRE is a new intermediate state between ST_NEGO_DONE
    // (legacy semantics: "autoneg finished, role_lock asserted") and the
    // training entry. When train_auto_en=0, the FSM transitions
    // ST_NEGO_DONE_PRE → ST_NEGO_DONE directly (preserving legacy bring-up).
    // When train_auto_en=1, ST_NEGO_DONE_PRE → ST_TRAIN_ENTER kicks off
    // the training sequence.
    localparam [3:0] ST_NEGO_DONE_PRE       = 4'd11; // branch point: train vs done
    localparam [3:0] ST_TRAIN_ENTER         = 4'd12; // master writes peer's SWI_TRAINING_MODE := 1
    localparam [3:0] ST_TRAIN_RUN           = 4'd13; // wait T_TRAIN_FSM for cal FSMs
    localparam [3:0] ST_TRAIN_POLL_PEER     = 4'd14; // master reads peer's SWI_LANE_LOCKED
    localparam [3:0] ST_TRAIN_EXIT          = 4'd15; // NOTE: this exhausts 4-bit state width!
    // ST_TRAIN_DONE / ST_TRAIN_FAIL need a 5-bit state register OR a separate
    // "training sub-state" register OR re-encoding of legacy states.
    //
    // Recommended approach: WIDEN `state_r` from [3:0] to [4:0] throughout
    // tidelink_autoneg.sv. This is a mechanical change (8 declarations,
    // 1 reset value, 1 default value). Then:
    //   ST_TRAIN_DONE = 5'd16
    //   ST_TRAIN_FAIL = 5'd17
    // and the legacy 4'dN constants get cast to 5'dN with leading zero.
    //
    // ALTERNATIVE: introduce a separate 2-bit `train_sub_r` register
    // and let `state_r` stay at 4 bits with ST_TRAIN_FINISH = 4'd15
    // covering both DONE and FAIL — train_sub_r distinguishes them.
    // Adds a few LUTs but no big-pattern change to state_r users.
    //
    // This sketch uses the WIDENING approach for clarity. Integrator
    // may pick either.
*/

// =============================================================================
// SECTION C — Configuration constants
// EXISTING: add after the existing localparam block, near
//           tidelink_autoneg.sv:175-186 (mask-handshake constants).
// =============================================================================

/*
    // Training transaction address pointers. The chiplet controller register
    // block places SWI_TRAINING_MODE @ 0x098, SWI_LANE_LOCKED @ 0x0A0,
    // SWI_LANE_FAULT @ 0x0A4. See staging/i2c_train/I2C_TRAIN_PROTOCOL.md §3.1.
    localparam [7:0] TRAIN_MODE_ADDR_MSB     = 8'h00;
    localparam [7:0] TRAIN_MODE_ADDR_LSB     = 8'h98;
    localparam [7:0] TRAIN_LANE_LOCKED_ADDR_MSB = 8'h00;
    localparam [7:0] TRAIN_LANE_LOCKED_ADDR_LSB = 8'hA0;
    localparam [7:0] TRAIN_LANE_FAULT_ADDR_MSB  = 8'h00;
    localparam [7:0] TRAIN_LANE_FAULT_ADDR_LSB  = 8'hA4;

    // Number of bytes for each training I²C transaction.
    // Write SWI_TRAINING_MODE: 2 addr + 4 data (only LSB carries the value)
    localparam [2:0] TRAIN_MODE_WR_BYTES     = 3'd6;
    // Read SWI_LANE_LOCKED / SWI_LANE_FAULT: address set-up (2 bytes), then
    // 4-byte read. Reuses the existing MASK_RD_ADDR_BYTES / MASK_RD_DATA_BYTES
    // = 3'd2 / 3'd4 pattern from the autoneg mask-read sub-flow.

    // Wait timer for ST_TRAIN_RUN. {train_fsm_wait_hi, 4'h0} apb_clk cycles
    // — granularity 16 cycles, max wait = (255 << 4) = 4080 cycles ≈ 41 µs
    // @ 100 MHz. Default = 4096 cycles when train_fsm_wait_hi = 8'h00 (see
    // T_TRAIN_FSM_DEFAULT below; selects on fwa = 0).
    localparam [11:0] T_TRAIN_FSM_DEFAULT    = 12'd4096;

    // Poll timeout default — number of poll attempts before giving up.
    localparam [3:0]  T_POLL_TIMEOUT_DEFAULT = 4'd16;

    // SW reset pulse-width — number of apb_clk cycles to hold swreset asserted.
    localparam [6:0]  T_SWRESET_HOLD         = 7'd128;
*/

// =============================================================================
// SECTION D — Additional registers
// EXISTING: add to the register declarations block at
//           tidelink_autoneg.sv:190-220.
// =============================================================================

/*
    // Wait counter for ST_TRAIN_RUN
    reg [11:0] train_wait_r,         train_wait_nxt;
    // Poll attempt counter for ST_TRAIN_POLL_PEER
    reg [3:0]  poll_attempt_r,       poll_attempt_nxt;
    // swreset hold counter for ST_TRAIN_EXIT
    reg [6:0]  swreset_hold_r,       swreset_hold_nxt;
    // Captured peer-side and local-side status values
    reg [7:0]  peer_lane_locked_r,   peer_lane_locked_nxt;
    reg [7:0]  peer_lane_fault_r,    peer_lane_fault_nxt;
    reg [7:0]  local_lane_fault_r,   local_lane_fault_nxt;
    // 2-byte assembly for peer lane-locked / lane-fault reads
    reg [2:0]  train_byte_cnt_r,     train_byte_cnt_nxt;
    // Sticky status
    reg        train_ok_r,           train_ok_nxt;
    reg        train_fail_r,         train_fail_nxt;
    reg        train_peer_nack_r,    train_peer_nack_nxt;
    // One-shot strobes to local Wlink register block
    reg        local_train_set_r;    // pulse SWI_TRAINING_MODE := 1
    reg        local_train_clr_r;    // pulse SWI_TRAINING_MODE := 0
    reg        local_swreset_r;      // hold swreset asserted during EXIT
    // Snapshot of the byte being written to peer's SWI_TRAINING_MODE
    // (selected by train_byte_cnt_r during ST_TRAIN_ENTER and ST_TRAIN_EXIT).
    reg [7:0]  train_mode_wr_byte;
    reg        train_mode_wr_last;
    // The training-mode value to send (1 in ENTER, 0 in EXIT) — sourced from
    // a "phase" flag set on entry to each state.
    reg        train_target_value_r;
*/

// =============================================================================
// SECTION E — Comparator wires (combinational)
// EXISTING: add after the mask comparator at tidelink_autoneg.sv:290-292.
// =============================================================================

/*
    // Combined lane-lock check: both sides must report 0xFF
    wire all_locked_w = (peer_lane_locked_r == 8'hFF) &&
                        (local_swi_lane_locked_i == 8'hFF);

    // Computed poll-timeout — falls back to default if SW left field at 0
    wire [3:0] poll_timeout_eff = (train_poll_timeout == 4'd0)
                                ? T_POLL_TIMEOUT_DEFAULT
                                : train_poll_timeout;
    // Wait expansion: {train_fsm_wait_hi, 4'h0}, falling back to default
    wire [11:0] train_fsm_wait_eff = (train_fsm_wait_hi == 8'd0)
                                   ? T_TRAIN_FSM_DEFAULT
                                   : {train_fsm_wait_hi, 4'h0};
*/

// =============================================================================
// SECTION F — Main FSM additions (combinational next-state logic)
// EXISTING: add cases to the case (state_r) block at
//           tidelink_autoneg.sv:396-701. Replace the existing
//           ST_NEGO_DONE handler with the wrapper below, and add the new
//           ST_NEGO_DONE_PRE + ST_TRAIN_* cases.
// =============================================================================

/*
    // The existing ST_NEGO_POLL handler at tidelink_autoneg.sv:472-532
    // sets `state_nxt = ST_NEGO_DONE` on master-win.
    // MODIFY: change that to `state_nxt = ST_NEGO_DONE_PRE` so the new
    // pre-state can branch. The legacy slave-win paths still go to
    // ST_NEGO_DONE directly.
    //
    // Same change at tidelink_autoneg.sv:633-679 — ST_NEGO_MASK_RES_TX
    // transitions to ST_NEGO_DONE on completion; change to ST_NEGO_DONE_PRE
    // (the chosen branch point for both master-win paths).

    ST_NEGO_DONE_PRE: begin
        // Only the master enters this state. The slave's flow stays in
        // the legacy ST_NEGO_DONE — its SWI_TRAINING_MODE is set by the
        // master's I²C write, and the slave's local Wlink autonomously
        // runs its cal FSM in response.
        if (train_auto_en) begin
            // Initialise training sub-flow
            train_byte_cnt_nxt = 3'd0;
            train_target_value_r_nxt = 1'b1;       // ENTER writes 1
            train_wait_nxt     = train_fsm_wait_eff;
            poll_attempt_nxt   = 4'd0;
            swreset_hold_nxt   = 7'd0;
            // Clear sticky status flags so a retrain starts clean
            train_ok_nxt        = 1'b0;
            train_fail_nxt      = 1'b0;
            train_peer_nack_nxt = 1'b0;
            // AXL setup — first transaction is a 6-byte write to peer
            txn_step_nxt = TXN_DATA;
            state_nxt    = ST_TRAIN_ENTER;
        end else begin
            state_nxt = ST_NEGO_DONE;
        end
    end

    ST_TRAIN_ENTER: begin
        // I²C write 6 bytes to peer's SWI_TRAINING_MODE @ 0x098.
        // Bytes: [00, 98, 01, 00, 00, 00] (addr-MSB, addr-LSB, training=1, 3×0).
        // Reuses the AXL write path from ST_NEGO_MASK_RES_TX with a
        // different byte source (train_mode_wr_byte selected below).
        case (txn_step_r)
            TXN_DATA: begin
                if (axl_done_r) begin
                    if (train_byte_cnt_r == TRAIN_MODE_WR_BYTES - 3'd1) begin
                        txn_step_nxt = TXN_COMMAND;
                    end else begin
                        train_byte_cnt_nxt = train_byte_cnt_r + 3'd1;
                    end
                end
            end
            TXN_COMMAND: begin
                if (axl_done_r) begin
                    txn_step_nxt = TXN_POLL;
                end
            end
            TXN_POLL: begin
                if (axl_done_r) begin
                    txn_step_nxt = TXN_CHECK;
                end
            end
            TXN_CHECK: begin
                if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                    if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                        // Peer didn't ACK — go to FAIL with nack flag set
                        train_peer_nack_nxt   = 1'b1;
                        peer_lane_fault_nxt   = 8'hFF;   // poison sentinel
                        peer_lane_locked_nxt  = 8'h00;
                        train_fail_nxt        = 1'b1;
                        // Trap local lane-fault snapshot for the SW diag
                        local_lane_fault_nxt  = local_swi_lane_fault_i;
                        state_nxt             = ST_TRAIN_FAIL;
                    end else begin
                        // ACK received. Also pulse local SWI_TRAINING_MODE := 1
                        // (the local_train_set_r assertion below in §G drives
                        // this strobe to the chiplet controller register block).
                        train_byte_cnt_nxt = 3'd0;
                        train_wait_nxt     = train_fsm_wait_eff;
                        state_nxt          = ST_TRAIN_RUN;
                    end
                end else begin
                    txn_step_nxt = TXN_POLL;
                end
            end
            default: ;
        endcase
    end

    ST_TRAIN_RUN: begin
        // Both sides are now in training mode. Wait for the per-lane
        // autonomous cal FSMs to converge. No I²C traffic during this state.
        if (train_wait_r == 12'd0) begin
            // Set up the read transaction for peer's SWI_LANE_LOCKED.
            // First the 2-byte address-write (TRAIN_LANE_LOCKED_ADDR), then
            // the 4-byte read. Reuses MASK_RD_ADDR / MASK_RD_DATA pattern.
            train_byte_cnt_nxt = 3'd0;
            txn_step_nxt       = TXN_DATA;
            state_nxt          = ST_TRAIN_POLL_PEER;
        end else begin
            train_wait_nxt = train_wait_r - 12'd1;
        end
    end

    ST_TRAIN_POLL_PEER: begin
        // Issue a read against peer's SWI_LANE_LOCKED. The transaction
        // protocol mirrors the existing ST_NEGO_MASK_RD_ADDR + RD_DATA
        // sequence — the only difference is which address bytes are
        // pushed (TRAIN_LANE_LOCKED_ADDR_MSB/LSB instead of MASK_RD_ADDR_*)
        // and where the captured bytes land (peer_lane_locked_r instead
        // of peer_tx/rx_lane_mask_r).
        //
        // The full read takes 2 sub-flows (RD_ADDR then RD_DATA), but for
        // brevity here we treat POLL_PEER as a "compound" state that
        // walks both. In the merged FSM the integrator can split into
        // ST_TRAIN_POLL_PEER_ADDR and ST_TRAIN_POLL_PEER_DATA mirroring
        // the existing MASK_RD_ADDR / MASK_RD_DATA states.
        //
        // After the 4 bytes are captured (byte 0 = peer_lane_locked,
        // bytes 1..3 padding) the FSM evaluates:
        //   all_locked_w == 1  →  ST_TRAIN_EXIT
        //   all_locked_w == 0 && poll_attempt < poll_timeout
        //                       →  poll_attempt++, re-enter POLL_PEER
        //   all_locked_w == 0 && poll_attempt == poll_timeout
        //                       →  ST_TRAIN_FAIL
        //
        // (See peer_lane_locked_capture_en in §G for the capture detail.)
        case (txn_step_r)
            TXN_DATA: begin
                if (axl_done_r) begin
                    // Captures happen in §G (peer_lane_locked_capture).
                    if (train_byte_cnt_r == MASK_RD_DATA_BYTES - 3'd1) begin
                        // All 4 bytes captured. Decide next step.
                        if (all_locked_w) begin
                            // Move to EXIT
                            train_byte_cnt_nxt = 3'd0;
                            train_target_value_r_nxt = 1'b0;  // EXIT writes 0
                            txn_step_nxt = TXN_DATA;
                            state_nxt    = ST_TRAIN_EXIT;
                        end else if (poll_attempt_r == poll_timeout_eff - 4'd1) begin
                            // Timeout — read fault registers and FAIL
                            local_lane_fault_nxt = local_swi_lane_fault_i;
                            // Snapshot peer_lane_fault by issuing one
                            // additional read (the integrator may add a
                            // small extra state ST_TRAIN_FAULT_READ for
                            // this). For this sketch we use the most-
                            // recently-captured peer values as the
                            // diagnostic snapshot.
                            peer_lane_fault_nxt = peer_lane_locked_r ^ 8'hFF;
                            // (Crude: derives "unlocked" from "locked".
                            // Integrator should replace with a real read.)
                            train_fail_nxt = 1'b1;
                            state_nxt      = ST_TRAIN_FAIL;
                        end else begin
                            poll_attempt_nxt   = poll_attempt_r + 4'd1;
                            train_byte_cnt_nxt = 3'd0;
                            // Re-issue the address set-up + 4-byte read
                            txn_step_nxt = TXN_DATA;
                            state_nxt    = ST_TRAIN_POLL_PEER;  // self-loop
                        end
                    end else begin
                        train_byte_cnt_nxt = train_byte_cnt_r + 3'd1;
                        // Drive next byte read via TXN_COMMAND/POLL/CHECK
                        txn_step_nxt = TXN_COMMAND;
                    end
                end
            end
            TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
            TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
            TXN_CHECK: begin
                if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                    txn_step_nxt = TXN_DATA;
                end else begin
                    txn_step_nxt = TXN_POLL;
                end
            end
            default: ;
        endcase
    end

    ST_TRAIN_EXIT: begin
        // I²C write 6 bytes to peer's SWI_TRAINING_MODE @ 0x098 with
        // training=0. Then a second 6-byte write to peer's
        // Wlink.EnableReset @ wlink_base + 0x08 — but the wlink_base is
        // not the same as tidelink_base, so the address pointer changes.
        // For this sketch we issue just one write (training=0). The
        // integrator extends with the swreset write if the local-only
        // swreset (via local_swreset_pulse) is insufficient to recover
        // the peer's FCSM.
        //
        // Same TXN_DATA/COMMAND/POLL/CHECK flow as ST_TRAIN_ENTER.
        case (txn_step_r)
            TXN_DATA: begin
                if (axl_done_r) begin
                    if (train_byte_cnt_r == TRAIN_MODE_WR_BYTES - 3'd1) begin
                        txn_step_nxt = TXN_COMMAND;
                    end else begin
                        train_byte_cnt_nxt = train_byte_cnt_r + 3'd1;
                    end
                end
            end
            TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
            TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
            TXN_CHECK: begin
                if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                    // Pulse local swreset. Held for T_SWRESET_HOLD cycles
                    // before transitioning to DONE — the sequential block
                    // in §G drives local_swreset_r through the hold window.
                    swreset_hold_nxt = T_SWRESET_HOLD;
                    if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                        // Peer NACK'd the EXIT write. The local side
                        // already exited (local_train_clr fires) but the
                        // peer is stuck in training. Still go to FAIL
                        // because the link is unrecoverable.
                        train_peer_nack_nxt = 1'b1;
                        train_fail_nxt      = 1'b1;
                        state_nxt           = ST_TRAIN_FAIL;
                    end else begin
                        train_ok_nxt = 1'b1;
                        state_nxt    = ST_TRAIN_DONE;
                    end
                end else begin
                    txn_step_nxt = TXN_POLL;
                end
            end
            default: ;
        endcase
    end

    ST_TRAIN_DONE: begin
        // Terminal-OK. Held until POR or until train_retrain_req is asserted.
        if (train_retrain_req) begin
            // Re-enter the training sequence. Clear sticky status and
            // restart from ST_NEGO_DONE_PRE.
            train_ok_nxt        = 1'b0;
            train_fail_nxt      = 1'b0;
            train_peer_nack_nxt = 1'b0;
            state_nxt           = ST_NEGO_DONE_PRE;
        end
        // swreset hold counter ticks down independently — drives
        // local_swreset_r low when expired.
        if (swreset_hold_r != '0) begin
            swreset_hold_nxt = swreset_hold_r - 7'd1;
        end
    end

    ST_TRAIN_FAIL: begin
        // Terminal-FAIL. Lane-fault registers are loaded; train_fail_irq
        // is asserted. Held until POR or train_retrain_req.
        if (train_retrain_req) begin
            train_fail_nxt      = 1'b0;
            train_peer_nack_nxt = 1'b0;
            state_nxt           = ST_NEGO_DONE_PRE;
        end
    end
*/

// =============================================================================
// SECTION G — One-shot strobes to local Wlink (sequential / driver helpers)
// EXISTING: add to a new `always_ff` block (or merge into the existing
//           one at tidelink_autoneg.sv:973-1012).
// =============================================================================

/*
    // Peer-side byte capture during ST_TRAIN_POLL_PEER read. Byte 0 is the
    // peer's SWI_LANE_LOCKED. Bytes 1-3 are padding (zero); discard.
    always_comb begin
        peer_lane_locked_capture_en = 1'b0;
        if (state_r == ST_TRAIN_POLL_PEER &&
            txn_step_r == TXN_DATA && axl_done_r &&
            train_byte_cnt_r == 3'd0) begin
            peer_lane_locked_capture_en = 1'b1;
        end
    end

    // Sequential latch for the captured peer lane-locked byte. Re-uses the
    // axl_rdata_r register written in the AXL sub-FSM.
    always_ff @(posedge clk or negedge poresetn) begin
        if (!poresetn) begin
            peer_lane_locked_r <= 8'h00;
        end else if (peer_lane_locked_capture_en) begin
            peer_lane_locked_r <= axl_rdata_r[7:0];
        end
    end

    // (Repeat for peer_lane_fault_r — captured in a similar additional
    // read transaction during ST_TRAIN_FAIL entry. Integrator splits the
    // FAIL state into ST_TRAIN_FAIL_RD_ADDR + ST_TRAIN_FAIL_RD_DATA in
    // a fully-faithful implementation; this sketch leaves the snapshot
    // taken from the last lane-locked read for simplicity.)

    // Byte source for I²C write transactions in ST_TRAIN_ENTER /
    // ST_TRAIN_EXIT. 6 bytes: addr-MSB, addr-LSB, training=value, 3×0.
    always_comb begin
        case (train_byte_cnt_r)
            3'd0: begin train_mode_wr_byte = TRAIN_MODE_ADDR_MSB;     train_mode_wr_last = 1'b0; end
            3'd1: begin train_mode_wr_byte = TRAIN_MODE_ADDR_LSB;     train_mode_wr_last = 1'b0; end
            3'd2: begin train_mode_wr_byte = {7'd0, train_target_value_r}; train_mode_wr_last = 1'b0; end
            3'd3: begin train_mode_wr_byte = 8'h00;                   train_mode_wr_last = 1'b0; end
            3'd4: begin train_mode_wr_byte = 8'h00;                   train_mode_wr_last = 1'b0; end
            3'd5: begin train_mode_wr_byte = 8'h00;                   train_mode_wr_last = 1'b1; end
            default: begin train_mode_wr_byte = 8'h00;                train_mode_wr_last = 1'b0; end
        endcase
    end

    // Plug train_mode_wr_byte / train_mode_wr_last into the axl_target_wdata
    // selection (existing logic at tidelink_autoneg.sv:778-799). Add a new
    // branch:
    //   else if (state_r == ST_TRAIN_ENTER || state_r == ST_TRAIN_EXIT) begin
    //       axl_target_wdata = {22'd0, train_mode_wr_last, 1'b0, train_mode_wr_byte};
    //   end
    // And for read of peer's SWI_LANE_LOCKED, plug into MASK_RD_ADDR /
    // MASK_RD_DATA branches with the appropriate address-byte source.
    //
    // Concretely, in tidelink_autoneg.sv:768-799, extend the TXN_DATA arm
    // of the axl_target_wdata case to also branch on
    // (state_r == ST_TRAIN_POLL_PEER) — push TRAIN_LANE_LOCKED_ADDR_MSB/LSB
    // for the address set-up, then axl_is_read = 1 for the byte reads.

    // Local strobes — single-cycle pulses to the chiplet controller.
    always_comb begin
        local_train_set_r = (state_r == ST_TRAIN_ENTER &&
                             txn_step_r == TXN_CHECK &&
                             !axl_rdata_r[I2C_STS_BUSY] && busy_seen_r &&
                             !axl_rdata_r[I2C_STS_MISS_ACK] &&
                             state_nxt == ST_TRAIN_RUN);
        local_train_clr_r = (state_r == ST_TRAIN_EXIT &&
                             txn_step_r == TXN_CHECK &&
                             !axl_rdata_r[I2C_STS_BUSY] && busy_seen_r &&
                             state_nxt == ST_TRAIN_DONE);
    end

    // Local swreset is asserted during the EXIT → DONE transition and held
    // for T_SWRESET_HOLD cycles via the swreset_hold counter.
    assign local_training_mode_set = local_train_set_r;
    assign local_training_mode_clr = local_train_clr_r;
    assign local_swreset_pulse     = (swreset_hold_r != '0);
*/

// =============================================================================
// SECTION H — Output assignments
// EXISTING: add to the output assignment block at
//           tidelink_autoneg.sv:1014-1023.
// =============================================================================

/*
    // Re-route nego_state to a wider expose if state_r is widened to 5 bits.
    // train_state is the 4-bit re-encoding for NEGO_TRAIN_STATUS (see
    // I2C_TRAIN_PROTOCOL.md §3.4 for the encoding mapping).
    assign train_state = (state_r == ST_NEGO_DONE_PRE)    ? 4'd0 :
                         (state_r == ST_TRAIN_ENTER)      ? 4'd1 :
                         (state_r == ST_TRAIN_RUN)        ? 4'd2 :
                         (state_r == ST_TRAIN_POLL_PEER)  ? 4'd3 :
                         (state_r == ST_TRAIN_EXIT)       ? 4'd4 :
                         (state_r == ST_TRAIN_DONE)       ? 4'd5 :
                         (state_r == ST_TRAIN_FAIL)       ? 4'd6 :
                                                            4'd0;

    assign train_ok                 = train_ok_r;
    assign train_fail               = train_fail_r;
    assign train_in_progress        = (state_r >= ST_NEGO_DONE_PRE &&
                                       state_r != ST_TRAIN_DONE &&
                                       state_r != ST_TRAIN_FAIL);
    assign train_peer_nack          = train_peer_nack_r;
    assign train_peer_lane_locked_o = peer_lane_locked_r;
    assign train_peer_lane_fault_o  = peer_lane_fault_r;
    assign train_local_lane_fault_o = local_lane_fault_r;
    assign train_fail_irq           = train_fail_r;   // sticky → level-active

    // (If the integrator chose to keep `state_r` at 4 bits and use a
    // separate `train_sub_r`, the train_state encoding above is replaced
    // by the appropriate combination of state_r and train_sub_r.)
*/

// =============================================================================
// SECTION I — Integration notes
// =============================================================================
/*
    NOTES FOR THE INTEGRATOR:

    1. The 4-bit-vs-5-bit state-width decision (see §B above) is the single
       biggest mechanical change. Do this first; everything else follows.

    2. The `mask_byte_cnt_r` register is currently 3 bits (max 6). The
       training transactions also fit in 3 bits, so no width change needed
       — it can be reused or paralleled by `train_byte_cnt_r`. Reuse is
       cleaner: it's already cleared on entry to each transaction-type
       state. Recommendation: rename to `byte_cnt_r` and reuse for both
       mask and training paths.

    3. Timeout: the existing `timeout_ctr_r` decrements during all
       transient states. Extend its decrement guard to include
       ST_TRAIN_* states (tidelink_autoneg.sv:376-394). Pick a generous
       timeout (>17 ms worth of cycles) so the worst-case poll-retry
       does not trigger it.

    4. busy_seen reset: extend the reset-guard at
       tidelink_autoneg.sv:354-365 to include the new states. New
       transaction starts trigger busy_seen_nxt = 0:
         - ST_TRAIN_ENTER TXN_DATA mask_byte_cnt_r == 0
         - ST_TRAIN_EXIT  TXN_DATA mask_byte_cnt_r == 0
         - ST_TRAIN_POLL_PEER TXN_COMMAND (per-byte read commands)

    5. AXL drive gate at tidelink_autoneg.sv:889-895: extend the state
       list to include ST_TRAIN_ENTER, ST_TRAIN_POLL_PEER, ST_TRAIN_EXIT.
       ST_TRAIN_RUN and ST_TRAIN_DONE/FAIL never drive AXL.

    6. Sequential reset of new registers (poresetn block at
       tidelink_autoneg.sv:973-1012): add all the new _r registers with
       sensible reset values:
         train_wait_r        <= '0;
         poll_attempt_r      <= '0;
         swreset_hold_r      <= '0;
         peer_lane_locked_r  <= 8'h00;
         peer_lane_fault_r   <= 8'h00;
         local_lane_fault_r  <= 8'h00;
         train_byte_cnt_r    <= 3'd0;
         train_ok_r          <= 1'b0;
         train_fail_r        <= 1'b0;
         train_peer_nack_r   <= 1'b0;
         train_target_value_r <= 1'b0;

    7. The chiplet controller wrapper at
       deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv
       (search for `u_autoneg`) needs to receive the new outputs
       (train_*) and feed them to the new APB register fields
       (NEGO_TRAIN_STATUS, etc). The wrapper also fans out
       local_training_mode_set/clr to the local-side APB write port
       of the chiplet controller's SWI_TRAINING_MODE register at 0x098.

    8. The slave side does NOT walk ST_TRAIN_* states. Its
       SWI_TRAINING_MODE is set by the master's I²C write, captured by
       the slave's I²C-slave-to-AXIL-to-APB bridge, and lands in the
       slave's local SWI_TRAINING_MODE register, which feeds the local
       Wlink PHY's training mode. This is exactly the same pattern as
       the existing lane-mask handshake (slave's
       link_lane_mask_hs_result @ 0x21C is written by master's I²C).
*/
