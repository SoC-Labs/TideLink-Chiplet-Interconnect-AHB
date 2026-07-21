// =============================================================================
// eth_ptp_phc_subsystem/tb_top.sv
//
// FIRST-EVER functional (driven) simulation of `ethernet_ss_ahb_phc` — the
// PHC variant of the ethernet subsystem. This is the JOIN of the two proven
// halves of the grandmaster chain:
//
//   * CAPTURE half  (cocotb/eth_ptp_chain): a REAL MII PTP frame is timestamped
//     by HA1588 (this bench reproduces the MII external loopback so the same
//     real capture path runs here too).
//   * SERVO half    (ptp-hardware-clock-ahb/cocotb/phc_ha1588_servo_loop): the
//     ha1588_servo disciplines the PHC onto the HA1588 RTC. There the RTC was a
//     TB STUB and the PHC was driven by a bare APB port. HERE the RTC is the
//     REAL running HA1588 RTC inside the subsystem, and the PHC is programmed
//     through the subsystem's OWN AHB matrix + AHB->APB bridge (eth_ss_0).
//
// No TideLink link, no CPU firmware (M0+ parked on a spin image). The subsystem
// external AHB-Lite slave port `eth_ss_0` is driven directly by a cocotb AHB
// master. All servo/PHC witness nets are TOP-LEVEL wires of ethernet_ss_ahb_phc
// (phc_seconds, ha1588_hw_capture, ha1588_hw_set_time, ha1588_servo_locked, ...)
// so they are read non-intrusively via the `u_dut.<net>` hierarchy from the
// test — no probes forced into the DUT.
// =============================================================================
`timescale 1ns/1ps

`ifndef ETH_IMEM_HEX
  `define ETH_IMEM_HEX "image_spin.hex"
`endif

