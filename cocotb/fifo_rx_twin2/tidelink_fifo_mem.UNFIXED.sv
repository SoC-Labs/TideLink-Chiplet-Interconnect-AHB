//=============================================================================
// FROZEN NEGATIVE CONTROL — DO NOT "FIX", DO NOT SYNTHESISE, DO NOT SOURCE
// FROM ANY FLIST EXCEPT cocotb/fifo_rx_twin2/flist_unfixed.f
//
// This is a verbatim copy of src/rtl/fifo/tidelink_fifo_mem.sv as it stood at
// commit 9c157851 — i.e. IMMEDIATELY BEFORE the RX-FIFO TWIN 2 fix
// (docs/proposals/twin2_fix.patch) was applied to the tree on 2026-07-19.
// It therefore has NO ENABLE_AHB_WRITE parameter and NO guard on the
// write-side packet-length latch arm.
//
// WHY IT EXISTS: it is the A/B bench's negative control. tb_top.sv passes
// ENABLE_AHB_WRITE(0); on THIS copy the parameter does not exist, so VCS warns
// and ignores it, AHB writes stay enabled, and the TWIN 2 defect reproduces —
// the test MUST FAIL here. That failure is what proves the gate test has teeth.
// If this copy ever starts PASSING, the test has gone blind and the PASS on the
// real tree means nothing.
//
// It is DELIBERATELY frozen and will drift from the live RTL. That is fine: its
// only job is to embody the pre-fix behaviour of the write-arm, which is
// historical and will not change. Do not refresh it from the live tree.
//=============================================================================
//-----------------------------------------------------------------------------
// SoCLabs TideLink FIFO Memory Data Path
// - SRAM-backed data path with AHB slave interface, FIFO pointer control,
//   and address translation for the TideLink credit-based FIFO.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_fifo_mem #(
    // System Parameters
    parameter SYS_DATA_W = 32,  // System Data Width
    parameter RAM_ADDR_W = 14,  // Size of SRAM
    parameter RAM_DATA_W = 32   // Data Width of RAM
)(
    // --------------------------------------------------------------------------
    // Port Definitions
    // --------------------------------------------------------------------------
    input  logic                  hclk,      // system bus clock
    input  logic                  hresetn,   // system bus reset
    input  logic                  hsel,      // AHB peripheral select
    input  logic                  hready,    // AHB ready input
    input  logic            [1:0] htrans,    // AHB transfer type
    input  logic            [2:0] hsize,     // AHB hsize
    input  logic                  hwrite,    // AHB hwrite
    input  logic [RAM_ADDR_W-1:0] haddr,     // AHB address bus
    input  logic [SYS_DATA_W-1:0] hwdata,    // AHB write data bus
    output wire                   hreadyout, // AHB ready output to S->M mux
    output wire                   hresp,     // AHB response
    output wire  [SYS_DATA_W-1:0] hrdata,    // AHB read data bus

    // Completion pulse: fires when a read packet finishes (drives returner)
    output wire                   read_complete,

    output wire  [RAM_ADDR_W-2:0] current_credit_count,

    // Sideband outputs for returner
    output logic [RAM_ADDR_W-1:0] packet_word_length_out,

    // Interrupt: packet committed to FIFO (set on write_complete, cleared on read addr 0)
    output wire                   packet_committed_irq,

    // Sticky error flags (from FIFO ctrl, cleared by flush)
    output wire                   overrun,
    output wire                   underrun,

    // Control inputs (from APB registers)
    input  wire                   flush,

    // FC direct write interface (single-cycle, bypasses AHB)
    input  wire                   fc_wr_valid,
    input  wire                   fc_wr_write,
    input  wire  [RAM_ADDR_W-1:0] fc_wr_addr,
    input  wire  [SYS_DATA_W-1:0] fc_wr_wdata,
    output wire                   fc_wr_ready,

    // PUF SRAM read interface (lowest priority, for TideChart boot entropy)
    input  wire [RAM_ADDR_W-3:0]  puf_addr,
    input  wire                   puf_req,
    output wire [RAM_DATA_W-1:0]  puf_rdata,
    output reg                    puf_ack
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------
    logic [RAM_ADDR_W-3:0] ahb_sram_addr;   // from cmsdk_ahb_to_sram
    logic [RAM_DATA_W-1:0] ahb_sram_wdata;
    logic [RAM_DATA_W-1:0] rdata;
    logic            [3:0] ahb_sram_wen;
    logic                  ahb_sram_cs;
    logic [RAM_ADDR_W-3:0] translated_addr;
    logic [RAM_ADDR_W-1:0] translated_haddr;
    logic [RAM_ADDR_W-1:0] fc_translated_addr;  // from fifo_ctrl FC write path

    // SRAM arbiter: FC direct writes have priority over AHB; PUF reads are lowest
    wire fc_active = fc_wr_valid && fc_wr_write;
    assign fc_wr_ready = 1'b1;  // SRAM completes writes in 1 cycle

    // PUF read: lowest priority — only when FC and AHB are both idle
    wire puf_can_read = puf_req && !fc_active && !ahb_sram_cs;

    // Final SRAM signals (muxed between FC, AHB, and PUF paths).
    // (HAL URDWIR cleanup: a `sram_addr` mux wire previously here was unused —
    // the SRAM port is driven via `ahb_sram_addr` directly at the instance
    // below, with FC/PUF addresses muxed at their respective ports.)
    wire [RAM_DATA_W-1:0] sram_wdata = fc_active ? fc_wr_wdata                        : ahb_sram_wdata;
    wire            [3:0] sram_wen   = fc_active    ? 4'b1111 :
                                        puf_can_read ? 4'b0000 :
                                                       ahb_sram_wen;
    wire                  sram_cs    = fc_active | ahb_sram_cs | puf_can_read;

    // PUF read data: shared SRAM output, valid one cycle after puf_can_read
    assign puf_rdata = rdata;

    // PUF ack: registered one cycle after read (SRAM has 1-cycle read latency)
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            puf_ack <= 1'b0;
        else
            puf_ack <= puf_can_read;
    end

    // AHB stall: hold hready low when FC write occupies the SRAM
    wire ahb_hready_gated = hready && !fc_active;
    wire ahb_hreadyout_raw;

    // Testbench-visible signal aliases (preserve cocotb probe paths)
    // hal lint_off URDREG UCOPNM
    logic [RAM_ADDR_W-1:0] write_ptr;
    logic [RAM_ADDR_W-1:0] read_ptr;
    logic [RAM_ADDR_W-1:0] write_target_addr;
    logic [RAM_ADDR_W-1:0] read_target_addr;
    logic [RAM_ADDR_W-1:0] packet_word_length;
    logic [RAM_ADDR_W-2:0] credit_count;
    // hal lint_on URDREG UCOPNM

    // --------------------------------------------------------------------------
    // FIFO Control Logic
    // --------------------------------------------------------------------------
    tidelink_fifo_ctrl #(
        .RAM_ADDR_W (RAM_ADDR_W)
    ) u_fifo_ctrl (
        .hclk                (hclk),
        .hresetn             (hresetn),
        .hsel                (hsel),
        .htrans              (htrans),
        .hready              (hready),
        .hwrite              (hwrite),
        .haddr               (haddr),
        .hwdata              ({2'b0, hwdata[31:20]}),
        .rdata               ({2'b0, rdata[31:20]}),
        .addr                (ahb_sram_addr),
        .translated_addr     (translated_addr),
        .translated_haddr    (translated_haddr),
        .read_complete       (read_complete),
        .current_credit_count (current_credit_count),
        .write_ptr           (write_ptr),
        .read_ptr            (read_ptr),
        .write_target_addr   (write_target_addr),
        .read_target_addr    (read_target_addr),
        .packet_word_length  (packet_word_length),
        .credit_count         (credit_count),
        .packet_committed_irq(packet_committed_irq),
        .overrun             (overrun),
        .underrun            (underrun),
        .flush               (flush),
        // FC direct write interface
        .fc_wr_valid         (fc_wr_valid),
        .fc_wr_write         (fc_wr_write),
        .fc_wr_addr          (fc_wr_addr),
        .fc_wr_wdata         ({2'b0, fc_wr_wdata[31:20]}),
        .fc_translated_addr  (fc_translated_addr)
    );

    // --------------------------------------------------------------------------
    // AHB to SRAM Conversion
    // --------------------------------------------------------------------------
    cmsdk_ahb_to_sram #(
        .AW (RAM_ADDR_W)
    ) u_ahb_to_sram (
        // AHB Inputs (hready gated when FC write occupies SRAM)
        .HCLK       (hclk),
        .HRESETn    (hresetn),
        .HSEL       (hsel),
        .HADDR      (translated_haddr),
        .HTRANS     (htrans),
        .HSIZE      (hsize),
        .HWRITE     (hwrite),
        .HWDATA     (hwdata),
        .HREADY     (ahb_hready_gated),

        // AHB Outputs
        .HREADYOUT  (ahb_hreadyout_raw),
        .HRDATA     (hrdata),
        .HRESP      (hresp),

        // SRAM input
        .SRAMRDATA  (rdata),

        // SRAM Outputs (muxed with FC path before reaching SRAM)
        .SRAMADDR   (ahb_sram_addr),
        .SRAMWDATA  (ahb_sram_wdata),
        .SRAMWEN    (ahb_sram_wen),
        .SRAMCS     (ahb_sram_cs)
   );

    // AHB hreadyout: stall when FC write is active
    assign hreadyout = ahb_hreadyout_raw && !fc_active;

    // --------------------------------------------------------------------------
    // SRAM (swap tidelink_sram.sv in filelist for FPGA vs ASIC)
    // --------------------------------------------------------------------------
    tidelink_sram #(
        .AW (RAM_ADDR_W)
    ) u_sram (
        .CLK        (hclk),
        .ADDR       (fc_active    ? fc_translated_addr[RAM_ADDR_W-1:2] :
                     puf_can_read ? puf_addr :
                                    translated_addr),
        .WDATA      (sram_wdata),
        .WREN       (sram_wen),
        .CS         (sram_cs),
        .RDATA      (rdata)
    );

    // Sideband: expose packet_word_length for returner
    assign packet_word_length_out = packet_word_length;

endmodule
