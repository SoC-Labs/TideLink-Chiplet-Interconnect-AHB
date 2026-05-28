//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge — pad_clk_tx Centred-Launch ODDR Wrapper (Target A + ODDR)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Tiny wrapper that re-launches the forwarded TX clock through a SAME_EDGE
// ODDR primitive so the clock edge driven out on pad_clk_tx is CENTRED in the
// pad_tx[*] data eye, rather than edge-aligned to the data transitions (the
// behaviour of the original combinational `assign io_pad_clk = io_link_clk`
// inside WavD2DGpioTx.v line 97).
//
// Per UG903 Example Six "Forwarded clocks (centre-aligned)": D1=0, D2=1 with
// DDR_CLK_EDGE("SAME_EDGE") emits a clock whose rising edge falls in the
// middle of the bit period. The slave's pad_clk_rx therefore samples
// pad_rx[*] at the centre of the data eye instead of right at the edge.
//
// See docs/UG903_FORWARDED_CLOCKS_AUDIT_2026_05_28.md for the audit + rationale.
//
// Instantiated inside the BD via:
//   create_bd_cell -type module -reference tidelink_clk_tx_oddr clk_tx_oddr
//
// The BD wires tidelink_0/pad_clk_tx -> clk_tx_oddr.clk_in (the gated MMCM
// net launched by WavD2DGpioTx) and clk_tx_oddr.pad_out -> the BD-level
// pad_clk_tx port (Y9 master / Y7 slave on the PYNQ-Z2 J13 header).
//
// reset is wired to proc_sys_reset_0/peripheral_reset (active-high) so the
// ODDR is held in a defined state during PS reset; tied to 1'b0 otherwise.
//-----------------------------------------------------------------------------

module tidelink_clk_tx_oddr (
    input  wire clk_in,    // launching clock (50 MHz from clk_wiz_0/clk_out1)
    input  wire reset,     // active-high reset, default 0
    output wire pad_out    // to top-level pad_clk_tx pin (Y9 master / Y7 slave)
);

    // SAME_EDGE ODDR centred-launch: D1=0, D2=1 emits a clock that is 180°
    // out of phase with clk_in — i.e. the rising edge of pad_out lands in
    // the middle of the bit period (canonical centred-launch pattern from
    // UG903 Example Six). SRTYPE="ASYNC" because reset is the PS
    // peripheral_reset which is itself synchronised to the clk_wiz domain
    // but applied here as an asynchronous async-reset to the ODDR cell.
    ODDR #(
        .DDR_CLK_EDGE("SAME_EDGE"),
        .INIT(1'b0),
        .SRTYPE("ASYNC")
    ) u_oddr (
        .Q  (pad_out),
        .C  (clk_in),
        .CE (1'b1),
        .D1 (1'b0),   // centred forward — Q falls on rising edge of clk_in
        .D2 (1'b1),   // Q rises on falling edge of clk_in
        .R  (reset),
        .S  (1'b0)
    );

endmodule