module tb_top;

    // ---- Clocks -------------------------------------------------------------
    // sys_fclk: free-running input; the CPU PRMU derives sys_hclk from it.
    logic sys_fclk = 1'b0;  always #10 sys_fclk = ~sys_fclk;   // 50 MHz
    // rtc_clk: HA1588 RTC reference (deliberately asynchronous to hclk).
    logic rtc_clk  = 1'b0;  always #16 rtc_clk  = ~rtc_clk;    // ~31.25 MHz
    // MII: source-synchronous loopback => ONE shared 25 MHz clock (a real
    // loopback is source-synchronous; two free oscillators would be a phaseless
    // CDC — the eth_ptp_chain bench established this).
    logic mtx_clk  = 1'b0;  always #20 mtx_clk  = ~mtx_clk;    // 25 MHz

    // ---- Reset --------------------------------------------------------------
    logic sys_sysresetn = 1'b0;   // released by the cocotb test

    // ---- DUT clock/reset outputs (PRMU-generated) ---------------------------
    wire sys_poresetn;
    wire sys_hclk;
    wire sys_hresetn;

    // =========================================================================
    // eth_ss_0 — external AHB-Lite slave port, driven by the cocotb AHB master.
    // =========================================================================
    logic [31:0] eth_ss_0_haddr    = 32'h0;
    logic [1:0]  eth_ss_0_htrans   = 2'b00;
    logic        eth_ss_0_hwrite   = 1'b0;
    logic [2:0]  eth_ss_0_hsize    = 3'b010;
    logic [2:0]  eth_ss_0_hburst   = 3'b000;
    logic [3:0]  eth_ss_0_hprot    = 4'h0;
    logic [31:0] eth_ss_0_hwdata   = 32'h0;
    logic        eth_ss_0_hmastlock = 1'b0;
    wire  [31:0] eth_ss_0_hrdata;
    wire         eth_ss_0_hready;
    wire         eth_ss_0_hresp;

    // =========================================================================
    // MII external loopback (mtxd/mtxen -> mrxd/mrxdv), full-duplex.
    // =========================================================================
    wire [3:0] mtxd;
    wire       mtxen;
    wire       mtxerr;
    wire [3:0] mrxd  = mtxd;      // loop TX nibble back into RX
    wire       mrxdv = mtxen;
    wire       mrxerr = 1'b0;
    wire       mcrs  = mtxen;     // carrier tracks the loop
    wire       mcoll = 1'b0;      // full-duplex, no collisions
    wire       mrx_clk = mtx_clk; // source-synchronous

    // ---- RTC time observation (top-level outputs) ---------------------------
    wire [31:0] rtc_time_ptp_ns;
    wire [47:0] rtc_time_ptp_sec;
    wire        rtc_time_one_pps;

    // =========================================================================
    // MII wire recorder (verify the INSTRUMENT before the DUT): capture the
    // bytes physically on the MII TX wire so a depth=0 can be told apart from a
    // wrong-byte-order frame. Mirrors eth_ptp_chain's recorder.
    // =========================================================================
    logic [7:0] mii_cap_mem [0:255];
    int         mii_cap_len = 0;
    logic [3:0] mii_cap_lo  = 4'h0;
    logic       mii_cap_hi  = 1'b0;
    logic       mtxen_q     = 1'b0;
    int         mii_frames  = 0;

    always @(posedge mtx_clk) begin
        mtxen_q <= mtxen;
        if (mtxen && !mtxen_q) begin
            mii_cap_len <= 0;
            mii_cap_hi  <= 1'b0;
            mii_frames  <= mii_frames + 1;
        end
        if (mtxen) begin
            if (!mii_cap_hi) begin
                mii_cap_lo <= mtxd;
                mii_cap_hi <= 1'b1;
            end else begin
                if (mii_cap_len < 256)
                    mii_cap_mem[mii_cap_len] <= {mtxd, mii_cap_lo};
                mii_cap_len <= mii_cap_len + 1;
                mii_cap_hi  <= 1'b0;
            end
        end
    end

    // =========================================================================
    // DUT
    // =========================================================================
    ethernet_ss_ahb_phc #(
        .IMEM_MEM_FPGA_IMG (`ETH_IMEM_HEX)
    ) u_dut (
        .sys_fclk        (sys_fclk),
        .sys_sysresetn   (sys_sysresetn),
        .sys_scanenable  (1'b0),
        .sys_testmode    (1'b0),
        .sys_sysresetreq (1'b0),
        .sys_poresetn    (sys_poresetn),
        .sys_hclk        (sys_hclk),
        .sys_hresetn     (sys_hresetn),
        .cpu_0_pmuenable (1'b0),
        // CPU system-passthrough master — unused; keep the bus quiescent.
        .cpu_0_haddr     (),
        .cpu_0_htrans    (),
        .cpu_0_hwrite    (),
        .cpu_0_hsize     (),
        .cpu_0_hburst    (),
        .cpu_0_hprot     (),
        .cpu_0_hwdata    (),
        .cpu_0_hmastlock (),
        .cpu_0_hrdata    (32'h0),
        .cpu_0_hready    (1'b1),
        .cpu_0_hresp     (1'b0),
        // eth_ss_0 <- cocotb AHB master (THE DRIVE POINT)
        .eth_ss_0_haddr     (eth_ss_0_haddr),
        .eth_ss_0_htrans    (eth_ss_0_htrans),
        .eth_ss_0_hwrite    (eth_ss_0_hwrite),
        .eth_ss_0_hsize     (eth_ss_0_hsize),
        .eth_ss_0_hburst    (eth_ss_0_hburst),
        .eth_ss_0_hprot     (eth_ss_0_hprot),
        .eth_ss_0_hwdata    (eth_ss_0_hwdata),
        .eth_ss_0_hmastlock (eth_ss_0_hmastlock),
        .eth_ss_0_hrdata    (eth_ss_0_hrdata),
        .eth_ss_0_hready    (eth_ss_0_hready),
        .eth_ss_0_hresp     (eth_ss_0_hresp),
        // eth_ss_1 idle
        .eth_ss_1_haddr     (32'h0),
        .eth_ss_1_htrans    (2'b00),
        .eth_ss_1_hwrite    (1'b0),
        .eth_ss_1_hsize     (3'b010),
        .eth_ss_1_hburst    (3'b000),
        .eth_ss_1_hprot     (4'h0),
        .eth_ss_1_hwdata    (32'h0),
        .eth_ss_1_hmastlock (1'b0),
        .eth_ss_1_hrdata    (),
        .eth_ss_1_hready    (),
        .eth_ss_1_hresp     (),
        // CPU sideband
        .cpu_0_nmi       (1'b0),
        .cpu_0_irq       (32'h0),
        .cpu_0_txev      (),
        .cpu_0_rxev      (1'b0),
        .cpu_0_lockup    (),
        .cpu_0_sysresetreq(),
        .cpu_0_sleeping  (),
        .cpu_0_sleepdeep (),
        // SWD idle
        .cpu_0_swdi      (1'b0),
        .cpu_0_swclk     (1'b0),
        .cpu_0_swdo      (),
        .cpu_0_swdoen    (),
        // RTC / PTP
        .rtc_clk         (rtc_clk),
        .rtc_time_ptp_ns (rtc_time_ptp_ns),
        .rtc_time_ptp_sec(rtc_time_ptp_sec),
        .rtc_time_one_pps(rtc_time_one_pps),
        // MII loopback
        .mtx_clk_i       (mtx_clk),
        .mtxd_o          (mtxd),
        .mtxen_o         (mtxen),
        .mtxerr_o        (mtxerr),
        .mrx_clk_i       (mrx_clk),
        .mrxd_i          (mrxd),
        .mrxdv_i         (mrxdv),
        .mrxerr_i        (mrxerr),
        .mcoll_i         (mcoll),
        .mcrs_i          (mcrs),
        // MDIO idle
        .md_pad_i        (1'b1),
        .mdc_pad_o       (),
        .md_pad_o        (),
        .md_padoe_o      (),
        // UART idle
        .uart_rxd        (1'b1),
        .uart_txd        (),
        .eth_irq         (),
        // PHC sideband
        .phc_pps_out     (),
        .phc_pps_irq     (),
        .phc_alarm_irq   ()
    );

`ifndef TB_TOP_NO_DUMP
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_top);
    end
`endif

endmodule
