###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 Paired GPIO-Bridge Block Design TCL (Wave B2)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Creates a Vivado block design named "tidelink_design" for the Pynq-Z2
### (Zynq XC7Z020CLG400-1) in paired configuration. The same bitstream
### programs both boards in a TideLink GPIO-bridge pair; role is selected
### at runtime via an AXI GPIO at 0x4404_0000 (bit 0 = role_strap_i).
### The PYNQ runtime reads $FPGAHUB_LOCAL_ROLE (injected by fpgahub when
### the action runs against a paired board) and writes:
###   $FPGAHUB_LOCAL_ROLE == "die_a"  -> strap = 0 (slave)
###   $FPGAHUB_LOCAL_ROLE == "die_b"  -> strap = 1 (master)
###
### Design contents (vs single-instance: + 1 AXI GPIO for the strap):
###   - Zynq PS7 (FCLK_CLK0=100MHz, M_AXI_GP0 enabled, IRQ_F2P[5:0])
###   - Clocking Wizard (100 MHz -> 50 MHz; one MMCM, two sync outputs)
###   - Processor System Reset (synchronised to 50 MHz domain)
###   - AXI SmartConnect (1 master, 7 slaves — extra port for axi_gpio_strap)
###   - 4x AXI4-Lite -> AHB-Lite bridges (ahb_sub, ahb_tx, ahb_fifo, ahb_ptp)
###   - 1x AXI4-Lite -> APB bridge (apb config)
###   - 1x AXI GPIO (1-bit output -> tidelink_0/role_strap_i)
###   - 1x xlconcat (IRQ aggregator -> PS IRQ_F2P[5:0])
###   - TideLink IP (soclabs.org:user:tidelink_vivado_wrapper:1.0)
###
### Address map (PS7 M_AXI_GP0 address space):
###   0x4000_0000 .. 0x43FF_FFFF  ahb_sub  (64 MB — transparent chiplet window)
###   0x4400_0000 .. 0x4400_FFFF  ahb_tx   (64 KB  — TX aperture, RAM_ADDR_W=14)
###   0x4401_0000 .. 0x4401_FFFF  ahb_fifo (64 KB  — RX FIFO window)
###   0x4402_0000 .. 0x4402_0FFF  ahb_ptp  (4 KB   — PTP TX write port)
###   0x4403_0000 .. 0x4403_7FFF  apb      (32 KB  — unified config registers)
###   0x4404_0000 .. 0x4404_0FFF  strap    (4 KB   — AXI GPIO; bit 0 = role_strap_i)
###
### NOTE (Q4 / PHC tie-off):
###   For first bring-up the PHC interface is driven by tie-off constants:
###     phc_clk         = clk_wiz 50 MHz output (shared with hclk)
###     phc_resetn      = proc_sys_reset peripheral_aresetn
###     phc_nanoseconds = 30'h0  (zeros — no free-running counter in BD)
###     phc_seconds     = 48'h0
###     phc_pps         = 1'b0
###     phc_hw_cap_*    = 0
###     phc_locked_i    = 1'b0
###   A proper PHC IP instance will replace these in Q4 once
###   ptp-hardware-clock-ahb is integrated.
###
### NOTE (role_strap_i):
###   Driven by an AXI GPIO at 0x4404_0000 (bit 0). The PYNQ runtime
###   selects role at boot from the FPGAHUB_LOCAL_ROLE env var that
###   fpgahub injects into the action subprocess (die_a -> 0, die_b -> 1).
###
### NOTE (ahb_mng):
###   The AHB manager port (incoming from remote chiplet) is left unconnected
###   in this single-instance target. The bridge stub is omitted — ahb_mng
###   will float or be tied off in the wrapper. Wire to a BlockRAM in a
###   future revision once the paired target validates the manager path.
###
### NOTE (tc_axis_tx / tc_axis_rx):
###   TideChart AXI-Stream ports are tied off in the board wrapper:
###     tc_axis_tx_tvalid = 1'b0
###     tc_axis_tx_tdata  = 48'h0
###     tc_axis_rx_tready = 1'b1
###   (The IP handles these via discrete ports, not IPI bus interfaces.)
###
### NOTE (I2C / scan ports):
###   I2C sideband and DFT scan ports are tied off in the board wrapper.
###-----------------------------------------------------------------------------

