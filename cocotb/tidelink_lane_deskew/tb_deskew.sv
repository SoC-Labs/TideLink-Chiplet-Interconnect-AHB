// =============================================================================
// tb_deskew.sv — thin cocotb test wrapper around tidelink_lane_deskew.
//
// The DUT's lane_clk / lane_data are PACKED vector ports. cocotb cannot cleanly
// (a) take a RisingEdge on a single bit of a packed input vector, nor (b) drive
// a 16-bit slice of a packed input without an X-prone read-modify-write. This
// wrapper exposes per-lane SCALAR clocks (lane_clk0..7) and per-lane 16-bit
// data ports (lane_data0..7), concatenating them onto the DUT's packed buses.
// out_data is exposed split per-lane too for convenient checking, plus the raw
// 128-bit out_data for whole-word compares.
//
// Pure structural — no behaviour added. Faithful to the DUT.
// =============================================================================
`default_nettype none

module tb_deskew (
    input  wire        rst_n,
    input  wire        training_mode,
    input  wire        out_clk,

    input  wire        lane_clk0, lane_clk1, lane_clk2, lane_clk3,
    input  wire        lane_clk4, lane_clk5, lane_clk6, lane_clk7,

    input  wire [15:0] lane_data0, lane_data1, lane_data2, lane_data3,
    input  wire [15:0] lane_data4, lane_data5, lane_data6, lane_data7,

    output wire [127:0] out_data
);

    wire [7:0]   lane_clk  = { lane_clk7, lane_clk6, lane_clk5, lane_clk4,
                               lane_clk3, lane_clk2, lane_clk1, lane_clk0 };

    wire [127:0] lane_data = { lane_data7, lane_data6, lane_data5, lane_data4,
                               lane_data3, lane_data2, lane_data1, lane_data0 };

    tidelink_lane_deskew u_dut (
        .rst_n         (rst_n),
        .lane_clk      (lane_clk),
        .lane_data     (lane_data),
        .training_mode (training_mode),
        .out_clk       (out_clk),
        .out_data      (out_data)
    );

endmodule

`default_nettype wire
