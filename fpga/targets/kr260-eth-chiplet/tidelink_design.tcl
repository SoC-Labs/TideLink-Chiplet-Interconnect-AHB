###-----------------------------------------------------------------------------
### nanoSoC eth-chiplet - KR260 Block Design TCL (die_a / straight)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Builds the "tidelink_design" block design for the KR260 eth-chiplet target
### (xck26, K26 SOM). Unlike the bare-link kr260-pair targets, TideLink is
### INTERNAL to the packaged nanosoc_eth_chiplet IP; the on-chip Cortex-M0 cores
### drive the D2D link. The PS role here is:
###
###   - provide clocks + reset (PL0_REF 100 MHz -> clk_wiz),
###   - reach the SoC AHB matrix through the eth_ss_0 backdoor via
###     M_AXI_HPM0 -> AXI-SmartConnect -> axi_ahblite_bridge (firmware load +
###     register poke; KR260 HPM0 base 0x8000_0000),
###   - aggregate eth/phc/tidechart IRQs into pl_ps_irq0.
###
### The GPIO-PHY pads go to the J21 ribbon (kr260_eth_chiplet_tidelink.xdc), and
### CoreSight SWD goes to PMOD4 (swclk/swdio_* -> board wrapper IOBUF).
###
### ┌── SCOPING STATUS ─────────────────────────────────────────────────────────
### │ FIRST-CUT scaffold. The OOC IP synth (make package_eth_chiplet_ip) is the
### │ scoping gate that proves the SoC fits xck26; THIS block-design build is the
### │ next phase and WILL need Vivado-interactive iteration on the items marked
### │ `SCOPING-TODO` below (exact PS8 preset, eth_ss_0 clock association since the
### │ SoC derives its own hclk from sys_fclk, and the HPM0 address assignment).
### └───────────────────────────────────────────────────────────────────────────
###
### die_a vs die_b: this file is shared; the flip (die_b) target swaps the
### TX/RX balls in its XDC and defaults the role strap to 1. Set by the target
### dir the Makefile selects; PTP inclusion follows FPGA_TIDELINK_PTP.
###-----------------------------------------------------------------------------

