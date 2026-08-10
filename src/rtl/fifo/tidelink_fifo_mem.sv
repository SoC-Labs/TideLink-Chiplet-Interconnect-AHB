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
    parameter RAM_DATA_W = 32,  // Data Width of RAM
    // PENDING-DECISION #1 pass-through (default 1'b1 = bit-identical). See
    // tidelink_fifo_ctrl.ENABLE_AHB_WRITE.
    parameter bit ENABLE_AHB_WRITE = 1'b1
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

    // RX-FIFO TWIN 2 sticky fault: AHB write into RX aperture while disarmed.
    output wire                   ahb_inject_fault,

    // Control inputs (from APB registers)
    input  wire                   flush,

    // RX-FIFO TWIN 2 (chip-killer) — runtime arm for the AHB CPU-write-into-RX
    // path, POR-disarmed at tidelink_apb_regs CTRL[3]. See tidelink_fifo_ctrl.
    input  wire                   swi_ahb_inject_arm,

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

    // --------------------------------------------------------------------------
    // AHB-read / FC-write SRAM arbitration race fix (link-survey campaign,
    // 2026-08-02)
    // --------------------------------------------------------------------------
    // ROOT CAUSE (proven by cocotb/tidelink_fifo_concurrent_race/
    // test_diag_sram_addr_hijack.py): the vendor SRAM (cmsdk_fpga_sram.v,
    // read-only IP) registers its read address (addr_q1) UNCONDITIONALLY
    // every cycle, from whatever this module's own ADDR mux happens to show
    // that cycle, regardless of chip-select. An AHB read's target address
    // only flows correctly through cmsdk_ahb_to_sram's SRAMADDR output
    // DURING its own address-phase cycle (its internal `ahb_read`
    // combinational condition, which needs HSEL+HTRANS+HREADY together) —
    // for every cycle afterward, while this module holds the data phase
    // open via ahb_hready_gated, the AHB master has typically already
    // dropped HSEL (single-beat, non-pipelined transfer, exactly how every
    // driver in this repo — production and test — issues an AHB FIFO
    // read), so cmsdk's own SRAMADDR reverts to `buf_addr` (an unrelated
    // write-buffer leftover). If a concurrent FC direct write's
    // `fc_active` cycle lands anywhere in that stalled window, its own
    // address wins the top-priority ADDR mux below and gets latched into
    // addr_q1 — clobbering the read's real target. Because
    // `ahb_hreadyout_raw` never wait-states on its own (cmsdk_ahb_to_sram's
    // `HREADYOUT` is hardwired 1'b1 — it has no internal stall logic), this
    // module's own `hreadyout` used to release the very same cycle
    // `fc_active` cleared: one full SRAM pipeline stage too early — the
    // re-presented correct address hadn't yet been re-latched into
    // addr_q1, let alone had a further cycle for the corresponding data to
    // become valid at the SRAM's output.
    //
    // FIX (direction (b) from the investigation, not a bare stall
    // extension: extending the stall ALONE cannot work here, because once
    // HSEL drops after the address phase nothing ever re-drives the real
    // HADDR through cmsdk_ahb_to_sram again — waiting longer just samples
    // `buf_addr` garbage instead of the FC poison, not the real target).
    // Capture the read's own translated SRAM address the cycle its address
    // phase is accepted (`read_addr_pending_r`), and re-present THAT
    // captured address to the physical SRAM on every subsequent cycle the
    // FC-write path isn't actively driving the port, for as long as the
    // read remains unresolved (`read_active_r`). Only release (let
    // hreadyout go high again) once the re-presented address has survived
    // one full clean (non-fc_active) cycle immediately followed by another
    // clean cycle — i.e. addr_q1 has been correctly re-registered with the
    // real address AND the corresponding data has had a further cycle to
    // become valid at the SRAM output. A multi-cycle, or repeated, FC-write
    // burst simply keeps re-arming this condition every time it disturbs
    // the port; it self-clears exactly 2 cycles after the SRAM is last left
    // alone. Cost: ZERO extra cycles on any read that never races an FC
    // write (the overwhelming majority — see the suite results this change
    // was verified against); exactly the minimum extra stall needed on
    // ones that do.
    //
    logic                   read_active_r;       // an AHB read's data has not yet been safely delivered
    logic                   addr_clean_prev_r;    // fc_active was 0 during the cycle immediately preceding this one
    logic [RAM_ADDR_W-3:0]  read_addr_pending_r;  // captured, correct SRAM word address for that read

    // Extra stall needed: a read is outstanding and the address was not
    // cleanly (re-)registered on the cycle immediately before this one —
    // i.e. at most one clean cycle has elapsed since the last disturbance
    // (or since the address phase, if the read has never been disturbed).
    wire read_recovery_stall = read_active_r && !addr_clean_prev_r;

    // Generalizes the original fc_active-only stall: hold the AHB port
    // whenever FC owns the SRAM this cycle, OR a prior read's data is not
    // yet safely re-registered following a disturbance. Declared here
    // (ahead of the original "AHB stall" section further down, which now
    // just consumes it) so ahb_read_addr_phase below can use it — VCS
    // requires continuous `wire = expr` assignments declared before use.
    wire hold_for_sram_race = fc_active || read_recovery_stall;
    wire ahb_hready_gated = hready && !hold_for_sram_race;

    // Mirrors cmsdk_ahb_to_sram's own internal `ahb_read` condition
    // (ahb_access & ~HWRITE, ahb_access = HTRANS[1] & HSEL & HREADY) using
    // this module's own view of the (gated) HREADY fed to that IP, so it
    // fires on exactly the same cycle cmsdk latches HADDR into its
    // SRAMADDR output — i.e. the address-phase-acceptance cycle of an AHB
    // read.
    wire ahb_read_addr_phase = hsel && htrans[1] && !hwrite && ahb_hready_gated;

    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn) begin
            read_active_r       <= 1'b0;
            addr_clean_prev_r   <= 1'b0;
            read_addr_pending_r <= '0;
        end else begin
            // Tracks "was the cycle that just ended clean" for use as next
            // cycle's recovery-stall input (one-cycle delayed fc_active,
            // sampled every cycle regardless of read_active_r).
            addr_clean_prev_r <= !fc_active;

            if (ahb_read_addr_phase) begin
                // New read address phase accepted -- always on a clean
                // cycle by construction (hold_for_sram_race gates
                // ahb_hready_gated, so it already forces fc_active=0
                // whenever this fires). Prime tracking for the data
                // phase(s) ahead.
                read_active_r       <= 1'b1;
                read_addr_pending_r <= ahb_sram_addr;
            end else if (read_active_r && !hold_for_sram_race) begin
                // hold_for_sram_race was 0 last cycle -> hreadyout was
                // high -> the data phase completed (per AHB semantics, a
                // completer's own HREADYOUT going high is the transfer
                // completing, independent of when a master's driver script
                // happens to poll it). Stop tracking so the ADDR mux below
                // reverts to the normal translated_addr path for whatever
                // comes next.
                read_active_r <= 1'b0;
            end
        end
    end

    // PUF read: lowest priority — only when FC, AHB, and an in-recovery AHB
    // read are all idle (the last exclusion keeps PUF from stealing the
    // SRAM port, and re-poisoning read_addr_pending_r's recovery window,
    // during the race-fix re-presentation cycles above).
    wire puf_can_read = puf_req && !fc_active && !ahb_sram_cs && !read_active_r;

    // Final SRAM signals (muxed between FC, AHB, and PUF paths).
    // (HAL URDWIR cleanup: a `sram_addr` mux wire previously here was unused —
    // the SRAM port is driven via `ahb_sram_addr` directly at the instance
    // below, with FC/PUF addresses muxed at their respective ports.)
    wire [RAM_DATA_W-1:0] sram_wdata = fc_active ? fc_wr_wdata                        : ahb_sram_wdata;
    wire            [3:0] sram_wen   = fc_active    ? 4'b1111 :
                                        puf_can_read ? 4'b0000 :
                                                       ahb_sram_wen;
    // read_active_r forces CS during the race-fix re-presentation cycles
    // (sram_wen stays 0 there, so this is a read-only access — see ADDR mux
    // below) so the vendor SRAM's registered `cs_reg` (see
    // cmsdk_fpga_sram.v) doesn't gate the eventually-valid RDATA back to
    // zero.
    wire                  sram_cs    = fc_active | ahb_sram_cs | puf_can_read | read_active_r;

    // PUF read data: shared SRAM output, valid one cycle after puf_can_read
    assign puf_rdata = rdata;

    // PUF ack: registered one cycle after read (SRAM has 1-cycle read latency)
    always @(posedge hclk or negedge hresetn) begin
        if (!hresetn)
            puf_ack <= 1'b0;
        else
            puf_ack <= puf_can_read;
    end

    // AHB stall: hold hready low when FC write occupies the SRAM, OR (race
    // fix, see above) while a prior read's data is not yet safely
    // re-registered after a disturbance. (ahb_hready_gated itself is
    // declared earlier, alongside hold_for_sram_race, since
    // ahb_read_addr_phase needs it ahead of this point.)
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
        .RAM_ADDR_W (RAM_ADDR_W),
        .ENABLE_AHB_WRITE (ENABLE_AHB_WRITE)
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
        .ahb_inject_fault    (ahb_inject_fault),
        .flush               (flush),
        .swi_ahb_inject_arm  (swi_ahb_inject_arm),
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

    // AHB hreadyout: stall when FC write is active, or (race fix) while a
    // prior read's data is not yet safely re-registered.
    assign hreadyout = ahb_hreadyout_raw && !hold_for_sram_race;

    // --------------------------------------------------------------------------
    // SRAM (swap tidelink_sram.sv in filelist for FPGA vs ASIC)
    // --------------------------------------------------------------------------
    tidelink_sram #(
        .AW (RAM_ADDR_W)
    ) u_sram (
        .CLK        (hclk),
        .ADDR       (fc_active     ? fc_translated_addr[RAM_ADDR_W-1:2] :
                     puf_can_read  ? puf_addr :
                     read_active_r ? read_addr_pending_r :
                                     translated_addr),
        .WDATA      (sram_wdata),
        .WREN       (sram_wen),
        .CS         (sram_cs),
        .RDATA      (rdata)
    );

    // Sideband: expose packet_word_length for returner
    assign packet_word_length_out = packet_word_length;

endmodule
