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
    input  logic [RAM_ADDR_W-2:0]   current_credit_count,
    input  logic                    read_complete,

    // Returner status stimulus
    input  logic                    returner_busy,

    // Error flag stimulus
    input  logic                    fifo_overrun,
    input  logic                    fifo_underrun,
    input  logic                    master_error,

    // Packet committed flag stimulus
    input  logic                    packet_committed,

    // Outputs
    output logic                    ctrl_flush,
    output logic                    doorbell_trigger,
    output logic                    reset_deassert_pulse,
    output logic [SYS_DATA_W-1:0]   credit_delta_data,
    output logic [SYS_DATA_W-1:0]   credit_count_data,
    output logic                    release_credits_trigger,
    output logic [SYS_ADDR_W-1:0]   pair_base_addr,
    output logic                    released_credits_irq,
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
        .current_credit_count (current_credit_count),
        .read_complete       (read_complete),
        .returner_busy       (returner_busy),
        .fifo_overrun        (fifo_overrun),
        .fifo_underrun       (fifo_underrun),
        .master_error        (master_error),
        .packet_committed    (packet_committed),
        .ctrl_flush          (ctrl_flush),
        .doorbell_trigger    (doorbell_trigger),
        .reset_deassert_pulse(reset_deassert_pulse),
        .credit_delta_data    (credit_delta_data),
        .credit_count_data    (credit_count_data),
        .release_credits_trigger(release_credits_trigger),
        .pair_base_addr      (pair_base_addr),
        .released_credits_irq (released_credits_irq),
        .doorbell_irq        (doorbell_irq),
        // PTP register pass-through (tied off — no tidelink_ptp in this testbench)
        .ptp_reg_rdata       ({SYS_DATA_W{1'b0}})
    );

    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
