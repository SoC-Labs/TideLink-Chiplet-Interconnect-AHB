###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge — ARM MPS3 Block Design TCL
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Creates a Vivado block design for the ARM MPS3 (Kintex UltraScale
### xcku115-flvb1760-1-c) containing:
###
###   - Clocking Wizard: 24 MHz OSCCLK[0] -> 50 MHz hclk (TideLink app clock)
###   - Processor System Reset: synchronised to 50 MHz domain, driven by PB1
###   - JTAG-AXI Master: bring-up path — operator drives MMIO from Vivado
###     Hardware Manager / xsdb.  Converts JTAG transactions to AXI4-Lite, then
###     routed through an AXI-to-AHB bridge to feed the TideLink AHB slave ports.
###   - AXI SmartConnect: routes the JTAG-AXI master to all TideLink AHB bridges
###     according to the address map below.
###   - 5 x AXI-to-AHB-Lite bridges (axi_ahblite_bridge:3.0):
###       axi_ahb_sub   -> ahb_sub   (chiplet access path, 32-bit addr)
###       axi_ahb_tx    -> ahb_tx    (TX FIFO aperture, 14-bit addr)
###       axi_ahb_fifo  -> ahb_fifo  (RX FIFO read window, 14-bit addr)
###       axi_ahb_ptp   -> ahb_ptp   (PTP TX write port, 4-bit addr)
###       axi_ahb_apb   -> apb       (APB config bus via AXI-APB bridge)
###   - AXI-APB bridge: converts AXI4-Lite to APB for the unified config slave.
###   - Constant IP: strap register at 0x4404_0000 tied to 0 (single-node MPS3).
###   - TideLink IP: soclabs.org:user:tidelink_vivado_wrapper:1.0
###
### NOTE: MPS3 has no Zynq PS. This design has NO processing_system7 / DDR /
###       FIXED_IO. The JTAG-AXI master is the sole bus initiator for first
###       bring-up. For production use, an external CPU (e.g. Cortex-M55 via
###       the Corstone-300 Cortex-M bitstream image loaded in addition) should
###       replace the JTAG-AXI master.
###
### Address map (32-bit, from JTAG-AXI master):
###   0x4000_0000  ahb_sub   (4 GB aperture; addr translator scopes remotely)
###   0x4400_0000  ahb_tx    (16 KB TX FIFO aperture)
###   0x4400_4000  ahb_fifo  (16 KB RX FIFO read window)
###   0x4400_8000  ahb_ptp   (16 B  PTP TX write port)
###   0x4401_0000  apb       (24 KB APB config: Wlink/TideLink/addr-translator)
###   0x4404_0000  strap_reg (4 B   Constant 0x00000000 — single-node unpaired)
###
### Usage:
###   source tidelink_design.tcl
###   create_root_design ""
###-----------------------------------------------------------------------------

###################################################################
# CREATE ROOT DESIGN
###################################################################
proc create_root_design { parentCell } {

    variable script_folder

    if { $parentCell eq "" } {
        set parentCell [get_bd_cells /]
    }

    set parentObj [get_bd_cells $parentCell]
    if { $parentObj == "" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" \
               "Unable to find parent cell <$parentCell>!"}
        return
    }

    set parentType [get_property TYPE $parentObj]
    if { $parentType ne "hier" } {
        catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" \
               "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
        return
    }

    set oldCurInst [current_bd_instance .]
    current_bd_instance $parentObj

    ###################################################################
    # EXTERNAL PORTS — board-level I/O visible at the BD boundary.
    # The board wrapper (tidelink_design_wrapper.v) connects these to
    # the actual FPGA pins via the XDC pin assignments.
    ###################################################################

    # Board oscillator + reset
    create_bd_port -dir I         OSCCLK       ;# 24 MHz fixed (AL15, LVCMOS18)
    create_bd_port -dir I         nrst         ;# USER_nPB[0] active-low (AT30)

    # TideLink GPIO PHY pads — 18 discrete I/O signals
    #   pad_clk_tx  : TX clock output  (1 pin)
    #   pad_tx[7:0] : TX data output   (8 pins)
    #   pad_clk_rx  : RX clock input   (1 pin)
    #   pad_rx[7:0] : RX data input    (8 pins)
    # Total = 18 PHY pins; assigned to FPGA-IO connector in the XDC.
    # TODO: Confirm physical pin assignments on the MPS3 FPGA-IO connector.
    create_bd_port -dir O         pad_clk_tx
    create_bd_port -dir O -from 7 -to 0  pad_tx
    create_bd_port -dir I         pad_clk_rx
    create_bd_port -dir I -from 7 -to 0  pad_rx

    # I2C sideband — board wrapper handles IOBUF
    create_bd_port -dir I         i2c_scl_i
    create_bd_port -dir O         i2c_scl_o
    create_bd_port -dir O         i2c_scl_t
    create_bd_port -dir I         i2c_sda_i
    create_bd_port -dir O         i2c_sda_o
    create_bd_port -dir O         i2c_sda_t

    # Link status / IRQ outputs for board LEDs
    # 9 TideLink IRQ outputs routed to available MPS3 user LEDs.
    # Unused LED slots driven low in the wrapper.
    create_bd_port -dir O         released_credits_irq
    create_bd_port -dir O         doorbell_irq
    create_bd_port -dir O         packet_committed_irq
    create_bd_port -dir O         ptp_irq
    create_bd_port -dir O         perf_irq
    create_bd_port -dir O         wlink_irq
    create_bd_port -dir O         nego_error_irq
    create_bd_port -dir O         i2c_nbsy_irq
    create_bd_port -dir O         i2c_nrd_empty_irq

    # Link active / D2D reset status
    create_bd_port -dir O         link_active
    create_bd_port -dir O         d2d_reset_o

    ###################################################################
    # CREATE IP INSTANCES
    ###################################################################

    #------------------------------------------------------------------
    # Clocking Wizard: 24 MHz OSCCLK[0] -> 50 MHz hclk
    #
    # 50 MHz is the natural TideLink application clock. The 24 MHz
    # OSCCLK[0] (AL15 — GC-capable site on xcku115) is the only
    # reliable fixed-rate clock on the MPS3 board and requires the
    # Clocking Wizard to generate 50 MHz. Vivado will use an MMCM.
    # TODO: Verify 50 MHz is achievable from 24 MHz on xcku115 with
    # acceptable jitter for the link PHY timing budget.
    #------------------------------------------------------------------
    set clk_wiz_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ      {24.000}  \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000}  \
        CONFIG.CLKOUT1_USED      {true}    \
        CONFIG.USE_LOCKED        {true}    \
        CONFIG.USE_RESET         {true}    \
        CONFIG.RESET_TYPE        {ACTIVE_LOW} \
        CONFIG.RESET_PORT        {resetn}  \
    ] $clk_wiz_0

    #------------------------------------------------------------------
    # Processor System Reset — synchronised to 50 MHz hclk domain
    # Reset source: PB1 (USER_nPB[0], active-low)
    #------------------------------------------------------------------
    set proc_sys_reset_0 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    #------------------------------------------------------------------
    # JTAG-AXI master (bring-up path)
    #
    # Provides AXI4-Lite master access from Vivado Hardware Manager /
    # xsdb over the JTAG cable. The operator drives MMIO reads/writes
    # directly from the host without any soft-core in the bitstream.
    # Protocol: AXI4-Lite 32-bit. Clock: hclk from clk_wiz_0.
    #
    # To use from xsdb:
    #   connect; targets -set -filter {name =~ "FPGA*"}
    #   source open_hw_target...  (see README.md)
    #   mwr 0x44000000 0xDEADBEEF   ;# AHB write through ahb_sub
    #   mrd 0x44010000             ;# APB config read
    #
    # Note: JTAG-AXI throughput is ~1 MB/s — adequate for register
    # bring-up but not for data-path stress testing.
    #------------------------------------------------------------------
    set jtag_axi_0 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0]
    set_property -dict [list \
        CONFIG.M_HAS_BURST {0} \
    ] $jtag_axi_0

    #------------------------------------------------------------------
    # AXI SmartConnect: fan-out from JTAG-AXI to 6 downstream slaves
    # (5 AXI-AHB bridges + 1 AXI-APB bridge for the APB config slave)
    # plus 1 AXI constant for the strap register.
    # Use SmartConnect rather than AXI Interconnect for better
    # resource utilisation on UltraScale.
    #------------------------------------------------------------------
    set axi_smc_0 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_0]
    set_property -dict [list \
        CONFIG.NUM_SI {1} \
        CONFIG.NUM_MI {7} \
    ] $axi_smc_0

    #------------------------------------------------------------------
    # AXI-to-AHB-Lite bridges (one per TideLink AHB slave port)
    # Vivado ships axi_ahblite_bridge:3.0 in the standard IP catalog.
    # Each bridge converts the SmartConnect AXI4-Lite output to the
    # AHB-Lite signals consumed by tidelink_vivado_wrapper.
    #------------------------------------------------------------------

    # Bridge 0: ahb_sub — chiplet access path (full 32-bit address range)
    set axi_ahb_sub [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_sub]
    set_property -dict [list \
        CONFIG.C_S_AXI_ADDR_WIDTH {32} \
        CONFIG.C_S_AXI_DATA_WIDTH {32} \
    ] $axi_ahb_sub

    # Bridge 1: ahb_tx — TX FIFO aperture (14-bit AHB address)
    set axi_ahb_tx [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_tx]
    set_property -dict [list \
        CONFIG.C_S_AXI_ADDR_WIDTH {14} \
        CONFIG.C_S_AXI_DATA_WIDTH {32} \
    ] $axi_ahb_tx

    # Bridge 2: ahb_fifo — RX FIFO read window (14-bit AHB address)
    set axi_ahb_fifo [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_fifo]
    set_property -dict [list \
        CONFIG.C_S_AXI_ADDR_WIDTH {14} \
        CONFIG.C_S_AXI_DATA_WIDTH {32} \
    ] $axi_ahb_fifo

    # Bridge 3: ahb_ptp — PTP TX write port (4-bit AHB address)
    set axi_ahb_ptp [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_ptp]
    set_property -dict [list \
        CONFIG.C_S_AXI_ADDR_WIDTH {4} \
        CONFIG.C_S_AXI_DATA_WIDTH {32} \
    ] $axi_ahb_ptp

    # Bridge 4: ahb_mng slave — AHB manager from remote chiplet needs a
    # target to write into.  For single-board bring-up, a 4 KB BRAM block
    # satisfies any incoming manager transfers without hanging.
    # NOTE: On a real deployment this would be the local SoC memory map;
    # leave as BRAM placeholder for MPS3 bring-up.
    set axi_bram_ctrl_mng [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_bram_ctrl:4.0 axi_bram_ctrl_mng]
    set_property -dict [list \
        CONFIG.SINGLE_PORT_BRAM {1} \
        CONFIG.DATA_WIDTH {32}      \
    ] $axi_bram_ctrl_mng
    set bram_mng [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:emb_mem_gen:1.0 bram_mng]

    #------------------------------------------------------------------
    # AXI-APB bridge: AXI4-Lite (from SmartConnect) -> APB (to TideLink
    # unified config slave: Wlink / TideLink / addr-translator registers)
    #------------------------------------------------------------------
    set axi_apb_bridge_0 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb_bridge_0]
    set_property -dict [list \
        CONFIG.C_APB_NUM_SLAVES {1} \
        CONFIG.C_S_AXI_ADDR_WIDTH {15} \
    ] $axi_apb_bridge_0

    #------------------------------------------------------------------
    # AXI Constant (strap register) at 0x4404_0000
    # Tied to 0x00000000 — single-node, unpaired MPS3 bring-up.
    # The strap value is read by software to distinguish paired vs
    # single configurations (same address as Z2-pair for runtime compat).
    # TODO: Determine if a strap register is needed for single-board use.
    # A Constant IP mapping to read-only 0 is the simplest safe option.
    #------------------------------------------------------------------
    set axi_const_strap [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_gpio:2.0 axi_const_strap]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH {32} \
        CONFIG.C_DOUT_DEFAULT {0x00000000} \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_IS_DUAL {0} \
    ] $axi_const_strap

    #------------------------------------------------------------------
    # TideLink IP
    # VLNV must match the output of fpga/vivado_ip/package_tidelink_ip.tcl:
    #   vendor  = soclabs.org  (FPGA_VENDOR env)
    #   library = user
    #   name    = tidelink_vivado_wrapper
    #   version = 1.0  (FPGA_CORE_REV=1 => version string 1.0)
    #------------------------------------------------------------------
    set tidelink_ip_0 [create_bd_cell -type ip \
        -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_ip_0]
    set_property -dict [list \
        CONFIG.TIDELINK_PAIR_BASE {0x00000000} \
        CONFIG.PHC_LOCK_GATE_EN   {0}          \
    ] $tidelink_ip_0

    ###################################################################
    # CONNECTIONS
    ###################################################################

    #------------------------------------------------------------------
    # Clock tree
    # OSCCLK (24 MHz) -> clk_wiz_0 -> 50 MHz hclk
    #------------------------------------------------------------------
    connect_bd_net [get_bd_ports OSCCLK] \
                   [get_bd_pins clk_wiz_0/clk_in1]

    # 50 MHz system clock fans out to everything
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                   [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
                   [get_bd_pins jtag_axi_0/aclk] \
                   [get_bd_pins axi_smc_0/aclk] \
                   [get_bd_pins axi_ahb_sub/s_axi_aclk] \
                   [get_bd_pins axi_ahb_tx/s_axi_aclk] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aclk] \
                   [get_bd_pins axi_ahb_ptp/s_axi_aclk] \
                   [get_bd_pins axi_apb_bridge_0/s_axi_aclk] \
                   [get_bd_pins axi_bram_ctrl_mng/s_axi_aclk] \
                   [get_bd_pins axi_const_strap/s_axi_aclk] \
                   [get_bd_pins tidelink_ip_0/hclk] \
                   [get_bd_pins tidelink_ip_0/phc_clk]

    #------------------------------------------------------------------
    # Reset tree
    # PB1 (nrst, active-low) -> clk_wiz resetn + proc_sys_reset ext_reset
    # clk_wiz locked -> proc_sys_reset dcm_locked
    # proc_sys_reset peripheral_aresetn -> everything
    #------------------------------------------------------------------
    connect_bd_net [get_bd_ports nrst] \
                   [get_bd_pins clk_wiz_0/resetn] \
                   [get_bd_pins proc_sys_reset_0/ext_reset_in]

    connect_bd_net [get_bd_pins clk_wiz_0/locked] \
                   [get_bd_pins proc_sys_reset_0/dcm_locked]

    # Active-low peripheral reset fans out to all IP
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins jtag_axi_0/aresetn] \
                   [get_bd_pins axi_smc_0/aresetn] \
                   [get_bd_pins axi_ahb_sub/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_ptp/s_axi_aresetn] \
                   [get_bd_pins axi_apb_bridge_0/s_axi_aresetn] \
                   [get_bd_pins axi_bram_ctrl_mng/s_axi_aresetn] \
                   [get_bd_pins axi_const_strap/s_axi_aresetn] \
                   [get_bd_pins tidelink_ip_0/hresetn] \
                   [get_bd_pins tidelink_ip_0/poresetn] \
                   [get_bd_pins tidelink_ip_0/phc_resetn]

    #------------------------------------------------------------------
    # AXI fabric: JTAG-AXI -> SmartConnect -> 7 downstream slaves
    # SmartConnect M00..M06 -> bridges + strap
    #------------------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] \
                        [get_bd_intf_pins axi_smc_0/S00_AXI]

    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M00_AXI] \
                        [get_bd_intf_pins axi_ahb_sub/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M01_AXI] \
                        [get_bd_intf_pins axi_ahb_tx/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M02_AXI] \
                        [get_bd_intf_pins axi_ahb_fifo/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M03_AXI] \
                        [get_bd_intf_pins axi_ahb_ptp/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M04_AXI] \
                        [get_bd_intf_pins axi_apb_bridge_0/AXI4_LITE_PCI]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M05_AXI] \
                        [get_bd_intf_pins axi_const_strap/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_0/M06_AXI] \
                        [get_bd_intf_pins axi_bram_ctrl_mng/S_AXI]

    #------------------------------------------------------------------
    # AHB: bridges -> TideLink AHB slave ports
    #------------------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_sub/AHB_MASTER] \
                        [get_bd_intf_pins tidelink_ip_0/ahb_sub]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_tx/AHB_MASTER] \
                        [get_bd_intf_pins tidelink_ip_0/ahb_tx]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_fifo/AHB_MASTER] \
                        [get_bd_intf_pins tidelink_ip_0/ahb_fifo]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_ptp/AHB_MASTER] \
                        [get_bd_intf_pins tidelink_ip_0/ahb_ptp]

    #------------------------------------------------------------------
    # APB: AXI-APB bridge -> TideLink APB config slave
    #------------------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins axi_apb_bridge_0/APB_M] \
                        [get_bd_intf_pins tidelink_ip_0/apb]

    #------------------------------------------------------------------
    # BRAM for ahb_mng slave target
    #------------------------------------------------------------------
    connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_mng/BRAM_PORTA] \
                        [get_bd_intf_pins bram_mng/BRAM_PORTA]

    # TideLink ahb_mng master -> BRAM via dedicated SmartConnect slot
    # (re-use M06 which already goes to axi_bram_ctrl_mng above)
    # The ahb_mng master port is an AHB master from TideLink — wrap with
    # AHB-to-AXI (ahblite_axi_bridge) so it can reach the SmartConnect.
    # TODO: Add ahblite_axi_bridge for the ahb_mng master path if
    # incoming chiplet transfers need to write local memory. For first
    # bring-up, leave ahb_mng disconnected or tied off:
    set_property CONFIG.POLARITY {ACTIVE_LOW} \
        [get_bd_ports nrst]

    #------------------------------------------------------------------
    # AXI-Stream TideChart ports — tie off for bare MPS3 bring-up.
    # No TideChart agent present; tc_axis_tx consumed by /dev/null
    # (tready=1), tc_axis_rx drives nothing (tvalid=0).
    #------------------------------------------------------------------
    # Create constant cells for tie-offs
    set tc_tx_tready_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 tc_tx_tready_const]
    set_property CONFIG.CONST_VAL {1} $tc_tx_tready_const
    set_property CONFIG.CONST_WIDTH {1} $tc_tx_tready_const

    set tc_rx_tvalid_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 tc_rx_tvalid_const]
    set_property CONFIG.CONST_VAL {0} $tc_rx_tvalid_const
    set_property CONFIG.CONST_WIDTH {1} $tc_rx_tvalid_const

    set tc_rx_tdata_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 tc_rx_tdata_const]
    set_property CONFIG.CONST_VAL {0} $tc_rx_tdata_const
    set_property CONFIG.CONST_WIDTH {48} $tc_rx_tdata_const

    connect_bd_net [get_bd_pins tc_tx_tready_const/dout] \
                   [get_bd_pins tidelink_ip_0/tc_axis_tx_tready]
    connect_bd_net [get_bd_pins tc_rx_tvalid_const/dout] \
                   [get_bd_pins tidelink_ip_0/tc_axis_rx_tvalid]
    connect_bd_net [get_bd_pins tc_rx_tdata_const/dout] \
                   [get_bd_pins tidelink_ip_0/tc_axis_rx_tdata]

    # TideChart tx signals (from tidelink_ip_0) — not consumed, left dangling
    # (Vivado leaves unconnected outputs warning-free as long as they are outputs)

    #------------------------------------------------------------------
    # PHC interface tie-offs — MPS3 does not have a dedicated PTP TCXO.
    # All PHC inputs driven to known-good constants; phc_clk reuses hclk.
    #------------------------------------------------------------------
    set phc_ns_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 phc_ns_const]
    set_property CONFIG.CONST_VAL  {0} $phc_ns_const
    set_property CONFIG.CONST_WIDTH {30} $phc_ns_const

    set phc_sec_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 phc_sec_const]
    set_property CONFIG.CONST_VAL  {0} $phc_sec_const
    set_property CONFIG.CONST_WIDTH {48} $phc_sec_const

    set phc_pps_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 phc_pps_const]
    set_property CONFIG.CONST_VAL  {0} $phc_pps_const
    set_property CONFIG.CONST_WIDTH {1} $phc_pps_const

    set phc_locked_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 phc_locked_const]
    set_property CONFIG.CONST_VAL  {1} $phc_locked_const
    set_property CONFIG.CONST_WIDTH {1} $phc_locked_const

    set phc_cap_sub_ns_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 phc_cap_sub_ns_const]
    set_property CONFIG.CONST_VAL  {0} $phc_cap_sub_ns_const
    set_property CONFIG.CONST_WIDTH {32} $phc_cap_sub_ns_const

    connect_bd_net [get_bd_pins phc_ns_const/dout]         [get_bd_pins tidelink_ip_0/phc_nanoseconds]
    connect_bd_net [get_bd_pins phc_sec_const/dout]        [get_bd_pins tidelink_ip_0/phc_seconds]
    connect_bd_net [get_bd_pins phc_pps_const/dout]        [get_bd_pins tidelink_ip_0/phc_pps]
    connect_bd_net [get_bd_pins phc_ns_const/dout]         [get_bd_pins tidelink_ip_0/phc_hw_cap_nanoseconds]
    connect_bd_net [get_bd_pins phc_sec_const/dout]        [get_bd_pins tidelink_ip_0/phc_hw_cap_seconds]
    connect_bd_net [get_bd_pins phc_cap_sub_ns_const/dout] [get_bd_pins tidelink_ip_0/phc_hw_cap_sub_nanoseconds]
    connect_bd_net [get_bd_pins phc_locked_const/dout]     [get_bd_pins tidelink_ip_0/phc_locked_i]

    #------------------------------------------------------------------
    # Miscellaneous tie-offs for role / negotiation / PUF / scan
    #------------------------------------------------------------------
    set role_strap_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 role_strap_const]
    set_property CONFIG.CONST_VAL  {0} $role_strap_const
    set_property CONFIG.CONST_WIDTH {1} $role_strap_const

    set nego_pri_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 nego_pri_const]
    set_property CONFIG.CONST_VAL  {0} $nego_pri_const
    set_property CONFIG.CONST_WIDTH {16} $nego_pri_const

    set puf_seed_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 puf_seed_const]
    set_property CONFIG.CONST_VAL  {0} $puf_seed_const
    set_property CONFIG.CONST_WIDTH {16} $puf_seed_const

    set puf_ready_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 puf_ready_const]
    set_property CONFIG.CONST_VAL  {1} $puf_ready_const
    set_property CONFIG.CONST_WIDTH {1} $puf_ready_const

    set tc_qos_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 tc_qos_const]
    set_property CONFIG.CONST_VAL  {0} $tc_qos_const
    set_property CONFIG.CONST_WIDTH {3} $tc_qos_const

    set tl_bcast_ack_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 tl_bcast_ack_const]
    set_property CONFIG.CONST_VAL  {0} $tl_bcast_ack_const
    set_property CONFIG.CONST_WIDTH {1} $tl_bcast_ack_const

    set scan_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 scan_const]
    set_property CONFIG.CONST_VAL  {0} $scan_const
    set_property CONFIG.CONST_WIDTH {1} $scan_const

    set user_ref_clk_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 user_ref_clk_const]
    set_property CONFIG.CONST_VAL  {0} $user_ref_clk_const
    set_property CONFIG.CONST_WIDTH {1} $user_ref_clk_const

    connect_bd_net [get_bd_pins role_strap_const/dout]   [get_bd_pins tidelink_ip_0/role_strap_i]
    connect_bd_net [get_bd_pins nego_pri_const/dout]      [get_bd_pins tidelink_ip_0/nego_priority_i]
    connect_bd_net [get_bd_pins puf_seed_const/dout]      [get_bd_pins tidelink_ip_0/puf_seed]
    connect_bd_net [get_bd_pins puf_ready_const/dout]     [get_bd_pins tidelink_ip_0/puf_ready]
    connect_bd_net [get_bd_pins tc_qos_const/dout]        [get_bd_pins tidelink_ip_0/tc_qos_priority]
    connect_bd_net [get_bd_pins tl_bcast_ack_const/dout]  [get_bd_pins tidelink_ip_0/tl_bcast_ack_i]
    connect_bd_net [get_bd_pins scan_const/dout]          [get_bd_pins tidelink_ip_0/scan_mode] \
                                                          [get_bd_pins tidelink_ip_0/scan_asyncrst_ctrl] \
                                                          [get_bd_pins tidelink_ip_0/scan_clk] \
                                                          [get_bd_pins tidelink_ip_0/scan_shift] \
                                                          [get_bd_pins tidelink_ip_0/scan_in]
    connect_bd_net [get_bd_pins user_ref_clk_const/dout]  [get_bd_pins tidelink_ip_0/user_ref_clk]

    # I2C AXI slave tie-offs (no I2C master CPU on MPS3 bring-up)
    set i2c_axi_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_const
    set_property CONFIG.CONST_WIDTH {1} $i2c_axi_const

    connect_bd_net [get_bd_pins i2c_axi_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awvalid] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_wvalid] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_bready] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arvalid] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_rready] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awlock] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_wlast] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arlock]

    set i2c_axi_data_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_data_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_data_const
    set_property CONFIG.CONST_WIDTH {32} $i2c_axi_data_const

    connect_bd_net [get_bd_pins i2c_axi_data_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_wdata] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_hrdata]

    set i2c_axi_4b_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_4b_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_4b_const
    set_property CONFIG.CONST_WIDTH {4} $i2c_axi_4b_const

    connect_bd_net [get_bd_pins i2c_axi_4b_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awaddr] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_araddr] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_wstrb]

    set i2c_axi_2b_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_2b_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_2b_const
    set_property CONFIG.CONST_WIDTH {2} $i2c_axi_2b_const

    connect_bd_net [get_bd_pins i2c_axi_2b_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awid] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arid] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awburst] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arburst]

    set i2c_axi_3b_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_3b_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_3b_const
    set_property CONFIG.CONST_WIDTH {3} $i2c_axi_3b_const

    connect_bd_net [get_bd_pins i2c_axi_3b_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awsize] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arsize]

    set i2c_axi_8b_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_8b_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_8b_const
    set_property CONFIG.CONST_WIDTH {8} $i2c_axi_8b_const

    connect_bd_net [get_bd_pins i2c_axi_8b_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awlen] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arlen]

    set i2c_axi_cache_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_cache_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_cache_const
    set_property CONFIG.CONST_WIDTH {4} $i2c_axi_cache_const

    connect_bd_net [get_bd_pins i2c_axi_cache_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awcache] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arcache]

    set i2c_axi_prot_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 i2c_axi_prot_const]
    set_property CONFIG.CONST_VAL  {0} $i2c_axi_prot_const
    set_property CONFIG.CONST_WIDTH {3} $i2c_axi_prot_const

    connect_bd_net [get_bd_pins i2c_axi_prot_const/dout] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_awprot] \
                   [get_bd_pins tidelink_ip_0/s_i2c_axi_arprot]

    # ahb_mng HRDATA / HRESP (responses from BRAM slave, wired to ahb_mng)
    # Tie-off hresp for bring-up (no error response generation needed)
    set ahb_mng_hresp_const [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 ahb_mng_hresp_const]
    set_property CONFIG.CONST_VAL  {0} $ahb_mng_hresp_const
    set_property CONFIG.CONST_WIDTH {1} $ahb_mng_hresp_const

    connect_bd_net [get_bd_pins ahb_mng_hresp_const/dout] \
                   [get_bd_pins tidelink_ip_0/ahb_mng_hresp]

    #------------------------------------------------------------------
    # PHY pad ports — pass through to BD external ports
    #------------------------------------------------------------------
    connect_bd_net [get_bd_pins tidelink_ip_0/pad_clk_tx] \
                   [get_bd_ports pad_clk_tx]
    connect_bd_net [get_bd_pins tidelink_ip_0/pad_tx] \
                   [get_bd_ports pad_tx]
    connect_bd_net [get_bd_ports pad_clk_rx] \
                   [get_bd_pins tidelink_ip_0/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx] \
                   [get_bd_pins tidelink_ip_0/pad_rx]

    #------------------------------------------------------------------
    # I2C sideband port pass-through
    #------------------------------------------------------------------
    connect_bd_net [get_bd_ports i2c_scl_i] [get_bd_pins tidelink_ip_0/i2c_scl_i]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_scl_o] [get_bd_ports i2c_scl_o]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_scl_t] [get_bd_ports i2c_scl_t]
    connect_bd_net [get_bd_ports i2c_sda_i] [get_bd_pins tidelink_ip_0/i2c_sda_i]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_sda_o] [get_bd_ports i2c_sda_o]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_sda_t] [get_bd_ports i2c_sda_t]

    #------------------------------------------------------------------
    # IRQ / status outputs -> BD external ports (routed to LEDs in wrapper)
    #------------------------------------------------------------------
    connect_bd_net [get_bd_pins tidelink_ip_0/released_credits_irq] \
                   [get_bd_ports released_credits_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/doorbell_irq] \
                   [get_bd_ports doorbell_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/packet_committed_irq] \
                   [get_bd_ports packet_committed_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/ptp_irq] \
                   [get_bd_ports ptp_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/perf_irq] \
                   [get_bd_ports perf_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/wlink_irq] \
                   [get_bd_ports wlink_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/nego_error_irq] \
                   [get_bd_ports nego_error_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_nbsy_irq] \
                   [get_bd_ports i2c_nbsy_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/i2c_nrd_empty_irq] \
                   [get_bd_ports i2c_nrd_empty_irq]
    connect_bd_net [get_bd_pins tidelink_ip_0/link_active] \
                   [get_bd_ports link_active]
    connect_bd_net [get_bd_pins tidelink_ip_0/d2d_reset_o] \
                   [get_bd_ports d2d_reset_o]

    ###################################################################
    # ADDRESS EDITOR
    # Assign AXI addresses for the SmartConnect slave segments.
    # These offsets are fixed by the TideLink runtime convention.
    ###################################################################
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_ahb_sub/AXI4_LITE/Reg]   \
        -range 0x10000000 -offset 0x40000000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_ahb_tx/AXI4_LITE/Reg]    \
        -range 0x00004000 -offset 0x44000000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_ahb_fifo/AXI4_LITE/Reg]  \
        -range 0x00004000 -offset 0x44004000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_ahb_ptp/AXI4_LITE/Reg]   \
        -range 0x00000010 -offset 0x44008000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_apb_bridge_0/AXI4_LITE_PCI/Reg] \
        -range 0x00006000 -offset 0x44010000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_const_strap/S_AXI/Reg]   \
        -range 0x00001000 -offset 0x44040000
    assign_bd_address -target_address_space /jtag_axi_0/Data \
        [get_bd_addr_segs axi_bram_ctrl_mng/S_AXI/Mem0] \
        -range 0x00001000 -offset 0x44050000

    ###################################################################
    # VALIDATE AND SAVE
    ###################################################################
    validate_bd_design
    save_bd_design

    current_bd_instance $oldCurInst
}
