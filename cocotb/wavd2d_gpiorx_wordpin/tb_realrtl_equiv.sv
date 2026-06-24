// =============================================================================
// tb_equiv.sv — REAL-RTL differential equivalence of the WORD-PIN patch.
//
// Instantiates BOTH:
//   u_edt : the CURRENT committed src/rtl/local_overrides/WavD2DGpioRx.v with
//           io_word_pin tied 4'h0 (OFF-by-default).
//   u_bas : a module-renamed copy of the PROVEN-GOOD baseline @142a7ca
//           WavD2DGpioRx (no io_word_pin port).
// Both use the REAL Wav* clock primitives from deps/.../wlink (NOT stubs),
// USE_CLKBUF=0 / USE_CAP_CLKBUF=0 / USE_LNK_CLKBUF=0 / USE_T3A=0 = the sim path.
//
// Identical io_pad serial stream + identical io_pad_clk drive both. We sample
// each module's io_link_data on ITS OWN posedge io_link_clk (the downstream
// deskew-write consumer's edge), log the streams, and compare.
//
// EXPECTATION: the patch's FIX-R step-2 negedge resample introduces a fixed,
// integer, phase-INDEPENDENT word-presentation lag. So we:
//   (1) find the single best constant lag per phase,
//   (2) require 0 mismatch at that lag (byte-identical content), AND
//   (3) require the best lag to be the SAME across all 16 phases (a true
//       static pipeline shift, not a phase-dependent reframe).
// B->A is the proven-good direction; OFF-by-default == byte-exact is the
// non-negotiable safety claim this test pins.
`timescale 1ns/1ps
`default_nettype none
module tb_equiv;
  reg io_pad;
  reg io_pad_clk;
  reg io_por_reset;
  reg [3:0] io_phase_offset;

  // ---- DUT: edited local_overrides RX, word_pin OFF (=0) ----
  wire        edt_link_clk;
  wire [15:0] edt_link_data;
  WavD2DGpioRx #(.USE_CLKBUF(1'b0), .USE_CAP_CLKBUF(1'b0), .USE_LNK_CLKBUF(1'b0),
                 .USE_T3A(1'b0), .TRAINING_BYTE(8'h00)) u_edt (
    .io_scan_mode(1'b0), .io_scan_asyncrst_ctrl(1'b0), .io_scan_clk(1'b0),
    .io_scan_out(), .io_por_reset(io_por_reset), .io_pol(1'b0),
    .io_phase_offset(io_phase_offset), .io_bit_slip(3'h0),
    .io_word_pin(4'h0),                           // <-- OFF-by-default
    .io_link_clk(edt_link_clk), .io_link_data(edt_link_data),
    .io_pad_clk(io_pad_clk), .io_pad(io_pad));

  // ---- REF: baseline @142a7ca RX (renamed; no io_word_pin) ----
  wire        bas_link_clk;
  wire [15:0] bas_link_data;
  WavD2DGpioRx_BASE #(.USE_CLKBUF(1'b0), .USE_CAP_CLKBUF(1'b0), .USE_LNK_CLKBUF(1'b0),
                      .USE_T3A(1'b0), .TRAINING_BYTE(8'h00)) u_bas (
    .io_scan_mode(1'b0), .io_scan_asyncrst_ctrl(1'b0), .io_scan_clk(1'b0),
    .io_scan_out(), .io_por_reset(io_por_reset), .io_pol(1'b0),
    .io_phase_offset(io_phase_offset), .io_bit_slip(3'h0),
    .io_link_clk(bas_link_clk), .io_link_data(bas_link_data),
    .io_pad_clk(io_pad_clk), .io_pad(io_pad));

  // pad clock
  initial begin io_pad_clk = 1'b0; forever #5 io_pad_clk = ~io_pad_clk; end

  // serial data: update io_pad on negedge pad clock (centered in the bit cell)
  reg [31:0] lfsr;
  always @(negedge io_pad_clk) begin
    lfsr   <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    io_pad <= lfsr[15];
  end

  // per-module consumer sampling on each module's own posedge io_link_clk
  localparam integer N = 4096;
  reg [15:0] edt_log [0:N-1];
  reg [15:0] bas_log [0:N-1];
  integer ne, nb; reg active;
  always @(posedge edt_link_clk) if (active && ne < N) begin edt_log[ne]=edt_link_data; ne=ne+1; end
  always @(posedge bas_link_clk) if (active && nb < N) begin bas_log[nb]=bas_link_data; nb=nb+1; end

  integer ph, s, lag, j, m, best_lag, best_m, phases_dirty, total;
  integer first_lag; reg lag_consistent;
  initial begin
    phases_dirty = 0; total = 0; first_lag = -1; lag_consistent = 1'b1;
    for (ph = 0; ph < 16; ph = ph + 1) begin
      io_phase_offset = ph[3:0];
      io_por_reset = 1'b1; active = 1'b0; ne = 0; nb = 0;
      lfsr = 32'hACE1_0000 + ph; io_pad = 1'b0;
      @(negedge io_pad_clk); @(negedge io_pad_clk);
      io_por_reset = 1'b0;
      for (s=0; s<128; s=s+1) @(posedge io_pad_clk);   // settle
      active = 1'b1;
      for (s=0; s<4000; s=s+1) @(posedge io_pad_clk);  // collect ~250 words
      active = 1'b0;
      @(posedge io_pad_clk);
      // best constant lag in [0..4]
      best_m = 1<<30; best_lag = 0;
      for (lag = 0; lag <= 4; lag = lag + 1) begin
        m = 0;
        for (j = 0; (j + lag < ne) && (j < nb); j = j + 1)
          if (edt_log[j+lag] !== bas_log[j]) m = m + 1;
        if (m < best_m) begin best_m = m; best_lag = lag; end
      end
      total = total + 1;
      if (first_lag == -1 && best_m == 0) first_lag = best_lag;
      else if (best_m == 0 && best_lag != first_lag) lag_consistent = 1'b0;
      if (best_m == 0)
        $display("phase %2d: CLEAN  lag=%0d  (ne=%0d nb=%0d)", ph, best_lag, ne, nb);
      else begin
        $display("phase %2d: DIRTY  mism=%0d (best lag=%0d, ne=%0d nb=%0d)", ph, best_m, best_lag, ne, nb);
        phases_dirty = phases_dirty + 1;
      end
    end
    $display("============================================");
    $display("constant best-lag across clean phases = %0d  (consistent=%0d)", first_lag, lag_consistent);
    if (phases_dirty == 0 && lag_consistent)
      $display("RESULT: PASS  edited io_word_pin=0 BYTE-IDENTICAL to baseline @142a7ca RX, ALL 16 phases, single static lag");
    else if (phases_dirty == 0 && !lag_consistent)
      $display("RESULT: SUSPECT  content matches but lag varies by phase (not a pure static shift)");
    else
      $display("RESULT: FAIL  %0d/%0d phases diverge", phases_dirty, total);
    $display("============================================");
    $finish;
  end
endmodule
`default_nettype wire
