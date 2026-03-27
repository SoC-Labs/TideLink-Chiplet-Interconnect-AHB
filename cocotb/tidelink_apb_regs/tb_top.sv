// Cocotb wrapper for tidelink_apb_regs standalone testing
module tb_top #(
    parameter SYS_ADDR_W = 32,
    parameter SYS_DATA_W = 32,
    parameter RAM_ADDR_W = 14,
    parameter APB_ADDR_W = 12,
    parameter [SYS_ADDR_W-1:0] TIDELINK_PAIR_BASE = 32'h4000_1000
)(
    input  logic                    hclk,
    input  logic                    hresetn,

    // APB interface
    input  logic                    psel,
    input  logic                    penable,
    input  logic                    pwrite,
    input  logic   [APB_ADDR_W-1:0] paddr,
    input  logic   [SYS_DATA_W-1:0] pwdata,
    output logic   [SYS_DATA_W-1:0] prdata,
    output logic                    pready,
    output logic                    pslverr,

    // FIFO sideband stimulus
    input  logic [RAM_ADDR_W-1:0]   packet_word_length,
    input  logic [RAM_ADDR_W-2:0]   current_token_count,
    input  logic                    read_complete,

    // Returner status stimulus
    input  logic                    returner_busy,

    // Outputs
    output logic                    doorbell_trigger,
    output logic                    reset_deassert_pulse,
    output logic [SYS_DATA_W-1:0]   token_delta_data,
    output logic [SYS_DATA_W-1:0]   token_count_data,
    output logic                    release_tokens_trigger,
    output logic [SYS_ADDR_W-1:0]   pair_base_addr,
    output logic                    released_tokens_irq,
    output logic                    doorbell_irq
);

    tidelink_apb_regs #(
        .SYS_ADDR_W       (SYS_ADDR_W),
        .SYS_DATA_W       (SYS_DATA_W),
        .RAM_ADDR_W       (RAM_ADDR_W),
        .APB_ADDR_W       (APB_ADDR_W),
        .TIDELINK_PAIR_BASE(TIDELINK_PAIR_BASE)
    ) u_dut (
        .hclk                (hclk),
        .hresetn             (hresetn),
        .psel                (psel),
        .penable             (penable),
        .pwrite              (pwrite),
        .paddr               (paddr),
        .pwdata              (pwdata),
        .prdata              (prdata),
        .pready              (pready),
        .pslverr             (pslverr),
        .packet_word_length  (packet_word_length),
        .current_token_count (current_token_count),
        .read_complete       (read_complete),
        .returner_busy       (returner_busy),
        .doorbell_trigger    (doorbell_trigger),
        .reset_deassert_pulse(reset_deassert_pulse),
        .token_delta_data    (token_delta_data),
        .token_count_data    (token_count_data),
        .release_tokens_trigger(release_tokens_trigger),
        .pair_base_addr      (pair_base_addr),
        .released_tokens_irq (released_tokens_irq),
        .doorbell_irq        (doorbell_irq)
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
