//-----------------------------------------------------------------------------
// TideLink I2C Auto-Negotiation FSM
//
// Dynamically resolves master/slave roles between two identical chiplets
// using the existing I2C sideband. Operates before role lock — Wlink
// remains in reset throughout negotiation.
//
// Protocol: priority-based backoff with SDA early-exit detection.
// The side with the lower numeric priority claims master first by
// switching to I2C master mode and writing a "claim" byte to the peer's
// I2C slave. The peer detects the SDA START condition and adopts slave.
//
// See docs/AUTONEG_PROTOCOL.md for the full specification.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic
// Access license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_autoneg #(
    parameter NEGO_TICK          = 1000,       // apb_clk cycles per priority unit
    parameter NEGO_BASE_DELAY    = 2000,       // minimum cycles before any claim
    parameter NEGO_TIMEOUT_DEFAULT = 32'd131_082_000,  // ~1.31s @ 100 MHz
    parameter NEGO_ADDR_DEFAULT  = 7'h7E,      // I2C negotiation slave address
    parameter NEGO_MST_INIT_WAIT = 16          // cycles after I2C master reset release
)(
    input  wire        clk,
    input  wire        poresetn,       // Power-on reset (active-low)

    // ── Configuration inputs (from NEGO_* registers) ─────────────────────
    input  wire        nego_en,        // NEGO_CFG[0]: enable autoneg
    input  wire        nego_start,     // NEGO_CFG[1]: explicit start trigger
    input  wire  [1:0] nego_pri_sel,   // NEGO_CFG[3:2]: priority source
    input  wire        nego_fallback,  // NEGO_CFG[4]: error fallback role
    input  wire        nego_force_lock,// NEGO_CFG[5]: auto-lock on completion

    // ── Priority inputs ──────────────────────────────────────────────────
    input  wire [15:0] nego_priority_reg, // From NEGO_PRIORITY register
    input  wire [15:0] nego_priority_i,   // From external OTP/UID port
    input  wire [15:0] puf_seed,          // From TideChart PUF sampler
    input  wire        puf_ready,         // PUF sampling complete

    // ── Timeout ──────────────────────────────────────────────────────────
    input  wire [31:0] nego_timeout_reg,  // From NEGO_TIMEOUT register

    // ── I2C bus monitoring ───────────────────────────────────────────────
    input  wire        i2c_sda_i,      // SDA input (for START detection)
    input  wire        i2c_scl_i,      // SCL input (qualifies START)

    // ── I2C prescaler (from existing I2C_PRESCALE register) ──────────────
    input  wire [15:0] i2c_prescale_reg,

    // ── AXI-Lite master interface (drives I2C master during negotiation) ─
    output reg   [7:0] m_axil_awaddr,
    output reg         m_axil_awvalid,
    input  wire        m_axil_awready,
    output reg  [31:0] m_axil_wdata,
    output reg   [3:0] m_axil_wstrb,
    output reg         m_axil_wvalid,
    input  wire        m_axil_wready,
    input  wire  [1:0] m_axil_bresp,
    input  wire        m_axil_bvalid,
    output reg         m_axil_bready,
    output reg   [7:0] m_axil_araddr,
    output reg         m_axil_arvalid,
    input  wire        m_axil_arready,
    input  wire [31:0] m_axil_rdata,
    input  wire  [1:0] m_axil_rresp,
    input  wire        m_axil_rvalid,
    output reg         m_axil_rready,

    // ── Role control outputs ─────────────────────────────────────────────
    output reg         nego_role_r,       // Drives 3-way role_effective mux
    output reg         nego_set_role_cfg, // Pulse: write role_cfg_reg
    output reg         nego_role_value,   // Value to write to role_cfg_reg
    output reg         nego_set_role_lock,// Pulse: set role_lock_reg = 1

    // ── Status outputs ───────────────────────────────────────────────────
    output wire  [3:0] nego_state,
    output reg         nego_done,
    output reg         nego_error,
    output reg         nego_won,
    output reg         nego_lost,
    output reg         sda_start_seen,
    output wire        nego_error_irq,

    // ── Peer-mask handshake (Phase 2 scaffolding) ────────────────────────
    // The local mask is supplied by the wrapper (sourced from Wlink's
    // tx_lane_mask_o / rx_lane_mask_o); the captured peer mask is driven
    // back to the wrapper to populate Wlink's link_lane_mask_peer @ 0x218.
    // mask_hs_local_match / _fail are sticky outputs the wrapper uses to
    // open or refuse the role-lock gate without going through the
    // SW-driven hs_result register write path.
    //
    // Currently driven from constant zero; Phase 2B fills in the FSM
    // logic that captures peer mask via I2C read transactions and sets
    // the sticky flags after the comparator runs.
    input  wire  [7:0] local_tx_lane_mask_i,
    input  wire  [7:0] local_rx_lane_mask_i,
    output wire  [7:0] peer_tx_lane_mask_o,
    output wire  [7:0] peer_rx_lane_mask_o,
    output wire        mask_hs_local_match,
    output wire        mask_hs_local_fail,
    input  wire        mask_hs_auto_en,      // NEGO_CFG[6]: enable HW handshake

    // ─── Training-mode coordination (Layer 2 — I2C-coordinated training) ─
    // Configuration from NEGO_TRAIN_CFG @ 0x10C (Region 8). The I2C-train
    // sub-flow runs on the master after the mask-handshake completes. It
    // writes peer's SWI_TRAINING_MODE := 1, dwells T_TRAIN_FSM cycles,
    // polls peer's SWI_LANE_STATUS, then writes peer's SWI_TRAINING_MODE
    // := 0 and pulses local swreset. The slave's autoneg FSM stays in
    // ST_NEGO_DONE; its SWI_TRAINING_MODE register is written by the
    // master's I2C transactions through the existing slave-AXIL bridge.
    input  wire        train_auto_en,        // NEGO_TRAIN_CFG[0]
    input  wire        train_sw_step,        // NEGO_TRAIN_CFG[1] (reserved; not used in v1)
    input  wire        train_retrain_req,    // NEGO_TRAIN_CFG[2] W1P
    input  wire  [3:0] train_poll_timeout,   // NEGO_TRAIN_CFG[7:4]
    input  wire  [7:0] train_fsm_wait_hi,    // NEGO_TRAIN_CFG[15:8]

    // Local lane-status observations from the autocal FSM (sync'd to apb_clk
    // in the wrapper before reaching this port).
    input  wire  [7:0] local_swi_lane_locked_i,
    input  wire  [7:0] local_swi_lane_fault_i,
    input  wire        local_calibration_done_i,

    // Local strobes — single-cycle pulses to the chiplet controller's
    // SWI_TRAINING_MODE register. The wrapper OR-merges these with the
    // I2C-slave-AXIL-bridge writes so peer-I2C and FSM-local writes both
    // land in the same register bit.
    output wire        local_training_mode_set, // pulse: write SWI_TRAINING_MODE := 1
    output wire        local_training_mode_clr, // pulse: write SWI_TRAINING_MODE := 0
    output wire        local_swreset_pulse,     // hold swreset during EXIT

    // Status to NEGO_TRAIN_STATUS @ 0x110.
    output wire  [3:0] train_state_o,
    output wire        train_ok_o,
    output wire        train_fail_o,
    output wire        train_in_progress_o,
    output wire        train_peer_nack_o,
    output wire  [7:0] train_peer_lane_locked_o,
    output wire  [7:0] train_peer_lane_fault_o,
    output wire  [7:0] train_local_lane_fault_o,
    output wire        train_fail_irq_o,

    // ── Bug N7/N8 silicon observability (local_overrides edit, 2026-06-01) ──
    //   Surface internal FSM counters/state so the wrapper APB Region C
    //   read-mux can publish them at MMIO 0x44032180+. Read-only side-band;
    //   no logic dependencies — the regs are still driven by the existing
    //   *_nxt / always-block plumbing inside this module.
    output wire [31:0] obs_delay_ctr_o,
    output wire [31:0] obs_timeout_ctr_o,
    output wire  [4:0] obs_init_wait_o,
    output wire  [2:0] obs_axl_state_o,
    output wire  [2:0] obs_txn_step_o
);

    // =====================================================================
    // State encoding. Widened from 4 to 5 bits in Phase 3 to host the I2C
    // training-mode coordination states (ST_TRAIN_*). The legacy
    // ST_NEGO_STATUS[3:0] field truncates state_r to 4 bits — Phase 3
    // states report through the new NEGO_TRAIN_STATUS.train_state field
    // (re-encoded 0..6) on the wrapper side.
    // =====================================================================
    localparam [4:0] ST_IDLE              = 5'd0;
    localparam [4:0] ST_NEGO_INIT         = 5'd1;
    localparam [4:0] ST_NEGO_WAIT         = 5'd2;
    localparam [4:0] ST_NEGO_CLAIM        = 5'd3;
    localparam [4:0] ST_NEGO_POLL         = 5'd4;
    localparam [4:0] ST_NEGO_DONE         = 5'd5;
    localparam [4:0] ST_BYPASS            = 5'd6;
    localparam [4:0] ST_ERROR             = 5'd7;
    // Phase 2 mask-handshake states (master only). Slave path is unchanged
    // — the slave's gate is driven by the master's I2C write to its
    // link_lane_mask_hs_result @ 0x21C, which lands via the existing
    // I2C-slave-AXIL-bridge → APB → Wlink path.
    //
    // Master-win flow (auto_en=1): POLL → MASK_RD_ADDR → MASK_RD_DATA →
    // MASK_RES_TX → DONE. The two read states fetch the peer's
    // link_lane_mask @ 0x214 (4 bytes) over I2C; the comparator then
    // selects 0x01/0x02 for the result-byte write in MASK_RES_TX.
    localparam [4:0] ST_NEGO_MASK_RES_TX  = 5'd8;  // I2C-write result byte to peer's 0x21C
    localparam [4:0] ST_NEGO_MASK_RD_ADDR = 5'd9;  // I2C-write 2 addr bytes (set peer's read pointer to 0x0214)
    localparam [4:0] ST_NEGO_MASK_RD_DATA = 5'd10; // I2C-read 4 bytes from peer's link_lane_mask

    // Phase 3 I2C-coordinated training states (master only). Slave's
    // autoneg stays in ST_NEGO_DONE; its SWI_TRAINING_MODE is written by
    // the master's I2C transactions arriving via the slave's I2C-slave +
    // AXIL-to-APB bridge.
    //
    // Flow: MASK_RES_TX → NEGO_DONE_PRE.
    //   If train_auto_en=1: NEGO_DONE_PRE → TRAIN_ENTER → TRAIN_RUN
    //     → TRAIN_POLL_PEER → TRAIN_EXIT → TRAIN_DONE.
    //   Otherwise:           NEGO_DONE_PRE → NEGO_DONE (legacy bypass).
    localparam [4:0] ST_NEGO_DONE_PRE     = 5'd11;
    localparam [4:0] ST_TRAIN_ENTER       = 5'd12;
    localparam [4:0] ST_TRAIN_RUN         = 5'd13;
    localparam [4:0] ST_TRAIN_POLL_PEER   = 5'd14;
    localparam [4:0] ST_TRAIN_EXIT        = 5'd15;
    localparam [4:0] ST_TRAIN_DONE        = 5'd16;
    localparam [4:0] ST_TRAIN_FAIL        = 5'd17;

    // I2C master register addresses (from i2c_master_axil)
    localparam [3:0] I2C_REG_STATUS  = 4'h0;
    localparam [3:0] I2C_REG_COMMAND = 4'h4;
    localparam [3:0] I2C_REG_DATA    = 4'h8;
    localparam [3:0] I2C_REG_PRESCALE = 4'hC;

    // I2C command bits
    localparam I2C_CMD_START = 8;
    localparam I2C_CMD_WRITE = 10;
    localparam I2C_CMD_STOP  = 12;

    // I2C status bits
    localparam I2C_STS_BUSY     = 0;
    localparam I2C_STS_BUS_CTRL = 1;
    localparam I2C_STS_MISS_ACK = 3;

    // I2C DATA register read-side bits (see i2c_master_axil.v line 181):
    //   [9] = data_last, [8] = data_valid, [7:0] = data
    // data_valid=0 ⇒ rd-data FIFO was empty when popped, [7:0] is garbage.
    localparam I2C_DATA_VALID   = 8;

    // AXI-Lite sub-state for driving I2C master transactions
    localparam [2:0] AXL_IDLE       = 3'd0;
    localparam [2:0] AXL_WR_ADDR    = 3'd1;
    localparam [2:0] AXL_WR_DATA    = 3'd2;
    localparam [2:0] AXL_WR_RESP    = 3'd3;
    localparam [2:0] AXL_RD_ADDR    = 3'd4;
    localparam [2:0] AXL_RD_DATA    = 3'd5;

    // I2C transaction sub-steps within NEGO_CLAIM/NEGO_POLL/NEGO_MASK_RES_TX.
    // TXN_DATA pushes one byte per axl_done; for multi-byte transactions the
    // outer state increments byte_count_r and stays in TXN_DATA until all
    // bytes are queued, then moves to TXN_COMMAND.
    localparam [2:0] TXN_PRESCALE   = 3'd0;
    localparam [2:0] TXN_DATA       = 3'd1;
    localparam [2:0] TXN_COMMAND    = 3'd2;
    localparam [2:0] TXN_POLL       = 3'd3;
    localparam [2:0] TXN_CHECK      = 3'd4;
    localparam [2:0] TXN_DONE       = 3'd5;

    // Number of bytes pushed for the result-write transaction:
    //   2 address bytes (MSB=0x02, LSB=0x1C → Wlink.link_lane_mask_hs_result)
    //   4 data bytes (only LSB is meaningful — 0x01 for match, 0x02 for fail)
    localparam [2:0] MASK_RES_BYTES = 3'd6;
    localparam [7:0] MASK_RES_ADDR_MSB = 8'h02;
    localparam [7:0] MASK_RES_ADDR_LSB = 8'h1C;

    // Read-phase address: peer's Wlink.link_lane_mask @ 0x0214. The slave
    // bridge auto-increments after each byte, so the master sets the
    // pointer once via a 2-byte cmd_write_multiple (no stop), then issues
    // 4 cmd_read commands to pull back tx_lane_mask, rx_lane_mask, and
    // two zero bytes (high half is unused in the 8-lane build).
    localparam [2:0] MASK_RD_ADDR_BYTES = 3'd2;
    localparam [7:0] MASK_RD_ADDR_MSB = 8'h02;
    localparam [7:0] MASK_RD_ADDR_LSB = 8'h14;
    localparam [2:0] MASK_RD_DATA_BYTES = 3'd4;

    // Phase 3 — I²C training transaction constants. Addresses target the
    // peer's TideLink-config APB Region 8 (paddr 0x100..0x11C inside the
    // tidelink_apb_regs block at MMIO 0x4403_2xxx). For the slave's
    // I2C-slave-to-AXIL bridge the address is the local TideLink-config
    // offset, NOT the Wlink-config region.
    //
    //   SWI_TRAINING_MODE  @ 0x2100  (master writes 1 then 0 to drive peer
    //                                 in/out of training)
    //   SWI_LANE_STATUS    @ 0x2108  (master reads to check
    //                                 [7:0]=lane_locked, [15:8]=lane_fault,
    //                                 [16]=calibration_done)
    //
    // The slave-side AXIL slave addresses the full 13-bit local APB, but
    // the I2C slave's pointer is byte-addressed within a 13-bit window —
    // the master pushes only the low 13 bits (MSB nibble truncated). The
    // existing mask-handshake path uses 8'h02 / 8'h1C as MSB/LSB and the
    // slave's bridge interprets MSB[7:5]=Wlink-region bits. For Region 8
    // (TideLink-config), MSB[7:5]=001 means the bridge routes to the
    // TideLink-APB rather than the Wlink-APB. NOTE: this routing change
    // is implemented in the chiplet_controller's slv_apb_active mux —
    // search "Region 8" in axi_chiplet_controller.sv.
    localparam [7:0] TRAIN_MODE_ADDR_MSB     = 8'h21;  // 0x2100 → byte 0x21
    localparam [7:0] TRAIN_MODE_ADDR_LSB     = 8'h00;
    localparam [7:0] TRAIN_STATUS_ADDR_MSB   = 8'h21;  // 0x2108
    localparam [7:0] TRAIN_STATUS_ADDR_LSB   = 8'h08;

    // 5-byte write to SWI_TRAINING_MODE: 2 addr + 4 data (LSB only carries
    // training bit, padding zeros). Matches the existing MASK_RES_BYTES
    // = 6-byte pattern; here we use 6 to mirror that.
    localparam [2:0] TRAIN_MODE_WR_BYTES     = 3'd6;

    // 4-byte read of SWI_LANE_STATUS: byte 0 = lane_locked,
    // byte 1 = lane_fault, byte 2 = {calibration_done, 7'b0},
    // byte 3 = padding. Reuse MASK_RD_DATA_BYTES = 3'd4.

    // Wait timer for ST_TRAIN_RUN. Effective wait = {train_fsm_wait_hi, 4'h0}
    // apb_clk cycles. With wait_hi=0 the default of 4096 is used (a 12-bit
    // counter). At 100 MHz this is ~41 µs — covers worst-case 8 × 32 = 256
    // link-clk cycles for the autocal sweep plus 10× slack.
    localparam [11:0] T_TRAIN_FSM_DEFAULT    = 12'd4095;  // 12-bit max-1, so all-ones countdown

    // Poll timeout default — number of poll-and-evaluate cycles before
    // giving up. Each cycle reads peer's SWI_LANE_STATUS and re-evaluates
    // the all-locked predicate.
    localparam [3:0]  T_POLL_TIMEOUT_DEFAULT = 4'd15;

    // SW reset pulse width during ST_TRAIN_EXIT. Held high for this many
    // apb_clk cycles before transitioning to ST_TRAIN_DONE.
    localparam [6:0]  T_SWRESET_HOLD         = 7'd127;

    // =====================================================================
    // Registers
    // =====================================================================
    reg [4:0]  state_r,         state_nxt;
    reg [2:0]  mask_byte_cnt_r, mask_byte_cnt_nxt;  // Multi-byte FIFO push counter
    reg        busy_seen_r,     busy_seen_nxt;      // Has the I2C master ever
                                                    // gone busy on this transaction?
    reg [31:0] delay_ctr_r,     delay_ctr_nxt;
    reg [31:0] timeout_ctr_r,   timeout_ctr_nxt;
    reg [4:0]  init_wait_r,     init_wait_nxt;     // I2C master init counter

    // Phase 3 — training-mode coordination registers
    reg [11:0] train_wait_r,        train_wait_nxt;
    reg [3:0]  poll_attempt_r,      poll_attempt_nxt;
    reg [6:0]  swreset_hold_r,      swreset_hold_nxt;

    // M4f (2026-06-05): sustained-lock gating to close the v18 20% residual.
    // Counts CONSECUTIVE poll-evaluations where both peer_lane_locked_r==0xFF
    // AND local_swi_lane_locked_i==0xFF (with no faults). Resets on any drop.
    // Primary-success requires this counter to reach M4F_LOCK_DWELL_MIN — i.e.
    // bilateral lane-lock must hold across N consecutive I²C polls (~600 µs
    // each) before TRAIN_EXIT fires. v18 silicon showed 20% master-only-fail
    // where slave's autoneg fired TRAIN_EXIT on a TRANSIENT lane_locked=0xFF
    // glitch mid-sweep (before slave's calibrator reached S_HOLD); the
    // resulting peer-clear I²C write dropped peer's training pattern source,
    // killing slave's own calibrator convergence. Requiring N=4 sustained
    // polls (~2.4 ms total) gives the local calibrator time to settle into
    // S_HOLD before declaring training done.
    localparam [3:0] M4F_LOCK_DWELL_MIN = 4'd4;
    reg [3:0]  consec_locked_polls_r,  consec_locked_polls_nxt;

    // M4b (2026-06-05): peer-unreachable escape hatch.
    // Counts apb_clk cycles spent in ST_TRAIN_POLL_PEER without ever observing
    // peer_cal_done=1. Reset on peer_cal_done observed, or on FSM leaving the
    // POLL_PEER state. When peer_unreach_timeout_r asserts, the FSM falls
    // through to ST_TRAIN_FAIL instead of re-arming poll forever.
    //
    // Silicon characterization v16 (2026-06-05): with the prior Bug N14a
    // bypass, slave would prematurely declare train_ok=1 and write peer's
    // swi_training_mode_r=0 over I²C while peer's calibrator was still
    // sweeping → peer's RX loses training pattern → 100% master-only-fail.
    // M4b removes that bypass; the only paths out of ST_TRAIN_POLL_PEER are
    // (a) primary success (peer_cal_done=1 AND local fully healthy) →
    // ST_TRAIN_EXIT, (b) this timeout → ST_TRAIN_FAIL. Production ≈ 1.3s at
    // 100MHz apb_clk / 2.6s at 50MHz — bounded fail-fast for a genuinely
    // broken peer; far longer than the prior poll budget so a slow peer
    // still has time to converge.
    //
    // Sim override: cocotb Makefile passes +define+TB_FAST_PEER_UNREACH so
    // tests don't run for 1.3s of sim time waiting for the timeout. Set to
    // 1000 cycles (~10µs at 100MHz) so tests verifying M4b's fail path can
    // hit the timeout in reasonable wall time.
