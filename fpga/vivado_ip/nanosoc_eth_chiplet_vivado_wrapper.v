//-----------------------------------------------------------------------------
// nanosoc_eth_chiplet - Vivado IP Integrator Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// IPI wrapper for the WHOLE eth-chiplet (nanosoc_eth_chiplet), for the KR260
// two-board ethernet demo. Unlike tidelink_vivado_wrapper (which packages the
// bare link), TideLink is INTERNAL here — the on-chip Cortex-M0 cores reach it
// via the 0x2E00_0000 D2D window. The FPGA boundary the PS/board sees is:
//
//   - eth_ss_0     : AHB-Lite SLAVE — the SoC's ethernet-subsystem matrix
//                    initiator port, used here as the PS BACKDOOR into the SoC
//                    AHB (firmware load + register poke via an AXI->AHB bridge).
//   - pad_clk_tx/rx, pad_tx/rx[7:0] : GPIO-PHY pads -> the KR260 J21 ribbon.
//   - swclk / swdio(_i/_o/_oe)       : CoreSight SWD -> PMOD4 (board IOBUF).
//   - eth_irq / phc_*_irq / tidechart_irq : interrupts -> PS pl_ps_irq.
//   - role_strap_i                   : die_a=0 / die_b=1 (board constant).
//
// M1 (no-PHY) posture: RMII is tied to a benign idle and the MAC runs in
// internal loopback (HA1588 still timestamps); MDIO/UART/QSPI/SPI/hostio and
// all scan/DFT/PUF/nego pins are tied off INSIDE this wrapper so the OOC synth
// and the BD see a clean boundary. M2 re-exposes RMII on a PMOD adapter.
//
// KNOWN GAP (finding G1): DEVICE_CLASS is not a nanosoc_eth_chiplet parameter
// (it lives in the internal tidechart_shim). Per-die DEVICE_CLASS strapping to
// close the dual-root election therefore needs a one-line RTL change in the
// parent repo to surface it. Until then, pin die_a grandmaster by strap and do
// NOT rely on auto-election. role_strap_i is the wired-out per-die strap.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_eth_chiplet_vivado_wrapper #(
    parameter NUM_PHY_LANES = 8
)(
    // =========================================================================
    // Clocks and Resets
    //   sys_fclk feeds the SoC's clock root; the SoC derives its own hclk
    //   (sys_hclk is an OUTPUT observation of that). For the FPGA build the BD
    //   drives sys_fclk from a clk_wiz output; eth_ss_0 is synchronous to the
    //   SoC's internal hclk. ASSOCIATED_BUSIF is declared for IPI hygiene.
    // =========================================================================
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.SYS_FCLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.SYS_FCLK, ASSOCIATED_RESET sys_sysresetn, ASSOCIATED_BUSIF eth_ss_0, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        sys_fclk,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.SYS_SYSRESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.SYS_SYSRESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        sys_sysresetn,

    // Wlink PLL reference + 200 MHz IDELAYCTRL reference (discrete clocks).
    // On KR260 USE_IDELAY=0 (HDIO bank 44), but the port stays for portability.
    input  wire        user_ref_clk,
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.IDELAY_REF_CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.IDELAY_REF_CLK, FREQ_HZ 200000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        idelay_ref_clk,

    // Observation outputs of the SoC's internal clock/reset tree
    output wire        sys_hclk,
    output wire        sys_hresetn,
    output wire        sys_poresetn,

    // =========================================================================
    // eth_ss_0 — AHB-Lite SLAVE (PS backdoor into the SoC AHB matrix)
    // The SoC is the slave; the external master (AXI->AHB bridge) drives it.
    // There is no external HSEL (matrix initiator port is always active).
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HADDR"     *) input  wire [31:0] eth_ss_0_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HTRANS"    *) input  wire  [1:0] eth_ss_0_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HWRITE"    *) input  wire        eth_ss_0_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HSIZE"     *) input  wire  [2:0] eth_ss_0_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HBURST"    *) input  wire  [2:0] eth_ss_0_hburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HPROT"     *) input  wire  [3:0] eth_ss_0_hprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HWDATA"    *) input  wire [31:0] eth_ss_0_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HMASTLOCK" *) input  wire        eth_ss_0_hmastlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HRDATA"    *) output wire [31:0] eth_ss_0_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HREADY"    *) output wire        eth_ss_0_hready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 eth_ss_0 HRESP"     *) output wire        eth_ss_0_hresp,

    // =========================================================================
    // GPIO-PHY pads — discrete I/O to the KR260 J21 ribbon (see XDC)
    // =========================================================================
    output wire                     pad_clk_tx,
    output wire [NUM_PHY_LANES-1:0] pad_tx,
    input  wire                     pad_clk_rx,
    input  wire [NUM_PHY_LANES-1:0] pad_rx,

    // =========================================================================
    // CoreSight SWD — discrete; board wrapper folds swdio(_i/_o/_oe) into an
    // IOBUF on PMOD4. swj_enable is tied 1 internally (SWD is the debug path).
    // =========================================================================
    input  wire        swclk,       // -> dap_swclktck  (PMOD4 pin1 / L2)
    input  wire        swdio_i,     // IOBUF O          (PMOD4 pin2 / T7)
    output wire        swdio_o,     // IOBUF I  (dap_swdo)
    output wire        swdio_oe,    // IOBUF T=~oe (dap_swdoen)
    input  wire        swd_nporesetn, // -> dap_npotrst (optional; PMOD4 pin3 / AF7)

    // =========================================================================
    // Per-die role strap (die_a=0, die_b=1) — board constant / AXI-GPIO bit
    // =========================================================================
    input  wire        role_strap_i,

    // =========================================================================
    // Interrupts -> PS pl_ps_irq (aggregate with a Concat in the BD)
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_eth INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_eth, SENSITIVITY LEVEL_HIGH" *)
    output wire        eth_irq,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_phc_pps INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_phc_pps, SENSITIVITY LEVEL_HIGH" *)
    output wire        phc_pps_irq,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_phc_alarm INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_phc_alarm, SENSITIVITY LEVEL_HIGH" *)
    output wire        phc_alarm_irq,
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_tidechart INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_tidechart, SENSITIVITY LEVEL_HIGH" *)
    output wire        tidechart_irq,

    // =========================================================================
    // Status sideband — discrete observation outputs
    // =========================================================================
    output wire        link_active,
    output wire        role_is_master,
    output wire        role_locked,
    output wire        servo_locked,
    output wire        ha1588_servo_locked,
    output wire [12:0] tl_ewma_credit,

    // =========================================================================
    // UART (bring the primary console out; chip_core UART tied off for M1)
    // =========================================================================
    input  wire        uart_rxd,
    output wire        uart_txd
);

    // -------------------------------------------------------------------------
    // M1 tie-offs and benign-idle constants
    // -------------------------------------------------------------------------
    // RMII idle: ref_clk 0, rxd 0, crs_dv 0. MAC internal loopback is selected
    // by SW/register at bring-up; txd/tx_en are simply left dangling (outputs).
    wire        rmii_ref_clk_idle = 1'b0;
    wire  [1:0] rmii_rxd_idle     = 2'b00;
    wire        rmii_crs_dv_idle  = 1'b0;

    nanosoc_eth_chiplet #(
        .NUM_PHY_LANES (NUM_PHY_LANES)
    ) u_chiplet (
        // Clocks / resets
        .sys_fclk            (sys_fclk),
        .sys_sysresetn       (sys_sysresetn),
        .sys_poresetn        (sys_poresetn),
        .sys_hclk            (sys_hclk),
        .sys_hresetn         (sys_hresetn),
        .sys_scanenable      (1'b0),
        .sys_testmode        (1'b0),
        .sys_sysresetreq     (1'b0),

        // eth_ss_0 AHB slave (PS backdoor)
        .eth_ss_0_haddr      (eth_ss_0_haddr),
        .eth_ss_0_htrans     (eth_ss_0_htrans),
        .eth_ss_0_hwrite     (eth_ss_0_hwrite),
        .eth_ss_0_hsize      (eth_ss_0_hsize),
        .eth_ss_0_hburst     (eth_ss_0_hburst),
        .eth_ss_0_hprot      (eth_ss_0_hprot),
        .eth_ss_0_hwdata     (eth_ss_0_hwdata),
        .eth_ss_0_hmastlock  (eth_ss_0_hmastlock),
        .eth_ss_0_hrdata     (eth_ss_0_hrdata),
        .eth_ss_0_hready     (eth_ss_0_hready),
        .eth_ss_0_hresp      (eth_ss_0_hresp),

        // Core control sideband — tie inputs to benign, leave status open
        .network_core_pmuenable   (1'b1),
        .chip_core_pmuenable      (1'b1),
        .network_core_nmi         (1'b0),
        .network_core_txev        (),
        .network_core_rxev        (1'b0),
        .network_core_lockup      (),
        .network_core_sysresetreq (),
        .network_core_sleeping    (),
        .network_core_sleepdeep   (),
        .chip_core_nmi            (1'b0),
        .chip_core_txev           (),
        .chip_core_rxev           (1'b0),
        .chip_core_lockup         (),
        .chip_core_sysresetreq    (),
        .chip_core_sleeping       (),
        .chip_core_sleepdeep      (),

        // DAP / SWD — SWD path only; JTAG TAP tied off, swj_enable = 1
        .dap_swclktck        (swclk),
        .dap_swditms         (swdio_i),
        .dap_swdo            (swdio_o),
        .dap_swdoen          (swdio_oe),
        .dap_tdi             (1'b0),
        .dap_tdo             (),
        .dap_ntdoen          (),
        .dap_ntrst           (1'b1),
        .dap_npotrst         (swd_nporesetn),
        .dap_swj_enable      (1'b1),

        // RMII — M1 idle (loopback selected in SW); txd/tx_en dangling
        .rmii_ref_clk        (rmii_ref_clk_idle),
        .rmii_txd            (),
        .rmii_tx_en          (),
        .rmii_rxd            (rmii_rxd_idle),
        .rmii_crs_dv         (rmii_crs_dv_idle),

        // MDIO — tie off
        .md_pad_i            (1'b0),
        .mdc_pad_o           (),
        .md_pad_o            (),
        .md_padoe_o          (),

        // UART — primary console out; chip_core console tied off
        .uart_rxd            (uart_rxd),
        .uart_txd            (uart_txd),
        .chip_core_uart_rxd  (1'b1),
        .chip_core_uart_txd  (),
        .chip_core_wdog_reset(),

        // RTC / PTP time observation
        .rtc_clk             (sys_fclk),
        .rtc_time_ptp_ns     (),
        .rtc_time_ptp_sec    (),
        .rtc_time_one_pps    (),

        // IRQ / status
        .eth_irq             (eth_irq),
        .phc_pps_out         (),
        .phc_pps_irq         (phc_pps_irq),
        .phc_alarm_irq       (phc_alarm_irq),
        .ha1588_servo_locked (ha1588_servo_locked),

        // QSPI / SPI / hostio — tie off (unused on the M1 board)
        .qspi_sclk           (),
        .qspi_csn            (),
        .qspi_io_o           (),
        .qspi_io_i           (4'b0000),
        .qspi_io_e           (),
        .spi_sclk            (),
        .spi_mosi            (),
        .spi_miso            (1'b0),
        .spi_ss              (),
        .hostio4_p1_in       (7'b0000000),
        .hostio4_p1_out      (),
        .hostio4_p1_outen    (),

        // GPIO-PHY pads + reference clocks
        .pad_clk_tx          (pad_clk_tx),
        .pad_tx              (pad_tx),
        .pad_clk_rx          (pad_clk_rx),
        .pad_rx              (pad_rx),
        .user_ref_clk        (user_ref_clk),
        .idelay_ref_clk      (idelay_ref_clk),

        // I2C sideband — tie off
        .i2c_scl_i           (1'b1),
        .i2c_scl_o           (),
        .i2c_scl_t           (),
        .i2c_sda_i           (1'b1),
        .i2c_sda_o           (),
        .i2c_sda_t           (),

        // Role / negotiation / PUF
        .role_strap_i        (role_strap_i),
        .nego_priority_i     (16'h0000),
        .mask_hs_bypass_i    (1'b0),
        .apb_debug_unlock_i  (1'b0),
        .puf_seed            (16'h0000),
        .puf_ready           (1'b0),

        // Scan / DFT — tie off for FPGA
        .scan_mode           (1'b0),
        .scan_asyncrst_ctrl  (1'b0),
        .scan_clk            (1'b0),
        .scan_shift          (1'b0),
        .scan_in             (1'b0),
        .scan_out            (),

        // Link / role / telemetry status
        .link_active_o       (link_active),
        .d2d_reset_o         (),
        .role_is_master_o    (role_is_master),
        .role_locked_o       (role_locked),
        .servo_locked_o      (servo_locked),
        .tl_ewma_credit_o    (tl_ewma_credit),
        .tidechart_irq_o     (tidechart_irq)
    );

endmodule
