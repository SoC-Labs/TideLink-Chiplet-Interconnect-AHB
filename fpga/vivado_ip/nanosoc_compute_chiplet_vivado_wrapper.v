//-----------------------------------------------------------------------------
// nanosoc_compute_chiplet - Vivado IP Integrator Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// IPI wrapper for the WHOLE compute-chiplet (nanosoc_compute_chiplet), for the
// KR260 two-board compute demo. This is the two-link sibling of
// nanosoc_eth_chiplet_vivado_wrapper: TideLink is INTERNAL, the on-chip cores
// drive it, and there are TWO links. The FPGA boundary the PS/board sees is:
//
//   - ps_ahb_s     : AHB-Lite SLAVE — the compute SoC's PS host-backdoor target
//                    (G2). Becomes the SoC top-matrix initiator ps_m. Used here
//                    as the PS BACKDOOR into the SoC AHB (firmware load +
//                    register poke via an AXI->AHB bridge). Replaces the eth
//                    chiplet's eth_ss_0.
//   - pad_clk_tx_0/rx_0, pad_tx_0/rx_0[7:0] : LINK 0 GPIO-PHY pads -> KR260 J21.
//   - i2c_scl/sda_{i,o,t}_0 : LINK 0 I2C sideband (board IOBUF).
//   - LINK 1 pads/i2c/strap : EXPOSED but TIED OFF in the BD (G8) — there is no
//                    second ribbon on this single-board bring-up. pad_tx_1 /
//                    pad_clk_tx_1 outputs are left open in the BD (no board pin).
//   - swclk / swdio(_i/_o/_oe) / jtag_tdi / jtag_tdo(_o/_t) / jtag_ntrst :
//                    FULL CoreSight SWJ-DP -> PMOD2 (board IOBUFs). The compute
//                    chiplet is SWJ (SWD + JTAG TAP), unlike the eth chiplet
//                    which was SWD-only.
//   - tidechart_irq : the ONE interrupt at the chiplet boundary -> PS pl_ps_irq.
//   - role_strap_i_0 : die_a=0 / die_b=1 (board constant / AXI-GPIO bit).
//
// NO ETHERNET. The compute chiplet has no ethernet subsystem, so there are no
// RMII / MDIO ports (dropped vs the eth template).
//
// IRQ FINDING: the compute SoC routes ALL TideLink/D2D interrupt vectors to the
// on-chip dual-NVIC INTERNALLY (d2d{0,1}_irq[15:0] never leave the SoC). The only
// interrupt output at this chiplet boundary is tidechart_irq_o (observability).
// So the PS sees exactly ONE PL IRQ here. See SCOPING-TODO in tidelink_design.tcl.
//
// KNOWN GAP (finding G1): DEVICE_CLASS is a TideChart PARAMETER (defaults to
// 16'h0001, the value that wins the root election), not a chiplet port — per-die
// strapping to close the dual-root election needs an RTL change to surface it.
// Until then, pin die_a grandmaster by role_strap_i_0 and do NOT rely on
// auto-election.
//
// swj_enable / npotrst are tied active inside this wrapper, mirroring the ASIC
// chip-boundary ties (sys_desc/chip_boundary/nanosoc_compute_chiplet.yaml).
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module nanosoc_compute_chiplet_vivado_wrapper #(
    parameter NUM_PHY_LANES = 8
)(
    // =========================================================================
    // Clocks and Resets
    //   sys_fclk feeds the SoC's clock root; the SoC derives its own hclk
    //   (sys_hclk is an OUTPUT observation of that). For the FPGA build the BD
    //   drives sys_fclk from a clk_wiz output; ps_ahb_s is synchronous to the
    //   SoC's internal hclk. ASSOCIATED_BUSIF is declared for IPI hygiene.
    // =========================================================================
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.SYS_FCLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.SYS_FCLK, ASSOCIATED_RESET sys_sysresetn, ASSOCIATED_BUSIF ps_ahb_s, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        sys_fclk,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.SYS_SYSRESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.SYS_SYSRESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        sys_sysresetn,

    // Per-link Wlink PLL reference clocks. The compute chiplet has SEPARATE
    // user_ref_clk_0 / user_ref_clk_1 (the eth chiplet aliased a single one).
    input  wire        user_ref_clk_0,
    input  wire        user_ref_clk_1,

    // 200 MHz IDELAYCTRL reference (discrete). Fanned to BOTH links' idelay refs.
    // On KR260 USE_IDELAY=0 (HDIO bank 44), but the port stays for portability.
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.IDELAY_REF_CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.IDELAY_REF_CLK, FREQ_HZ 200000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        idelay_ref_clk,

    // Observation outputs of the SoC's internal clock/reset tree
    output wire        sys_hclk,
    output wire        sys_hresetn,
    output wire        sys_poresetn,

    // =========================================================================
    // ps_ahb_s — AHB-Lite SLAVE (PS backdoor into the SoC AHB matrix, G2)
    // The SoC is the slave; the external master (AXI->AHB bridge) drives it.
    // Plain AHB-Lite (hprot[3:0], hmastlock present). No external HSEL (the SoC's
    // top-matrix initiator port is always active).
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HADDR"     *) input  wire [31:0] ps_ahb_s_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HTRANS"    *) input  wire  [1:0] ps_ahb_s_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HWRITE"    *) input  wire        ps_ahb_s_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HSIZE"     *) input  wire  [2:0] ps_ahb_s_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HBURST"    *) input  wire  [2:0] ps_ahb_s_hburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HPROT"     *) input  wire  [3:0] ps_ahb_s_hprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HWDATA"    *) input  wire [31:0] ps_ahb_s_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HMASTLOCK" *) input  wire        ps_ahb_s_hmastlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HRDATA"    *) output wire [31:0] ps_ahb_s_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HREADY"    *) output wire        ps_ahb_s_hready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ps_ahb_s HRESP"     *) output wire        ps_ahb_s_hresp,

    // =========================================================================
    // LINK 0 — GPIO-PHY pads (KR260 J21 ribbon) + I2C sideband + strap + status
    // =========================================================================
    output wire                     pad_clk_tx_0,
    output wire [NUM_PHY_LANES-1:0] pad_tx_0,
    input  wire                     pad_clk_rx_0,
    input  wire [NUM_PHY_LANES-1:0] pad_rx_0,

    // I2C sideband (open-drain). _t is a Hi-Z enable (1 = float) => direct IOBUF.T.
    input  wire        i2c_scl_i_0,
    output wire        i2c_scl_o_0,
    output wire        i2c_scl_t_0,
    input  wire        i2c_sda_i_0,
    output wire        i2c_sda_o_0,
    output wire        i2c_sda_t_0,

    // Per-die role strap (die_a=0, die_b=1) — board constant / AXI-GPIO bit
    input  wire        role_strap_i_0,

    // Link 0 status / observability (link_active_0 -> led0, role_is_master_0 -> led1)
    output wire        link_active_0,
    output wire        role_is_master_0,
    output wire        role_locked_0,
    output wire        d2d_reset_0,

    // =========================================================================
    // LINK 1 — EXPOSED for the BD to TIE OFF (G8). No second ribbon on this board.
    // =========================================================================
    output wire                     pad_clk_tx_1,   // left open in the BD (no pin)
    output wire [NUM_PHY_LANES-1:0] pad_tx_1,       // left open in the BD (no pin)
    input  wire                     pad_clk_rx_1,   // BD drives const 0 (parked)
    input  wire [NUM_PHY_LANES-1:0] pad_rx_1,       // BD drives const 0
    input  wire        i2c_scl_i_1,                 // BD drives const 1 (idle high)
    output wire        i2c_scl_o_1,
    output wire        i2c_scl_t_1,
    input  wire        i2c_sda_i_1,                 // BD drives const 1 (idle high)
    output wire        i2c_sda_o_1,
    output wire        i2c_sda_t_1,
    input  wire        role_strap_i_1,              // BD drives const (fixed role)
    output wire        link_active_1,
    output wire        role_is_master_1,
    output wire        role_locked_1,
    output wire        d2d_reset_1,

    // =========================================================================
    // CoreSight SWJ-DP — discrete. Board wrapper folds swdio + jtag_tdo into
    // IOBUFs on PMOD2. swj_enable / npotrst are tied active INSIDE this wrapper.
    //   swdio_oe  : dap_swdoen, ACTIVE-HIGH oe (board IOBUF T = ~swdio_oe)
    //   jtag_tdo_t: dap_ntdoen, ACTIVE-LOW oe == active-high Hi-Z T (board IOBUF
    //               T = jtag_tdo_t directly; 1 = float)
    // =========================================================================
    input  wire        swclk,        // -> dap_swclktck
    input  wire        swdio_i,      // IOBUF O  -> dap_swditms
    output wire        swdio_o,      // IOBUF I  <- dap_swdo
    output wire        swdio_oe,     // IOBUF T=~oe <- dap_swdoen (active high)
    input  wire        jtag_tdi,     // -> dap_tdi
    output wire        jtag_tdo_o,   // IOBUF I  <- dap_tdo
    output wire        jtag_tdo_t,   // IOBUF T  <- dap_ntdoen (1 = float)
    input  wire        jtag_ntrst,   // -> dap_ntrst

    // =========================================================================
    // Interrupt -> PS pl_ps_irq (aggregate with a Concat in the BD)
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_tidechart INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_tidechart, SENSITIVITY LEVEL_HIGH" *)
    output wire        tidechart_irq,

    // =========================================================================
    // UART (bring the primary console out)
    // =========================================================================
    input  wire        uart_rxd,
    output wire        uart_txd
);

    // -------------------------------------------------------------------------
    // The compute chiplet. Non-boundary pins (scan/DFT, qspi, PTP, unused link
    // straps, negotiation/PUF) tied to benign constants / left open here, exactly
    // as the ASIC chip-boundary spec classifies them (ties/opens), so the BD sees
    // a clean boundary.
    // -------------------------------------------------------------------------
    nanosoc_compute_chiplet #(
        .NUM_PHY_LANES (NUM_PHY_LANES)
    ) u_chiplet (
        // System clock / reset
        .sys_fclk            (sys_fclk),
        .sys_sysresetn       (sys_sysresetn),
        .sys_poresetn        (sys_poresetn),
        .sys_hclk            (sys_hclk),
        .sys_hresetn         (sys_hresetn),
        .sys_scanenable      (1'b0),
        .sys_testmode        (1'b0),
        .sys_sysresetreq     (1'b0),

        // QSPI flash — unused on the M1 board: tie inputs, leave outputs open
        .qspi_sclk           (),
        .qspi_csn            (),
        .qspi_io_o           (),
        .qspi_io_i           (4'b0000),
        .qspi_io_e           (),

        // UART — primary console out
        .uart_rxd            (uart_rxd),
        .uart_txd            (uart_txd),

        // PTP 1PPS out — no board pin in this bring-up; leave open
        .phc_pps_out         (),

        // Debug access port — FULL SWJ-DP (SWD + JTAG TAP)
        .dap_swclktck        (swclk),
        .dap_swditms         (swdio_i),
        .dap_swdo            (swdio_o),
        .dap_swdoen          (swdio_oe),
        .dap_tdi             (jtag_tdi),
        .dap_tdo             (jtag_tdo_o),
        .dap_ntdoen          (jtag_tdo_t),   // active-low OE == active-high Hi-Z T
        .dap_ntrst           (jtag_ntrst),
        .dap_npotrst         (1'b1),         // tied per chip_boundary (PoR deasserted)
        .dap_swj_enable      (1'b1),         // tied per chip_boundary (SWD/JTAG enabled)

        // PS host backdoor (external AHB target -> ps_m)
        .ps_ahb_s_haddr      (ps_ahb_s_haddr),
        .ps_ahb_s_htrans     (ps_ahb_s_htrans),
        .ps_ahb_s_hwrite     (ps_ahb_s_hwrite),
        .ps_ahb_s_hsize      (ps_ahb_s_hsize),
        .ps_ahb_s_hburst     (ps_ahb_s_hburst),
        .ps_ahb_s_hprot      (ps_ahb_s_hprot),
        .ps_ahb_s_hwdata     (ps_ahb_s_hwdata),
        .ps_ahb_s_hmastlock  (ps_ahb_s_hmastlock),
        .ps_ahb_s_hrdata     (ps_ahb_s_hrdata),
        .ps_ahb_s_hready     (ps_ahb_s_hready),
        .ps_ahb_s_hresp      (ps_ahb_s_hresp),

        // DFT / scan — tie off for FPGA (scan_out open)
        .scan_mode           (1'b0),
        .scan_asyncrst_ctrl  (1'b0),
        .scan_clk            (1'b0),
        .scan_shift          (1'b0),
        .scan_in             (1'b0),
        .scan_out            (),

        // ---- LINK 0 ----
        .pad_clk_tx_0        (pad_clk_tx_0),
        .pad_tx_0            (pad_tx_0),
        .pad_clk_rx_0        (pad_clk_rx_0),
        .pad_rx_0            (pad_rx_0),
        .user_ref_clk_0      (user_ref_clk_0),
        .idelay_ref_clk_0    (idelay_ref_clk),
        .i2c_scl_i_0         (i2c_scl_i_0),
        .i2c_scl_o_0         (i2c_scl_o_0),
        .i2c_scl_t_0         (i2c_scl_t_0),
        .i2c_sda_i_0         (i2c_sda_i_0),
        .i2c_sda_o_0         (i2c_sda_o_0),
        .i2c_sda_t_0         (i2c_sda_t_0),
        .role_strap_i_0      (role_strap_i_0),
        .mask_hs_bypass_i_0  (1'b0),
        .apb_debug_unlock_i_0(1'b0),
        .nego_priority_i_0   (16'h0001),
        .puf_seed_0          (16'h0000),
        .puf_ready_0         (1'b0),
        .link_active_o_0     (link_active_0),
        .d2d_reset_o_0       (d2d_reset_0),
        .role_is_master_o_0  (role_is_master_0),
        .role_locked_o_0     (role_locked_0),
        .servo_locked_o_0    (),               // open per chip_boundary
        .tl_ewma_credit_o_0  (),               // open per chip_boundary

        // ---- LINK 1 (exposed; BD ties off) ----
        .pad_clk_tx_1        (pad_clk_tx_1),
        .pad_tx_1            (pad_tx_1),
        .pad_clk_rx_1        (pad_clk_rx_1),
        .pad_rx_1            (pad_rx_1),
        .user_ref_clk_1      (user_ref_clk_1),
        .idelay_ref_clk_1    (idelay_ref_clk),
        .i2c_scl_i_1         (i2c_scl_i_1),
        .i2c_scl_o_1         (i2c_scl_o_1),
        .i2c_scl_t_1         (i2c_scl_t_1),
        .i2c_sda_i_1         (i2c_sda_i_1),
        .i2c_sda_o_1         (i2c_sda_o_1),
        .i2c_sda_t_1         (i2c_sda_t_1),
        .role_strap_i_1      (role_strap_i_1),
        .mask_hs_bypass_i_1  (1'b0),
        .apb_debug_unlock_i_1(1'b0),
        .nego_priority_i_1   (16'h0001),
        .puf_seed_1          (16'h0000),
        .puf_ready_1         (1'b0),
        .link_active_o_1     (link_active_1),
        .d2d_reset_o_1       (d2d_reset_1),
        .role_is_master_o_1  (role_is_master_1),
        .role_locked_o_1     (role_locked_1),
        .servo_locked_o_1    (),               // open per chip_boundary
        .tl_ewma_credit_o_1  (),               // open per chip_boundary

        // ---- shared TideChart interrupt ----
        .tidechart_irq_o     (tidechart_irq)
    );

endmodule
