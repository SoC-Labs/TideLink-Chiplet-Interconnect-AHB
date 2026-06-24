// Confirm the two REJECTED load points are DIRTY vs legacy at phase!=0, and
// that word_pin=k genuinely re-cuts the window (distinct captured words).
`timescale 1ns/1ps
module wp_reject;
  reg w_pad_clk, io_pad, reset;
  reg [3:0] io_phase_offset, io_word_pin;

  reg [3:0] count;
  always @(posedge w_pad_clk or posedge reset)
    if (reset) count <= 4'hf; else count <= count + 4'h1;
  wire [3:0] adj_count = count + io_phase_offset;

  reg [15:0] link_data_pad_clk; integer bi;
  always @(posedge w_pad_clk or posedge reset) begin
    if (reset) link_data_pad_clk <= 16'h0;
    else for (bi=0; bi<16; bi=bi+1)
      if (adj_count == bi[3:0]) link_data_pad_clk[bi] <= io_pad;
  end
  wire io_link_clk = ~adj_count[3];

  // legacy
  reg [15:0] legacy_reg;
  always @(posedge io_link_clk or posedge reset)
    if (reset) legacy_reg <= 16'h0; else legacy_reg <= link_data_pad_clk;

  // REJECT-A: deps-style  count == word_pin (pin=0 => count==0), posedge io_link_clk consume
  reg [15:0] rejA_word, rejA_reg;
  always @(posedge w_pad_clk or posedge reset) begin
    if (reset) rejA_word <= 16'h0;
    else if (count == io_word_pin) rejA_word <= link_data_pad_clk;
  end
  always @(negedge io_link_clk or posedge reset)
    if (reset) rejA_reg <= 16'h0; else rejA_reg <= rejA_word;

  // REJECT-B: load at adj_count == 15 - word_pin (pin=0 => adj_count==15)
  reg [15:0] rejB_word, rejB_reg;
  always @(posedge w_pad_clk or posedge reset) begin
    if (reset) rejB_word <= 16'h0;
    else if (adj_count == (4'hf - io_word_pin)) rejB_word <= link_data_pad_clk;
  end
  always @(negedge io_link_clk or posedge reset)
    if (reset) rejB_reg <= 16'h0; else rejB_reg <= rejB_word;

  // ACCEPT: adj_count == 0 - word_pin
  reg [15:0] accW, accReg;
  always @(posedge w_pad_clk or posedge reset) begin
    if (reset) accW <= 16'h0;
    else if (adj_count == (4'h0 - io_word_pin)) accW <= link_data_pad_clk;
  end
  always @(negedge io_link_clk or posedge reset)
    if (reset) accReg <= 16'h0; else accReg <= accW;

  // consumer
  reg [15:0] s_leg, s_rejA, s_rejB, s_acc;
  always @(posedge io_link_clk or posedge reset)
    if (reset) begin s_leg<=0; s_rejA<=0; s_rejB<=0; s_acc<=0; end
    else begin s_leg<=legacy_reg; s_rejA<=rejA_reg; s_rejB<=rejB_reg; s_acc<=accReg; end

  reg active; integer nlog;
  reg [15:0] L[0:4095], A[0:4095], B[0:4095], C[0:4095];
  always @(posedge io_link_clk)
    if (active && nlog<4096) begin
      L[nlog]=s_leg; A[nlog]=s_rejA; B[nlog]=s_rejB; C[nlog]=s_acc; nlog=nlog+1;
    end

  reg [31:0] lfsr;
  always @(negedge w_pad_clk) begin
    lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    io_pad <= lfsr[15];
  end
  initial begin w_pad_clk=0; forever #5 w_pad_clk=~w_pad_clk; end

  task run_phase(input [3:0] ph);
    integer s;
    begin
      reset=1; active=0; nlog=0; io_phase_offset=ph; lfsr=32'hBEEF_0000+ph; io_pad=0;
      @(negedge w_pad_clk); @(negedge w_pad_clk); reset=0;
      for (s=0;s<64;s=s+1) @(posedge w_pad_clk);
      active=1; for (s=0;s<2000;s=s+1) @(posedge w_pad_clk); active=0; @(posedge w_pad_clk);
    end
  endtask

  function integer bestmism(input integer which); // 1=rejA 2=rejB 3=acc
    integer lag,j,m,bm; reg [15:0] x;
    begin
      bm=1<<30;
      for (lag=0;lag<=4;lag=lag+1) begin
        m=0;
        for (j=0;j+lag<nlog;j=j+1) begin
          case (which) 1: x=A[j+lag]; 2: x=B[j+lag]; 3: x=C[j+lag]; endcase
          if (L[j]!==x) m=m+1;
        end
        if (m<bm) bm=m;
      end
      bestmism=bm;
    end
  endfunction

  integer ph, ma, mb, mc, fa, fb, fc;
  initial begin
    io_word_pin=4'h0; fa=0; fb=0; fc=0;
    for (ph=0; ph<16; ph=ph+1) begin
      run_phase(ph[3:0]);
      ma=bestmism(1); mb=bestmism(2); mc=bestmism(3);
      if (ma!=0) fa=fa+1; if (mb!=0) fb=fb+1; if (mc!=0) fc=fc+1;
      $display("ph %2d  rejA(count==wp)=%0d  rejB(adj==15-wp)=%0d  ACCEPT(adj==0-wp)=%0d", ph, ma, mb, mc);
    end
    $display("----------------------------------------------------------------");
    $display("DIRTY-phase counts:  rejA=%0d/16   rejB=%0d/16   ACCEPT=%0d/16", fa, fb, fc);
    if (fc==0 && fa>0 && fb>0)
      $display("VERDICT: ONLY adj_count==(0-wp) is byte-exact. rejected forms confirmed dirty.");
    else
      $display("VERDICT: UNEXPECTED — review (fc=%0d fa=%0d fb=%0d)", fc, fa, fb);

    // window re-cut check at phase 0: distinct words per pin
    $display("--- window re-cut: capture one word per pin at phase 0 ---");
    begin
      integer pk; reg [15:0] prev; integer distinct;
      distinct=0; prev=16'hxxxx;
      for (pk=0; pk<16; pk=pk+1) begin
        io_word_pin = pk[3:0];
        run_phase(4'h0);
        if (C[100] !== prev) distinct = distinct + 1;
        prev = C[100];
        $display("  word_pin=%2d -> captured word = %h", pk, C[100]);
      end
      $display("distinct-on-change count across pins (rough): %0d", distinct);
    end
    io_word_pin=4'h0;
    $finish;
  end
endmodule
