module WlinkGenericFCReplayV2_13(
  input         app_clk,
  input         app_reset,
  input         app_enable,
  input  [47:0] app_data,
  input         app_valid,
  output        app_ready,
  input         link_clk,
  input         link_reset,
  input         link_ack_update,
  input  [4:0]  link_ack_addr,
  input         link_revert,
  input  [4:0]  link_revert_addr,
  output [4:0]  link_cur_addr,
  output [47:0] link_data,
  output        link_valid,
  input         link_advance,
  output        link_empty,
  // ---------------------------------------------------------------------------
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 -- David Mapstone
  // Purely additive read-only fan-outs of existing internal nets (NO functional
  // change). The two sim-proven fixes (reset-coherency + ACK-pointer-gate) both
  // FAILED on silicon, so app_ready alone is not enough to localize the false-
  // FULL. These four taps expose the raw pointers + both terms of app_ready so
  // silicon can compute the exact desync:
  //   obs_a2l_wptr          = fifo_io_wbin_ptr        (app-clk WRITE bin ptr)
  //   obs_a2l_synced_ack    = a2l_link_addr_app_clk   (ACK ptr synced to app-clk)
  //   obs_a2l_full          = a2l_full                (the false-FULL flag)
  //   obs_enable_app_clk_demet = enable_app_clk_demet_io_out (other app_ready term)
  // app_ready == ~a2l_full & enable_app_clk_demet. If a2l_full=1 it is the
  // pointer issue (compare wptr vs synced_ack for the lap); if a2l_full=0 but
  // app_ready=0 then enable_app_clk_demet=0 (a different bug).
  output [4:0]  obs_a2l_wptr,
  output [4:0]  obs_a2l_synced_ack,
  output        obs_a2l_full,
  output        obs_enable_app_clk_demet,
  // ---------------------------------------------------------------------------
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  // -- David Mapstone. Purely additive read-only fan-outs of existing internal
  // nets (NO functional change). app_ready/wptr/synced_ack localized the false-
  // FULL to the WRITE side, but did not say WHY the link/READ side never drains
  // (link_empty=1 while wptr advanced). The remaining suspect is that the LINK-
  // side reset io_rreset (= link_reset) is HELD, which keeps the read-side write-
  // ptr sync pinned and the FIFO permanently empty on the read side. Expose the
  // raw read-side reset + the raw LINK read binary pointer so silicon can
  // confirm reset-held vs sync-broken:
  //   obs_a2l_rreset = link_reset       (the read-side FIFO reset, fed to
  //                                       fifo_io_rreset; 1 = read side held in
  //                                       reset -> read ptr sync stuck).
  //   obs_a2l_rptr   = fifo_io_rbin_ptr (the LINK read binary pointer, also
  //                                       drives link_cur_addr).
  // If obs_a2l_rreset=1 the read side is held in reset. If obs_a2l_rreset=0 and
  // obs_a2l_rptr is stuck while obs_a2l_wptr advances, the write-ptr Gray sync
  // into the read domain is broken.
  output        obs_a2l_rreset,
  output [4:0]  obs_a2l_rptr
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
`endif // RANDOMIZE_REG_INIT
  wire  enable_app_clk_demet_clock; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_reset; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  enable_app_clk_demet_io_out; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_clock; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_reset; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_io_in; // @[Stdcell.scala 58:23]
  wire  enable_link_clk_demet_io_out; // @[Stdcell.scala 58:23]
  wire  fifo_io_wclk; // @[FC.scala 743:20]
  wire  fifo_io_wreset; // @[FC.scala 743:20]
  wire  fifo_io_winc; // @[FC.scala 743:20]
  wire  fifo_io_rclk; // @[FC.scala 743:20]
  wire  fifo_io_rreset; // @[FC.scala 743:20]
  wire  fifo_io_rinc; // @[FC.scala 743:20]
  wire  fifo_io_rrevert; // @[FC.scala 743:20]
  wire [4:0] fifo_io_rrevert_addr; // @[FC.scala 743:20]
  wire [47:0] fifo_io_wdata; // @[FC.scala 743:20]
  wire [47:0] fifo_io_rdata; // @[FC.scala 743:20]
  wire  fifo_io_wfull; // @[FC.scala 743:20]
  wire  fifo_io_rempty; // @[FC.scala 743:20]
  wire [4:0] fifo_io_rbin_ptr; // @[FC.scala 743:20]
  wire [4:0] fifo_io_wbin_ptr; // @[FC.scala 743:20]
  wire  link_addr_to_app_clk_w_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_reset; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_w_inc; // @[FC.scala 773:37]
  wire [4:0] link_addr_to_app_clk_w_addr; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_clk; // @[FC.scala 773:37]
  wire  link_addr_to_app_clk_r_reset; // @[FC.scala 773:37]
  wire [4:0] link_addr_to_app_clk_r_addr; // @[FC.scala 773:37]
  wire [4:0] a2l_app_addr = fifo_io_wbin_ptr; // @[FC.scala 725:29 FC.scala 749:25]
  wire [4:0] a2l_link_addr_app_clk = link_addr_to_app_clk_r_addr; // @[FC.scala 723:41 FC.scala 781:33]
  wire  a2l_full = a2l_app_addr[4] != a2l_link_addr_app_clk[4] & a2l_app_addr[3:0] == a2l_link_addr_app_clk[3:0]; // @[FC.scala 727:88]
  reg [4:0] a2l_link_addr; // @[FC.scala 770:103]
  // ---------------------------------------------------------------------------
  // TIDELINK LOCAL OVERRIDE (Bug A / a2l replay false-FULL) -- David Mapstone
  //
  // The a2l_full check above is the original Chisel-generated gray-style
  // exactly-full test; it is correct PROVIDED the ACK (link) pointer can never
  // lead what has actually been read out and transmitted. The silicon bug is
  // that an ACK packet received during CR/CRACK bring-up drove a2l_link_addr to
  // a junk value a full lap ahead of every other pointer (ack = 0b10001 = 17
  // while the write/read ptrs were 0). Synced into app_clk that left the FIFO
  // false-FULL on the very first write (a2l_full=1 -> app_ready=0 -> winc never
  // fires -> the FCSM never transmits): the months-old data blocker, reproduced
  // deterministically in cocotb/tidelink_a2l_replay_cdc.
  //
  // ROOT-CAUSE FIX (at the ACK latch, link domain): the ACK pointer can ONLY
  // legitimately acknowledge data that has been READ OUT of the FIFO (the link
  // side only transmits words it has popped, advancing fifo_io_rbin_ptr). Thus
  // the acked address MUST lie inside the currently-outstanding, sent-but-not-
  // yet-acked window  [a2l_link_addr , fifo_io_rbin_ptr]  (lap-aware). We REJECT
  // any link_ack_update whose addr falls outside that window. When nothing has
  // been sent (rbin_ptr == a2l_link_addr) the window is empty, so a bring-up
  // ACK of a bogus addr (e.g. 17) is dropped and the ACK ptr stays 0. Both
  // a2l_link_addr and fifo_io_rbin_ptr are LINK-domain, directly comparable, so
  // this adds no CDC path. Legitimate in-window ACKs advance exactly as before.
  // ---------------------------------------------------------------------------
  wire [4:0] a2l_ack_off_req = link_ack_addr     - a2l_link_addr; // requested advance (mod 32)
  wire [4:0] a2l_ack_off_max = fifo_io_rbin_ptr  - a2l_link_addr; // outstanding window (mod 32)
  // accept only if the requested ACK addr is within the outstanding window and
  // within the FIFO depth (<=16); otherwise the ACK is spurious and ignored.
  wire  a2l_ack_valid = link_ack_update
                        & (a2l_ack_off_req <= a2l_ack_off_max)
                        & (a2l_ack_off_max <= 5'h10);
  wire [4:0] a2l_link_addr_in = a2l_ack_valid ? link_ack_addr : a2l_link_addr; // @[FC.scala 771:39]
  WavDemetReset enable_app_clk_demet ( // @[Stdcell.scala 58:23]
    .clock(enable_app_clk_demet_clock),
    .reset(enable_app_clk_demet_reset),
    .io_in(enable_app_clk_demet_io_in),
    .io_out(enable_app_clk_demet_io_out)
  );
  WavDemetReset enable_link_clk_demet ( // @[Stdcell.scala 58:23]
    .clock(enable_link_clk_demet_clock),
    .reset(enable_link_clk_demet_reset),
    .io_in(enable_link_clk_demet_io_in),
    .io_out(enable_link_clk_demet_io_out)
  );
  WavFIFO_20 fifo ( // @[FC.scala 743:20]
    .io_wclk(fifo_io_wclk),
    .io_wreset(fifo_io_wreset),
    .io_winc(fifo_io_winc),
    .io_rclk(fifo_io_rclk),
    .io_rreset(fifo_io_rreset),
    .io_rinc(fifo_io_rinc),
    .io_rrevert(fifo_io_rrevert),
    .io_rrevert_addr(fifo_io_rrevert_addr),
    .io_wdata(fifo_io_wdata),
    .io_rdata(fifo_io_rdata),
    .io_wfull(fifo_io_wfull),
    .io_rempty(fifo_io_rempty),
    .io_rbin_ptr(fifo_io_rbin_ptr),
    .io_wbin_ptr(fifo_io_wbin_ptr)
  );
  WlinkGenericFCReplayAddrSync_18 link_addr_to_app_clk ( // @[FC.scala 773:37]
    .w_clk(link_addr_to_app_clk_w_clk),
    .w_reset(link_addr_to_app_clk_w_reset),
    .w_inc(link_addr_to_app_clk_w_inc),
    .w_addr(link_addr_to_app_clk_w_addr),
    .r_clk(link_addr_to_app_clk_r_clk),
    .r_reset(link_addr_to_app_clk_r_reset),
    .r_addr(link_addr_to_app_clk_r_addr)
  );
  assign app_ready = ~a2l_full & enable_app_clk_demet_io_out; // @[FC.scala 728:36]
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only fan-out)
  assign obs_a2l_wptr             = fifo_io_wbin_ptr;
  assign obs_a2l_synced_ack       = a2l_link_addr_app_clk;
  assign obs_a2l_full             = a2l_full;
  assign obs_enable_app_clk_demet = enable_app_clk_demet_io_out;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER obs 2026-06-21 (RO)
  assign obs_a2l_rreset           = link_reset;       // == fifo_io_rreset
  assign obs_a2l_rptr             = fifo_io_rbin_ptr;  // == link_cur_addr
  assign link_cur_addr = fifo_io_rbin_ptr; // @[FC.scala 763:25]
  assign link_data = fifo_io_rdata; // @[FC.scala 754:25]
  assign link_valid = enable_link_clk_demet_io_out & ~link_empty; // @[FC.scala 740:39]
  assign link_empty = fifo_io_rempty; // @[FC.scala 738:39 FC.scala 755:25]
  assign enable_app_clk_demet_clock = app_clk; // @[FC.scala 721:51]
  assign enable_app_clk_demet_reset = app_reset; // @[FC.scala 721:70]
  assign enable_app_clk_demet_io_in = app_enable; // @[Stdcell.scala 59:17]
  assign enable_link_clk_demet_clock = link_clk; // @[FC.scala 734:53]
  assign enable_link_clk_demet_reset = link_reset; // @[FC.scala 734:73]
  assign enable_link_clk_demet_io_in = app_enable; // @[Stdcell.scala 59:17]
  assign fifo_io_wclk = app_clk; // @[FC.scala 744:25]
  assign fifo_io_wreset = app_reset; // @[FC.scala 745:25]
  assign fifo_io_winc = app_ready & app_valid; // @[FC.scala 729:35]
  assign fifo_io_rclk = link_clk; // @[FC.scala 751:25]
  assign fifo_io_rreset = link_reset; // @[FC.scala 752:25]
  assign fifo_io_rinc = link_valid & link_advance; // @[FC.scala 741:46]
  assign fifo_io_rrevert = link_revert; // @[FC.scala 757:29]
  assign fifo_io_rrevert_addr = link_revert_addr; // @[FC.scala 758:29]
  assign fifo_io_wdata = app_data; // @[FC.scala 747:25]
  assign link_addr_to_app_clk_w_clk = link_clk; // @[FC.scala 774:45]
  assign link_addr_to_app_clk_w_reset = link_reset; // @[FC.scala 775:33]
  assign link_addr_to_app_clk_w_inc = a2l_link_addr != a2l_link_addr_in; // @[FC.scala 776:50]
  assign link_addr_to_app_clk_w_addr = a2l_link_addr_in; // gated ACK (see local override above)
  assign link_addr_to_app_clk_r_clk = app_clk; // @[FC.scala 779:44]
  assign link_addr_to_app_clk_r_reset = app_reset; // @[FC.scala 780:33]
  always @(posedge link_clk or posedge link_reset) begin
    if (link_reset) begin
      a2l_link_addr <= 5'h0;
    end else if (a2l_ack_valid) begin   // gated ACK advance (see local override above)
      a2l_link_addr <= link_ack_addr;
    end
  end
// Register and memory initialization
`ifdef RANDOMIZE_GARBAGE_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_INVALID_ASSIGN
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_REG_INIT
`define RANDOMIZE
`endif
`ifdef RANDOMIZE_MEM_INIT
`define RANDOMIZE
`endif
`ifndef RANDOM
`define RANDOM $random
`endif
`ifdef RANDOMIZE_MEM_INIT
  integer initvar;
`endif
`ifndef SYNTHESIS
`ifdef FIRRTL_BEFORE_INITIAL
`FIRRTL_BEFORE_INITIAL
`endif
initial begin
  `ifdef RANDOMIZE
    `ifdef INIT_RANDOM
      `INIT_RANDOM
    `endif
    `ifndef VERILATOR
      `ifdef RANDOMIZE_DELAY
        #`RANDOMIZE_DELAY begin end
      `else
        #0.002 begin end
      `endif
    `endif
`ifdef RANDOMIZE_REG_INIT
  _RAND_0 = {1{`RANDOM}};
  a2l_link_addr = _RAND_0[4:0];
`endif // RANDOMIZE_REG_INIT
  if (link_reset) begin
    a2l_link_addr = 5'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
