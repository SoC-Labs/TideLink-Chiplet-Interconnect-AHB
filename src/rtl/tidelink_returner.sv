//-----------------------------------------------------------------------------
// SoCLabs TideLink Returner
// - A simple AHB Lite master that performs a single-beat write transfer
//   when any of three interrupt channels is asserted. Channel 0 has
//   highest priority, channel 2 has lowest.
// - Uses pending registers so short pulses are never lost, even if the
//   returner is busy when the pulse fires.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_returner #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32
)(
    // Clock and Reset
    input  wire                  hclk,
    input  wire                  hresetn,

    // Interrupt channel 0 (release credits — highest priority)
    input  wire                  interrupt_0,
    input  wire [SYS_ADDR_W-1:0] write_addr_0,
    input  wire [SYS_DATA_W-1:0] write_data_0,

    // Interrupt channel 1 (doorbell — medium priority)
    input  wire                  interrupt_1,
    input  wire [SYS_ADDR_W-1:0] write_addr_1,
    input  wire [SYS_DATA_W-1:0] write_data_1,

    // Interrupt channel 2 (reset doorbell — lowest priority)
    input  wire                  interrupt_2,
    input  wire [SYS_ADDR_W-1:0] write_addr_2,
    input  wire [SYS_DATA_W-1:0] write_data_2,

    // AHB Lite Master Interface
    output logic [SYS_ADDR_W-1:0] haddr,
    output logic [SYS_DATA_W-1:0] hwdata,
    output logic            [1:0] htrans,
    output logic            [2:0] hsize,
    output logic                  hwrite,
    input  wire                   hready,
    // hal lint_off USEPRT
    input  wire                   hresp,         // AHB spec — unused by write-only master
    input  wire  [SYS_DATA_W-1:0] hrdata,        // AHB spec — unused by write-only master
    // hal lint_on USEPRT

    // Status output
    output wire                   busy,

    // Sticky error flag: set when master port receives ERROR response
    output wire                   master_error,

    // Control input: clears master_error
    input  wire                   flush
);

    // AHB Transfer Types
    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;

    // AHB Transfer Size (32-bit word)
    localparam [2:0] HSIZE_WORD = 3'b010;

    // State encoding
    typedef enum logic [1:0] {
        ST_IDLE       = 2'b00,
        ST_ADDR_PHASE = 2'b01,
        ST_DATA_PHASE = 2'b10
    } state_t;

    state_t state_r, state_next;

    // Registered write parameters (captured on interrupt)
    logic [SYS_ADDR_W-1:0] write_addr_r;
    logic [SYS_DATA_W-1:0] write_data_r;

    // Interrupt edge detection
    logic interrupt_0_r, interrupt_1_r, interrupt_2_r;
    wire  interrupt_0_rising = interrupt_0 & ~interrupt_0_r;
    wire  interrupt_1_rising = interrupt_1 & ~interrupt_1_r;
    wire  interrupt_2_rising = interrupt_2 & ~interrupt_2_r;

    // Pending registers — latch on rising edge, hold until serviced
    logic pending_0, pending_1, pending_2;
    wire  any_pending = pending_0 | pending_1 | pending_2;

    assign busy = (state_r != ST_IDLE);

    // Interrupt edge registers
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            interrupt_0_r <= 1'b0;
            interrupt_1_r <= 1'b0;
            interrupt_2_r <= 1'b0;
        end else begin
            interrupt_0_r <= interrupt_0;
            interrupt_1_r <= interrupt_1;
            interrupt_2_r <= interrupt_2;
        end
    end

    // Pending register logic: set on rising edge, clear when serviced
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            pending_0 <= 1'b0;
            pending_1 <= 1'b0;
            pending_2 <= 1'b0;
        end else begin
            // Set on rising edge (can set even while busy)
            if (interrupt_0_rising) pending_0 <= 1'b1;
            if (interrupt_1_rising) pending_1 <= 1'b1;
            if (interrupt_2_rising) pending_2 <= 1'b1;

            // Clear the highest-priority pending when transitioning out of IDLE
            if (state_r == ST_IDLE && any_pending) begin
                if      (pending_0) pending_0 <= 1'b0;
                else if (pending_1) pending_1 <= 1'b0;
                else if (pending_2) pending_2 <= 1'b0;
            end
        end
    end

    // Capture write parameters when transitioning out of IDLE (priority: 0 > 1 > 2)
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            write_addr_r <= '0;
            write_data_r <= '0;
        end else if (state_r == ST_IDLE && any_pending) begin
            if (pending_0) begin
                write_addr_r <= write_addr_0;
                write_data_r <= write_data_0;
            end else if (pending_1) begin
                write_addr_r <= write_addr_1;
                write_data_r <= write_data_1;
            end else if (pending_2) begin
                write_addr_r <= write_addr_2;
                write_data_r <= write_data_2;
            end
        end
    end

    // State register
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            state_r <= ST_IDLE;
        else
            state_r <= state_next;
    end

    // Next-state logic
    always_comb begin
        state_next = state_r;
        case (state_r)
            ST_IDLE: begin
                if (any_pending)
                    state_next = ST_ADDR_PHASE;
            end
            ST_ADDR_PHASE: begin
                if (hready)
                    state_next = ST_DATA_PHASE;
            end
            ST_DATA_PHASE: begin
                if (hready)
                    state_next = ST_IDLE;
            end
            default: state_next = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Master Error Sticky Flag
    // -------------------------------------------------------------------------
    // Set when the AHB master receives an ERROR response (hresp=1) during
    // the data phase. Sticky — remains set until cleared by flush.
    logic master_error_r;

    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            master_error_r <= 1'b0;
        else if (flush)
            master_error_r <= 1'b0;
        else if (state_r == ST_DATA_PHASE && hready && hresp)
            master_error_r <= 1'b1;
    end

    assign master_error = master_error_r;

    // AHB output logic
    always_comb begin
        haddr  = '0;
        hwdata = '0;
        htrans = HTRANS_IDLE;
        hsize  = HSIZE_WORD;
        hwrite = 1'b0;

        case (state_r)
            ST_ADDR_PHASE: begin
                haddr  = write_addr_r;
                htrans = HTRANS_NONSEQ;
                hwrite = 1'b1;
                hsize  = HSIZE_WORD;
            end
            ST_DATA_PHASE: begin
                hwdata = write_data_r;
            end
            default: ;
        endcase
    end

endmodule
