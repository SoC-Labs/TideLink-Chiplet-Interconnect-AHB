// Diagnostic cocotb wrapper for tidelink_fifo_mem — link-survey campaign,
// 2026-08-01.
//
// PURPOSE: cocotb/tidelink_fifo/tb_top.sv (the existing unit-level FIFO
// testbench) ties fc_wr_* off and only exercises the AHB port. That hides
// exactly the interaction under investigation: in production
// (tidelink_fifo.sv), the SAME tidelink_fifo_mem / tidelink_fifo_ctrl
// instance serves BOTH
//   (a) inbound packet writes arriving from the peer over the link, via the
//       single-cycle FC direct-write port (fc_wr_*) — this is how a die's RX
//       FSM (tidelink_fc_adapter RX_ADDR_PHASE) delivers newly-arrived words
//       into that die's RX FIFO, and
//   (b) local software/TXGEN AHB reads that DRAIN already-queued packets out
//       of that same RX FIFO.
// This wrapper exposes fc_wr_* as top-level ports (instead of tying them
// off) so a cocotb test can drive an FC write concurrently with an
// in-progress AHB read and observe the DUT's internal packet-metadata state
// (packet_active_r, packet_word_length_r, read_target_addr_r,
// write_target_addr_r, check_addr_r) at cycle granularity around the race
// window. No RTL is modified — this is the identical tidelink_fifo_mem
// instance production code uses, just with more of its ports wired out.
module tb_top #(
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32
)(
    input  logic                  hclk,
    input  logic                  hresetn,

    // AHB slave (drain / read-side, and legacy AHB-write-side)
    input  logic                  hsel,
    input  logic            [1:0] htrans,
    input  logic            [2:0] hsize,
    input  logic                  hwrite,
    input  logic [RAM_ADDR_W-1:0] haddr,
    input  logic [SYS_DATA_W-1:0] hwdata,
    output logic                  hready,
    output logic                  hresp,
    output logic [SYS_DATA_W-1:0] hrdata,

    output logic                  read_complete,
    output logic [RAM_ADDR_W-1:0] packet_word_length_out,
    output logic                  packet_committed_irq,
    output logic                  overrun,
    output logic                  underrun,
    input  logic                  flush,

    // RX-FIFO TWIN 2 runtime arm — hardwired on, as the existing
    // cocotb/tidelink_fifo/tb_top.sv does, so the AHB write-side path (used
    // only for setup/reference here, not for the race itself) behaves as if
    // software armed it.
    // FC direct write interface — the inbound "packet arrives from peer"
    // path. Driven directly by the test to simulate concurrent TX/inbound
    // traffic while an AHB drain read is in flight.
    input  logic                   fc_wr_valid,
    input  logic                   fc_wr_write,
    input  logic [RAM_ADDR_W-1:0]  fc_wr_addr,
    input  logic [SYS_DATA_W-1:0]  fc_wr_wdata,
    output logic                   fc_wr_ready
);

    // In a single-slave system, HREADY = HREADYOUT
    wire hreadyout;
    assign hready = hreadyout;

    tidelink_fifo_mem #(
        .SYS_DATA_W(SYS_DATA_W),
        .RAM_ADDR_W(RAM_ADDR_W),
        .RAM_DATA_W(RAM_DATA_W)
    ) u_dut (
        .hclk      (hclk),
        .hresetn   (hresetn),
        .hsel      (hsel),
        .hready    (hready),
        .htrans    (htrans),
        .hsize     (hsize),
        .hwrite    (hwrite),
        .haddr     (haddr),
        .hwdata    (hwdata),
        .hreadyout     (hreadyout),
        .hresp         (hresp),
        .hrdata        (hrdata),
        .read_complete        (read_complete),
        .current_credit_count (),
        .packet_word_length_out(packet_word_length_out),
        .packet_committed_irq (packet_committed_irq),
        .overrun              (overrun),
        .underrun             (underrun),
        .flush                (flush),
        .swi_ahb_inject_arm   (1'b1),
        // FC direct write port — wired out to the test, unlike the existing
        // unit-level tb_top.sv which ties it off.
        .fc_wr_valid          (fc_wr_valid),
        .fc_wr_write          (fc_wr_write),
        .fc_wr_addr           (fc_wr_addr),
        .fc_wr_wdata          (fc_wr_wdata),
        .fc_wr_ready          (fc_wr_ready),
        // PUF SRAM read port — unused here
        .puf_addr             ({(RAM_ADDR_W-2){1'b0}}),
        .puf_req              (1'b0),
        .puf_rdata            (),
        .puf_ack              ()
    );

    // Waveform dump
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
