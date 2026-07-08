module TideLinkToWlink(
  input         clock,
  input         reset,
  input         auto_wlink_tidelinktl_rx_in_sop,
  input  [7:0]  auto_wlink_tidelinktl_rx_in_data_id,
  input  [15:0] auto_wlink_tidelinktl_rx_in_word_count,
  input  [55:0] auto_wlink_tidelinktl_rx_in_data,
  input         auto_wlink_tidelinktl_rx_in_valid,
  input  [15:0] auto_wlink_tidelinktl_rx_in_crc,
  output        auto_wlink_tidelinktl_tx_out_sop,
  output [7:0]  auto_wlink_tidelinktl_tx_out_data_id,
  output [15:0] auto_wlink_tidelinktl_tx_out_word_count,
  output [55:0] auto_wlink_tidelinktl_tx_out_data,
  output [15:0] auto_wlink_tidelinktl_tx_out_crc,
  input         auto_wlink_tidelinktl_tx_out_advance,
  input         auto_in_psel,
  input         auto_in_penable,
  input         auto_in_pwrite,
  input  [12:0] auto_in_paddr,
  input  [31:0] auto_in_pwdata,
  input  [3:0]  auto_in_pstrb,
  output        auto_in_pready,
  output [31:0] auto_in_prdata,
  input         io_app_clk,
  input         io_app_reset,
  input         io_app_enable,
  input         io_tx_clk,
  input         io_tx_reset,
  input         io_rx_clk,
  input         io_rx_reset,
  output        io_rx_crc_err,
  output [49:0] tl_bus_out_0,
  input  [49:0] bore_1,
  // SoC Labs credit-path observability — pass-through of the FCSM
  // (wlink_tidelinktl) internals up to Wlink.v. See WlinkGenericFCSM_6.v.
  output [2:0]  io_obs_fcsm_state,
  output        io_obs_cr_pkt_seen_rx,
  output        io_obs_crack_pkt_seen_rx,
  output        io_obs_pkt_is_cr_pkt,
  output        io_obs_pkt_is_crack_pkt,
  // SoC Labs Bug-A FCSM observation 2026-06-02 — pass-through of the gate
  // signals for the state 4→5 (LINK_IDLE → LINK_DATA) transition.
  output        io_obs_a2l_replay_link_valid,
  output [7:0]  io_obs_fe_rx_credit_max,
  output        io_obs_fe_rx_is_full,
  // SoC Labs Bug-A FCSM observation 2026-06-03
  output        io_obs_a2l_replay_app_valid,
  // SoC Labs V2 data-send observation 2026-06-21 — pass-through of the a2l
  // replay buffer's true app_ready (app-clk) and link_empty (link-clk).
  output        io_obs_a2l_replay_app_ready,
  output        io_obs_a2l_replay_link_empty,
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 — pass-through of
  // the a2l replay buffer's raw write ptr, app-clk-synced ACK ptr, false-FULL
  // flag, and the enable demet term of app_ready. Read-only fan-outs.
  output [4:0]  io_obs_a2l_wptr,
  output [4:0]  io_obs_a2l_synced_ack,
  output        io_obs_a2l_full,
  output        io_obs_a2l_enable_app_demet,
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  // — pass-through of the a2l replay buffer's read-side reset and LINK read
  // binary pointer. Read-only fan-outs.
  output        io_obs_a2l_rreset,
  output [4:0]  io_obs_a2l_rptr,
  // SoC Labs a2l ACK-sync MAILBOX observation 2026-07-08 — David Mapstone.
  // Pass-through of the a2l replay CDC "tear surface": LINK-domain ACK ptr input
  // + ping-pong mailbox internals. Read-only fan-outs (NO functional change).
  // Packed into APB obs reg 0x4403_21BC (marker 0xCB) in axi_chiplet_controller.
  output [4:0]  io_obs_a2l_link_addr,
  output [4:0]  io_obs_mbx_raddr,
  output [4:0]  io_obs_mbx_mem_0,
  output [4:0]  io_obs_mbx_mem_1,
  output        io_obs_mbx_wptr,
  output        io_obs_mbx_rptr,
  output        io_obs_mbx_w_ready,
  output        io_obs_mbx_r_ready,
  // SoC Labs FC credit observation 2026-06-12 — far-end RX credit pointer
  output [7:0]  io_obs_fe_rx_ptr,
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap) — packed
  // sticky FCSM delivery word forwarded up from the FCSM instance.
  output [31:0] io_obs_fcsmcap
);
  // SoC Labs observability nets from the FCSM instance.
  wire [2:0] wlink_tidelinktl_io_obs_state;
  wire       wlink_tidelinktl_io_obs_cr_pkt_seen_rx;
  wire       wlink_tidelinktl_io_obs_crack_pkt_seen_rx;
  wire       wlink_tidelinktl_io_obs_pkt_is_cr_pkt;
  wire       wlink_tidelinktl_io_obs_pkt_is_crack_pkt;
  // SoC Labs Bug-A FCSM observation 2026-06-02
  wire       wlink_tidelinktl_io_obs_a2l_replay_link_valid;
  wire [7:0] wlink_tidelinktl_io_obs_fe_rx_credit_max;
  wire       wlink_tidelinktl_io_obs_fe_rx_is_full;
  // SoC Labs Bug-A FCSM observation 2026-06-03
  wire       wlink_tidelinktl_io_obs_a2l_replay_app_valid;
  // SoC Labs V2 data-send observation 2026-06-21
  wire       wlink_tidelinktl_io_obs_a2l_replay_app_ready;
  wire       wlink_tidelinktl_io_obs_a2l_replay_link_empty;
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
  wire [4:0] wlink_tidelinktl_io_obs_a2l_wptr;
  wire [4:0] wlink_tidelinktl_io_obs_a2l_synced_ack;
  wire       wlink_tidelinktl_io_obs_a2l_full;
  wire       wlink_tidelinktl_io_obs_a2l_enable_app_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
  wire       wlink_tidelinktl_io_obs_a2l_rreset;
  wire [4:0] wlink_tidelinktl_io_obs_a2l_rptr;
  // SoC Labs a2l ACK-sync MAILBOX observation 2026-07-08 (read-only fan-out wires)
  wire [4:0] wlink_tidelinktl_io_obs_a2l_link_addr;
  wire [4:0] wlink_tidelinktl_io_obs_mbx_raddr;
  wire [4:0] wlink_tidelinktl_io_obs_mbx_mem_0;
  wire [4:0] wlink_tidelinktl_io_obs_mbx_mem_1;
  wire       wlink_tidelinktl_io_obs_mbx_wptr;
  wire       wlink_tidelinktl_io_obs_mbx_rptr;
  wire       wlink_tidelinktl_io_obs_mbx_w_ready;
  wire       wlink_tidelinktl_io_obs_mbx_r_ready;
  // SoC Labs FC credit observation 2026-06-12
  wire [7:0] wlink_tidelinktl_io_obs_fe_rx_ptr;
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap)
  wire [31:0] wlink_tidelinktl_io_obs_fcsmcap;
  wire  wlink_tidelinktl_clock; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_reset; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_in_psel; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_in_penable; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_in_pwrite; // @[TideLink.scala 177:22]
  wire [12:0] wlink_tidelinktl_auto_in_paddr; // @[TideLink.scala 177:22]
  wire [31:0] wlink_tidelinktl_auto_in_pwdata; // @[TideLink.scala 177:22]
  wire [3:0] wlink_tidelinktl_auto_in_pstrb; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_in_pready; // @[TideLink.scala 177:22]
  wire [31:0] wlink_tidelinktl_auto_in_prdata; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_rx_in_sop; // @[TideLink.scala 177:22]
  wire [7:0] wlink_tidelinktl_auto_rx_in_data_id; // @[TideLink.scala 177:22]
  wire [15:0] wlink_tidelinktl_auto_rx_in_word_count; // @[TideLink.scala 177:22]
  wire [55:0] wlink_tidelinktl_auto_rx_in_data; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_rx_in_valid; // @[TideLink.scala 177:22]
  wire [15:0] wlink_tidelinktl_auto_rx_in_crc; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_tx_out_sop; // @[TideLink.scala 177:22]
  wire [7:0] wlink_tidelinktl_auto_tx_out_data_id; // @[TideLink.scala 177:22]
  wire [15:0] wlink_tidelinktl_auto_tx_out_word_count; // @[TideLink.scala 177:22]
  wire [55:0] wlink_tidelinktl_auto_tx_out_data; // @[TideLink.scala 177:22]
  wire [15:0] wlink_tidelinktl_auto_tx_out_crc; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_auto_tx_out_advance; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_clk; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_reset; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_enable; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_a2l_valid; // @[TideLink.scala 177:22]
  wire [47:0] wlink_tidelinktl_io_app_a2l_data; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_a2l_ready; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_l2a_valid; // @[TideLink.scala 177:22]
  wire [47:0] wlink_tidelinktl_io_app_l2a_data; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_app_l2a_accept; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_tx_clk; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_tx_reset; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_rx_clk; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_rx_reset; // @[TideLink.scala 177:22]
  wire  wlink_tidelinktl_io_rx_crc_err; // @[TideLink.scala 177:22]
  wire [49:0] tl_bus_out = {wlink_tidelinktl_io_app_a2l_ready,wlink_tidelinktl_io_app_l2a_valid,
    wlink_tidelinktl_io_app_l2a_data}; // @[Cat.scala 30:58]
  WlinkGenericFCSM_6 wlink_tidelinktl ( // @[TideLink.scala 177:22]
    .clock(wlink_tidelinktl_clock),
    .reset(wlink_tidelinktl_reset),
    .auto_in_psel(wlink_tidelinktl_auto_in_psel),
    .auto_in_penable(wlink_tidelinktl_auto_in_penable),
    .auto_in_pwrite(wlink_tidelinktl_auto_in_pwrite),
    .auto_in_paddr(wlink_tidelinktl_auto_in_paddr),
    .auto_in_pwdata(wlink_tidelinktl_auto_in_pwdata),
    .auto_in_pstrb(wlink_tidelinktl_auto_in_pstrb),
    .auto_in_pready(wlink_tidelinktl_auto_in_pready),
    .auto_in_prdata(wlink_tidelinktl_auto_in_prdata),
    .auto_rx_in_sop(wlink_tidelinktl_auto_rx_in_sop),
    .auto_rx_in_data_id(wlink_tidelinktl_auto_rx_in_data_id),
    .auto_rx_in_word_count(wlink_tidelinktl_auto_rx_in_word_count),
    .auto_rx_in_data(wlink_tidelinktl_auto_rx_in_data),
    .auto_rx_in_valid(wlink_tidelinktl_auto_rx_in_valid),
    .auto_rx_in_crc(wlink_tidelinktl_auto_rx_in_crc),
    .auto_tx_out_sop(wlink_tidelinktl_auto_tx_out_sop),
    .auto_tx_out_data_id(wlink_tidelinktl_auto_tx_out_data_id),
    .auto_tx_out_word_count(wlink_tidelinktl_auto_tx_out_word_count),
    .auto_tx_out_data(wlink_tidelinktl_auto_tx_out_data),
    .auto_tx_out_crc(wlink_tidelinktl_auto_tx_out_crc),
    .auto_tx_out_advance(wlink_tidelinktl_auto_tx_out_advance),
    .io_app_clk(wlink_tidelinktl_io_app_clk),
    .io_app_reset(wlink_tidelinktl_io_app_reset),
    .io_app_enable(wlink_tidelinktl_io_app_enable),
    .io_app_a2l_valid(wlink_tidelinktl_io_app_a2l_valid),
    .io_app_a2l_data(wlink_tidelinktl_io_app_a2l_data),
    .io_app_a2l_ready(wlink_tidelinktl_io_app_a2l_ready),
    .io_app_l2a_valid(wlink_tidelinktl_io_app_l2a_valid),
    .io_app_l2a_data(wlink_tidelinktl_io_app_l2a_data),
    .io_app_l2a_accept(wlink_tidelinktl_io_app_l2a_accept),
    .io_tx_clk(wlink_tidelinktl_io_tx_clk),
    .io_tx_reset(wlink_tidelinktl_io_tx_reset),
    .io_rx_clk(wlink_tidelinktl_io_rx_clk),
    .io_rx_reset(wlink_tidelinktl_io_rx_reset),
    .io_rx_crc_err(wlink_tidelinktl_io_rx_crc_err),
    .io_obs_state(wlink_tidelinktl_io_obs_state),
    .io_obs_cr_pkt_seen_rx(wlink_tidelinktl_io_obs_cr_pkt_seen_rx),
    .io_obs_crack_pkt_seen_rx(wlink_tidelinktl_io_obs_crack_pkt_seen_rx),
    .io_obs_pkt_is_cr_pkt(wlink_tidelinktl_io_obs_pkt_is_cr_pkt),
    .io_obs_pkt_is_crack_pkt(wlink_tidelinktl_io_obs_pkt_is_crack_pkt),
    // SoC Labs Bug-A FCSM observation 2026-06-02
    .io_obs_a2l_replay_link_valid(wlink_tidelinktl_io_obs_a2l_replay_link_valid),
    .io_obs_fe_rx_credit_max(wlink_tidelinktl_io_obs_fe_rx_credit_max),
    .io_obs_fe_rx_is_full(wlink_tidelinktl_io_obs_fe_rx_is_full),
    // SoC Labs Bug-A FCSM observation 2026-06-03
    .io_obs_a2l_replay_app_valid(wlink_tidelinktl_io_obs_a2l_replay_app_valid),
    // SoC Labs V2 data-send observation 2026-06-21
    .io_obs_a2l_replay_app_ready(wlink_tidelinktl_io_obs_a2l_replay_app_ready),
    .io_obs_a2l_replay_link_empty(wlink_tidelinktl_io_obs_a2l_replay_link_empty),
    // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21
    .io_obs_a2l_wptr(wlink_tidelinktl_io_obs_a2l_wptr),
    .io_obs_a2l_synced_ack(wlink_tidelinktl_io_obs_a2l_synced_ack),
    .io_obs_a2l_full(wlink_tidelinktl_io_obs_a2l_full),
    .io_obs_a2l_enable_app_demet(wlink_tidelinktl_io_obs_a2l_enable_app_demet),
    // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER observation 2026-06-21
    .io_obs_a2l_rreset(wlink_tidelinktl_io_obs_a2l_rreset),
    .io_obs_a2l_rptr(wlink_tidelinktl_io_obs_a2l_rptr),
    // SoC Labs a2l ACK-sync MAILBOX observation 2026-07-08 (read-only fan-outs)
    .io_obs_a2l_link_addr(wlink_tidelinktl_io_obs_a2l_link_addr),
    .io_obs_mbx_raddr(wlink_tidelinktl_io_obs_mbx_raddr),
    .io_obs_mbx_mem_0(wlink_tidelinktl_io_obs_mbx_mem_0),
    .io_obs_mbx_mem_1(wlink_tidelinktl_io_obs_mbx_mem_1),
    .io_obs_mbx_wptr(wlink_tidelinktl_io_obs_mbx_wptr),
    .io_obs_mbx_rptr(wlink_tidelinktl_io_obs_mbx_rptr),
    .io_obs_mbx_w_ready(wlink_tidelinktl_io_obs_mbx_w_ready),
    .io_obs_mbx_r_ready(wlink_tidelinktl_io_obs_mbx_r_ready),
    // SoC Labs FC credit observation 2026-06-12
    .io_obs_fe_rx_ptr(wlink_tidelinktl_io_obs_fe_rx_ptr),
    // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (rxcap)
    .io_obs_fcsmcap(wlink_tidelinktl_io_obs_fcsmcap)
  );
  // SoC Labs credit-path observability pass-through.
  assign io_obs_fcsm_state        = wlink_tidelinktl_io_obs_state;
  assign io_obs_cr_pkt_seen_rx    = wlink_tidelinktl_io_obs_cr_pkt_seen_rx;
  assign io_obs_crack_pkt_seen_rx = wlink_tidelinktl_io_obs_crack_pkt_seen_rx;
  assign io_obs_pkt_is_cr_pkt     = wlink_tidelinktl_io_obs_pkt_is_cr_pkt;
  assign io_obs_pkt_is_crack_pkt  = wlink_tidelinktl_io_obs_pkt_is_crack_pkt;
  // SoC Labs Bug-A FCSM observation 2026-06-02
  assign io_obs_a2l_replay_link_valid = wlink_tidelinktl_io_obs_a2l_replay_link_valid;
  assign io_obs_fe_rx_credit_max      = wlink_tidelinktl_io_obs_fe_rx_credit_max;
  assign io_obs_fe_rx_is_full         = wlink_tidelinktl_io_obs_fe_rx_is_full;
  // SoC Labs Bug-A FCSM observation 2026-06-03
  assign io_obs_a2l_replay_app_valid  = wlink_tidelinktl_io_obs_a2l_replay_app_valid;
  // SoC Labs V2 data-send observation 2026-06-21 (read-only fan-out)
  assign io_obs_a2l_replay_app_ready  = wlink_tidelinktl_io_obs_a2l_replay_app_ready;
  assign io_obs_a2l_replay_link_empty = wlink_tidelinktl_io_obs_a2l_replay_link_empty;
  // SoC Labs V2 data-send RAW-POINTER observation 2026-06-21 (read-only fan-out)
  assign io_obs_a2l_wptr              = wlink_tidelinktl_io_obs_a2l_wptr;
  assign io_obs_a2l_synced_ack        = wlink_tidelinktl_io_obs_a2l_synced_ack;
  assign io_obs_a2l_full              = wlink_tidelinktl_io_obs_a2l_full;
  assign io_obs_a2l_enable_app_demet  = wlink_tidelinktl_io_obs_a2l_enable_app_demet;
  // SoC Labs V2 data-send LINK-SIDE RESET + READ-POINTER obs 2026-06-21 (RO fan-out)
  assign io_obs_a2l_rreset            = wlink_tidelinktl_io_obs_a2l_rreset;
  assign io_obs_a2l_rptr              = wlink_tidelinktl_io_obs_a2l_rptr;
  // SoC Labs a2l ACK-sync MAILBOX obs 2026-07-08 (read-only fan-outs)
  assign io_obs_a2l_link_addr         = wlink_tidelinktl_io_obs_a2l_link_addr;
  assign io_obs_mbx_raddr             = wlink_tidelinktl_io_obs_mbx_raddr;
  assign io_obs_mbx_mem_0             = wlink_tidelinktl_io_obs_mbx_mem_0;
  assign io_obs_mbx_mem_1             = wlink_tidelinktl_io_obs_mbx_mem_1;
  assign io_obs_mbx_wptr              = wlink_tidelinktl_io_obs_mbx_wptr;
  assign io_obs_mbx_rptr              = wlink_tidelinktl_io_obs_mbx_rptr;
  assign io_obs_mbx_w_ready           = wlink_tidelinktl_io_obs_mbx_w_ready;
  assign io_obs_mbx_r_ready           = wlink_tidelinktl_io_obs_mbx_r_ready;
  // SoC Labs FC credit observation 2026-06-12
  assign io_obs_fe_rx_ptr             = wlink_tidelinktl_io_obs_fe_rx_ptr;
  // SoC Labs FCSM long-DATA DELIVERY STICKY CAPTURE 2026-06-21 (RO fan-out)
  assign io_obs_fcsmcap               = wlink_tidelinktl_io_obs_fcsmcap;
  assign auto_wlink_tidelinktl_tx_out_sop = wlink_tidelinktl_auto_tx_out_sop; // @[LazyModule.scala 311:12]
  assign auto_wlink_tidelinktl_tx_out_data_id = wlink_tidelinktl_auto_tx_out_data_id; // @[LazyModule.scala 311:12]
  assign auto_wlink_tidelinktl_tx_out_word_count = wlink_tidelinktl_auto_tx_out_word_count; // @[LazyModule.scala 311:12]
  assign auto_wlink_tidelinktl_tx_out_data = wlink_tidelinktl_auto_tx_out_data; // @[LazyModule.scala 311:12]
  assign auto_wlink_tidelinktl_tx_out_crc = wlink_tidelinktl_auto_tx_out_crc; // @[LazyModule.scala 311:12]
  assign auto_in_pready = wlink_tidelinktl_auto_in_pready; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign auto_in_prdata = wlink_tidelinktl_auto_in_prdata; // @[Nodes.scala 1207:84 LazyModule.scala 298:16]
  assign io_rx_crc_err = wlink_tidelinktl_io_rx_crc_err; // @[TideLink.scala 215:19]
  assign tl_bus_out_0 = tl_bus_out;
  assign wlink_tidelinktl_clock = clock;
  assign wlink_tidelinktl_reset = reset;
  assign wlink_tidelinktl_auto_in_psel = auto_in_psel; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_in_penable = auto_in_penable; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_in_pwrite = auto_in_pwrite; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_in_paddr = auto_in_paddr; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_in_pwdata = auto_in_pwdata; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_in_pstrb = auto_in_pstrb; // @[Nodes.scala 1210:84 LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_sop = auto_wlink_tidelinktl_rx_in_sop; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_data_id = auto_wlink_tidelinktl_rx_in_data_id; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_word_count = auto_wlink_tidelinktl_rx_in_word_count; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_data = auto_wlink_tidelinktl_rx_in_data; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_valid = auto_wlink_tidelinktl_rx_in_valid; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_rx_in_crc = auto_wlink_tidelinktl_rx_in_crc; // @[LazyModule.scala 309:16]
  assign wlink_tidelinktl_auto_tx_out_advance = auto_wlink_tidelinktl_tx_out_advance; // @[LazyModule.scala 311:12]
  assign wlink_tidelinktl_io_app_clk = io_app_clk; // @[TideLink.scala 235:29]
  assign wlink_tidelinktl_io_app_reset = io_app_reset; // @[TideLink.scala 236:29]
  assign wlink_tidelinktl_io_app_enable = io_app_enable; // @[TideLink.scala 237:29]
  assign wlink_tidelinktl_io_app_a2l_valid = bore_1[49]; // @[TideLink.scala 240:31]
  assign wlink_tidelinktl_io_app_a2l_data = bore_1[48:1]; // @[TideLink.scala 241:31]
  assign wlink_tidelinktl_io_app_l2a_accept = bore_1[0]; // @[TideLink.scala 242:31]
  assign wlink_tidelinktl_io_tx_clk = io_tx_clk; // @[TideLink.scala 230:29]
  assign wlink_tidelinktl_io_tx_reset = io_tx_reset; // @[TideLink.scala 231:29]
  assign wlink_tidelinktl_io_rx_clk = io_rx_clk; // @[TideLink.scala 232:29]
  assign wlink_tidelinktl_io_rx_reset = io_rx_reset; // @[TideLink.scala 233:29]
endmodule