`ifdef TB_FAST_PEER_UNREACH
    localparam [26:0] T_PEER_UNREACH_DEFAULT = 27'd1000;
`else
    localparam [26:0] T_PEER_UNREACH_DEFAULT = 27'd130_000_000;
`endif
    reg [26:0] peer_unreach_ctr_r,      peer_unreach_ctr_nxt;
    reg        peer_unreach_timeout_r,  peer_unreach_timeout_nxt;
    reg [7:0]  peer_lane_locked_r,  peer_lane_locked_nxt;
    reg [7:0]  peer_lane_fault_r,   peer_lane_fault_nxt;
    reg        peer_cal_done_r,     peer_cal_done_nxt;
    reg [7:0]  local_lane_fault_snapshot_r, local_lane_fault_snapshot_nxt;
    reg        train_ok_r,          train_ok_nxt;
    reg        train_fail_r,        train_fail_nxt;
    reg        train_peer_nack_r,   train_peer_nack_nxt;
    reg        train_target_value_r;   // 1 in ENTER, 0 in EXIT (selects byte source)
    reg        train_target_value_nxt;
    reg        local_train_set_pulse_r;
    reg        local_train_clr_pulse_r;
    // Sub-phase within ST_TRAIN_POLL_PEER: 0 = address-write, 1 = byte-reads.
    reg        train_poll_phase_r,  train_poll_phase_nxt;
    // Peer-byte capture strobes (set in main_comb, latched in seq block).
    reg        peer_lane_locked_capture_en;
    reg        peer_lane_fault_capture_en;
    reg        peer_cal_done_capture_en;

    // AXI-Lite sub-state
    // Bug N7/N8 silicon observability: mark_debug on the AXL sub-FSM regs.
    // Inert unless FPGA_INSERT_DEBUG_CORE=1 (pynq-z2-pair-i2c-ila target).
    (* mark_debug = "true" *) reg [2:0]  axl_state_r;
                              reg [2:0]  axl_state_nxt;
    (* mark_debug = "true" *) reg [2:0]  txn_step_r;
                              reg [2:0]  txn_step_nxt;
    (* mark_debug = "true" *) reg        axl_done_r;
                              reg        axl_done_nxt;       // Pulse when AXL transaction completes
    reg [31:0] axl_rdata_r,     axl_rdata_nxt;      // Captured read data

    // SDA edge detection
    reg        sda_prev_r;

    // Peer-mask capture and verdict (Phase 2 scaffolding — driven to defaults
    // until Phase 2B fills in the FSM logic).
    reg [7:0]  peer_tx_lane_mask_r;
    reg [7:0]  peer_rx_lane_mask_r;
    reg        mask_hs_local_match_r;
    reg        mask_hs_local_fail_r;

    // Sticky status
    reg        nego_done_r,      nego_done_nxt;
    reg        nego_error_r,     nego_error_nxt;
    reg        nego_won_r,       nego_won_nxt;
    reg        nego_lost_r,      nego_lost_nxt;
    reg        sda_start_seen_r, sda_start_seen_nxt;

    // Role output
    reg        nego_role_nxt;

    // =====================================================================
    // Priority selection mux
    // =====================================================================
    reg [15:0] selected_priority;

    always_comb begin
        case (nego_pri_sel)
            2'd0: selected_priority = nego_priority_reg;
            2'd1: selected_priority = nego_priority_i;
            2'd2: selected_priority = puf_seed;
            2'd3: selected_priority = 16'hFFFF;
        endcase
    end

    // Backoff delay = priority * NEGO_TICK + NEGO_BASE_DELAY
    // Use a constant multiply (NEGO_TICK is a parameter)
    wire [31:0] backoff_delay = (32'(selected_priority) * NEGO_TICK) + NEGO_BASE_DELAY;

    // =====================================================================
    // SDA START condition detector
    // =====================================================================
    // I2C START = SDA falling edge while SCL is high
    wire sda_start_detect = sda_prev_r && !i2c_sda_i && i2c_scl_i;

    always_ff @(posedge clk or negedge poresetn) begin
        if (!poresetn)
            sda_prev_r <= 1'b1;
        else
            sda_prev_r <= i2c_sda_i;
    end

    // synthesis translate_off
    reg [4:0] prev_state_dbg;
    always_ff @(posedge clk) begin
        if (state_r !== prev_state_dbg) begin
            $display("[%0t] [%m] state %0d -> %0d  (won=%b lost=%b done=%b err=%b)",
              $time, prev_state_dbg, state_r,
              nego_won_r, nego_lost_r, nego_done_r, nego_error_r);
            prev_state_dbg <= state_r;
        end
    end
    // synthesis translate_on


    // Peer-mask capture / verdict registers. POR-cleared.
    //   Phase 2C: peer_{tx,rx}_lane_mask_r are loaded one byte at a time
    //   from the I2C read data FIFO during ST_NEGO_MASK_RD_DATA. After
    //   the 4-byte read completes, the comparator wires (below) compute
    //   match/fail from the crossover identity — local.tx == peer.rx and
    //   local.rx == peer.tx — and that verdict is latched on entry to
    //   ST_NEGO_MASK_RES_TX so the result-write transaction sends the
    //   correct byte (0x01 match, 0x02 fail).
    //
    //   Capture scheme: in ST_NEGO_MASK_RD_DATA TXN_DATA, after axl_done
    //   the rdata holds the just-popped data-FIFO byte. mask_byte_cnt_r
    //   selects which peer-mask byte to load (0=tx, 1=rx, 2/3 discarded).
    //   The capture write happens combinationally from main_comb (via the
    //   peer_*_capture_en strobes) and is latched here.
    reg peer_tx_capture_en;
    reg peer_rx_capture_en;

    // Crossover identity comparator (pure comb). The link is symmetric: lane
    // K is usable in the A→B direction iff A.tx_mask[K] && B.rx_mask[K], so
    // for the link to come up cleanly the masks must match across the
    // crossover. Mismatch on either direction is a fail.
    wire mask_match_w = (local_tx_lane_mask_i == peer_rx_lane_mask_r) &&
                        (local_rx_lane_mask_i == peer_tx_lane_mask_r);
    wire mask_fail_w  = ~mask_match_w;

    always_ff @(posedge clk or negedge poresetn) begin
        if (!poresetn) begin
            peer_tx_lane_mask_r   <= 8'h00;
            peer_rx_lane_mask_r   <= 8'h00;
            mask_hs_local_match_r <= 1'b0;
            mask_hs_local_fail_r  <= 1'b0;
        end else begin
            if (peer_tx_capture_en)
                peer_tx_lane_mask_r <= axl_rdata_r[7:0];
            if (peer_rx_capture_en)
                peer_rx_lane_mask_r <= axl_rdata_r[7:0];
            // Sticky local-match / local-fail: latched only when the
            // result-write transaction completes. Latching earlier
            // (e.g. on entry to MASK_RES_TX) would open the
            // mask-handshake gate while the FSM is still
            // mid-transaction; with force_lock=1 the wrapper would
            // immediately latch role_lock_reg, deassert nego_driving,
            // and hand the I2C-master AXIL bus back to the bridge —
            // dropping bvalid before the FSM's WR_RESP can capture it.
            //
            // Bug N13 fix (2026-06-02): the FSM exits MASK_RES_TX
            // via TXN_CHECK to ST_NEGO_DONE_PRE (line ~896), NEVER
            // directly to ST_NEGO_DONE. The original predicate
            // `state_nxt == ST_NEGO_DONE` therefore never fires for
            // the winner on production silicon, and mask_hs_local_match_r
            // stays 0 even when masks actually match. Sim tests pass
            // because tb_top.sv ties apb_debug_unlock_i =
            // mask_hs_bypass_i = 1'b1, opening mask_hs_gate_open
            // regardless of this latch. Silicon (straps tied 0)
            // exposes the broken predicate: master captures peer
            // masks as 0xFF but never latches local_match, gate
            // stays closed, role_lock_reg can never set. Accept
            // both ST_NEGO_DONE (no-train legacy path) and
            // ST_NEGO_DONE_PRE (train-enabled path) as valid exit
            // targets for the latch.
            if (state_r == ST_NEGO_MASK_RES_TX &&
                (state_nxt == ST_NEGO_DONE ||
                 state_nxt == ST_NEGO_DONE_PRE)) begin
                mask_hs_local_match_r <= mask_match_w;
                mask_hs_local_fail_r  <= mask_fail_w;
            end
        end
    end

    assign peer_tx_lane_mask_o = peer_tx_lane_mask_r;
    assign peer_rx_lane_mask_o = peer_rx_lane_mask_r;
    assign mask_hs_local_match = mask_hs_local_match_r;
    assign mask_hs_local_fail  = mask_hs_local_fail_r;

    // =====================================================================
    // Main FSM — combinational next-state logic
    // =====================================================================
    always_comb begin
        // Defaults: hold current values
        state_nxt          = state_r;
        delay_ctr_nxt      = delay_ctr_r;
        timeout_ctr_nxt    = timeout_ctr_r;
        init_wait_nxt      = init_wait_r;
        nego_role_nxt      = nego_role_r;
        nego_done_nxt      = nego_done_r;
        nego_error_nxt     = nego_error_r;
        nego_won_nxt       = nego_won_r;
        nego_lost_nxt      = nego_lost_r;
        sda_start_seen_nxt = sda_start_seen_r;
        mask_byte_cnt_nxt  = mask_byte_cnt_r;
        // Bug N8 fix (2026-06-01): hold-default for txn_step_nxt.
        // Without this default, Vivado infers a latch (warning [Synth 8-327]
        // at tidelink_autoneg.sv:637). Sim sees X-propagation; silicon sees a
        // real latch that holds stale values across cycles where no explicit
        // txn_step_nxt assignment fires. Symptom on v9 silicon: master's
        // i2c_master_axil core's busy_int never asserts during ST_NEGO_CLAIM
        // because the FSM's TXN_PRESCALE→TXN_DATA→TXN_COMMAND walk
        // is corrupted, dropping the COMMAND write and leaving the i2c
        // master idle. cocotb tests pass because sim X-prop happens to
        // match expected behaviour. Fix matches commit be5eed2 on the
        // historical feat/i2c-autonomous-lock-integ branch.
        txn_step_nxt       = txn_step_r;
        // busy_seen is sticky-1 within a single transaction (so TXN_CHECK
        // can distinguish "early-read sees idle" from "transaction done").
        // It is reset by default any cycle the FSM is NOT in a transaction
        // (e.g. CLAIM TXN_PRESCALE/DATA setup, or post-DONE), and latched
        // when busy=1 is observed during CHECK.
        if ((state_r == ST_NEGO_POLL ||
             state_r == ST_NEGO_MASK_RES_TX ||
             state_r == ST_NEGO_MASK_RD_ADDR ||
             state_r == ST_NEGO_MASK_RD_DATA ||
             state_r == ST_TRAIN_ENTER ||
             state_r == ST_TRAIN_POLL_PEER ||
             state_r == ST_TRAIN_EXIT) &&
            txn_step_r == TXN_CHECK &&
            axl_rdata_r[I2C_STS_BUSY])
            busy_seen_nxt = 1'b1;
        else if (state_r == ST_NEGO_CLAIM ||
                 (state_r == ST_NEGO_MASK_RES_TX && txn_step_r == TXN_DATA &&
                  mask_byte_cnt_r == 3'd0) ||
                 (state_r == ST_NEGO_MASK_RD_ADDR && txn_step_r == TXN_DATA &&
                  mask_byte_cnt_r == 3'd0) ||
                 // Defense-in-depth (mask-FSM audit, 2026-05-21):
                 // The TXN_DATA-byte-0 reset above covers the normal entry
                 // path POLL→MASK_RD_ADDR (and the miss-ACK retry path that
                 // re-enters TXN_DATA at byte_cnt=0). But the MASK_RD_ADDR
                 // I²C transaction does not actually go on the wire until
                 // TXN_COMMAND queues cmd_start|cmd_write_multiple — that
                 // is the unambiguous "start of the address-write txn".
                 // Adding the TXN_COMMAND entry here scrubs any stale
                 // busy_seen that escaped the byte-0 gate (e.g. via a future
                 // refactor that re-enters this state on a different path).
                 (state_r == ST_NEGO_MASK_RD_ADDR && txn_step_r == TXN_COMMAND) ||
                 // Each byte read in MASK_RD_DATA is its own I2C transaction
                 // (one cmd_read, one busy/idle round-trip), so reset
                 // busy_seen at every TXN_COMMAND entry.
                 (state_r == ST_NEGO_MASK_RD_DATA && txn_step_r == TXN_COMMAND) ||
                 // Same pattern for training-mode I²C transactions
                 (state_r == ST_TRAIN_ENTER && txn_step_r == TXN_DATA &&
                  mask_byte_cnt_r == 3'd0) ||
                 (state_r == ST_TRAIN_EXIT && txn_step_r == TXN_DATA &&
                  mask_byte_cnt_r == 3'd0) ||
                 // POLL_PEER walks RD_ADDR-then-RD_DATA-equivalent flow:
                 //   byte 0 RD_ADDR (2 addr bytes)
                 //   bytes 0..3 RD_DATA (4 reads)
                 // So reset on TXN_COMMAND boundary for each read sub-byte
                 // and on TXN_DATA byte 0 for the address-write phase.
                 (state_r == ST_TRAIN_POLL_PEER && txn_step_r == TXN_DATA &&
                  mask_byte_cnt_r == 3'd0) ||
                 (state_r == ST_TRAIN_POLL_PEER && txn_step_r == TXN_COMMAND))
            busy_seen_nxt = 1'b0;  // start of a new transaction
        else
            busy_seen_nxt = busy_seen_r;

        // One-shot outputs default to 0
        nego_set_role_cfg  = 1'b0;
        nego_role_value    = 1'b0;
        nego_set_role_lock = 1'b0;

        // Phase 3 next-state defaults — hold values
        train_wait_nxt                = train_wait_r;
        poll_attempt_nxt              = poll_attempt_r;
        swreset_hold_nxt              = swreset_hold_r;
        peer_unreach_ctr_nxt          = peer_unreach_ctr_r;
        peer_unreach_timeout_nxt      = peer_unreach_timeout_r;
        consec_locked_polls_nxt       = consec_locked_polls_r;

        // M4b peer-unreachable counter: countdown while in POLL_PEER without
        // peer_cal_done observed; reset on peer_cal_done observed; reset
        // outside the POLL_PEER state so each TRAIN attempt gets a fresh
        // ~1.3s budget.
        if (peer_cal_done_r) begin
            peer_unreach_ctr_nxt     = T_PEER_UNREACH_DEFAULT;
            peer_unreach_timeout_nxt = 1'b0;
        end else if (state_r == ST_TRAIN_POLL_PEER) begin
            if (peer_unreach_ctr_r == 27'd0) begin
                peer_unreach_timeout_nxt = 1'b1;
            end else begin
                peer_unreach_ctr_nxt = peer_unreach_ctr_r - 27'd1;
            end
        end else if (state_r != ST_TRAIN_EXIT) begin
            // Outside POLL_PEER/EXIT: reload counter, clear timeout flag.
            peer_unreach_ctr_nxt     = T_PEER_UNREACH_DEFAULT;
            peer_unreach_timeout_nxt = 1'b0;
        end
        peer_lane_locked_nxt          = peer_lane_locked_r;
        peer_lane_fault_nxt           = peer_lane_fault_r;
        peer_cal_done_nxt             = peer_cal_done_r;
        local_lane_fault_snapshot_nxt = local_lane_fault_snapshot_r;
        train_ok_nxt                  = train_ok_r;
        train_fail_nxt                = train_fail_r;
        train_peer_nack_nxt           = train_peer_nack_r;
        train_target_value_nxt        = train_target_value_r;
        train_poll_phase_nxt          = train_poll_phase_r;
        local_train_set_pulse_r       = 1'b0;
        local_train_clr_pulse_r       = 1'b0;
        peer_lane_locked_capture_en   = 1'b0;
        peer_lane_fault_capture_en    = 1'b0;
        peer_cal_done_capture_en      = 1'b0;

        // Timeout decrement: active in all transient negotiation states
        // (ST_IDLE excluded; ST_NEGO_DONE / BYPASS / ERROR are terminal so
        // also excluded; the mask-handshake states are transient master-only
        // and get the same timeout window).
        if (((state_r > ST_IDLE && state_r < ST_NEGO_DONE) ||
              state_r == ST_NEGO_MASK_RES_TX ||
              state_r == ST_NEGO_MASK_RD_ADDR ||
              state_r == ST_NEGO_MASK_RD_DATA ||
              state_r == ST_NEGO_DONE_PRE ||
              state_r == ST_TRAIN_ENTER ||
              state_r == ST_TRAIN_RUN ||
              state_r == ST_TRAIN_POLL_PEER ||
              state_r == ST_TRAIN_EXIT) && timeout_ctr_r != '0)
            timeout_ctr_nxt = timeout_ctr_r - 1;

        // Timeout check
        if (((state_r > ST_IDLE && state_r < ST_NEGO_DONE) ||
              state_r == ST_NEGO_MASK_RES_TX ||
              state_r == ST_NEGO_MASK_RD_ADDR ||
              state_r == ST_NEGO_MASK_RD_DATA ||
              state_r == ST_NEGO_DONE_PRE ||
              state_r == ST_TRAIN_ENTER ||
              state_r == ST_TRAIN_RUN ||
              state_r == ST_TRAIN_POLL_PEER ||
              state_r == ST_TRAIN_EXIT) && timeout_ctr_r == '0) begin
            // Force fallback role and transition to error
            nego_role_nxt      = nego_fallback;
            nego_error_nxt     = 1'b1;
            nego_set_role_cfg  = 1'b1;
            nego_role_value    = nego_fallback;
            if (nego_force_lock)
                nego_set_role_lock = 1'b1;
            state_nxt = ST_ERROR;
        end else begin
            case (state_r)
                ST_IDLE: begin
                    if (!nego_en) begin
                        state_nxt = ST_BYPASS;
                    end else if (nego_en && (nego_start || !nego_start)) begin
                        // Start negotiation: both sides begin as slave
                        nego_role_nxt   = 1'b1;  // slave
                        timeout_ctr_nxt = nego_timeout_reg;
                        state_nxt       = ST_NEGO_INIT;
                    end
                end

                ST_NEGO_INIT: begin
                    // Wait for PUF if using PUF priority source
                    if (nego_pri_sel == 2'd2 && !puf_ready) begin
                        // Stay in INIT, wait for PUF
                    end else begin
                        delay_ctr_nxt = backoff_delay;
                        state_nxt     = ST_NEGO_WAIT;
                    end
                end

                ST_NEGO_WAIT: begin
                    // SDA early-exit: peer already claiming
                    if (sda_start_detect) begin
                        sda_start_seen_nxt = 1'b1;
                        nego_role_nxt      = 1'b1;  // stay slave
                        nego_lost_nxt      = 1'b1;
                        nego_done_nxt      = 1'b1;
                        nego_set_role_cfg  = 1'b1;
                        nego_role_value    = 1'b1;   // slave
                        if (nego_force_lock)
                            nego_set_role_lock = 1'b1;
                        state_nxt = ST_NEGO_DONE;
                    end else if (delay_ctr_r == '0) begin
                        // Timer expired, we claim master
                        nego_role_nxt = 1'b0;   // switch to master
                        init_wait_nxt = NEGO_MST_INIT_WAIT[4:0];
                        txn_step_nxt  = TXN_PRESCALE;
                        state_nxt     = ST_NEGO_CLAIM;
                    end else begin
                        delay_ctr_nxt = delay_ctr_r - 1;
                    end
                end

                ST_NEGO_CLAIM: begin
                    // Wait for I2C master to exit reset
                    if (init_wait_r != '0) begin
                        init_wait_nxt = init_wait_r - 1;
                    end else begin
                        // Drive I2C transaction sub-steps via AXI-Lite
                        case (txn_step_r)
                            TXN_PRESCALE: begin
                                // Write prescaler to I2C master reg 0x0C
                                if (axl_done_r) begin
                                    txn_step_nxt = TXN_DATA;
                                end
                            end
                            TXN_DATA: begin
                                // Write claim byte (0x01) to data reg 0x08
                                if (axl_done_r) begin
                                    txn_step_nxt = TXN_COMMAND;
                                end
                            end
                            TXN_COMMAND: begin
                                // Write command: START + WRITE + STOP + address
                                if (axl_done_r) begin
                                    txn_step_nxt = TXN_POLL;
                                    state_nxt    = ST_NEGO_POLL;
                                end
                            end
                            default: ;
                        endcase
                    end
                end

                ST_NEGO_POLL: begin
                    case (txn_step_r)
                        TXN_POLL: begin
                            // Read status register 0x00
                            if (axl_done_r) begin
                                txn_step_nxt = TXN_CHECK;
                            end
                        end
                        TXN_CHECK: begin
                            // Evaluate I2C status. The master IP needs several
                            // cycles after cmd is queued before it actually
                            // starts the I2C bus transaction; during that
                            // window busy=0 and bus_ctrl=0 (idle), which
                            // would falsely trip the "lost arbitration" check.
                            // Require busy_seen_r=1 (we observed busy=1 at
                            // some point during this transaction) before
                            // accepting busy=0 as completion.
                            if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                // Transaction complete
                                if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                                    // NACK → become slave
                                    nego_role_nxt     = 1'b1;
                                    nego_lost_nxt     = 1'b1;
                                    nego_done_nxt     = 1'b1;
                                    nego_set_role_cfg = 1'b1;
                                    nego_role_value   = 1'b1;
                                    if (nego_force_lock)
                                        nego_set_role_lock = 1'b1;
                                    state_nxt = ST_NEGO_DONE;
                                end else begin
                                    // ACK received → we are master
                                    nego_role_nxt     = 1'b0;
                                    nego_won_nxt      = 1'b1;
                                    nego_done_nxt     = 1'b1;
                                    nego_set_role_cfg = 1'b1;
                                    nego_role_value   = 1'b0;
                                    if (nego_force_lock)
                                        nego_set_role_lock = 1'b1;
                                    // If mask-handshake auto mode is enabled,
                                    // proceed into the read-and-compare path:
                                    //   MASK_RD_ADDR (write peer's reg ptr) →
                                    //   MASK_RD_DATA (pull 4 bytes back) →
                                    //   MASK_RES_TX (write computed verdict
                                    //   byte to peer's hs_result) → NEGO_DONE_PRE.
                                    // Otherwise (legacy / SW-driven), branch
                                    // via NEGO_DONE_PRE so the optional
                                    // training-mode sub-flow can engage.
                                    if (mask_hs_auto_en) begin
                                        mask_byte_cnt_nxt = 3'd0;
                                        txn_step_nxt      = TXN_DATA;
                                        state_nxt         = ST_NEGO_MASK_RD_ADDR;
                                    end else begin
                                        state_nxt = ST_NEGO_DONE_PRE;
                                    end
                                end
                            end else begin
                                // Still busy — re-poll
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        default: ;
                    endcase
                end

                ST_NEGO_MASK_RD_ADDR: begin
                    // Write phase of the peer-mask register read. Pushes 2
                    // address bytes (0x02, 0x14 → Wlink.link_lane_mask)
                    // into the master's wr-data FIFO and issues
                    // cmd_start | cmd_write_multiple WITHOUT cmd_stop, so
                    // the slave's internal address pointer is set without
                    // releasing the bus. The next state issues a repeated
                    // start + read to pull the 4 bytes back.
                    case (txn_step_r)
                        TXN_DATA: begin
                            if (axl_done_r) begin
                                if (mask_byte_cnt_r == MASK_RD_ADDR_BYTES - 3'd1) begin
                                    txn_step_nxt = TXN_COMMAND;
                                end else begin
                                    mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
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
                                // Address pointer is now set on the peer
                                // side. Move to the read phase: issue 4
                                // cmd_read commands one at a time, draining
                                // each byte from the rd-data FIFO before
                                // queueing the next.
                                mask_byte_cnt_nxt = 3'd0;
                                txn_step_nxt      = TXN_COMMAND;
                                state_nxt         = ST_NEGO_MASK_RD_DATA;
                            end else begin
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        default: ;
                    endcase
                end

                ST_NEGO_MASK_RD_DATA: begin
                    // Read phase: for each of the 4 bytes, push a single
                    // cmd_read into the cmd FIFO (with cmd_start on byte 0
                    // for the repeated start, cmd_stop on byte 3 for the
                    // bus release), poll until the master goes idle, then
                    // pop the byte from the rd-data FIFO. The captured
                    // bytes feed peer_{tx,rx}_lane_mask_r (byte 0 = peer
                    // tx_mask, byte 1 = peer rx_mask; bytes 2/3 are unused
                    // padding from the upper half of the 32-bit register
                    // and are discarded).
                    case (txn_step_r)
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
                                // I2C bus transaction complete; the byte is
                                // now in the rd-data FIFO. Pop it via a
                                // DATA-register read in TXN_DATA.
                                txn_step_nxt = TXN_DATA;
                            end else begin
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        TXN_DATA: begin
                            // axl is doing a DATA-register read; capture
                            // happens in seq logic via peer_*_capture_en.
                            if (axl_done_r) begin
                                if (mask_byte_cnt_r ==
                                    MASK_RD_DATA_BYTES - 3'd1) begin
                                    // All 4 bytes captured; comparator
                                    // verdict latches on the state edge
                                    // below.
                                    mask_byte_cnt_nxt = 3'd0;
                                    txn_step_nxt      = TXN_DATA;
                                    state_nxt         = ST_NEGO_MASK_RES_TX;
                                end else begin
                                    mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
                                    txn_step_nxt      = TXN_COMMAND;
                                end
                            end
                        end
                        default: ;
                    endcase
                end

                ST_NEGO_MASK_RES_TX: begin
                    // Master writes the result byte (0x01 = match, 0x02 =
                    // fail) to peer's link_lane_mask_hs_result @ 0x21C via
                    // I2C. Push 6 bytes (2 addr + 4 data) into the
                    // wr-data FIFO, then issue cmd_write_multiple. The
                    // result byte itself is selected by the comparator
                    // verdict latched on entry from MASK_RD_DATA. After
                    // completion, mask_hs_local_match_r (or _fail_r) is
                    // latched so master's own gate opens.
                    case (txn_step_r)
                        TXN_DATA: begin
                            if (axl_done_r) begin
                                if (mask_byte_cnt_r == MASK_RES_BYTES - 3'd1) begin
                                    // All 6 bytes pushed; issue command
                                    txn_step_nxt = TXN_COMMAND;
                                end else begin
                                    mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
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
                            // Wait for busy_seen before accepting busy=0 as
                            // completion (same early-read avoidance pattern
                            // as ST_NEGO_POLL TXN_CHECK).
                            if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                // Transaction complete. Whether ACK was good
                                // or not, terminate to NEGO_DONE_PRE — the
                                // slave either captured the result byte or
                                // didn't. The local match flag is set in seq
                                // logic. The new branch point picks
                                // legacy-DONE or training-mode sub-flow.
                                state_nxt = ST_NEGO_DONE_PRE;
                            end else begin
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        default: ;
                    endcase
                end

                // =============================================================
                // Phase 3 — I²C-coordinated training-mode sub-flow.
                //
                // Only the master walks these states; the slave's
                // autoneg parks in ST_NEGO_DONE and observes its own
                // SWI_TRAINING_MODE register being toggled by master's
                // I²C writes. The slave's autocal FSM runs independently
                // off that register.
                // =============================================================

                ST_NEGO_DONE_PRE: begin
                    // Branch point: enter training sub-flow when enabled,
                    // otherwise drop into legacy terminal-DONE.
                    if (train_auto_en) begin
                        mask_byte_cnt_nxt        = 3'd0;
                        train_target_value_nxt   = 1'b1;       // ENTER writes 1
                        train_wait_nxt           = (train_fsm_wait_hi == 8'd0)
                                                 ? T_TRAIN_FSM_DEFAULT
                                                 : {train_fsm_wait_hi, 4'h0};
                        poll_attempt_nxt         = 4'd0;
                        swreset_hold_nxt         = 7'd0;
                        train_ok_nxt             = 1'b0;
                        train_fail_nxt           = 1'b0;
                        train_peer_nack_nxt      = 1'b0;
                        peer_lane_locked_nxt     = 8'h00;     // clear capture
                        peer_lane_fault_nxt      = 8'h00;
                        peer_cal_done_nxt        = 1'b0;
                        txn_step_nxt             = TXN_DATA;
                        state_nxt                = ST_TRAIN_ENTER;
                    end else begin
                        state_nxt = ST_NEGO_DONE;
                    end
                end

                ST_TRAIN_ENTER: begin
                    // I²C-write 6 bytes to peer's SWI_TRAINING_MODE @ 0x2100,
                    // payload bit[0]=1. Mirrors the existing
                    // ST_NEGO_MASK_RES_TX byte-push pattern.
                    case (txn_step_r)
                        TXN_DATA: begin
                            if (axl_done_r) begin
                                if (mask_byte_cnt_r == TRAIN_MODE_WR_BYTES - 3'd1) begin
                                    txn_step_nxt = TXN_COMMAND;
                                end else begin
                                    mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
                                end
                            end
                        end
                        TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
                        TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
                        TXN_CHECK: begin
                            if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                                    // Peer NACK'd — bail out
                                    train_peer_nack_nxt           = 1'b1;
                                    peer_lane_fault_nxt           = 8'hFF;  // poison sentinel
                                    peer_lane_locked_nxt          = 8'h00;
                                    train_fail_nxt                = 1'b1;
                                    local_lane_fault_snapshot_nxt = local_swi_lane_fault_i;
                                    state_nxt                     = ST_TRAIN_FAIL;
                                end else begin
                                    // Peer ACK'd — pulse local set strobe,
                                    // dwell for the cal FSMs to converge.
                                    local_train_set_pulse_r = 1'b1;
                                    mask_byte_cnt_nxt       = 3'd0;
                                    train_wait_nxt          = (train_fsm_wait_hi == 8'd0)
                                                            ? T_TRAIN_FSM_DEFAULT
                                                            : {train_fsm_wait_hi, 4'h0};
                                    state_nxt               = ST_TRAIN_RUN;
                                end
                            end else begin
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        default: ;
                    endcase
                end

                ST_TRAIN_RUN: begin
                    // Both sides in training-mode; cal FSMs converge in
                    // parallel. No I²C traffic.
                    if (train_wait_r == 12'd0) begin
                        mask_byte_cnt_nxt = 3'd0;
                        txn_step_nxt      = TXN_DATA;
                        state_nxt         = ST_TRAIN_POLL_PEER;
                    end else begin
                        train_wait_nxt = train_wait_r - 12'd1;
                    end
                end

                ST_TRAIN_POLL_PEER: begin
                    // Compound state — two sub-phases tracked by
                    // train_poll_phase_r:
                    //   Phase 0: I²C-write 2 address bytes (no STOP) to set
                    //            peer's SWI_LANE_STATUS read pointer.
                    //   Phase 1: I²C-read 4 bytes; the seq block captures
                    //            byte 0 → peer_lane_locked,
                    //            byte 1 → peer_lane_fault,
                    //            byte 2 → peer_cal_done (bit 0).
                    //            On byte 3 capture, this state evaluates:
                    //              all_locked & cal_done & no_fault →
                    //                 ST_TRAIN_EXIT
                    //              else if poll_attempt < timeout →
                    //                 re-arm (phase 0, mask_byte_cnt=0)
                    //              else timeout → ST_TRAIN_FAIL.
                    if (train_poll_phase_r == 1'b0) begin
                        // ---- Address-write sub-phase ----
                        case (txn_step_r)
                            TXN_DATA: begin
                                if (axl_done_r) begin
                                    if (mask_byte_cnt_r == MASK_RD_ADDR_BYTES - 3'd1) begin
                                        txn_step_nxt = TXN_COMMAND;
                                    end else begin
                                        mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
                                    end
                                end
                            end
                            TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
                            TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
                            TXN_CHECK: begin
                                if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                    if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                                        train_peer_nack_nxt           = 1'b1;
                                        peer_lane_fault_nxt           = 8'hFF;
                                        train_fail_nxt                = 1'b1;
                                        local_lane_fault_snapshot_nxt = local_swi_lane_fault_i;
                                        state_nxt                     = ST_TRAIN_FAIL;
                                    end else begin
                                        // Address pointer set — switch to
                                        // read sub-phase.
                                        mask_byte_cnt_nxt    = 3'd0;
                                        txn_step_nxt         = TXN_COMMAND;
                                        train_poll_phase_nxt = 1'b1;
                                    end
                                end else begin
                                    txn_step_nxt = TXN_POLL;
                                end
                            end
                            default: ;
                        endcase
                    end else begin
                        // ---- Per-byte read sub-phase ----
                        case (txn_step_r)
                            TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
                            TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
                            TXN_CHECK: begin
                                if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                    txn_step_nxt = TXN_DATA;
                                end else begin
                                    txn_step_nxt = TXN_POLL;
                                end
                            end
                            TXN_DATA: begin
                                if (axl_done_r) begin
                                    // Drive per-byte capture strobes for the
                                    // seq block to latch the just-popped
                                    // axl_rdata_r byte into peer_*_r.
                                    case (mask_byte_cnt_r)
                                        3'd0: peer_lane_locked_capture_en = 1'b1;
                                        3'd1: peer_lane_fault_capture_en  = 1'b1;
                                        3'd2: peer_cal_done_capture_en    = 1'b1;
                                        default: ; // byte 3 is reserved padding
                                    endcase
                                    if (mask_byte_cnt_r == MASK_RD_DATA_BYTES - 3'd1) begin
                                        // Last byte just captured — evaluate
                                        // using already-captured peer_lane_*
                                        // (bytes 0-2 were captured in earlier
                                        // cycles, so their *_r values are
                                        // already up-to-date). Byte 3 is
                                        // reserved padding and not used.
                                        // M4e (2026-06-05): primary success
                                        // predicate relaxed — declare TRAIN
                                        // success on bilateral lane-lock
                                        // alone (drop both peer_cal_done_r
                                        // AND local_calibration_done_i).
                                        //
                                        // Rationale (silicon v17, 2026-06-05):
                                        // With M4b's removal of the N14a
                                        // bypass, slave's autoneg cannot
                                        // reach TRAIN_EXIT until peer AND
                                        // local cal_done are observed. But
                                        // cal_done requires S_VALIDATE→S_DONE
                                        // which requires cr_pkt_seen_i which
                                        // requires the peer's FCSM to emit a
                                        // CR_PKT — which it cannot do while
                                        // its swi_training_mode_r=1 forces
                                        // the TX MUX to training-pattern.
                                        // → chicken-and-egg deadlock.
                                        //
                                        // The lane_locked=0xFF condition is
                                        // the actual "training succeeded"
                                        // signal (per N14a's analysis); the
                                        // cal_done bit is downstream of S_HOLD
                                        // / S_VALIDATE which serve POST-
                                        // training-mode validation. Once both
                                        // dies' lane_checkers report 0xFF
                                        // (sustained match against training
                                        // pattern) and no faults, it is safe
                                        // to TRAIN_EXIT — dropping training_
                                        // mode unblocks the FCSMs to exchange
                                        // CR/CRACK and both calibrators then
                                        // naturally complete S_VALIDATE.
                                        //
                                        // M4b's escape timeout still guards
                                        // a genuinely broken peer (lane_locked
                                        // never reaches 0xFF).
                                        // M4f (2026-06-05): sustained-lock
                                        // gating. The bilateral lane-lock
                                        // observation must hold across at
                                        // least M4F_LOCK_DWELL_MIN consecutive
                                        // polls (~600 µs each) before
                                        // declaring TRAIN_EXIT. Bumps the
                                        // counter on each consistent poll;
                                        // resets to 0 on ANY drop. Closes
                                        // the v18 20% residual where slave
                                        // fired TRAIN_EXIT on a transient
                                        // mid-sweep lane_locked=0xFF glitch.
                                        if ((peer_lane_locked_r == 8'hFF) &&
                                            (local_swi_lane_locked_i == 8'hFF) &&
                                            (peer_lane_fault_r == 8'h00) &&
                                            (local_swi_lane_fault_i == 8'h00)) begin
                                            // Bilateral lane-lock present at
                                            // this poll. Either bump the
                                            // dwell counter or proceed.
                                            if (consec_locked_polls_r >= M4F_LOCK_DWELL_MIN - 4'd1) begin
                                                // Lock has been stable for
                                                // M4F_LOCK_DWELL_MIN polls —
                                                // safe to TRAIN_EXIT.
                                                mask_byte_cnt_nxt      = 3'd0;
                                                train_target_value_nxt = 1'b0;
                                                txn_step_nxt           = TXN_DATA;
                                                train_poll_phase_nxt   = 1'b0;
                                                consec_locked_polls_nxt = 4'd0;
                                                state_nxt              = ST_TRAIN_EXIT;
                                            end else begin
                                                // Bump dwell; re-arm poll.
                                                consec_locked_polls_nxt = consec_locked_polls_r + 4'd1;
                                                poll_attempt_nxt     = 4'd0;
                                                mask_byte_cnt_nxt    = 3'd0;
                                                txn_step_nxt         = TXN_DATA;
                                                train_poll_phase_nxt = 1'b0;
                                            end
                                        end else if (poll_attempt_r ==
                                                     ((train_poll_timeout == 4'd0)
                                                      ? T_POLL_TIMEOUT_DEFAULT
                                                      : train_poll_timeout)) begin
                                            // Poll-budget timeout reached.
                                            //
                                            // M4b (2026-06-05): peer-coordinated
                                            // training_mode release. The prior
                                            // Bug N10/N14a bypass declared
                                            // train_ok=1 here whenever local
                                            // lanes were healthy (lane_locked=0xFF,
                                            // lane_fault=0) but peer_cal_done
                                            // was still 0. ST_TRAIN_EXIT then
                                            // issued an I²C write clearing
                                            // peer's swi_training_mode_r → peer
                                            // lost the training pattern from us
                                            // mid-sweep → peer never converged.
                                            //
                                            // Silicon v16 (10 deploys, 2026-06-05)
                                            // showed 100% master-only-fail: slave
                                            // ran the bypass, wrote master's
                                            // swi_training_mode_r=0, master's
                                            // calibrator spent ~2970 retries in
                                            // S_SWEEP unable to lock against the
                                            // resulting idle data. An APB
                                            // experiment (force SWI_TRAINING_MODE=1
                                            // on both dies) instantly recovered
                                            // master's lane_locked=0xFF →
                                            // mechanism proven.
                                            //
                                            // New behavior: don't bypass here.
                                            // Re-arm the poll budget and keep our
                                            // local training_mode high. The only
                                            // exits from POLL_PEER are now:
                                            //   - primary success (block above)
                                            //   - peer_unreach_timeout_r (~1.3s)
                                            //     → ST_TRAIN_FAIL (broken peer)
                                            if (peer_unreach_timeout_r) begin
                                                local_lane_fault_snapshot_nxt = local_swi_lane_fault_i;
                                                train_fail_nxt                = 1'b1;
                                                state_nxt                     = ST_TRAIN_FAIL;
                                            end else begin
                                                // Re-arm poll budget; keep
                                                // training_mode high.
                                                // M4f: lock dwell counter
                                                // resets on lock drop.
                                                consec_locked_polls_nxt = 4'd0;
                                                poll_attempt_nxt     = 4'd0;
                                                mask_byte_cnt_nxt    = 3'd0;
                                                txn_step_nxt         = TXN_DATA;
                                                train_poll_phase_nxt = 1'b0;
                                            end
                                        end else begin
                                            // Re-poll: increment attempt,
                                            // re-arm address-write sub-phase.
                                            // M4f: lock dwell counter resets
                                            // on lock drop (we got here
                                            // because the bilateral-lock
                                            // predicate above failed).
                                            consec_locked_polls_nxt = 4'd0;
                                            poll_attempt_nxt    = poll_attempt_r + 4'd1;
                                            mask_byte_cnt_nxt   = 3'd0;
                                            txn_step_nxt        = TXN_DATA;
                                            train_poll_phase_nxt = 1'b0;
                                        end
                                    end else begin
                                        mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
                                        txn_step_nxt      = TXN_COMMAND;
                                    end
                                end
                            end
                            default: ;
                        endcase
                    end
                end

                ST_TRAIN_EXIT: begin
                    // I²C-write peer's SWI_TRAINING_MODE := 0. Hold local
                    // swreset for T_SWRESET_HOLD cycles before TRAIN_DONE.
                    case (txn_step_r)
                        TXN_DATA: begin
                            if (axl_done_r) begin
                                if (mask_byte_cnt_r == TRAIN_MODE_WR_BYTES - 3'd1) begin
                                    txn_step_nxt = TXN_COMMAND;
                                end else begin
                                    mask_byte_cnt_nxt = mask_byte_cnt_r + 3'd1;
                                end
                            end
                        end
                        TXN_COMMAND: if (axl_done_r) txn_step_nxt = TXN_POLL;
                        TXN_POLL:    if (axl_done_r) txn_step_nxt = TXN_CHECK;
                        TXN_CHECK: begin
                            if (!axl_rdata_r[I2C_STS_BUSY] && busy_seen_r) begin
                                if (axl_rdata_r[I2C_STS_MISS_ACK]) begin
                                    // Peer NACK'd the exit write. Local
                                    // side already cleared; surface as fail.
                                    train_peer_nack_nxt = 1'b1;
                                    train_fail_nxt      = 1'b1;
                                    local_train_clr_pulse_r = 1'b1;
                                    state_nxt           = ST_TRAIN_FAIL;
                                end else begin
                                    local_train_clr_pulse_r = 1'b1;
                                    swreset_hold_nxt        = T_SWRESET_HOLD;
                                    train_ok_nxt            = 1'b1;
                                    state_nxt               = ST_TRAIN_DONE;
                                end
                            end else begin
                                txn_step_nxt = TXN_POLL;
                            end
                        end
                        default: ;
                    endcase
                end

                ST_TRAIN_DONE: begin
                    // Terminal-OK. Drain swreset_hold counter so
                    // local_swreset_pulse falls cleanly. Allow retrain on
                    // SW request (train_retrain_req from W1P bit).
                    if (swreset_hold_r != '0)
                        swreset_hold_nxt = swreset_hold_r - 7'd1;
                    if (train_retrain_req) begin
                        train_ok_nxt        = 1'b0;
                        train_fail_nxt      = 1'b0;
                        train_peer_nack_nxt = 1'b0;
                        state_nxt           = ST_NEGO_DONE_PRE;
                    end
                end

                ST_TRAIN_FAIL: begin
                    // Terminal-FAIL. Stickies hold; allow retrain.
                    if (train_retrain_req) begin
                        train_fail_nxt      = 1'b0;
                        train_peer_nack_nxt = 1'b0;
                        state_nxt           = ST_NEGO_DONE_PRE;
                    end
                end

                ST_NEGO_DONE: begin
                    // Terminal state — wait for POR
                end

                ST_BYPASS: begin
                    // Static-assignment terminal — but allow re-arming if SW
                    // programs nego_en after the FSM has already entered
                    // BYPASS. Avoids the chicken-and-egg problem where SW
                    // can only configure NEGO_CFG post-reset, by which point
                    // the FSM has sampled nego_en=0 and parked in BYPASS.
                    if (nego_en) begin
                        nego_role_nxt   = 1'b1;
                        timeout_ctr_nxt = nego_timeout_reg;
                        state_nxt       = ST_NEGO_INIT;
                    end
                end

                ST_ERROR: begin
                    // Terminal state — fallback applied
                end

                // SILICON BUG #3 structural fix (2026-05-20): outer
                // case(state_r) was decoding only 11 of 16 possible 4-bit
                // encodings without a default. Synth log: "[Synth 8-155]
                // case statement is not full and has no default
                // [tidelink_autoneg.sv:444]". Vivado's optimizer interpreted
                // the missing default as freedom to collapse the
                // `if (mask_hs_auto_en)` gate at line 565 (the POLL→MASK
                // transition for the master-winning path), so state never
                // entered state 9 (MASK_RD_ADDR) on silicon even with
                // NEGO_CFG[6]=1. Same class as the be5eed2 txn_step_nxt
                // latch fix. Adding the explicit default forces synth to
                // honour every state's transitions. ASIC-portable (no
                // Xilinx-specific attributes). See bench evidence in
                // staging/i2c_train/HW_VALIDATION_RESULTS.md §A.10-A.11.
                default: state_nxt = state_r;
            endcase
        end
    end

    // =====================================================================
    // AXI-Lite sub-state machine — drives individual register transactions
    // =====================================================================
    // Determines what to write/read based on txn_step_r
    reg  [7:0] axl_target_addr;
    reg [31:0] axl_target_wdata;
    reg        axl_is_read;

    // Byte to push during the result-write transaction (selected by
    // mask_byte_cnt_r). Bytes 0/1 are the AXIL address (MSB/LSB); bytes 2-5
    // are the 4-byte data payload, of which only byte 2 (the LSB) carries
    // the match/fail token and the rest are zero. The token is sourced
    // directly from the comparator wire (not the sticky latch) so the
    // result-write reflects the verdict during MASK_RES_TX without
    // requiring the latch to fire — that latch is deferred to the
    // RES_TX → DONE edge to keep nego_driving asserted through the
    // entire transaction.
    reg [7:0] mask_res_byte;
    reg       mask_res_last;
    wire [7:0] mask_res_verdict_byte = mask_match_w ? 8'h01 : 8'h02;
    always_comb begin
        case (mask_byte_cnt_r)
            3'd0: begin mask_res_byte = MASK_RES_ADDR_MSB;     mask_res_last = 1'b0; end
            3'd1: begin mask_res_byte = MASK_RES_ADDR_LSB;     mask_res_last = 1'b0; end
            3'd2: begin mask_res_byte = mask_res_verdict_byte; mask_res_last = 1'b0; end
            3'd3: begin mask_res_byte = 8'h00;                 mask_res_last = 1'b0; end
            3'd4: begin mask_res_byte = 8'h00;                 mask_res_last = 1'b0; end
            3'd5: begin mask_res_byte = 8'h00;                 mask_res_last = 1'b1; end
            default: begin mask_res_byte = 8'h00;              mask_res_last = 1'b0; end
        endcase
    end

    // Byte to push during the read-phase address write (selected by
    // mask_byte_cnt_r). 2 bytes total: 0x02, 0x14 (peer's link_lane_mask
    // offset). The second is marked data_last so cmd_write_multiple
    // releases the wr-data FIFO.
    reg [7:0] mask_rd_addr_byte;
    reg       mask_rd_addr_last;
    always_comb begin
        case (mask_byte_cnt_r)
            3'd0: begin mask_rd_addr_byte = MASK_RD_ADDR_MSB; mask_rd_addr_last = 1'b0; end
            3'd1: begin mask_rd_addr_byte = MASK_RD_ADDR_LSB; mask_rd_addr_last = 1'b1; end
            default: begin mask_rd_addr_byte = 8'h00;         mask_rd_addr_last = 1'b0; end
        endcase
    end

    // ---- Phase 3 byte sources ----
    // 6-byte write to peer's SWI_TRAINING_MODE @ 0x2100: [addr_MSB, addr_LSB,
    // training_value, 0, 0, 0]. training_value = 1 in ENTER, 0 in EXIT.
    reg [7:0] train_mode_wr_byte;
    reg       train_mode_wr_last;
    always_comb begin
        case (mask_byte_cnt_r)
            3'd0: begin train_mode_wr_byte = TRAIN_MODE_ADDR_MSB;          train_mode_wr_last = 1'b0; end
            3'd1: begin train_mode_wr_byte = TRAIN_MODE_ADDR_LSB;          train_mode_wr_last = 1'b0; end
            3'd2: begin train_mode_wr_byte = {7'd0, train_target_value_r}; train_mode_wr_last = 1'b0; end
            3'd3: begin train_mode_wr_byte = 8'h00;                        train_mode_wr_last = 1'b0; end
            3'd4: begin train_mode_wr_byte = 8'h00;                        train_mode_wr_last = 1'b0; end
            3'd5: begin train_mode_wr_byte = 8'h00;                        train_mode_wr_last = 1'b1; end
            default: begin train_mode_wr_byte = 8'h00;                     train_mode_wr_last = 1'b0; end
        endcase
    end

    // 2-byte read-pointer set-up for peer's SWI_LANE_STATUS @ 0x2108. Used in
    // ST_TRAIN_POLL_PEER phase 0 (address-write sub-phase).
    reg [7:0] train_status_addr_byte;
    reg       train_status_addr_last;
    always_comb begin
        case (mask_byte_cnt_r)
            3'd0: begin train_status_addr_byte = TRAIN_STATUS_ADDR_MSB; train_status_addr_last = 1'b0; end
            3'd1: begin train_status_addr_byte = TRAIN_STATUS_ADDR_LSB; train_status_addr_last = 1'b1; end
            default: begin train_status_addr_byte = 8'h00;              train_status_addr_last = 1'b0; end
        endcase
    end

    // Peer-mask byte capture. In ST_NEGO_MASK_RD_DATA TXN_DATA, after
    // axl_done arrives the rdata holds the just-popped byte from the
    // master's rd-data FIFO. mask_byte_cnt_r=0 → peer.tx_lane_mask;
    // mask_byte_cnt_r=1 → peer.rx_lane_mask; bytes 2/3 are the
    // unused upper half of the 32-bit register and are discarded.
    //
    // Defense-in-depth (mask-FSM audit, 2026-05-21): gate capture on the
    // I²C master's data_valid bit (axl_rdata_r[8]). Per
    // i2c_master_axil.v:181 the DATA register read returns
    // [8]=data_valid, [7:0]=data; if the rd-data FIFO is empty when we
    // pop, data_valid=0 and [7:0] is garbage. The busy/busy_seen guard
    // in TXN_CHECK already ensures the I²C transaction completed before
    // we issue this DATA read, so today data_valid should always be 1
    // — but checking explicitly prevents a poisoned peer-mask comparator
    // verdict if the I²C master IP ever introduces a 1-cycle lag between
    // busy-drop and FIFO-push, or if a glitch eats the byte.
    always_comb begin
        peer_tx_capture_en = 1'b0;
        peer_rx_capture_en = 1'b0;
        if (state_r == ST_NEGO_MASK_RD_DATA &&
            txn_step_r == TXN_DATA && axl_done_r &&
            axl_rdata_r[I2C_DATA_VALID]) begin
            if (mask_byte_cnt_r == 3'd0)
                peer_tx_capture_en = 1'b1;
            else if (mask_byte_cnt_r == 3'd1)
                peer_rx_capture_en = 1'b1;
        end
    end

    always_comb begin
        axl_target_addr  = 8'd0;
        axl_target_wdata = 32'd0;
        axl_is_read      = 1'b0;

        case (txn_step_r)
            TXN_PRESCALE: begin
                axl_target_addr  = {4'd0, I2C_REG_PRESCALE};
                axl_target_wdata = {16'd0, i2c_prescale_reg};
            end
            TXN_DATA: begin
                axl_target_addr  = {4'd0, I2C_REG_DATA};
                if (state_r == ST_NEGO_MASK_RES_TX) begin
                    // [9]=data_last, [8]=data_valid (auto-set on write), [7:0]=data
                    axl_target_wdata = {22'd0, mask_res_last, 1'b0, mask_res_byte};
                end else if (state_r == ST_NEGO_MASK_RD_ADDR) begin
                    // Push the 2 address bytes (0x02, 0x14) for the
                    // peer-mask register read pointer set-up.
                    axl_target_wdata = {22'd0, mask_rd_addr_last, 1'b0,
                                        mask_rd_addr_byte};
                end else if (state_r == ST_NEGO_MASK_RD_DATA) begin
                    // Drain phase: TXN_DATA reads the master's DATA register
                    // to pull one byte from the rd-data FIFO. axl_is_read=1
                    // (set below).
                    axl_target_wdata = 32'd0;
                end else if (state_r == ST_TRAIN_ENTER ||
                             state_r == ST_TRAIN_EXIT) begin
                    // 6-byte write to SWI_TRAINING_MODE @ 0x2100
                    axl_target_wdata = {22'd0, train_mode_wr_last, 1'b0,
                                        train_mode_wr_byte};
                end else if (state_r == ST_TRAIN_POLL_PEER &&
                             train_poll_phase_r == 1'b0) begin
                    // Address-write sub-phase: push 2-byte pointer for
                    // SWI_LANE_STATUS @ 0x2108
                    axl_target_wdata = {22'd0, train_status_addr_last, 1'b0,
                                        train_status_addr_byte};
                end else if (state_r == ST_TRAIN_POLL_PEER &&
                             train_poll_phase_r == 1'b1) begin
                    // Read sub-phase: DATA register read pulls one byte
                    axl_target_wdata = 32'd0;
                end else begin
                    // Legacy claim transaction: single byte 0x01
                    axl_target_wdata = 32'h01;
                end
                if (state_r == ST_NEGO_MASK_RD_DATA ||
                    (state_r == ST_TRAIN_POLL_PEER && train_poll_phase_r == 1'b1))
                    axl_is_read = 1'b1;
            end
            TXN_COMMAND: begin
                axl_target_addr  = {4'd0, I2C_REG_COMMAND};
                if (state_r == ST_NEGO_MASK_RES_TX) begin
                    // cmd_start | cmd_write_multiple | cmd_stop
                    axl_target_wdata = {19'd0,
                                        1'b1,               // [12] cmd_stop
                                        1'b1,               // [11] cmd_wr_mult
                                        1'b0,               // [10] cmd_write
                                        1'b0,               // [9]  cmd_read
                                        1'b1,               // [8]  cmd_start
                                        1'b0,               // [7]  reserved
                                        NEGO_ADDR_DEFAULT}; // [6:0] address
                end else if (state_r == ST_NEGO_MASK_RD_ADDR) begin
                    // cmd_start | cmd_write_multiple, NO STOP — the
                    // following MASK_RD_DATA phase issues a repeated
                    // start to flip into the read direction.
                    axl_target_wdata = {19'd0,
                                        1'b0,               // [12] cmd_stop
                                        1'b1,               // [11] cmd_wr_mult
                                        1'b0,               // [10] cmd_write
                                        1'b0,               // [9]  cmd_read
                                        1'b1,               // [8]  cmd_start
                                        1'b0,               // [7]  reserved
                                        NEGO_ADDR_DEFAULT};
                end else if (state_r == ST_NEGO_MASK_RD_DATA) begin
                    // Per-byte cmd_read. mask_byte_cnt_r=0 also asserts
                    // cmd_start (repeated start, switches the bus from
                    // write to read direction); mask_byte_cnt_r=3 also
                    // asserts cmd_stop (releases the bus after the last
                    // byte). Bytes 1/2 just pull the next data byte.
                    axl_target_wdata = {19'd0,
                                        (mask_byte_cnt_r == MASK_RD_DATA_BYTES - 3'd1), // [12] cmd_stop
                                        1'b0,                                            // [11] cmd_wr_mult
                                        1'b0,                                            // [10] cmd_write
                                        1'b1,                                            // [9]  cmd_read
                                        (mask_byte_cnt_r == 3'd0),                       // [8]  cmd_start
                                        1'b0,                                            // [7]  reserved
                                        NEGO_ADDR_DEFAULT};
                end else if (state_r == ST_TRAIN_ENTER ||
                             state_r == ST_TRAIN_EXIT) begin
                    // 6-byte cmd_write_multiple with START + STOP. Same
                    // shape as ST_NEGO_MASK_RES_TX.
                    axl_target_wdata = {19'd0,
                                        1'b1,               // cmd_stop
                                        1'b1,               // cmd_wr_mult
                                        1'b0,               // cmd_write
                                        1'b0,               // cmd_read
                                        1'b1,               // cmd_start
                                        1'b0,
                                        NEGO_ADDR_DEFAULT};
                end else if (state_r == ST_TRAIN_POLL_PEER &&
                             train_poll_phase_r == 1'b0) begin
                    // Address-write phase: cmd_write_multiple with START,
                    // NO STOP (pointer set, repeated start follows).
                    axl_target_wdata = {19'd0,
                                        1'b0,               // cmd_stop
                                        1'b1,               // cmd_wr_mult
                                        1'b0,               // cmd_write
                                        1'b0,               // cmd_read
                                        1'b1,               // cmd_start
                                        1'b0,
                                        NEGO_ADDR_DEFAULT};
                end else if (state_r == ST_TRAIN_POLL_PEER &&
                             train_poll_phase_r == 1'b1) begin
                    // Per-byte cmd_read for SWI_LANE_STATUS. byte 0 sets
                    // cmd_start (repeated start), byte 3 sets cmd_stop.
                    axl_target_wdata = {19'd0,
                                        (mask_byte_cnt_r == MASK_RD_DATA_BYTES - 3'd1),
                                        1'b0,
                                        1'b0,
                                        1'b1,                                  // cmd_read
                                        (mask_byte_cnt_r == 3'd0),             // cmd_start
                                        1'b0,
                                        NEGO_ADDR_DEFAULT};
                end else begin
                    // Legacy claim: cmd_start | cmd_write | cmd_stop
                    axl_target_wdata = {19'd0,
                                        1'b1,               // [12] cmd_stop
                                        1'b0,               // [11] cmd_wr_mult
                                        1'b1,               // [10] cmd_write
                                        1'b0,               // [9]  cmd_read
                                        1'b1,               // [8]  cmd_start
                                        1'b0,               // [7]  reserved
                                        NEGO_ADDR_DEFAULT};
                end
            end
            TXN_POLL: begin
                axl_target_addr = {4'd0, I2C_REG_STATUS};
                axl_is_read     = 1'b1;
            end
            // TXN_CHECK and TXN_DONE are pure FSM-evaluation steps — no
            // AXIL transaction needed. The AXL drive gate excludes them
            // (see below) so the lookup defaults are unused.
            default: ;
        endcase
    end

    // AXI-Lite output drive logic
    always_comb begin
        // Defaults: deassert all
        m_axil_awaddr  = 8'd0;
        m_axil_awvalid = 1'b0;
        m_axil_wdata   = 32'd0;
        m_axil_wstrb   = 4'b0000;
        m_axil_wvalid  = 1'b0;
        m_axil_bready  = 1'b0;
        m_axil_araddr  = 8'd0;
        m_axil_arvalid = 1'b0;
        m_axil_rready  = 1'b0;

        axl_state_nxt  = axl_state_r;
        axl_done_nxt   = 1'b0;
        axl_rdata_nxt  = axl_rdata_r;

        // NOTE: do not drive m_axil_rready outside AXL_RD_DATA. The i2c
        // master IP asserts rvalid one cycle after arready and clears
        // it on rready=1; an unconditional drain would eat that rvalid
        // pulse in the cycle between the FSM observing arready and
        // entering AXL_RD_DATA, leaving the read response permanently
        // unobserved.

        // Only drive AXIL transactions when in an active master-side state
        // (CLAIM/POLL/MASK_RES_TX/MASK_RD_ADDR/MASK_RD_DATA/TRAIN_*) AND
        // the txn_step actually has work to do (not CHECK or DONE — those
        // are pure FSM evaluation steps with no AXIL target).
        if (((state_r == ST_NEGO_CLAIM && init_wait_r == '0) ||
              state_r == ST_NEGO_POLL ||
              state_r == ST_NEGO_MASK_RES_TX ||
              state_r == ST_NEGO_MASK_RD_ADDR ||
              state_r == ST_NEGO_MASK_RD_DATA ||
              state_r == ST_TRAIN_ENTER ||
              state_r == ST_TRAIN_POLL_PEER ||
              state_r == ST_TRAIN_EXIT) &&
             (txn_step_r == TXN_PRESCALE || txn_step_r == TXN_DATA ||
              txn_step_r == TXN_COMMAND  || txn_step_r == TXN_POLL)) begin
            case (axl_state_r)
                AXL_IDLE: if (!axl_done_r) begin
                    // Hold AXL_IDLE while axl_done_r is asserted — the main
                    // FSM still has to consume that pulse to advance txn_step
                    // (or mask_byte_cnt). Starting a new transaction here
                    // would race with the about-to-happen txn_step transition
                    // and leave AXL stranded mid-transaction once the gate
                    // closes (e.g. on TXN_POLL→TXN_CHECK).
                    if (!axl_is_read) begin
                        // Start write transaction
                        m_axil_awaddr  = axl_target_addr;
                        m_axil_awvalid = 1'b1;
                        m_axil_wdata   = axl_target_wdata;
                        m_axil_wstrb   = 4'b1111;
                        m_axil_wvalid  = 1'b1;
                        if (m_axil_awready && m_axil_wready)
                            axl_state_nxt = AXL_WR_RESP;
                        else if (m_axil_awready)
                            axl_state_nxt = AXL_WR_DATA;
                        else if (m_axil_wready)
                            axl_state_nxt = AXL_WR_ADDR;
                    end else begin
                        // Start read transaction
                        m_axil_araddr  = axl_target_addr;
                        m_axil_arvalid = 1'b1;
                        if (m_axil_arready)
                            axl_state_nxt = AXL_RD_DATA;
                    end
                end

                AXL_WR_ADDR: begin
                    m_axil_awaddr  = axl_target_addr;
                    m_axil_awvalid = 1'b1;
                    if (m_axil_awready)
                        axl_state_nxt = AXL_WR_RESP;
                end

                AXL_WR_DATA: begin
                    m_axil_wdata  = axl_target_wdata;
                    m_axil_wstrb  = 4'b1111;
                    m_axil_wvalid = 1'b1;
                    if (m_axil_wready)
                        axl_state_nxt = AXL_WR_RESP;
                end

                AXL_WR_RESP: begin
                    m_axil_bready = 1'b1;
                    if (m_axil_bvalid) begin
                        axl_done_nxt  = 1'b1;
                        axl_state_nxt = AXL_IDLE;
                    end
                end

                AXL_RD_ADDR: begin
                    m_axil_araddr  = axl_target_addr;
                    m_axil_arvalid = 1'b1;
                    if (m_axil_arready)
                        axl_state_nxt = AXL_RD_DATA;
                end

                AXL_RD_DATA: begin
                    m_axil_rready = 1'b1;
                    if (m_axil_rvalid) begin
                        axl_rdata_nxt = m_axil_rdata;
                        axl_done_nxt  = 1'b1;
                        axl_state_nxt = AXL_IDLE;
                    end
                end

                default: axl_state_nxt = AXL_IDLE;
            endcase
        end
    end

    // =====================================================================
    // Sequential logic — POR-only reset domain
    // =====================================================================
    always_ff @(posedge clk or negedge poresetn) begin
        if (!poresetn) begin
            state_r          <= ST_IDLE;
            delay_ctr_r      <= '0;
            timeout_ctr_r    <= '0;
            init_wait_r      <= '0;
            axl_state_r      <= AXL_IDLE;
            txn_step_r       <= TXN_PRESCALE;
            axl_done_r       <= 1'b0;
            axl_rdata_r      <= '0;
            nego_role_r      <= 1'b1;  // default slave
            nego_done_r      <= 1'b0;
            nego_error_r     <= 1'b0;
            nego_won_r       <= 1'b0;
            nego_lost_r      <= 1'b0;
            sda_start_seen_r <= 1'b0;
            mask_byte_cnt_r  <= 3'd0;
            busy_seen_r      <= 1'b0;
            // Phase 3 — training-mode registers
            train_wait_r                <= '0;
            poll_attempt_r              <= '0;
            swreset_hold_r              <= '0;
            peer_unreach_ctr_r          <= T_PEER_UNREACH_DEFAULT;
            peer_unreach_timeout_r      <= 1'b0;
            consec_locked_polls_r       <= 4'd0;
            peer_lane_locked_r          <= 8'h00;
            peer_lane_fault_r           <= 8'h00;
            peer_cal_done_r             <= 1'b0;
            local_lane_fault_snapshot_r <= 8'h00;
            train_ok_r                  <= 1'b0;
            train_fail_r                <= 1'b0;
            train_peer_nack_r           <= 1'b0;
            train_target_value_r        <= 1'b0;
            train_poll_phase_r          <= 1'b0;
        end else begin
            state_r          <= state_nxt;
            delay_ctr_r      <= delay_ctr_nxt;
            timeout_ctr_r    <= timeout_ctr_nxt;
            init_wait_r      <= init_wait_nxt;
            axl_state_r      <= axl_state_nxt;
            txn_step_r       <= txn_step_nxt;
            // Clear axl_done across a state transition so stale "done" from
            // a previous transaction's STATUS read doesn't get mistaken
            // for a fresh-write completion in the next state's TXN_DATA.
            axl_done_r       <= (state_nxt != state_r) ? 1'b0 : axl_done_nxt;
            axl_rdata_r      <= axl_rdata_nxt;
            nego_role_r      <= nego_role_nxt;
            nego_done_r      <= nego_done_nxt;
            nego_error_r     <= nego_error_nxt;
            nego_won_r       <= nego_won_nxt;
            nego_lost_r      <= nego_lost_nxt;
            sda_start_seen_r <= sda_start_seen_nxt;
            mask_byte_cnt_r  <= mask_byte_cnt_nxt;
            busy_seen_r      <= busy_seen_nxt;
            // Phase 3
            train_wait_r         <= train_wait_nxt;
            poll_attempt_r       <= poll_attempt_nxt;
            swreset_hold_r       <= swreset_hold_nxt;
            peer_unreach_ctr_r     <= peer_unreach_ctr_nxt;
            peer_unreach_timeout_r <= peer_unreach_timeout_nxt;
            consec_locked_polls_r  <= consec_locked_polls_nxt;
            // Peer-byte captures: if capture_en pulses, latch axl_rdata_r[7:0];
            // otherwise hold (or take the _nxt assignment from the main_comb).
            if (peer_lane_locked_capture_en)
                peer_lane_locked_r <= axl_rdata_r[7:0];
            else
                peer_lane_locked_r <= peer_lane_locked_nxt;
            if (peer_lane_fault_capture_en)
                peer_lane_fault_r  <= axl_rdata_r[7:0];
            else
                peer_lane_fault_r  <= peer_lane_fault_nxt;
            if (peer_cal_done_capture_en)
                peer_cal_done_r    <= axl_rdata_r[0];
            else
                peer_cal_done_r    <= peer_cal_done_nxt;
            local_lane_fault_snapshot_r <= local_lane_fault_snapshot_nxt;
            train_ok_r                  <= train_ok_nxt;
            train_fail_r                <= train_fail_nxt;
            train_peer_nack_r           <= train_peer_nack_nxt;
            train_target_value_r        <= train_target_value_nxt;
            train_poll_phase_r          <= train_poll_phase_nxt;
        end
    end

    // =====================================================================
    // Output assignments
    // =====================================================================
    assign nego_state     = state_r[3:0];  // legacy 4-bit NEGO_STATUS[3:0]
                                            // — train_state_o is reported
                                            // separately through Region 8.
    assign nego_done      = nego_done_r;
    assign nego_error     = nego_error_r;
    assign nego_won       = nego_won_r;
    assign nego_lost      = nego_lost_r;
    assign sda_start_seen = sda_start_seen_r;
    assign nego_error_irq = nego_error_r;

    // ── Phase 3 outputs ──────────────────────────────────────────────────
    // Map the 5-bit internal state to the 4-bit re-encoded train_state for
    // NEGO_TRAIN_STATUS[7:4].
    assign train_state_o = (state_r == ST_NEGO_DONE_PRE)    ? 4'd0 :
                           (state_r == ST_TRAIN_ENTER)      ? 4'd1 :
                           (state_r == ST_TRAIN_RUN)        ? 4'd2 :
                           (state_r == ST_TRAIN_POLL_PEER)  ? 4'd3 :
                           (state_r == ST_TRAIN_EXIT)       ? 4'd4 :
                           (state_r == ST_TRAIN_DONE)       ? 4'd5 :
                           (state_r == ST_TRAIN_FAIL)       ? 4'd6 :
                                                              4'd0;

    assign train_ok_o            = train_ok_r;
    assign train_fail_o          = train_fail_r;
    assign train_in_progress_o   = (state_r == ST_NEGO_DONE_PRE) ||
                                    (state_r == ST_TRAIN_ENTER)   ||
                                    (state_r == ST_TRAIN_RUN)     ||
                                    (state_r == ST_TRAIN_POLL_PEER)||
                                    (state_r == ST_TRAIN_EXIT);
    assign train_peer_nack_o          = train_peer_nack_r;
    assign train_peer_lane_locked_o   = peer_lane_locked_r;
    assign train_peer_lane_fault_o    = peer_lane_fault_r;
    assign train_local_lane_fault_o   = local_lane_fault_snapshot_r;
    assign train_fail_irq_o           = train_fail_r;

    assign local_training_mode_set = local_train_set_pulse_r;
    assign local_training_mode_clr = local_train_clr_pulse_r;
    assign local_swreset_pulse     = (swreset_hold_r != '0);

    // Mark train_sw_step as deliberately unused in v1 to suppress lint.
    /* verilator lint_off UNUSED */
    wire _unused_train_sw_step = train_sw_step;
    /* verilator lint_on UNUSED */

    // ── Bug N7/N8 silicon observability passthrough ────────────────────────
    //   Snapshot of internal counters/state for APB Region C readback. All
    //   regs are existing module-internal state — wiring them to output
    //   ports is purely additive; no new always-blocks needed.
    assign obs_delay_ctr_o   = delay_ctr_r;
    assign obs_timeout_ctr_o = timeout_ctr_r;
    assign obs_init_wait_o   = init_wait_r;
    assign obs_axl_state_o   = axl_state_r;
    assign obs_txn_step_o    = txn_step_r;

endmodule
