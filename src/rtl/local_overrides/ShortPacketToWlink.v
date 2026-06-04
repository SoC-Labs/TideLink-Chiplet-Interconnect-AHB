module ShortPacketToWlink(
  input         auto_rx_in_sop,
  input  [7:0]  auto_rx_in_data_id,
  input  [15:0] auto_rx_in_word_count,
  input         auto_rx_in_valid,
  
  output        auto_tx_out_sop,           // SoC Labs ILA — TX valid (Bug B)
  output [7:0]  auto_tx_out_data_id,
  output [15:0] auto_tx_out_word_count,
  
  input         auto_tx_out_advance,       // SoC Labs ILA — TX ready/credit (Bug B)
  input         io_app_clk,
  input         io_app_reset,
  input         io_app_enable,
  input         io_tx_clk,
  input         io_tx_reset,
  input         io_rx_clk,
  input         io_rx_reset,
  output [25:0] sp_bus_out_0,
  input  [25:0] bore_2
);
`ifdef RANDOMIZE_REG_INIT
  reg [31:0] _RAND_0;
  reg [31:0] _RAND_1;
`endif // RANDOMIZE_REG_INIT
  wire  tx_fifo_io_wclk; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_wreset; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_winc; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_rclk; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_rreset; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_rinc; // @[ShortPacket.scala 193:25]
  wire [23:0] tx_fifo_io_wdata; // @[ShortPacket.scala 193:25]
  wire [23:0] tx_fifo_io_rdata; // @[ShortPacket.scala 193:25]
  wire  tx_fifo_io_wfull; // @[ShortPacket.scala 193:25]  SoC Labs ILA — tx_fifo wfull (Bug B, docs/ILA_PLACEMENT_AUDIT_2026_05_29.md §4)
  wire  tx_fifo_io_rempty; // @[ShortPacket.scala 193:25]  SoC Labs ILA — tx_fifo rempty (Bug B)
  wire  en_ff2_tx_demet_clock; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_reset; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_in; // @[Stdcell.scala 58:23]
  wire  en_ff2_tx_demet_io_out; // @[Stdcell.scala 58:23]
  wire  rx_fifo_io_wclk; // @[ShortPacket.scala 247:25]
  wire  rx_fifo_io_wreset; // @[ShortPacket.scala 247:25]
  wire  rx_fifo_io_winc; // @[ShortPacket.scala 247:25]  SoC Labs ILA — rx_fifo winc (feat/phc-ila-debug)
  wire  rx_fifo_io_rclk; // @[ShortPacket.scala 247:25]
  wire  rx_fifo_io_rreset; // @[ShortPacket.scala 247:25]
  wire  rx_fifo_io_rinc; // @[ShortPacket.scala 247:25]  SoC Labs ILA — rx_fifo rinc (feat/phc-ila-debug)
  wire [23:0] rx_fifo_io_wdata; // @[ShortPacket.scala 247:25]
  wire [23:0] rx_fifo_io_rdata; // @[ShortPacket.scala 247:25]
  wire  rx_fifo_io_wfull; // @[ShortPacket.scala 247:25]  SoC Labs ILA — rx_fifo wfull (feat/phc-ila-debug)
  wire  rx_fifo_io_rempty; // @[ShortPacket.scala 247:25]  SoC Labs ILA — rx_fifo rempty (feat/phc-ila-debug)
  wire  tx_valid = bore_2[25]; // @[ShortPacket.scala 184:31]
  wire [7:0] tx_data_id = bore_2[24:17]; // @[ShortPacket.scala 185:31]
  wire [15:0] tx_payload = bore_2[16:1]; // @[ShortPacket.scala 186:31]
  wire  rx_accept = bore_2[0]; // @[ShortPacket.scala 187:31]  SoC Labs ILA — ptp_sp_rx_accept (feat/phc-ila-debug)
  wire  _tx_fifo_io_winc_T = ~tx_fifo_io_wfull; // @[ShortPacket.scala 196:46]
  wire  tx_has_data = ~tx_fifo_io_rempty & en_ff2_tx_demet_io_out; // @[ShortPacket.scala 210:44]
  reg  tx_pending; // @[ShortPacket.scala 214:34]
  reg [23:0] tx_data_reg; // @[ShortPacket.scala 216:34]
  wire  _GEN_0 = ~tx_pending & tx_has_data | tx_pending; // @[ShortPacket.scala 223:41 ShortPacket.scala 224:25 ShortPacket.scala 220:21]
  wire  dataIdMatch = auto_rx_in_data_id == 8'h50 | auto_rx_in_data_id == 8'h51; // @[ShortPacket.scala 244:75]  SoC Labs ILA — PHC dataId match (feat/phc-ila-debug)
  wire  rx_pkt_valid = auto_rx_in_valid & auto_rx_in_sop & dataIdMatch; // @[ShortPacket.scala 245:49]  SoC Labs ILA — RX pkt valid+match (feat/phc-ila-debug)
  wire  _rx_fifo_io_rinc_T = ~rx_fifo_io_rempty; // @[ShortPacket.scala 256:48]
  wire [7:0] rx_data_id = rx_fifo_io_rdata[23:16]; // @[ShortPacket.scala 260:38]
  wire [15:0] rx_payload = rx_fifo_io_rdata[15:0]; // @[ShortPacket.scala 261:38]
  wire [25:0] sp_bus_out = {_tx_fifo_io_winc_T,_rx_fifo_io_rinc_T,rx_data_id,rx_payload}; // @[Cat.scala 30:58]
  WavFIFO_21 tx_fifo ( // @[ShortPacket.scala 193:25]
    .io_wclk(tx_fifo_io_wclk),
    .io_wreset(tx_fifo_io_wreset),
    .io_winc(tx_fifo_io_winc),
    .io_rclk(tx_fifo_io_rclk),
    .io_rreset(tx_fifo_io_rreset),
    .io_rinc(tx_fifo_io_rinc),
    .io_wdata(tx_fifo_io_wdata),
    .io_rdata(tx_fifo_io_rdata),
    .io_wfull(tx_fifo_io_wfull),
    .io_rempty(tx_fifo_io_rempty)
  );
  WavDemetReset en_ff2_tx_demet ( // @[Stdcell.scala 58:23]
    .clock(en_ff2_tx_demet_clock),
    .reset(en_ff2_tx_demet_reset),
    .io_in(en_ff2_tx_demet_io_in),
    .io_out(en_ff2_tx_demet_io_out)
  );
  WavFIFO_21 rx_fifo ( // @[ShortPacket.scala 247:25]
    .io_wclk(rx_fifo_io_wclk),
    .io_wreset(rx_fifo_io_wreset),
    .io_winc(rx_fifo_io_winc),
    .io_rclk(rx_fifo_io_rclk),
    .io_rreset(rx_fifo_io_rreset),
    .io_rinc(rx_fifo_io_rinc),
    .io_wdata(rx_fifo_io_wdata),
    .io_rdata(rx_fifo_io_rdata),
    .io_wfull(rx_fifo_io_wfull),
    .io_rempty(rx_fifo_io_rempty)
  );
  assign auto_tx_out_sop = tx_pending; // @[Nodes.scala 1207:84 ShortPacket.scala 233:24]
  assign auto_tx_out_data_id = tx_pending ? tx_data_reg[23:16] : 8'h0; // @[ShortPacket.scala 234:30]
  assign auto_tx_out_word_count = tx_pending ? tx_data_reg[15:0] : 16'h0; // @[ShortPacket.scala 235:30]
  assign sp_bus_out_0 = sp_bus_out;
  assign tx_fifo_io_wclk = io_app_clk; // @[ShortPacket.scala 194:32]
  assign tx_fifo_io_wreset = io_app_reset; // @[ShortPacket.scala 195:32]
  assign tx_fifo_io_winc = tx_valid & ~tx_fifo_io_wfull; // @[ShortPacket.scala 196:44]
  assign tx_fifo_io_rclk = io_tx_clk; // @[ShortPacket.scala 200:33]
  assign tx_fifo_io_rreset = io_tx_reset; // @[ShortPacket.scala 201:33]
  assign tx_fifo_io_rinc = ~tx_pending & tx_has_data; // @[ShortPacket.scala 223:25]
  assign tx_fifo_io_wdata = {tx_data_id,tx_payload}; // @[Cat.scala 30:58]
  assign en_ff2_tx_demet_clock = io_tx_clk; // @[ShortPacket.scala 207:33]
  assign en_ff2_tx_demet_reset = io_tx_reset; // @[ShortPacket.scala 207:54]
  assign en_ff2_tx_demet_io_in = io_app_enable; // @[Stdcell.scala 59:17]
  assign rx_fifo_io_wclk = io_rx_clk; // @[ShortPacket.scala 248:32]
  assign rx_fifo_io_wreset = io_rx_reset; // @[ShortPacket.scala 249:32]
  assign rx_fifo_io_winc = rx_pkt_valid & ~rx_fifo_io_wfull; // @[ShortPacket.scala 250:48]
  assign rx_fifo_io_rclk = io_app_clk; // @[ShortPacket.scala 254:33]
  assign rx_fifo_io_rreset = io_app_reset; // @[ShortPacket.scala 255:33]
  assign rx_fifo_io_rinc = rx_accept & ~rx_fifo_io_rempty; // @[ShortPacket.scala 256:46]
  assign rx_fifo_io_wdata = {auto_rx_in_data_id,auto_rx_in_word_count}; // @[Cat.scala 30:58]
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      tx_pending <= 1'h0;
    end else if (tx_pending & auto_tx_out_advance) begin
      tx_pending <= 1'h0;
    end else begin
      tx_pending <= _GEN_0;
    end
  end
  always @(posedge io_tx_clk or posedge io_tx_reset) begin
    if (io_tx_reset) begin
      tx_data_reg <= 24'h0;
    end else if (~tx_pending & tx_has_data) begin
      tx_data_reg <= tx_fifo_io_rdata;
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
  tx_pending = _RAND_0[0:0];
  _RAND_1 = {1{`RANDOM}};
  tx_data_reg = _RAND_1[23:0];
`endif // RANDOMIZE_REG_INIT
  if (io_tx_reset) begin
    tx_pending = 1'h0;
  end
  if (io_tx_reset) begin
    tx_data_reg = 24'h0;
  end
  `endif // RANDOMIZE
end // initial
`ifdef FIRRTL_AFTER_INITIAL
`FIRRTL_AFTER_INITIAL
`endif
`endif // SYNTHESIS
endmodule