proc create_root_design { parentCell } {

    if { $parentCell eq "" } { set parentCell [get_bd_cells /] }
    set parentObj [get_bd_cells $parentCell]
    current_bd_instance $parentObj

    # PTP inclusion knob (mirrors the bare-link targets)
    set tl_ptp 0
    if { [info exists ::env(FPGA_TIDELINK_PTP)] && $::env(FPGA_TIDELINK_PTP) == 1 } { set tl_ptp 1 }

    ###########################################################################
    # EXTERNAL PORTS (board wrapper connects these; see XDC)
    ###########################################################################
    # GPIO-PHY pads -> J21 ribbon
    create_bd_port -dir O           pad_clk_tx
    create_bd_port -dir O -from 7 -to 0 pad_tx
    create_bd_port -dir I           pad_clk_rx
    create_bd_port -dir I -from 7 -to 0 pad_rx

    # CoreSight SWD -> PMOD4 (SWDIO IOBUF lives in the board wrapper)
    create_bd_port -dir I           swclk
    create_bd_port -dir I           swd_nporesetn
    create_bd_port -dir I           swdio_i
    create_bd_port -dir O           swdio_o
    create_bd_port -dir O           swdio_oe

    # UART console + status LEDs
    create_bd_port -dir I           uart_rxd
    create_bd_port -dir O           uart_txd
    create_bd_port -dir O           led0
    create_bd_port -dir O           led1

    ###########################################################################
    # PROCESSING SYSTEM (ZynqMP / K26 SOM board preset)
    #   SCOPING-TODO: confirm the exact CONFIG.PSU__* set against a KR260 preset
    #   export; DDR4 + MIO come from apply_board_preset (not PL ports).
    ###########################################################################
    set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP0          {1} \
        CONFIG.PSU__USE__M_AXI_GP1          {0} \
        CONFIG.PSU__USE__M_AXI_GP2          {0} \
        CONFIG.PSU__MAXIGP0__DATA_WIDTH     {32} \
        CONFIG.PSU__USE__IRQ0               {1} \
        CONFIG.PSU__FPGA_PL0_ENABLE         {1} \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
        CONFIG.PSU__NUM_FABRIC_RESETS       {1} \
    ] $ps

    ###########################################################################
    # CLOCKING — 100 MHz PL0_REF -> sys_fclk + phy ref + (200 MHz idelay ref)
    #   KR260 sets USE_IDELAY=0 (HDIO bank 44), but the 200 MHz out is kept for
    #   portability; the eth-chiplet's idelay_ref_clk consumes it harmlessly.
    #   SCOPING-TODO: pick sys_fclk to match the SoC's timing budget on xck26.
    ###########################################################################
    set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ               {100.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000}  \
        CONFIG.CLKOUT1_USED               {true}    \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {25.000}  \
        CONFIG.CLKOUT2_USED               {true}    \
        CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000} \
        CONFIG.CLKOUT3_USED               {true}    \
        CONFIG.NUM_OUT_CLKS               {3}       \
        CONFIG.USE_LOCKED                 {true}    \
        CONFIG.USE_RESET                  {true}    \
        CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
        CONFIG.RESET_PORT                 {resetn}  \
    ] $clk_wiz

    # PHY link/pad clock /2 divider (per-target RTL, added by build_design.tcl)
    set phy_clk_div [create_bd_cell -type module -reference tidelink_phy_clk_div2 phy_clk_div2_0]

    set psr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    ###########################################################################
    # PS -> SoC AHB backdoor: M_AXI_HPM0 -> SmartConnect -> axi_ahblite_bridge
    #   -> nanosoc_eth_chiplet/eth_ss_0. KR260 HPM0 aperture base 0x8000_0000.
    ###########################################################################
    set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] $smc

    set ahb_bridge [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_eth_ss]

    ###########################################################################
    # Role strap AXI-GPIO (bit 0 -> role_strap_i). die_a default 0; the flip
    # target overrides C_DOUT_DEFAULT to 1 (or the PYNQ runtime writes it).
    ###########################################################################
    set strap_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_strap]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH   {1} \
        CONFIG.C_ALL_OUTPUTS  {1} \
        CONFIG.C_DOUT_DEFAULT {0x00000000} \
        CONFIG.C_IS_DUAL      {0} \
    ] $strap_gpio

    ###########################################################################
    # IRQ aggregation: eth / phc_pps / phc_alarm / tidechart -> pl_ps_irq0
    ###########################################################################
    set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
    set_property CONFIG.NUM_PORTS {4} $irq_concat

    ###########################################################################
    # The packaged eth-chiplet IP (whole multicore+ethernet SoC + TideLink)
    ###########################################################################
    set soc [create_bd_cell -type ip -vlnv soclabs.org:user:nanosoc_eth_chiplet_vivado_wrapper:1.0 nanosoc_eth_chiplet_0]

    ###########################################################################
    # CONNECTIONS
    ###########################################################################
    # Clocks
    connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $clk_wiz/clk_in1]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]  [get_bd_pins $soc/sys_fclk]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out2]  [get_bd_pins $phy_clk_div/clk_in]
    connect_bd_net [get_bd_pins $phy_clk_div/clk_out] [get_bd_pins $soc/user_ref_clk]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out3]  [get_bd_pins $soc/idelay_ref_clk]

    # Reset chain: clk_wiz locked -> proc_sys_reset -> sys_sysresetn
    connect_bd_net [get_bd_pins $ps/pl_resetn0]        [get_bd_pins $clk_wiz/resetn]
    connect_bd_net [get_bd_pins $clk_wiz/locked]       [get_bd_pins $psr/dcm_locked]
    connect_bd_net [get_bd_pins $ps/pl_resetn0]        [get_bd_pins $psr/ext_reset_in]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]     [get_bd_pins $psr/slowest_sync_clk]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $soc/sys_sysresetn]

    # PS M_AXI_HPM0 -> SmartConnect -> AHB bridge -> eth_ss_0
    connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $smc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $smc/M00_AXI]       [get_bd_intf_pins $ahb_bridge/AXI4]
    connect_bd_intf_net [get_bd_intf_pins $ahb_bridge/M_AHB]  [get_bd_intf_pins $soc/eth_ss_0]
    # SmartConnect + bridge clocks/resets on the SoC clock (eth_ss_0 domain)
    #   SCOPING-TODO: eth_ss_0 is synchronous to the SoC's INTERNAL hclk (derived
    #   from sys_fclk). If the SoC divides fclk, the bridge must run on sys_hclk
    #   (a chiplet OUTPUT) instead of clk_out1. Wire whichever matches.
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1] [get_bd_pins $smc/aclk]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1] [get_bd_pins $ahb_bridge/s_axi_aclk]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $smc/aresetn]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $ahb_bridge/s_axi_aresetn]

    # Role strap GPIO (its own AXI-Lite off the same SmartConnect would need
    # NUM_MI=2; SCOPING-TODO: add the strap GPIO to the AXI map, or drive
    # role_strap_i from an xlconstant for a fixed-role bring-up).
    connect_bd_net [get_bd_pins $strap_gpio/gpio_io_o] [get_bd_pins $soc/role_strap_i]

    # Interrupts -> concat -> pl_ps_irq0
    connect_bd_net [get_bd_pins $soc/eth_irq]        [get_bd_pins $irq_concat/In0]
    connect_bd_net [get_bd_pins $soc/phc_pps_irq]    [get_bd_pins $irq_concat/In1]
    connect_bd_net [get_bd_pins $soc/phc_alarm_irq]  [get_bd_pins $irq_concat/In2]
    connect_bd_net [get_bd_pins $soc/tidechart_irq]  [get_bd_pins $irq_concat/In3]
    connect_bd_net [get_bd_pins $irq_concat/dout]    [get_bd_pins $ps/pl_ps_irq0]

    # Pads, SWD, UART, LEDs to external ports
    connect_bd_net [get_bd_ports pad_clk_tx] [get_bd_pins $soc/pad_clk_tx]
    connect_bd_net [get_bd_ports pad_tx]     [get_bd_pins $soc/pad_tx]
    connect_bd_net [get_bd_ports pad_clk_rx] [get_bd_pins $soc/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx]     [get_bd_pins $soc/pad_rx]
    connect_bd_net [get_bd_ports swclk]         [get_bd_pins $soc/swclk]
    connect_bd_net [get_bd_ports swd_nporesetn] [get_bd_pins $soc/swd_nporesetn]
    connect_bd_net [get_bd_ports swdio_i]       [get_bd_pins $soc/swdio_i]
    connect_bd_net [get_bd_pins $soc/swdio_o]   [get_bd_ports swdio_o]
    connect_bd_net [get_bd_pins $soc/swdio_oe]  [get_bd_ports swdio_oe]
    connect_bd_net [get_bd_ports uart_rxd]      [get_bd_pins $soc/uart_rxd]
    connect_bd_net [get_bd_pins $soc/uart_txd]  [get_bd_ports uart_txd]
    connect_bd_net [get_bd_pins $soc/link_active]    [get_bd_ports led0]
    connect_bd_net [get_bd_pins $soc/role_is_master] [get_bd_ports led1]

    ###########################################################################
    # ADDRESS MAP — KR260 HPM0 aperture. SCOPING-TODO: confirm the offset/range
    # the firmware expects for the eth_ss_0 backdoor window.
    ###########################################################################
    assign_bd_address -offset 0x80000000 -range 0x40000000 \
        [get_bd_addr_segs {nanosoc_eth_chiplet_0/eth_ss_0/Reg}] -quiet
    assign_bd_address -quiet

    regenerate_bd_layout
    save_bd_design
}