proc create_root_design { parentCell } {

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

    ###########################################################################
    # CREATE EXTERNAL PORTS
    ###########################################################################

    # GPIO PHY pads — wired to Raspberry Pi header (see XDC)
    create_bd_port -dir O           pad_clk_tx
    create_bd_port -dir O -from 7 -to 0 pad_tx
    create_bd_port -dir I           pad_clk_rx
    create_bd_port -dir I -from 7 -to 0 pad_rx

    # Board LEDs (accent green, active-high)
    create_bd_port -dir O           led0
    create_bd_port -dir O           led1
    create_bd_port -dir O           led2
    create_bd_port -dir O           led3

    # DDR3 and Fixed IO (Zynq PS pass-through)
    create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
    create_bd_intf_port -mode Master \
        -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO

    ###########################################################################
    # CREATE IP INSTANCES
    ###########################################################################

    #--------------------------------------------------------------------------
    # Zynq Processing System 7
    # FCLK_CLK0 = 100 MHz feeds the Clocking Wizard.
    # M_AXI_GP0 is the PL fabric master (PYNQ MMIO).
    # IRQ_F2P[5:0] connected to xlconcat output for 6 TideLink IRQs.
    #--------------------------------------------------------------------------
    set ps7 [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]
    set_property -dict [list \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
        CONFIG.PCW_FPGA_FCLK0_ENABLE        {1} \
        CONFIG.PCW_EN_CLK0_PORT             {1} \
        CONFIG.PCW_EN_RST0_PORT             {1} \
        CONFIG.PCW_USE_M_AXI_GP0            {1} \
        CONFIG.PCW_USE_FABRIC_INTERRUPT     {1} \
        CONFIG.PCW_IRQ_F2P_INTR            {1} \
        CONFIG.PCW_UART0_PERIPHERAL_ENABLE  {1} \
        CONFIG.PCW_UART0_UART0_IO          {MIO 14 .. 15} \
        CONFIG.PCW_EN_UART0                {1} \
        CONFIG.PCW_UART0_BAUD_RATE         {115200} \
        CONFIG.PCW_UIPARAM_DDR_PARTNO      {MT41K256M16 RE-125} \
        CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3 (Low Voltage)} \
    ] $ps7

    #--------------------------------------------------------------------------
    # Clocking Wizard: 100 MHz -> 50 MHz
    # Single MMCM, two synchronous outputs both at 50 MHz:
    #   clk_out1 = hclk   (AHB/APB domain, SmartConnect, IP)
    #   clk_out2 = phc_clk (shared with hclk for first bring-up; no CDC issue
    #              because both outputs are phase-aligned from the same MMCM)
    # Active-low reset (resetn) from PS FCLK_RESET0_N.
    #--------------------------------------------------------------------------
    set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ              {100.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
        CONFIG.CLKOUT1_USED              {true} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {50.000} \
        CONFIG.CLKOUT2_USED              {true} \
        CONFIG.USE_LOCKED                {true} \
        CONFIG.USE_RESET                 {true} \
        CONFIG.RESET_TYPE                {ACTIVE_LOW} \
        CONFIG.RESET_PORT                {resetn} \
    ] $clk_wiz

    #--------------------------------------------------------------------------
    # Processor System Reset — synchronised to 50 MHz (hclk) domain.
    # peripheral_aresetn drives hresetn, poresetn, and phc_resetn on the IP.
    #--------------------------------------------------------------------------
    set psr [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    #--------------------------------------------------------------------------
    # AXI SmartConnect: 1 PS master -> 6 slaves (paired adds the strap GPIO)
    #   M00 -> axi_ahb_sub
    #   M01 -> axi_ahb_tx
    #   M02 -> axi_ahb_fifo
    #   M03 -> axi_ahb_ptp
    #   M04 -> axi_apb
    #   M05 -> axi_gpio_strap   (paired-only; selects role_strap_i at runtime)
    #--------------------------------------------------------------------------
    set smc [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    set_property -dict [list \
        CONFIG.NUM_SI   {1} \
        CONFIG.NUM_MI   {6} \
        CONFIG.NUM_CLKS {1} \
    ] $smc

    #--------------------------------------------------------------------------
    # AXI4-Lite -> AHB-Lite bridges (one per AHB slave port)
    # axi_ahblite_bridge:3.0 bus-interface names:
    #   slave  = AXI4
    #   master = M_AHB
    #--------------------------------------------------------------------------
    set ahb_sub_bridge [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_sub]

    set ahb_tx_bridge  [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_tx]

    set ahb_fifo_bridge [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_fifo]

    set ahb_ptp_bridge [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_ptp]

    #--------------------------------------------------------------------------
    # AXI4-Lite -> APB bridge (unified config registers)
    # C_M_APB_PROTOCOL=apb4 enables PPROT and PSTRB (needed for correct
    # TideLink APB register behaviour).
    # axi_apb_bridge:3.0 bus-interface names:
    #   slave  = AXI4_LITE
    #   master = APB_M
    #--------------------------------------------------------------------------
    set apb_bridge [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb]
    set_property -dict [list \
        CONFIG.C_APB_NUM_SLAVES  {1} \
        CONFIG.C_M_APB_PROTOCOL  {apb4} \
    ] $apb_bridge

    #--------------------------------------------------------------------------
    # AXI GPIO — runtime role-strap register (paired-only).
    # Single channel, 1-bit output. Default value 0 (slave/die_a).
    # PYNQ runtime writes 0 or 1 via MMIO at 0x4404_0000:
    #   bit 0 = role_strap_i (drives tidelink_0/role_strap_i)
    #--------------------------------------------------------------------------
    set strap_gpio [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_strap]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH    {1} \
        CONFIG.C_ALL_OUTPUTS   {1} \
        CONFIG.C_DOUT_DEFAULT  {0x00000000} \
        CONFIG.C_IS_DUAL       {0} \
    ] $strap_gpio

    #--------------------------------------------------------------------------
    # IRQ Concat: 6 TideLink interrupts -> PS IRQ_F2P[5:0]
    # Bit order (MSB first as Vivado xlconcat connects MSB to highest IRQ):
    #   In5 = wlink_irq           (IRQ_F2P[5])
    #   In4 = perf_irq            (IRQ_F2P[4])
    #   In3 = ptp_irq             (IRQ_F2P[3])
    #   In2 = packet_committed_irq (IRQ_F2P[2])
    #   In1 = doorbell_irq        (IRQ_F2P[1])
    #   In0 = released_credits_irq (IRQ_F2P[0])
    #--------------------------------------------------------------------------
    set irq_concat [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
    set_property -dict [list \
        CONFIG.NUM_PORTS {6} \
    ] $irq_concat

    #--------------------------------------------------------------------------
    # TideLink IP (packaged by Wave A3)
    # VLNV: soclabs.org:user:tidelink_vivado_wrapper:1.0
    #--------------------------------------------------------------------------
    set tl [create_bd_cell -type ip \
        -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_0]

    # Discrete tie-offs via xlconstant cells
    # PHC nanoseconds (30-bit zero)
    set const_ns [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_ns]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {30} \
        CONFIG.CONST_VAL   {0} \
    ] $const_ns

    # PHC seconds (48-bit zero)
    set const_sec [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_sec]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {48} \
        CONFIG.CONST_VAL   {0} \
    ] $const_sec

    # PHC hw_cap_seconds (48-bit zero)
    set const_cap_sec [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_cap_sec]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {48} \
        CONFIG.CONST_VAL   {0} \
    ] $const_cap_sec

    # PHC hw_cap_nanoseconds (30-bit zero)
    set const_cap_ns [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_cap_ns]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {30} \
        CONFIG.CONST_VAL   {0} \
    ] $const_cap_ns

    # PHC hw_cap_sub_nanoseconds (32-bit zero)
    set const_cap_subns [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_cap_subns]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {32} \
        CONFIG.CONST_VAL   {0} \
    ] $const_cap_subns

    # nego_priority_i (16-bit mid-priority = 0x8000)
    set const_nego [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_nego_priority]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {16} \
        CONFIG.CONST_VAL   {32768} \
    ] $const_nego

    # puf_seed (16-bit = 0xA5A5 = 42405)
    set const_puf_seed [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_puf_seed]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {16} \
        CONFIG.CONST_VAL   {42405} \
    ] $const_puf_seed

    #--------------------------------------------------------------------------
    # ILA — capture pad_clk_rx + pad_rx[7:0] (signals coming FROM the slave).
    # Sampled in the local hclk (50 MHz) domain; the goal is to see whether
    # the slave's pad_tx pins are alive (toggling, stuck high, stuck low,
    # floating) on the master's RX pads.
    #
    # Clock = pad_clk_rx itself (the recovered clock from the slave). If the
    # slave's pad_clk_tx is dead, this domain will be too — which is itself
    # the diagnostic. We connect pad_clk_rx to ILA's clk through a BUFG so
    # Vivado sees it as a real clock; pad_rx[7:0] is the 8-bit data probe.
    # If pad_clk_rx is dead, the ILA never samples — try the second ILA on
    # the hclk (50 MHz) domain to capture the raw pin value asynchronously.
    #--------------------------------------------------------------------------
    set ila_rx [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_rx]
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES   {2} \
        CONFIG.C_PROBE0_WIDTH    {1} \
        CONFIG.C_PROBE1_WIDTH    {8} \
        CONFIG.C_DATA_DEPTH      {4096} \
        CONFIG.C_INPUT_PIPE_STAGES {2} \
        CONFIG.C_EN_STRG_QUAL    {0} \
        CONFIG.ALL_PROBE_SAME_MU {true} \
        CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
        CONFIG.C_TRIGOUT_EN      {false} \
        CONFIG.C_TRIGIN_EN       {false} \
        CONFIG.C_ADV_TRIGGER     {false} \
    ] $ila_rx

    # Second ILA in the hclk (50 MHz) domain — captures pad_clk_rx as data
    # so we can see whether the pad is even toggling at all.
    set ila_pad [create_bd_cell -type ip -vlnv xilinx.com:ip:ila:6.2 ila_pad]
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES   {2} \
        CONFIG.C_PROBE0_WIDTH    {1} \
        CONFIG.C_PROBE1_WIDTH    {8} \
        CONFIG.C_DATA_DEPTH      {4096} \
        CONFIG.C_INPUT_PIPE_STAGES {2} \
        CONFIG.C_EN_STRG_QUAL    {0} \
        CONFIG.ALL_PROBE_SAME_MU {true} \
        CONFIG.ALL_PROBE_SAME_MU_CNT {2} \
        CONFIG.C_TRIGOUT_EN      {false} \
        CONFIG.C_TRIGIN_EN       {false} \
        CONFIG.C_ADV_TRIGGER     {false} \
    ] $ila_pad

    ###########################################################################
    # CONNECTIONS
    ###########################################################################

    #-- PS DDR and Fixed IO pass-through
    connect_bd_intf_net [get_bd_intf_ports DDR]      [get_bd_intf_pins processing_system7_0/DDR]
    connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins processing_system7_0/FIXED_IO]

    #-- Clock: PS FCLK_CLK0 (100 MHz) -> clk_wiz input
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
                   [get_bd_pins clk_wiz_0/clk_in1]

    #-- Reset: PS FCLK_RESET0_N -> clk_wiz resetn and proc_sys_reset ext_reset_in
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
                   [get_bd_pins clk_wiz_0/resetn] \
                   [get_bd_pins proc_sys_reset_0/ext_reset_in]

    #-- clk_wiz locked -> proc_sys_reset dcm_locked
    connect_bd_net [get_bd_pins clk_wiz_0/locked] \
                   [get_bd_pins proc_sys_reset_0/dcm_locked]

    #-- Clock fan-out: clk_wiz clk_out1 (50 MHz hclk) drives all logic
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                   [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
                   [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
                   [get_bd_pins axi_smc/aclk] \
                   [get_bd_pins axi_ahb_sub/s_axi_aclk] \
                   [get_bd_pins axi_ahb_tx/s_axi_aclk] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aclk] \
                   [get_bd_pins axi_ahb_ptp/s_axi_aclk] \
                   [get_bd_pins axi_apb/s_axi_aclk] \
                   [get_bd_pins axi_gpio_strap/s_axi_aclk] \
                   [get_bd_pins tidelink_0/hclk] \
                   [get_bd_pins tidelink_0/user_ref_clk] \
                   [get_bd_pins tidelink_0/scan_clk] \
                   [get_bd_pins tidelink_0/idelay_ref_clk]

    #-- phc_clk: clk_wiz clk_out2 (50 MHz, same MMCM — phase-aligned to hclk)
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] \
                   [get_bd_pins tidelink_0/phc_clk]

    #-- Reset fan-out (active-low peripheral_aresetn)
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins axi_smc/aresetn] \
                   [get_bd_pins axi_ahb_sub/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_ptp/s_axi_aresetn] \
                   [get_bd_pins axi_apb/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_strap/s_axi_aresetn] \
                   [get_bd_pins tidelink_0/hresetn] \
                   [get_bd_pins tidelink_0/poresetn] \
                   [get_bd_pins tidelink_0/phc_resetn]

    #-- AXI: PS M_AXI_GP0 -> SmartConnect slave
    connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                        [get_bd_intf_pins axi_smc/S00_AXI]

    #-- AXI: SmartConnect M00 -> AHB sub bridge -> tidelink ahb_sub
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                        [get_bd_intf_pins axi_ahb_sub/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_sub/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_sub]

    #-- AXI: SmartConnect M01 -> AHB tx bridge -> tidelink ahb_tx
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] \
                        [get_bd_intf_pins axi_ahb_tx/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_tx/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_tx]

    #-- AXI: SmartConnect M02 -> AHB fifo bridge -> tidelink ahb_fifo
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] \
                        [get_bd_intf_pins axi_ahb_fifo/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_fifo/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_fifo]

    #-- AXI: SmartConnect M03 -> AHB ptp bridge -> tidelink ahb_ptp
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] \
                        [get_bd_intf_pins axi_ahb_ptp/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_ptp/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_ptp]

    #-- AXI: SmartConnect M04 -> APB bridge -> tidelink apb
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] \
                        [get_bd_intf_pins axi_apb/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_apb/APB_M] \
                        [get_bd_intf_pins tidelink_0/apb]

    #-- AXI: SmartConnect M05 -> AXI GPIO strap (1-bit -> role_strap_i)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] \
                        [get_bd_intf_pins axi_gpio_strap/S_AXI]
    connect_bd_net [get_bd_pins axi_gpio_strap/gpio_io_o] \
                   [get_bd_pins tidelink_0/role_strap_i]

    #-- GPIO PHY pads -> external ports (with ILA taps on RX side)
    connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_ports pad_clk_tx]
    connect_bd_net [get_bd_pins tidelink_0/pad_tx]     [get_bd_ports pad_tx]
    connect_bd_net [get_bd_ports pad_clk_rx]            [get_bd_pins tidelink_0/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx]                [get_bd_pins tidelink_0/pad_rx]

    #-- ILA probes
    # ila_rx samples in the recovered-clock domain. Clock = pad_clk_rx
    # (taps the same external port). Probe0 = pad_clk_rx (1-bit, mostly
    # for trigger reference), probe1 = pad_rx[7:0].
    connect_bd_net [get_bd_ports pad_clk_rx] [get_bd_pins ila_rx/clk]
    connect_bd_net [get_bd_ports pad_clk_rx] [get_bd_pins ila_rx/probe0]
    connect_bd_net [get_bd_ports pad_rx]      [get_bd_pins ila_rx/probe1]

    # ila_pad samples in the local hclk (50 MHz) domain — survives even
    # when pad_clk_rx is dead. Lets us see the raw pin level / toggling.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] [get_bd_pins ila_pad/clk]
    connect_bd_net [get_bd_ports pad_clk_rx]         [get_bd_pins ila_pad/probe0]
    connect_bd_net [get_bd_ports pad_rx]              [get_bd_pins ila_pad/probe1]

    #-- LEDs -> external ports
    #   led0 = link_active    (lit when D2D link is up)
    #   led1 = role_is_master (lit when this node is master)
    #   led2 = wlink_irq      (blinks on Wlink PHY events)
    #   led3 = released_credits_irq (blinks on credit release)
    connect_bd_net [get_bd_pins tidelink_0/link_active]          [get_bd_ports led0]
    connect_bd_net [get_bd_pins tidelink_0/role_is_master_o]     [get_bd_ports led1]
    connect_bd_net [get_bd_pins tidelink_0/wlink_irq]            [get_bd_ports led2]
    connect_bd_net [get_bd_pins tidelink_0/released_credits_irq] [get_bd_ports led3]

    #-- IRQ Concat -> PS IRQ_F2P[5:0]
    #   IRQ_F2P bit assignment (xlconcat In[N] -> IRQ_F2P[N]):
    #     In0 = released_credits_irq -> IRQ_F2P[0]
    #     In1 = doorbell_irq         -> IRQ_F2P[1]
    #     In2 = packet_committed_irq -> IRQ_F2P[2]
    #     In3 = ptp_irq              -> IRQ_F2P[3]
    #     In4 = perf_irq             -> IRQ_F2P[4]
    #     In5 = wlink_irq            -> IRQ_F2P[5]
    connect_bd_net [get_bd_pins tidelink_0/released_credits_irq] \
                   [get_bd_pins xlconcat_irq/In0]
    connect_bd_net [get_bd_pins tidelink_0/doorbell_irq] \
                   [get_bd_pins xlconcat_irq/In1]
    connect_bd_net [get_bd_pins tidelink_0/packet_committed_irq] \
                   [get_bd_pins xlconcat_irq/In2]
    connect_bd_net [get_bd_pins tidelink_0/ptp_irq] \
                   [get_bd_pins xlconcat_irq/In3]
    connect_bd_net [get_bd_pins tidelink_0/perf_irq] \
                   [get_bd_pins xlconcat_irq/In4]
    connect_bd_net [get_bd_pins tidelink_0/wlink_irq] \
                   [get_bd_pins xlconcat_irq/In5]

    connect_bd_net [get_bd_pins xlconcat_irq/dout] \
                   [get_bd_pins processing_system7_0/IRQ_F2P]

    #-- PHC tie-offs (first bring-up — Q4 to replace with PHC IP)
    connect_bd_net [get_bd_pins xlconst_phc_ns/dout]      [get_bd_pins tidelink_0/phc_nanoseconds]
    connect_bd_net [get_bd_pins xlconst_phc_sec/dout]     [get_bd_pins tidelink_0/phc_seconds]
    connect_bd_net [get_bd_pins xlconst_phc_cap_sec/dout] [get_bd_pins tidelink_0/phc_hw_cap_seconds]
    connect_bd_net [get_bd_pins xlconst_phc_cap_ns/dout]  [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds]
    connect_bd_net [get_bd_pins xlconst_phc_cap_subns/dout] \
                   [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds]

    #-- Misc tie-offs (discrete scalar 1-bit values handled in wrapper,
    #   but multi-bit constants are easier as xlconstant in the BD)
    connect_bd_net [get_bd_pins xlconst_nego_priority/dout] \
                   [get_bd_pins tidelink_0/nego_priority_i]
    connect_bd_net [get_bd_pins xlconst_puf_seed/dout] \
                   [get_bd_pins tidelink_0/puf_seed]

    ###########################################################################
    # ADDRESS MAP
    #
    # Offset and range assigned within the PS7 M_AXI_GP0 (32-bit) space.
    # Vivado SmartConnect requires power-of-two ranges >= 4 KB.
    #
    #   ahb_sub  : 0x4000_0000   64 MB — transparent chiplet data window
    #   ahb_tx   : 0x4400_0000   64 KB — TX aperture (RAM_ADDR_W=14)
    #   ahb_fifo : 0x4401_0000   64 KB — RX FIFO window
    #   ahb_ptp  : 0x4402_0000    4 KB — PTP TX write port (16 B internal)
    #   apb      : 0x4403_0000   32 KB — unified config registers (15-bit PADDR)
    ###########################################################################

    # ahb_sub: 256 MB window starting at 0x4000_0000
    # ahb_sub: 64 MB at 0x4000_0000 (covers 0x4000_0000 .. 0x43FF_FFFF;
    # the next slave at 0x4400_0000 is intentionally just past this region).
    assign_bd_address -offset 0x40000000 -range 0x04000000 \
        [get_bd_addr_segs {tidelink_0/ahb_sub/Reg}]

    # ahb_tx: 64 KB at 0x4400_0000
    assign_bd_address -offset 0x44000000 -range 0x00010000 \
        [get_bd_addr_segs {tidelink_0/ahb_tx/Reg}]

    # ahb_fifo: 64 KB at 0x4401_0000
    assign_bd_address -offset 0x44010000 -range 0x00010000 \
        [get_bd_addr_segs {tidelink_0/ahb_fifo/Reg}]

    # ahb_ptp: 4 KB at 0x4402_0000 (internal decode is 4 bits / 16 B)
    assign_bd_address -offset 0x44020000 -range 0x00001000 \
        [get_bd_addr_segs {tidelink_0/ahb_ptp/Reg}]

    # apb: 32 KB at 0x4403_0000 (covers 15-bit PADDR = 32 KB)
    assign_bd_address -offset 0x44030000 -range 0x00008000 \
        [get_bd_addr_segs {tidelink_0/apb/Reg}]

    # strap GPIO: 4 KB at 0x4404_0000 (paired-only)
    assign_bd_address -offset 0x44040000 -range 0x00001000 \
        [get_bd_addr_segs {axi_gpio_strap/S_AXI/Reg}]

    ###########################################################################
    # VALIDATE AND SAVE
    ###########################################################################
    regenerate_bd_layout
    validate_bd_design
    save_bd_design

    current_bd_instance $oldCurInst
}
