// =============================================================================
// tidelink_phy_align_regs.sv — APB-decoded shim for §9 PHY alignment controls
// =============================================================================
//
// Provides a small APB-writable register block exposing:
//   - swi_bit_slip[23:0]      (8 lanes × 3 bits, per-lane bit-slip SW override)
//   - swi_training_mode       (1 bit, TX serialiser training-pattern SW override)
//
// And RO status registers driven by the on-chip auto-calibration FSM
// (tidelink_phy_align_calibrator):
//   - swi_lane_locked[7:0]    (per-lane locked status from lane checker)
//   - swi_lane_fault[7:0]     (sticky per-lane fault from calibrator)
//   - swi_calibration_done    (calibration FSM has completed the sweep)
//
// The SW-writable swi_bit_slip / swi_training_mode regs act as SW OVERRIDE for
// the autocal FSM: the chiplet-controller ORs the calibrator's outputs with
// these SW registers before driving Wlink, so SW can either (a) leave them at
// 0 and let the autocal FSM run (production / autonomous bring-up), or
// (b) write non-zero values for debug / characterisation. The cocotb sandbox
// (which uses hierarchical-force into WavD2DGpio.swi_bit_slip) is unaffected:
// the WavD2DGpio-internal OR-mux already merges hierarchical writes with the
// external port chain.
//
// APB layout (offsets relative to base address — typical 0x4403_1xxx on master):
//   +0x00  SWI_BIT_SLIP            RW  [23:0]  per-lane bit-slip SW override, packed 8×3
//   +0x04  SWI_TRAINING_MODE       RW  [0]     training-mode SW override
//   +0x08  SWI_LANE_LOCKED         RO  [7:0]   per-lane locked status (from checker)
//   +0x0C  SWI_LANE_FAULT          RO  [7:0]   per-lane sticky fault (from calibrator)
//   +0x10  SWI_CALIBRATION_DONE    RO  [0]     calibration FSM done flag
//                                              [8]=calibration_done, [15:8]=cal state[3:0]
//
// =============================================================================

`timescale 1ns/1ps

module tidelink_phy_align_regs (
    input  wire        clk,
    input  wire        rstn,           // active-low reset

    // APB slave (32-bit data, byte-strobed)
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,          // local offset within this block
    input  wire [31:0] pwdata,
    input  wire [3:0]  pstrb,
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // SW-override outputs (OR'd with calibrator outputs in the chiplet
    // controller before driving Wlink's swi_bit_slip_in / swi_training_mode_in).
    output wire [23:0] swi_bit_slip_o,
    output wire        swi_training_mode_o,

    // RO status inputs from the autocal FSM / lane checker.
    // Resampled into the apb_clk domain via a 2-flop synchroniser below —
    // these inputs are nominally in the link_rx_clk domain.
    input  wire [7:0]  lane_locked_in,
    input  wire [7:0]  lane_fault_in,
    input  wire        calibration_done_in,
    input  wire [3:0]  cal_state_in
);

    // Single-cycle APB slave (always ready, no error)
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    wire access_phase = psel & penable;
    wire write_strobe = access_phase & pwrite;

    // -------------------------------------------------------------------------
    // CDC: status signals come from the link-rx clock; resample for APB reads.
    // 2-flop synchroniser per bit. The signals are slow-changing so simple
    // flop-flop CDC is sufficient.
    // -------------------------------------------------------------------------
    reg [7:0]  lane_locked_sync0,  lane_locked_sync1;
    reg [7:0]  lane_fault_sync0,   lane_fault_sync1;
    reg        cal_done_sync0,     cal_done_sync1;
    reg [3:0]  cal_state_sync0,    cal_state_sync1;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            lane_locked_sync0 <= 8'h0;
            lane_locked_sync1 <= 8'h0;
            lane_fault_sync0  <= 8'h0;
            lane_fault_sync1  <= 8'h0;
            cal_done_sync0    <= 1'b0;
            cal_done_sync1    <= 1'b0;
            cal_state_sync0   <= 4'h0;
            cal_state_sync1   <= 4'h0;
        end else begin
            lane_locked_sync0 <= lane_locked_in;
            lane_locked_sync1 <= lane_locked_sync0;
            lane_fault_sync0  <= lane_fault_in;
            lane_fault_sync1  <= lane_fault_sync0;
            cal_done_sync0    <= calibration_done_in;
            cal_done_sync1    <= cal_done_sync0;
            cal_state_sync0   <= cal_state_in;
            cal_state_sync1   <= cal_state_sync0;
        end
    end

    // Register storage (SW override)
    reg [23:0] swi_bit_slip_r;
    reg        swi_training_mode_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            swi_bit_slip_r      <= 24'h0;
            swi_training_mode_r <= 1'b0;
        end else if (write_strobe) begin
            case (paddr[4:2])  // 4-byte stride, 5 offsets used
                3'b000: begin   // +0x00 SWI_BIT_SLIP
                    if (pstrb[0]) swi_bit_slip_r[7:0]   <= pwdata[7:0];
                    if (pstrb[1]) swi_bit_slip_r[15:8]  <= pwdata[15:8];
                    if (pstrb[2]) swi_bit_slip_r[23:16] <= pwdata[23:16];
                end
                3'b001: begin   // +0x04 SWI_TRAINING_MODE
                    if (pstrb[0]) swi_training_mode_r <= pwdata[0];
                end
                default: ;
            endcase
        end
    end

    // Read mux
    always @* begin
        case (paddr[4:2])
            3'b000:  prdata = {8'h0, swi_bit_slip_r};
            3'b001:  prdata = {31'h0, swi_training_mode_r};
            3'b010:  prdata = {24'h0, lane_locked_sync1};
            3'b011:  prdata = {24'h0, lane_fault_sync1};
            3'b100:  prdata = {16'h0, 4'h0, cal_state_sync1, 7'h0, cal_done_sync1};
            default: prdata = 32'h0;
        endcase
    end

    assign swi_bit_slip_o      = swi_bit_slip_r;
    assign swi_training_mode_o = swi_training_mode_r;

endmodule
