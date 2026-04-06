//-----------------------------------------------------------------------------
// SoCLabs TideLink FIFO Top-Level Module
// - Wraps a TideLink FIFO memory data path (AHB slave), a TideLink Returner
//   (AHB master), and an APB slave register interface for configuration
//   and status.
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------

module tidelink_fifo #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter RAM_DATA_W = 32,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = '0  // APB base address of the paired tidelink
)(
    // --------------------------------------------------------------------------
    // Clock and Reset
    // --------------------------------------------------------------------------
    input  logic                    hclk,
    input  logic                    hresetn,

    // --------------------------------------------------------------------------
    // AHB Slave Interface (to TideLink FIFO Memory)
    // --------------------------------------------------------------------------
    input  logic                    ahbs_hsel,
    input  logic                    ahbs_hready,
    input  logic              [1:0] ahbs_htrans,
    input  logic              [2:0] ahbs_hsize,
    input  logic                    ahbs_hwrite,
    input  logic   [RAM_ADDR_W-1:0] ahbs_haddr,
    input  logic   [SYS_DATA_W-1:0] ahbs_hwdata,
    output wire                     ahbs_hreadyout,
    output wire                     ahbs_hresp,
    output wire    [SYS_DATA_W-1:0] ahbs_hrdata,

    // --------------------------------------------------------------------------
    // AHB Master Interface (from TideLink Returner)
    // --------------------------------------------------------------------------
    output wire    [SYS_ADDR_W-1:0] ahbm_haddr,
    output wire    [SYS_DATA_W-1:0] ahbm_hwdata,
    output wire               [1:0] ahbm_htrans,
    output wire               [2:0] ahbm_hsize,
    output wire                     ahbm_hwrite,
    input  logic                    ahbm_hready,
    input  logic                    ahbm_hresp,
    input  logic   [SYS_DATA_W-1:0] ahbm_hrdata,

    // --------------------------------------------------------------------------
    // APB Slave Interface (Configuration and Status Registers)
    // --------------------------------------------------------------------------
    input  logic                    apbs_psel,
    input  logic                    apbs_penable,
    input  logic                    apbs_pwrite,
    input  logic   [APB_ADDR_W-1:0] apbs_paddr,
    input  logic   [SYS_DATA_W-1:0] apbs_pwdata,
    output wire    [SYS_DATA_W-1:0] apbs_prdata,
    output wire                     apbs_pready,
    output wire                     apbs_pslverr,

    // --------------------------------------------------------------------------
    // Interrupt Outputs
    // --------------------------------------------------------------------------
    output wire                     released_credits_irq,  // Pair freed credits (channel 0 deltas)
    output wire                     doorbell_irq,         // Pair responded to doorbell (channel 1 totals)
    output wire                     packet_committed_irq, // Packet committed to FIFO (cleared on read addr 0)

    // --------------------------------------------------------------------------
    // PTP Register Pass-Through (to/from tidelink_ptp via tidelink_top)
    // --------------------------------------------------------------------------
    output wire                     ptp_reg_write,
    output wire               [2:0] ptp_reg_addr,
    output wire  [SYS_DATA_W-1:0]  ptp_reg_wdata,
    input  logic [SYS_DATA_W-1:0]  ptp_reg_rdata,
    output wire                     ptp_reg_region,  // 0=Region 1 (basic PTP), 1=Region 2 (HW sync)

    // --------------------------------------------------------------------------
    // Servo Register Pass-Through (to/from tidelink_ptp_servo via tidelink_top)
    // --------------------------------------------------------------------------
    output wire                     servo_reg_write,
    output wire               [2:0] servo_reg_addr,
    output wire    [SYS_DATA_W-1:0] servo_reg_wdata,
    input  logic   [SYS_DATA_W-1:0] servo_reg_rdata,

    // --------------------------------------------------------------------------
    // Timestamp Mailbox Pass-Through (FC SIDEBAND → servo, write-only)
    // --------------------------------------------------------------------------
    output wire                     mbox_reg_write,
    output wire               [2:0] mbox_reg_addr,
    output wire    [SYS_DATA_W-1:0] mbox_reg_wdata,

    // --------------------------------------------------------------------------
    // Chiplet Controller Register Pass-Through (Region 4)
    // --------------------------------------------------------------------------
    output wire                     ctrl_reg_write,
    output wire               [2:0] ctrl_reg_addr,
    output wire    [SYS_DATA_W-1:0] ctrl_reg_wdata,
    input  logic   [SYS_DATA_W-1:0] ctrl_reg_rdata,

    // --------------------------------------------------------------------------
    // Performance Profiling Register Pass-Through (Regions 5-7)
    // --------------------------------------------------------------------------
    output wire                     perf_reg_write,
    output wire               [2:0] perf_reg_addr,
    output wire    [SYS_DATA_W-1:0] perf_reg_wdata,
    input  logic   [SYS_DATA_W-1:0] perf_reg_rdata,
    output wire               [1:0] perf_reg_region,

    // --------------------------------------------------------------------------
    // Credit Count Observation (for performance profiling)
    // --------------------------------------------------------------------------
    output wire  [RAM_ADDR_W-2:0]   perf_credit_count,

    // --------------------------------------------------------------------------
    // FC Direct Write Interface (single-cycle, bypasses AHB for FIFO writes)
    // --------------------------------------------------------------------------
    input  wire                    fc_wr_valid,
    input  wire                    fc_wr_write,
    input  wire  [RAM_ADDR_W-1:0] fc_wr_addr,
    input  wire  [SYS_DATA_W-1:0] fc_wr_wdata,
    output wire                    fc_wr_ready
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------

    // FIFO sideband signals
    logic                  read_complete;
    logic [RAM_ADDR_W-2:0] current_credit_count;
    logic [RAM_ADDR_W-1:0] packet_word_length;

    // Expose credit count for performance profiling
    assign perf_credit_count = current_credit_count;

    // FIFO error flags
    logic                   fifo_overrun;
    logic                   fifo_underrun;

    // Control signals (from APB regs to FIFO and returner)
    logic                   ctrl_flush;

    // Returner status
    logic                   returner_busy;
    logic                   master_error;

    // APB register outputs → returner
    logic                    doorbell_trigger;
    logic                    reset_deassert_pulse;
    logic [SYS_DATA_W-1:0]  credit_delta_data;
    logic [SYS_DATA_W-1:0]  credit_count_data;
    logic [SYS_ADDR_W-1:0]  pair_base_addr;
    logic                    release_credits_trigger;

    // Delay trigger by 1 cycle so credit_delta_data is stable when the
    // returner captures it (both are registered on release_credits_trigger).
    logic                    release_credits_trigger_d;
    always_ff @(posedge hclk or negedge hresetn) begin
        if (!hresetn) release_credits_trigger_d <= 1'b0;
        else          release_credits_trigger_d <= release_credits_trigger;
    end

    // Paired tidelink's target addresses (derived from RW pair_base_addr register)
    wire [SYS_ADDR_W-1:0] PAIR_RELEASED_CREDITS_ADDR    = pair_base_addr + SYS_ADDR_W'(32'h0000_0020);
    wire [SYS_ADDR_W-1:0] PAIR_DOORBELL_RESPONSE_ADDR  = pair_base_addr + SYS_ADDR_W'(32'h0000_0024);
    wire [SYS_ADDR_W-1:0] PAIR_DOORBELL_ADDR           = pair_base_addr + SYS_ADDR_W'(32'h0000_0014);

    // --------------------------------------------------------------------------
    // TideLink FIFO Memory Instance
    // --------------------------------------------------------------------------
    tidelink_fifo_mem #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W)
    ) u_fifo_mem (
        .hclk                   (hclk),
        .hresetn                (hresetn),
        .hsel                   (ahbs_hsel),
        .hready                 (ahbs_hready),
        .htrans                 (ahbs_htrans),
        .hsize                  (ahbs_hsize),
        .hwrite                 (ahbs_hwrite),
        .haddr                  (ahbs_haddr),
        .hwdata                 (ahbs_hwdata),
        .hreadyout              (ahbs_hreadyout),
        .hresp                  (ahbs_hresp),
        .hrdata                 (ahbs_hrdata),
        .read_complete          (read_complete),
        .current_credit_count    (current_credit_count),
        .packet_word_length_out (packet_word_length),
        .packet_committed_irq   (packet_committed_irq),
        .overrun                (fifo_overrun),
        .underrun               (fifo_underrun),
        .flush                  (ctrl_flush),
        // FC direct write interface
        .fc_wr_valid            (fc_wr_valid),
        .fc_wr_write            (fc_wr_write),
        .fc_wr_addr             (fc_wr_addr),
        .fc_wr_wdata            (fc_wr_wdata),
        .fc_wr_ready            (fc_wr_ready)
    );

    // --------------------------------------------------------------------------
    // APB Register Interface Instance
    // --------------------------------------------------------------------------
    tidelink_apb_regs #(
        .SYS_ADDR_W       (SYS_ADDR_W),
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .APB_ADDR_W       (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_apb_regs (
        .hclk                (hclk),
        .hresetn             (hresetn),
        // APB slave
        .psel                (apbs_psel),
        .penable             (apbs_penable),
        .pwrite              (apbs_pwrite),
        .paddr               (apbs_paddr),
        .pwdata              (apbs_pwdata),
        .prdata              (apbs_prdata),
        .pready              (apbs_pready),
        .pslverr             (apbs_pslverr),
        // FIFO sideband
        .packet_word_length  (packet_word_length),
        .current_credit_count (current_credit_count),
        .read_complete       (read_complete),
        // Returner status
        .returner_busy       (returner_busy),
        // Error flags
        .fifo_overrun        (fifo_overrun),
        .fifo_underrun       (fifo_underrun),
        .master_error        (master_error),
        // Packet committed (for STATUS[4] polling)
        .packet_committed    (packet_committed_irq),
        // Control outputs (to FIFO and returner)
        .ctrl_flush          (ctrl_flush),
        // Returner control
        .doorbell_trigger    (doorbell_trigger),
        .reset_deassert_pulse(reset_deassert_pulse),
        .credit_delta_data    (credit_delta_data),
        .credit_count_data    (credit_count_data),
        .release_credits_trigger(release_credits_trigger),
        // Pair base address
        .pair_base_addr      (pair_base_addr),
        // IRQs
        .released_credits_irq (released_credits_irq),
        .doorbell_irq        (doorbell_irq),
        // PTP register pass-through
        .ptp_reg_write       (ptp_reg_write),
        .ptp_reg_addr        (ptp_reg_addr),
        .ptp_reg_wdata       (ptp_reg_wdata),
        .ptp_reg_rdata       (ptp_reg_rdata),
        .ptp_reg_region      (ptp_reg_region),
        // Servo register pass-through
        .servo_reg_write     (servo_reg_write),
        .servo_reg_addr      (servo_reg_addr),
        .servo_reg_wdata     (servo_reg_wdata),
        .servo_reg_rdata     (servo_reg_rdata),
        // Timestamp mailbox pass-through
        .mbox_reg_write      (mbox_reg_write),
        .mbox_reg_addr       (mbox_reg_addr),
        .mbox_reg_wdata      (mbox_reg_wdata),
        // Chiplet controller register pass-through
        .ctrl_reg_write      (ctrl_reg_write),
        .ctrl_reg_addr       (ctrl_reg_addr),
        .ctrl_reg_wdata      (ctrl_reg_wdata),
        .ctrl_reg_rdata      (ctrl_reg_rdata),
        // Performance profiling register pass-through
        .perf_reg_write      (perf_reg_write),
        .perf_reg_addr       (perf_reg_addr),
        .perf_reg_wdata      (perf_reg_wdata),
        .perf_reg_rdata      (perf_reg_rdata),
        .perf_reg_region     (perf_reg_region)
    );

    // --------------------------------------------------------------------------
    // TideLink Returner Instance
    // --------------------------------------------------------------------------
    // Channel 0 (highest priority): release credits on read completion
    //   → writes DELTA to pair's released credits accumulator (0x020)
    // Channel 1: doorbell — triggered by software OR by pair's reset
    //   → writes TOTAL free credits to pair's doorbell response accumulator (0x024)
    // Channel 2 (lowest priority): reset doorbell — fires on reset deassertion
    //   → rings pair's doorbell register (0x014)
    tidelink_returner #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_returner (
        .hclk        (hclk),
        .hresetn     (hresetn),

        // Channel 0: release credits (delayed 1 cycle so credit_delta_data is stable)
        .interrupt_0 (release_credits_trigger_d),
        .write_addr_0(PAIR_RELEASED_CREDITS_ADDR),
        .write_data_0(credit_delta_data),

        // Channel 1: doorbell response
        .interrupt_1 (doorbell_trigger),
        .write_addr_1(PAIR_DOORBELL_RESPONSE_ADDR),
        .write_data_1(credit_count_data),

        // Channel 2: reset doorbell
        .interrupt_2 (reset_deassert_pulse),
        .write_addr_2(PAIR_DOORBELL_ADDR),
        .write_data_2(32'h0000_0001),

        // AHB Master
        .haddr       (ahbm_haddr),
        .hwdata      (ahbm_hwdata),
        .htrans      (ahbm_htrans),
        .hsize       (ahbm_hsize),
        .hwrite      (ahbm_hwrite),
        .hready      (ahbm_hready),
        .hresp       (ahbm_hresp),
        .hrdata      (ahbm_hrdata),
        .busy        (returner_busy),
        .master_error(master_error),
        .flush       (ctrl_flush)
    );

endmodule
