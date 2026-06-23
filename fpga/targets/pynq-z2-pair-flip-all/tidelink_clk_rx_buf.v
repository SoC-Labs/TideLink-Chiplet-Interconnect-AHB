//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge — pad_clk_rx Single IBUFG + BUFG Wrapper
// (pynq-z2-pair-flip-all / die_b FLIP build)
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Tiny wrapper that drives the forwarded RX clock through a SINGLE IBUFG and a
// SINGLE BUFG, then fans the global clock net out to TideLink IP's pad_clk_rx
// port. Mirrors the proven pynq-z2-pair-mmcmbypass(-oddr)-flip-all wrapper and
// the PHY-BIST flip target's tidelink_clk_rx_buf (which closed timing clean,
// WHS +0.05).
//
// WHY (die_b A->B fix, 2026-06-23): on the FLIP bitstream pad_clk_rx lands on
// Y9 (IO_L14P_T2_SRCC_13, single-region clock-capable) — the weaker SRCC pin —
// vs die_a's Y7 (MRCC). The packaged TideLink IP's internal BUFG (USE_CLKBUF=1)
// is built out-of-context INSIDE the IP, so it is invisible to the TOP-level
// IO clock placer on the ~97%-packed die. Vivado's top-level BUFG inference on
// pad_clk_rx then fails on the SRCC pin and falls back to a LUT-routed clock
// (WHS -21.7 ns). Giving the top level an EXPLICIT IBUFG+BUFG here — with the IP
// param overridden to USE_CLKBUF=0 (no in-IP per-lane cap BUFGs) — makes the
// real global clock buffer visible to the placer so it routes the forwarded
// clock on the dedicated clock network (see pynq_z2_tidelink_drc.xdc
// CLOCK_DEDICATED_ROUTE TRUE). This is the die_a (pair-all) -> die_b parity fix.
//
// Instantiated inside the BD via:
//   create_bd_cell -type module -reference tidelink_clk_rx_buf clk_rx_buf
//
// The BD wires pad_clk_rx (port) -> clk_rx_buf.pad_in and
// clk_rx_buf.clk_out -> tidelink_0/pad_clk_rx.
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
    // USE_CLKBUF=0 via IPI override; see tidelink_design.tcl).
    BUFG u_bufg (
        .I (w_ibufg),
        .O (clk_out)
    );

endmodule
