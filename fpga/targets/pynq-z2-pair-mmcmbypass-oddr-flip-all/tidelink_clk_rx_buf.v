//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge — pad_clk_rx Single IBUFG + BUFG Wrapper (Target A)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Tiny wrapper that drives the forwarded RX clock through a SINGLE IBUFG and
// a SINGLE BUFG, then fans the global clock net out to TideLink IP's
// pad_clk_rx port. Used by the Target A mmcmbypass variants of pynq-z2-pair*
// to cut the slave-side capacitive load on pad_clk_rx from ~48 pF (8 per-lane
// BUFG inputs) down to ~8 pF (one IBUFG input).
//
// See docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md for the full diagnosis
// + architecture. Pieces 1+2 (RTL split of USE_CLKBUF into USE_CAP_CLKBUF +
// USE_LNK_CLKBUF) land on a separate branch (feat/target-a-rtl). Pieces 3+4
// (this wrapper + the new target dirs + the IPI param override) live here on
// feat/target-a-bd.
//
// Instantiated inside the BD via:
//   create_bd_cell -type module -reference tidelink_clk_rx_buf clk_rx_buf
//
// The BD wires pad_clk_rx (port) -> clk_rx_buf.pad_in and
// clk_rx_buf.clk_out -> tidelink_0/pad_clk_rx.
//
// FLIP variant: identical Verilog body to the pair-mmcmbypass-all target.
// Only the XDC pin assignments differ (mirrored RPi pinout for the cross
// cable) — the buffer wrapper itself is pin-independent.
//-----------------------------------------------------------------------------

module tidelink_clk_rx_buf (
    input  wire pad_in,   // direct from top-level pad_clk_rx port (Y9 / J13 pin 40)
    output wire clk_out   // global clock net feeding tidelink_0/pad_clk_rx
);

    // Per-pad single-ended IBUFG. Drives a dedicated clock-routing wire.
    wire w_ibufg;
    IBUFG u_ibufg (
        .I (pad_in),
        .O (w_ibufg)
    );

    // Single global BUFG. The post-BUFG net is a Vivado global clock buffer
    // output, so the BD-level fan-out to the IP's pad_clk_rx port does NOT
    // re-trigger per-lane BUFG insertion downstream (the IP wrapper sets
    // USE_CAP_CLKBUF=0 via IPI override; see tidelink_design.tcl).
    BUFG u_bufg (
        .I (w_ibufg),
        .O (clk_out)
    );

endmodule
