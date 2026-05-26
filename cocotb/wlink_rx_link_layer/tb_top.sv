// =============================================================================
// tb_top.sv -- standalone unit testbench for WlinkRxLinkLayer
// =============================================================================
//
// Purpose: pin the byte-align FSM of WlinkRxLinkLayer at unit level so the
// "state==1 stuck on training filler" bug (caught today by the slow
// cocotb/wlink_pair/test_paired_recal_to_link_data.py at ~60 s/run) becomes a
// sub-10-second sim-gate. Future L4 candidate fixes can iterate against this
// testbench in ~5 s instead of waiting for the full paired-die sim.
//
// Bug background
// --------------
// During the slave-side bringup window, WavD2DGpio deserialises the master's
// per-lane TRAINING_BYTE filler (0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59,
// 0x2D). The first 3 bytes of those (lane 0..2) form a candidate packet
// header (PH) with ph[7:0]=0xA3, which is > swi_short_packet_max=0x7F. The
// byte-align FSM sees is_long_pkt=1 and transitions state 0->1, latching a
// phony long-packet expectation that consumes the framer forever.
//
// The L4 fix (override at src/rtl/local_overrides/WlinkRxLinkLayer.v) adds a
// sticky `first_short_pkt_seen` gate so the 0->1 transition is GATED until at
// least one valid SHORT packet has been decoded. The first real bringup pkt
// is CR (data_id=0x44 < 0x7F), so the gate bootstraps off the CR.
//
// Test approach
// -------------
// Drive io_link_data directly with crafted 128-bit values:
//   - 8-lane packed (io_active_lanes=7, io_lane_mask=0xFF, swi_short_pkt=0x7F)
//   - For an 8-lane CR header the framer parses:
//       lane 0 [7:0]    = data_id      (e.g. 0x44 for CR)
//       lane 1 [23:16]  = word_count[7:0]
//       lane 2 [39:32]  = word_count[15:8]
//       lane 3 [55:48]  = ECC byte (calculated from {wc[15:8], wc[7:0], di})
//   - For training filler we drive each of the 8 lane's [15:0] slot with the
//     deserialised 16-bit training byte pattern WavD2DGpio would emit (the
//     8-bit TRAINING_BYTE repeated, e.g. 0xA3A3 on lane 0). This matches
//     what the pair sim sees on the wire.
//
// Expose: clock, reset, io_link_data, io_enable, io_swi_short_packet_max,
// io_active_lanes, io_lane_mask + every io_obs_* + auto_out_* port so the
// cocotb test can sample state, is_short_pkt, is_long_pkt, valid, data_id.
//
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
// license.
//
// Contributors
//   David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_top (
    input  wire         clock,
    input  wire         reset,
    input  wire         io_enable,
    input  wire [7:0]   io_swi_short_packet_max,
    input  wire [7:0]   io_active_lanes,
    input  wire [7:0]   io_lane_mask,
    input  wire [127:0] io_link_data,
    output wire         auto_out_sop,
    output wire [7:0]   auto_out_data_id,
    output wire [15:0]  auto_out_word_count,
    output wire [111:0] auto_out_data,
    output wire         auto_out_valid,
    output wire [15:0]  auto_out_crc,
    output wire         io_ecc_corrected,
    output wire         io_ecc_corrupted,
    output wire         io_in_error_state,
    output wire [1:0]   io_obs_state,
    output wire         io_obs_is_short_pkt,
    output wire         io_obs_is_long_pkt,
    output wire         io_obs_valid
);

    WlinkRxLinkLayer u_dut (
        .clock                   (clock),
        .reset                   (reset),
        .auto_out_sop            (auto_out_sop),
        .auto_out_data_id        (auto_out_data_id),
        .auto_out_word_count     (auto_out_word_count),
        .auto_out_data           (auto_out_data),
        .auto_out_valid          (auto_out_valid),
        .auto_out_crc            (auto_out_crc),
        .io_enable               (io_enable),
        .io_swi_short_packet_max (io_swi_short_packet_max),
        .io_active_lanes         (io_active_lanes),
        .io_lane_mask            (io_lane_mask),
        .io_ecc_corrected        (io_ecc_corrected),
        .io_ecc_corrupted        (io_ecc_corrupted),
        .io_link_data            (io_link_data),
        .io_in_error_state       (io_in_error_state),
        .io_obs_state            (io_obs_state),
        .io_obs_is_short_pkt     (io_obs_is_short_pkt),
        .io_obs_is_long_pkt      (io_obs_is_long_pkt),
        .io_obs_valid            (io_obs_valid)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule

`default_nettype wire
