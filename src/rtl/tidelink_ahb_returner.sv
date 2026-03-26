//-----------------------------------------------------------------------------
// SoCLabs TideLink AHB Returner
// - A simple AHB Lite master that performs a single-beat write transfer
//   when either of two interrupt channels is asserted. Channel 0 has
//   priority over channel 1.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_ahb_returner #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32
)(
    // Clock and Reset
    input  wire                  hclk,
    input  wire                  hresetn,

    // Interrupt channel 0 (release tokens — higher priority)
    input  wire                  interrupt_0,
    input  wire [SYS_ADDR_W-1:0] write_addr_0,
    input  wire [SYS_DATA_W-1:0] write_data_0,

    // Interrupt channel 1 (doorbell — lower priority)
    input  wire                  interrupt_1,
    input  wire [SYS_ADDR_W-1:0] write_addr_1,
    input  wire [SYS_DATA_W-1:0] write_data_1,

    // AHB Lite Master Interface
    output logic [SYS_ADDR_W-1:0] haddr,
    output logic [SYS_DATA_W-1:0] hwdata,
    output logic            [1:0] htrans,
    output logic            [2:0] hsize,
    output logic                  hwrite,
    input  wire                   hready,
    input  wire                   hresp,
    input  wire  [SYS_DATA_W-1:0] hrdata,

    // Status output
    output wire                   busy
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

    // Interrupt edge detection — channel 0
    logic interrupt_0_r;
    wire  interrupt_0_rising;
    assign interrupt_0_rising = interrupt_0 & ~interrupt_0_r;

    // Interrupt edge detection — channel 1
    logic interrupt_1_r;
    wire  interrupt_1_rising;
    assign interrupt_1_rising = interrupt_1 & ~interrupt_1_r;

    assign busy = (state_r != ST_IDLE);

    // Interrupt edge registers
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            interrupt_0_r <= 1'b0;
            interrupt_1_r <= 1'b0;
        end else begin
            interrupt_0_r <= interrupt_0;
            interrupt_1_r <= interrupt_1;
        end
    end

    // Capture write parameters on interrupt rising edge (channel 0 has priority)
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            write_addr_r <= '0;
            write_data_r <= '0;
        end else if (state_r == ST_IDLE) begin
            if (interrupt_0_rising) begin
                write_addr_r <= write_addr_0;
                write_data_r <= write_data_0;
            end else if (interrupt_1_rising) begin
                write_addr_r <= write_addr_1;
                write_data_r <= write_data_1;
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
                if (interrupt_0_rising || interrupt_1_rising)
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
