//-----------------------------------------------------------------------------
// SoCLabs TideLink Top-Level Module
// - Wraps a TideLink FIFO (AHB slave), a TideLink Returner
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

module tidelink #(
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
    // AHB Slave Interface (to TideLink FIFO)
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
    output wire                     released_tokens_irq,  // Pair freed tokens (channel 0 deltas)
    output wire                     doorbell_irq,         // Pair responded to doorbell (channel 1 totals)
    output wire                     packet_committed_irq  // Packet committed to FIFO (cleared on read addr 0)
);

    // --------------------------------------------------------------------------
    // Internal Wiring
    // --------------------------------------------------------------------------

    // FIFO sideband signals
    logic                  read_complete;
    logic [RAM_ADDR_W-2:0] current_token_count;
    logic [RAM_ADDR_W-1:0] packet_word_length;

    // FIFO error flags
    logic                   fifo_overrun;
    logic                   fifo_underrun;

    // Control signals (from APB regs to FIFO and returner)
    logic                   ctrl_enable;
    logic                   ctrl_flush;

    // Returner status
    logic                   returner_busy;
    logic                   master_error;

    // APB register outputs → returner
    logic                    doorbell_trigger;
    logic                    reset_deassert_pulse;
    logic [SYS_DATA_W-1:0]  token_delta_data;
    logic [SYS_DATA_W-1:0]  token_count_data;
    logic [SYS_ADDR_W-1:0]  pair_base_addr;
    logic                    release_tokens_trigger;

    // Paired tidelink's target addresses (derived from RW pair_base_addr register)
    wire [SYS_ADDR_W-1:0] PAIR_RELEASED_TOKENS_ADDR    = pair_base_addr + SYS_ADDR_W'(32'h0000_0020);
    wire [SYS_ADDR_W-1:0] PAIR_DOORBELL_RESPONSE_ADDR  = pair_base_addr + SYS_ADDR_W'(32'h0000_0024);
    wire [SYS_ADDR_W-1:0] PAIR_DOORBELL_ADDR           = pair_base_addr + SYS_ADDR_W'(32'h0000_0014);

    // --------------------------------------------------------------------------
    // TideLink FIFO Instance
    // --------------------------------------------------------------------------
    tidelink_fifo #(
        .SYS_DATA_W (SYS_DATA_W),
        .RAM_ADDR_W (RAM_ADDR_W),
        .RAM_DATA_W (RAM_DATA_W)
    ) u_fifo (
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
        .current_token_count    (current_token_count),
        .packet_word_length_out (packet_word_length),
        .packet_committed_irq   (packet_committed_irq),
        .overrun                (fifo_overrun),
        .underrun               (fifo_underrun),
        .enable                 (ctrl_enable),
        .flush                  (ctrl_flush)
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
        .current_token_count (current_token_count),
        .read_complete       (read_complete),
        // Returner status
        .returner_busy       (returner_busy),
        // Error flags
        .fifo_overrun        (fifo_overrun),
        .fifo_underrun       (fifo_underrun),
        .master_error        (master_error),
        // Control outputs (to FIFO and returner)
        .ctrl_enable         (ctrl_enable),
        .ctrl_flush          (ctrl_flush),
        // Returner control
        .doorbell_trigger    (doorbell_trigger),
        .reset_deassert_pulse(reset_deassert_pulse),
        .token_delta_data    (token_delta_data),
        .token_count_data    (token_count_data),
        .release_tokens_trigger(release_tokens_trigger),
        // Pair base address
        .pair_base_addr      (pair_base_addr),
        // IRQs
        .released_tokens_irq (released_tokens_irq),
        .doorbell_irq        (doorbell_irq)
    );

    // --------------------------------------------------------------------------
    // TideLink Returner Instance
    // --------------------------------------------------------------------------
    // Channel 0 (highest priority): release tokens on read completion
    //   → writes DELTA to pair's released tokens accumulator (0x020)
    // Channel 1: doorbell — triggered by software OR by pair's reset
    //   → writes TOTAL free tokens to pair's doorbell response accumulator (0x024)
    // Channel 2 (lowest priority): reset doorbell — fires on reset deassertion
    //   → rings pair's doorbell register (0x014)
    tidelink_returner #(
        .SYS_ADDR_W (SYS_ADDR_W),
        .SYS_DATA_W (SYS_DATA_W)
    ) u_returner (
        .hclk        (hclk),
        .hresetn     (hresetn),

        // Channel 0: release tokens (gated by threshold accumulator)
        .interrupt_0 (release_tokens_trigger),
        .write_addr_0(PAIR_RELEASED_TOKENS_ADDR),
        .write_data_0(token_delta_data),

        // Channel 1: doorbell response
        .interrupt_1 (doorbell_trigger),
        .write_addr_1(PAIR_DOORBELL_RESPONSE_ADDR),
        .write_data_1(token_count_data),

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
