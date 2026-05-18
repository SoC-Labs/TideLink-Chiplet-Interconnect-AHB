//-----------------------------------------------------------------------------
// TideLink Chiplet Bridge - Vivado IP Integrator Wrapper
// A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
//
// Contributors
//
// David Mapstone (d.a.mapstone@soton.ac.uk)
//
// Copyright (C) 2026, SoC Labs (www.soclabs.org)
//-----------------------------------------------------------------------------
// Vivado IP Integrator wrapper for tidelink_top. Exposes:
//   - AHB-Lite slave: ahb_sub (regular chiplet access path, 32-bit)
//   - AHB-Lite slave: ahb_tx  (TideLink TX aperture, 14-bit addr)
//   - AHB-Lite slave: ahb_fifo (local RX FIFO read window, 14-bit addr)
//   - AHB-Lite slave: ahb_ptp (PTP TX write port, 4-bit addr)
//   - AHB-Lite master: ahb_mng (incoming from remote chiplet, 32-bit)
//   - APB slave: apb (unified config; Wlink/TideLink/addr-translator)
//   - AXI-Stream master: tc_axis_tx (TideChart TX, 48-bit data)
//   - AXI-Stream slave:  tc_axis_rx (TideChart RX, 48-bit data)
//   - GPIO PHY pads: pad_clk_tx/rx, pad_tx[7:0]/pad_rx[7:0] (discrete I/O)
//   - PHC interface signals (discrete I/O — connect to phc_hardware_clock IP)
//   - IRQ outputs (each annotated INTERRUPT INTERRUPT, LEVEL_HIGH)
//   - I2C sideband (discrete tristate I/O)
//   - I2C AXI slave (discrete — for CPU-driven I2C master path)
//   - Misc: link_active, d2d_reset_o, congestion sideband, role, nego, PUF, scan
//
// AHB slave HSEL / HREADY workaround:
//   Xilinx's axi_ahblite_bridge:3.0 master deliberately omits HSEL and
//   HREADY_IN from its bus interface output — it assumes a single-slave bus
//   (slave always selected; slave's own HREADYOUT is the only HREADY on wire).
//   Exposing HSEL/HREADY_IN through X_INTERFACE_INFO causes Vivado to leave
//   them unconnected (tied to 0) => slave never selected => bus hangs.
//   Fix: keep HSEL and HREADY_IN internal; hardwire HSEL=1 and feed HREADYOUT
//   back into HREADY_IN for each slave port.  Only HREADYOUT is exported to
//   IPI via sub-signal name "HREADY" (the bridge reads HREADY from the slave).
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tidelink_vivado_wrapper #(
    // System bus widths — keep at Vivado-friendly 32-bit defaults
    parameter SYS_ADDR_W     = 32,
    parameter SYS_DATA_W     = 32,
    // FIFO SRAM address width (14 => 16 KB FIFO aperture)
    parameter RAM_ADDR_W     = 14,
    // FC node data width (48 matches AXI-Stream port)
    parameter FC_DATA_W      = 48,
    // Number of GPIO PHY lanes
    parameter NUM_PHY_LANES  = 8,
    // Default pair base address
    parameter [31:0] TIDELINK_PAIR_BASE = 32'h0,
    // PHC lock gate enable
    parameter PHC_LOCK_GATE_EN = 0,
    // SoC Labs §9 structural fix: per-lane IDELAYE2 RX delay element.
    // Defaults to 1 here (this is the FPGA IP wrapper — the only place
    // the Xilinx IDELAYE2 is wanted). fpga/build_design.tcl additionally
    // defines TIDELINK_USE_IDELAY (the unisim-primitive `ifdef guard).
    // Override to 0 to build the FPGA image with passthrough RX (A/B
    // determinism comparison).
    parameter USE_IDELAY = 1'b1
)(
    // =========================================================================
    // Clocks and Resets
    // =========================================================================

    // Primary AHB/application clock.
    // ASSOCIATED_BUSIF covers all slave/master AHB paths and the APB config bus.
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.HCLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.HCLK, ASSOCIATED_RESET hresetn, ASSOCIATED_BUSIF ahb_sub:ahb_tx:ahb_fifo:ahb_ptp:ahb_mng:apb, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        hclk,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.HRESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.HRESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        hresetn,

    // Power-on reset (active-low); tie together with hresetn on most boards
    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.PORESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.PORESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        poresetn,

    // PHC clock — may differ from hclk on boards with dedicated PTP TCXO
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.PHCCLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.PHCCLK, ASSOCIATED_RESET phc_resetn, FREQ_HZ 50000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        phc_clk,

    (* X_INTERFACE_INFO      = "xilinx.com:signal:reset:1.0 RST.PHCRESETN RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME RST.PHCRESETN, INSERT_VIP 0, POLARITY ACTIVE_LOW" *)
    input  wire        phc_resetn,

    // Wlink PLL reference clock (discrete — no IPI auto-connect needed)
    input  wire        user_ref_clk,

    // SoC Labs §9 IDELAYE2 RX delay: 200 MHz IDELAYCTRL reference clock.
    // Marked as a clock interface so the BD connects a clk_wiz 200 MHz
    // output. Only meaningful when USE_IDELAY=1. The MMCM/PLL freq-check
    // DRC is already suppressed for this IP (package_tidelink_ip.tcl).
    (* X_INTERFACE_INFO      = "xilinx.com:signal:clock:1.0 CLK.IDELAY_REF_CLK CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK.IDELAY_REF_CLK, FREQ_HZ 200000000, FREQ_TOLERANCE_HZ 0, INSERT_VIP 0, PHASE 0.0" *)
    input  wire        idelay_ref_clk,

    // =========================================================================
    // AHB-Lite Slave — ahb_sub (regular chiplet access, 32-bit address)
    // HSEL and HREADY_IN are kept internal (see file header).
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HADDR"  *) input  wire [31:0] ahb_sub_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HBURST" *) input  wire  [2:0] ahb_sub_hburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HPROT"  *) input  wire  [3:0] ahb_sub_hprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HSIZE"  *) input  wire  [2:0] ahb_sub_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HTRANS" *) input  wire  [1:0] ahb_sub_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HWDATA" *) input  wire [31:0] ahb_sub_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HWRITE" *) input  wire        ahb_sub_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HRDATA" *) output wire [31:0] ahb_sub_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HRESP"  *) output wire        ahb_sub_hresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_sub HREADY" *) output wire        ahb_sub_hready,

    // =========================================================================
    // AHB-Lite Slave — ahb_tx (TideLink TX aperture, RAM_ADDR_W-bit address)
    // No HBURST/HPROT on this port (FC node accepts single transfers only).
    // HSEL and HREADY_IN are kept internal (see file header).
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HADDR"  *) input  wire [13:0] ahb_tx_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HSIZE"  *) input  wire  [2:0] ahb_tx_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HTRANS" *) input  wire  [1:0] ahb_tx_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HWDATA" *) input  wire [31:0] ahb_tx_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HWRITE" *) input  wire        ahb_tx_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HRDATA" *) output wire [31:0] ahb_tx_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HRESP"  *) output wire        ahb_tx_hresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_tx HREADY" *) output wire        ahb_tx_hready,

    // =========================================================================
    // AHB-Lite Slave — ahb_fifo (local RX FIFO read window, RAM_ADDR_W-bit addr)
    // No HBURST/HPROT on this port (FIFO controller only handles single xfers).
    // HSEL and HREADY_IN are kept internal (see file header).
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HADDR"  *) input  wire [13:0] ahb_fifo_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HSIZE"  *) input  wire  [2:0] ahb_fifo_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HTRANS" *) input  wire  [1:0] ahb_fifo_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HWDATA" *) input  wire [31:0] ahb_fifo_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HWRITE" *) input  wire        ahb_fifo_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HRDATA" *) output wire [31:0] ahb_fifo_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HRESP"  *) output wire        ahb_fifo_hresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_fifo HREADY" *) output wire        ahb_fifo_hready,

    // =========================================================================
    // AHB-Lite Slave — ahb_ptp (PTP TX write port, 4-bit address)
    // Small aperture (16 B), minimal AHB signals. Keep HSEL/HREADY internal.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HADDR"  *) input  wire  [3:0] ahb_ptp_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HSIZE"  *) input  wire  [2:0] ahb_ptp_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HTRANS" *) input  wire  [1:0] ahb_ptp_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HWDATA" *) input  wire [31:0] ahb_ptp_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HWRITE" *) input  wire        ahb_ptp_hwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HRDATA" *) output wire [31:0] ahb_ptp_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HRESP"  *) output wire        ahb_ptp_hresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_ptp HREADY" *) output wire        ahb_ptp_hready,

    // =========================================================================
    // AHB-Lite Master — ahb_mng (incoming from remote chiplet, 32-bit)
    // This port drives an AHB slave on the local SoC fabric.
    // Note: tidelink_top exposes ahb_mng_hprot as [6:0] (XHB500 extended
    // protection bits). The AHB-Lite:2.0 HPROT sub-signal is 4-bit; only
    // [3:0] participates in bus-interface auto-connect. Bit [6:4] (secure/
    // privileged extensions) are passed through but Vivado ignores them for
    // auto-connect purposes — this is correct behaviour.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HADDR"  *) output wire [31:0] ahb_mng_haddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HBURST" *) output wire  [2:0] ahb_mng_hburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HPROT"  *) output wire  [6:0] ahb_mng_hprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HSIZE"  *) output wire  [2:0] ahb_mng_hsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HTRANS" *) output wire  [1:0] ahb_mng_htrans,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HWDATA" *) output wire [31:0] ahb_mng_hwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HWRITE" *) output wire        ahb_mng_hwrite,
    // HREADY flows slave→manager; fixed direction (was incorrectly `output`
    // here and on the tidelink_top RTL boundary it wraps).
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HREADY" *) input  wire        ahb_mng_hready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HRDATA" *) input  wire [31:0] ahb_mng_hrdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:ahblite:2.0 ahb_mng HRESP"  *) input  wire        ahb_mng_hresp,

    // =========================================================================
    // APB Slave — unified configuration (Wlink / TideLink / addr-translator)
    //   0x0000-0x1FFF: Wlink chiplet controller
    //   0x2000-0x3FFF: TideLink config + PTP registers
    //   0x4000-0x5FFF: Address translator configuration
    // APB address width is 15 bits (32 KB range). The IPI apb:1.0 interface
    // definition carries PADDR at 32 bits; we truncate to [14:0] internally.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PADDR"   *) input  wire [31:0] apb_paddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PENABLE" *) input  wire        apb_penable,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PWRITE"  *) input  wire        apb_pwrite,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSTRB"   *) input  wire  [3:0] apb_pstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PPROT"   *) input  wire  [2:0] apb_pprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PWDATA"  *) input  wire [31:0] apb_pwdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSEL"    *) input  wire        apb_psel,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PRDATA"  *) output wire [31:0] apb_prdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PREADY"  *) output wire        apb_pready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:apb:1.0 apb PSLVERR" *) output wire        apb_pslverr,

    // =========================================================================
    // AXI-Stream Master — tc_axis_tx (TideChart TX to external, 48-bit)
    // Packets with pkt_type=2'b10 are routed out on this port.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_tx TVALID" *) input  wire        tc_axis_tx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_tx TDATA"  *) input  wire [47:0] tc_axis_tx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_tx TREADY" *) output wire        tc_axis_tx_tready,

    // =========================================================================
    // AXI-Stream Slave — tc_axis_rx (TideChart RX from external, 48-bit)
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_rx TVALID" *) output wire        tc_axis_rx_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_rx TDATA"  *) output wire [47:0] tc_axis_rx_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 tc_axis_rx TREADY" *) input  wire        tc_axis_rx_tready,

    // =========================================================================
    // GPIO PHY Pads — discrete I/O, no bus interface annotation
    // Board wrapper (targets/<board>/tidelink_design_wrapper.v) connects to XDC
    // =========================================================================
    output wire        pad_clk_tx,
    output wire  [7:0] pad_tx,
    input  wire        pad_clk_rx,
    input  wire  [7:0] pad_rx,

    // =========================================================================
    // PHC (Precision Time Protocol Hardware Clock) interface — discrete I/O
    // Connect to the phc_hardware_clock IP instance in the block design.
    // =========================================================================
    output wire        phc_hw_capture,
    input  wire [29:0] phc_nanoseconds,
    input  wire [47:0] phc_seconds,
    input  wire        phc_pps,
    input  wire [47:0] phc_hw_cap_seconds,
    input  wire [29:0] phc_hw_cap_nanoseconds,
    input  wire [31:0] phc_hw_cap_sub_nanoseconds,
    output wire        phc_hw_set_time,
    output wire [47:0] phc_hw_set_seconds,
    output wire [29:0] phc_hw_set_nanoseconds,
    output wire        phc_hw_adj_valid,
    output wire [31:0] phc_hw_adj_ns_incr_frac,
    input  wire        phc_locked_i,
    output wire        servo_locked,

    // =========================================================================
    // Interrupt Outputs
    // Each annotated individually; aggregate with a Concat block feeding AXI INTC
    // or PS IRQ_F2P. SENSITIVITY=LEVEL_HIGH matches Arm GIC conventions.
    // =========================================================================
    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_released_credits INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_released_credits, SENSITIVITY LEVEL_HIGH" *)
    output wire        released_credits_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_doorbell INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_doorbell, SENSITIVITY LEVEL_HIGH" *)
    output wire        doorbell_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_packet_committed INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_packet_committed, SENSITIVITY LEVEL_HIGH" *)
    output wire        packet_committed_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_ptp INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_ptp, SENSITIVITY LEVEL_HIGH" *)
    output wire        ptp_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_perf INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_perf, SENSITIVITY LEVEL_HIGH" *)
    output wire        perf_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_wlink INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_wlink, SENSITIVITY LEVEL_HIGH" *)
    output wire        wlink_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_nego_error INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_nego_error, SENSITIVITY LEVEL_HIGH" *)
    output wire        nego_error_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_i2c_nbsy INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_i2c_nbsy, SENSITIVITY LEVEL_HIGH" *)
    output wire        i2c_nbsy_irq,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_i2c_nrd_empty INTERRUPT" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME irq_i2c_nrd_empty, SENSITIVITY LEVEL_HIGH" *)
    output wire        i2c_nrd_empty_irq,

    // =========================================================================
    // Link / Congestion sideband — discrete status outputs (for TideChart agent)
    // =========================================================================
    output wire        link_active,
    output wire        d2d_reset_o,
    output wire  [4:0] tl_local_link_state_o,
    output wire        tl_link_state_change_o,
    output wire [12:0] tl_ewma_credit_o,
    input  wire        tl_bcast_ack_i,

    // =========================================================================
    // Role / Auto-Negotiation / PUF — discrete I/O
    // =========================================================================
    input  wire        role_strap_i,
    output wire        role_is_master_o,
    output wire        role_locked_o,
    input  wire        apb_debug_unlock_i,
    input  wire        mask_hs_bypass_i,
    input  wire [15:0] nego_priority_i,
    input  wire [15:0] puf_seed,
    input  wire        puf_ready,

    // =========================================================================
    // QoS priority hint (from TideChart)
    // =========================================================================
    input  wire  [2:0] tc_qos_priority,

    // =========================================================================
    // I2C Sideband — open-drain tristate (board wrapper muxes to IOBUF)
    // =========================================================================
    input  wire        i2c_scl_i,
    output wire        i2c_scl_o,
    output wire        i2c_scl_t,
    input  wire        i2c_sda_i,
    output wire        i2c_sda_o,
    output wire        i2c_sda_t,

    // =========================================================================
    // I2C AXI Slave — discrete; CPU-driven I2C master path
    // Exposed as raw signals (not bus-annotated) so the board wrapper can
    // connect a standard AXI Interconnect without IP Integrator guessing
    // the role from the annotation.
    // =========================================================================
    input  wire        s_i2c_axi_awvalid,
    input  wire  [1:0] s_i2c_axi_awid,
    input  wire  [3:0] s_i2c_axi_awaddr,
    input  wire  [7:0] s_i2c_axi_awlen,
    input  wire  [2:0] s_i2c_axi_awsize,
    input  wire  [1:0] s_i2c_axi_awburst,
    input  wire        s_i2c_axi_awlock,
    input  wire  [3:0] s_i2c_axi_awcache,
    input  wire  [2:0] s_i2c_axi_awprot,
    output wire        s_i2c_axi_awready,
    input  wire        s_i2c_axi_wvalid,
    input  wire [31:0] s_i2c_axi_wdata,
    input  wire  [3:0] s_i2c_axi_wstrb,
    input  wire        s_i2c_axi_wlast,
    output wire        s_i2c_axi_wready,
    output wire        s_i2c_axi_bvalid,
    output wire  [1:0] s_i2c_axi_bid,
    output wire  [1:0] s_i2c_axi_bresp,
    input  wire        s_i2c_axi_bready,
    input  wire        s_i2c_axi_arvalid,
    input  wire  [1:0] s_i2c_axi_arid,
    input  wire  [3:0] s_i2c_axi_araddr,
    input  wire  [7:0] s_i2c_axi_arlen,
    input  wire  [2:0] s_i2c_axi_arsize,
    input  wire  [1:0] s_i2c_axi_arburst,
    input  wire        s_i2c_axi_arlock,
    input  wire  [3:0] s_i2c_axi_arcache,
    input  wire  [2:0] s_i2c_axi_arprot,
    output wire        s_i2c_axi_arready,
    output wire        s_i2c_axi_rvalid,
    output wire  [1:0] s_i2c_axi_rid,
    output wire [31:0] s_i2c_axi_rdata,
    output wire  [1:0] s_i2c_axi_rresp,
    output wire        s_i2c_axi_rlast,
    input  wire        s_i2c_axi_rready,

    // =========================================================================
    // Scan / DFT ports — expose as discrete inputs; tie to 0 in board wrapper
    // for normal FPGA use. Keeping them on the IP boundary allows scan-insertion
    // flows to override without modifying the packaged IP.
    // =========================================================================
    input  wire        scan_mode,
    input  wire        scan_asyncrst_ctrl,
    input  wire        scan_clk,
    input  wire        scan_shift,
    input  wire        scan_in,
    output wire        scan_out
);

    // =========================================================================
    // Internal HSEL / HREADY wires for the HSEL=1 HREADY-loopback pattern
    // (see file header for explanation)
    // =========================================================================
    wire sub_hreadyout_int;
    wire tx_hreadyout_int;
    wire fifo_hreadyout_int;
    wire ptp_hreadyout_int;

    // Each slave's HREADYOUT is looped back to its own HREADY_IN.
    // The wrapper port (ahb_*_hready) is the exported HREADYOUT only.
    assign ahb_sub_hready  = sub_hreadyout_int;
    assign ahb_tx_hready   = tx_hreadyout_int;
    assign ahb_fifo_hready = fifo_hreadyout_int;
    assign ahb_ptp_hready  = ptp_hreadyout_int;

    // =========================================================================
    // tidelink_top instantiation
    // =========================================================================
    tidelink_top #(
        .SYS_ADDR_W          (SYS_ADDR_W),
        .SYS_DATA_W          (SYS_DATA_W),
        .RAM_ADDR_W          (RAM_ADDR_W),
        .RAM_DATA_W          (SYS_DATA_W),
        .APB_ADDR_W          (12),
        .FC_DATA_W           (FC_DATA_W),
        .NUM_PHY_LANES       (NUM_PHY_LANES),
        .TIDELINK_PAIR_BASE  (TIDELINK_PAIR_BASE),
        .PHC_LOCK_GATE_EN    (PHC_LOCK_GATE_EN),
        // §9 structural fix: per-lane IDELAYE2 RX delay (FPGA wants it on).
        .USE_IDELAY          (USE_IDELAY)
    ) u_tidelink_top (
        // Clocks and resets
        .hclk                       (hclk),
        .hresetn                    (hresetn),
        .poresetn                   (poresetn),
        .phc_clk                    (phc_clk),
        .phc_resetn                 (phc_resetn),
        .user_ref_clk               (user_ref_clk),

        // AHB Subordinate — ahb_sub (HSEL hardwired 1, HREADY loopback)
        .ahb_sub_hsel               (1'b1),
        .ahb_sub_haddr              (ahb_sub_haddr),
        .ahb_sub_hburst             (ahb_sub_hburst),
        .ahb_sub_hprot              (ahb_sub_hprot),
        .ahb_sub_hsize              (ahb_sub_hsize),
        .ahb_sub_htrans             (ahb_sub_htrans),
        .ahb_sub_hwdata             (ahb_sub_hwdata),
        .ahb_sub_hwrite             (ahb_sub_hwrite),
        .ahb_sub_hready             (sub_hreadyout_int),
        .ahb_sub_hrdata             (ahb_sub_hrdata),
        .ahb_sub_hresp              (ahb_sub_hresp),
        .ahb_sub_hreadyout          (sub_hreadyout_int),

        // AHB Subordinate — ahb_tx (HSEL hardwired 1, HREADY loopback)
        .ahb_tx_hsel                (1'b1),
        .ahb_tx_haddr               (ahb_tx_haddr),
        .ahb_tx_htrans              (ahb_tx_htrans),
        .ahb_tx_hsize               (ahb_tx_hsize),
        .ahb_tx_hwrite              (ahb_tx_hwrite),
        .ahb_tx_hwdata              (ahb_tx_hwdata),
        .ahb_tx_hready              (tx_hreadyout_int),
        .ahb_tx_hrdata              (ahb_tx_hrdata),
        .ahb_tx_hresp               (ahb_tx_hresp),
        .ahb_tx_hreadyout           (tx_hreadyout_int),

        // AHB Subordinate — ahb_fifo (HSEL hardwired 1, HREADY loopback)
        .ahb_fifo_hsel              (1'b1),
        .ahb_fifo_haddr             (ahb_fifo_haddr),
        .ahb_fifo_htrans            (ahb_fifo_htrans),
        .ahb_fifo_hsize             (ahb_fifo_hsize),
        .ahb_fifo_hwrite            (ahb_fifo_hwrite),
        .ahb_fifo_hwdata            (ahb_fifo_hwdata),
        .ahb_fifo_hready            (fifo_hreadyout_int),
        .ahb_fifo_hrdata            (ahb_fifo_hrdata),
        .ahb_fifo_hresp             (ahb_fifo_hresp),
        .ahb_fifo_hreadyout         (fifo_hreadyout_int),

        // AHB Subordinate — ahb_ptp (HSEL hardwired 1, HREADY loopback)
        .ahb_ptp_hsel               (1'b1),
        .ahb_ptp_haddr              (ahb_ptp_haddr),
        .ahb_ptp_htrans             (ahb_ptp_htrans),
        .ahb_ptp_hsize              (ahb_ptp_hsize),
        .ahb_ptp_hwrite             (ahb_ptp_hwrite),
        .ahb_ptp_hwdata             (ahb_ptp_hwdata),
        .ahb_ptp_hready             (ptp_hreadyout_int),
        .ahb_ptp_hrdata             (ahb_ptp_hrdata),
        .ahb_ptp_hresp              (ahb_ptp_hresp),
        .ahb_ptp_hreadyout          (ptp_hreadyout_int),

        // AHB Manager — ahb_mng (drives local SoC fabric slave)
        .ahb_mng_haddr              (ahb_mng_haddr),
        .ahb_mng_hburst             (ahb_mng_hburst),
        .ahb_mng_hprot              (ahb_mng_hprot),
        .ahb_mng_hsize              (ahb_mng_hsize),
        .ahb_mng_htrans             (ahb_mng_htrans),
        .ahb_mng_hwdata             (ahb_mng_hwdata),
        .ahb_mng_hwrite             (ahb_mng_hwrite),
        .ahb_mng_hready             (ahb_mng_hready),
        .ahb_mng_hrdata             (ahb_mng_hrdata),
        .ahb_mng_hresp              (ahb_mng_hresp),

        // APB — truncate 32-bit IPI PADDR to 15-bit internal width
        .apb_paddr                  (apb_paddr[14:0]),
        .apb_penable                (apb_penable),
        .apb_pwrite                 (apb_pwrite),
        .apb_pstrb                  (apb_pstrb),
        .apb_pprot                  (apb_pprot),
        .apb_pwdata                 (apb_pwdata),
        .apb_psel                   (apb_psel),
        .apb_prdata                 (apb_prdata),
        .apb_pready                 (apb_pready),
        .apb_pslverr                (apb_pslverr),

        // AXI-Stream TideChart
        .tc_axis_tx_tvalid          (tc_axis_tx_tvalid),
        .tc_axis_tx_tdata           (tc_axis_tx_tdata),
        .tc_axis_tx_tready          (tc_axis_tx_tready),
        .tc_axis_rx_tvalid          (tc_axis_rx_tvalid),
        .tc_axis_rx_tdata           (tc_axis_rx_tdata),
        .tc_axis_rx_tready          (tc_axis_rx_tready),
        .tc_qos_priority            (tc_qos_priority),

        // PHY pads
        .pad_clk_tx                 (pad_clk_tx),
        .pad_tx                     (pad_tx),
        .pad_clk_rx                 (pad_clk_rx),
        .pad_rx                     (pad_rx),

        // §9 IDELAYE2 RX delay: 200 MHz IDELAYCTRL reference clock
        .idelay_ref_clk             (idelay_ref_clk),

        // PHC interface
        .phc_hw_capture             (phc_hw_capture),
        .phc_nanoseconds            (phc_nanoseconds),
        .phc_seconds                (phc_seconds),
        .phc_pps                    (phc_pps),
        .phc_hw_cap_seconds         (phc_hw_cap_seconds),
        .phc_hw_cap_nanoseconds     (phc_hw_cap_nanoseconds),
        .phc_hw_cap_sub_nanoseconds (phc_hw_cap_sub_nanoseconds),
        .phc_hw_set_time            (phc_hw_set_time),
        .phc_hw_set_seconds         (phc_hw_set_seconds),
        .phc_hw_set_nanoseconds     (phc_hw_set_nanoseconds),
        .phc_hw_adj_valid           (phc_hw_adj_valid),
        .phc_hw_adj_ns_incr_frac    (phc_hw_adj_ns_incr_frac),
        .phc_locked_i               (phc_locked_i),
        .servo_locked               (servo_locked),

        // Interrupts
        .released_credits_irq       (released_credits_irq),
        .doorbell_irq               (doorbell_irq),
        .packet_committed_irq       (packet_committed_irq),
        .ptp_irq                    (ptp_irq),
        .perf_irq                   (perf_irq),
        .wlink_irq                  (wlink_irq),
        .nego_error_irq             (nego_error_irq),
        .i2c_nbsy_irq               (i2c_nbsy_irq),
        .i2c_nrd_empty_irq          (i2c_nrd_empty_irq),

        // Congestion / link sideband
        .tl_local_link_state_o      (tl_local_link_state_o),
        .tl_link_state_change_o     (tl_link_state_change_o),
        .tl_ewma_credit_o           (tl_ewma_credit_o),
        .tl_bcast_ack_i             (tl_bcast_ack_i),
        .link_active                (link_active),
        .d2d_reset_o                (d2d_reset_o),

        // Role / negotiation / PUF
        .role_strap_i               (role_strap_i),
        .role_is_master_o           (role_is_master_o),
        .role_locked_o              (role_locked_o),
        .apb_debug_unlock_i         (apb_debug_unlock_i),
        .mask_hs_bypass_i           (mask_hs_bypass_i),
        .nego_priority_i            (nego_priority_i),
        .puf_seed                   (puf_seed),
        .puf_ready                  (puf_ready),

        // I2C sideband
        .i2c_scl_i                  (i2c_scl_i),
        .i2c_scl_o                  (i2c_scl_o),
        .i2c_scl_t                  (i2c_scl_t),
        .i2c_sda_i                  (i2c_sda_i),
        .i2c_sda_o                  (i2c_sda_o),
        .i2c_sda_t                  (i2c_sda_t),

        // I2C AXI slave
        .s_i2c_axi_awvalid          (s_i2c_axi_awvalid),
        .s_i2c_axi_awid             (s_i2c_axi_awid),
        .s_i2c_axi_awaddr           (s_i2c_axi_awaddr),
        .s_i2c_axi_awlen            (s_i2c_axi_awlen),
        .s_i2c_axi_awsize           (s_i2c_axi_awsize),
        .s_i2c_axi_awburst          (s_i2c_axi_awburst),
        .s_i2c_axi_awlock           (s_i2c_axi_awlock),
        .s_i2c_axi_awcache          (s_i2c_axi_awcache),
        .s_i2c_axi_awprot           (s_i2c_axi_awprot),
        .s_i2c_axi_awready          (s_i2c_axi_awready),
        .s_i2c_axi_wvalid           (s_i2c_axi_wvalid),
        .s_i2c_axi_wdata            (s_i2c_axi_wdata),
        .s_i2c_axi_wstrb            (s_i2c_axi_wstrb),
        .s_i2c_axi_wlast            (s_i2c_axi_wlast),
        .s_i2c_axi_wready           (s_i2c_axi_wready),
        .s_i2c_axi_bvalid           (s_i2c_axi_bvalid),
        .s_i2c_axi_bid              (s_i2c_axi_bid),
        .s_i2c_axi_bresp            (s_i2c_axi_bresp),
        .s_i2c_axi_bready           (s_i2c_axi_bready),
        .s_i2c_axi_arvalid          (s_i2c_axi_arvalid),
        .s_i2c_axi_arid             (s_i2c_axi_arid),
        .s_i2c_axi_araddr           (s_i2c_axi_araddr),
        .s_i2c_axi_arlen            (s_i2c_axi_arlen),
        .s_i2c_axi_arsize           (s_i2c_axi_arsize),
        .s_i2c_axi_arburst          (s_i2c_axi_arburst),
        .s_i2c_axi_arlock           (s_i2c_axi_arlock),
        .s_i2c_axi_arcache          (s_i2c_axi_arcache),
        .s_i2c_axi_arprot           (s_i2c_axi_arprot),
        .s_i2c_axi_arready          (s_i2c_axi_arready),
        .s_i2c_axi_rvalid           (s_i2c_axi_rvalid),
        .s_i2c_axi_rid              (s_i2c_axi_rid),
        .s_i2c_axi_rdata            (s_i2c_axi_rdata),
        .s_i2c_axi_rresp            (s_i2c_axi_rresp),
        .s_i2c_axi_rlast            (s_i2c_axi_rlast),
        .s_i2c_axi_rready           (s_i2c_axi_rready),

        // Scan / DFT
        .scan_mode                  (scan_mode),
        .scan_asyncrst_ctrl         (scan_asyncrst_ctrl),
        .scan_clk                   (scan_clk),
        .scan_shift                 (scan_shift),
        .scan_in                    (scan_in),
        .scan_out                   (scan_out)
    );

endmodule
