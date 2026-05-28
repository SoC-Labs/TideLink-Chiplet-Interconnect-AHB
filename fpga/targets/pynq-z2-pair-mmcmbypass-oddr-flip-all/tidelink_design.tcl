###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 Paired GPIO-Bridge Block Design TCL
### (Wave B2, Target A mmcmbypass FLIP variant — single IBUFG+BUFG on pad_clk_rx)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### TARGET A + ODDR FLIP (mmcmbypass-oddr-flip-all variant, 2026-05-28):
###   FLIP mirror of pynq-z2-pair-mmcmbypass-oddr-all. Same two structural
###   changes vs pynq-z2-pair-flip-all:
###     (1) pad_clk_rx routed through single IBUFG+BUFG (tidelink_clk_rx_buf)
###         to cut the slave-side capacitive load (~48 pF -> ~8 pF).
###     (2) pad_clk_tx re-launched through a SAME_EDGE ODDR
###         (tidelink_clk_tx_oddr) so the forwarded clock edge is CENTRED in
###         the pad_tx[*] data eye (UG903 Example Six pattern).
###   Only the XDC pin map differs from the straight (oddr-all) target.
###
###   See docs/UG903_FORWARDED_CLOCKS_AUDIT_2026_05_28.md.
###
###   Pairs with the RTL split USE_CLKBUF -> USE_CAP_CLKBUF + USE_LNK_CLKBUF
###   on feat/target-a-rtl. This BD sets USE_CAP_CLKBUF=0 + USE_LNK_CLKBUF=1
###   on $tl via IPI override.
###
###   See docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md for full diagnosis.
### XDC pin assignments are unchanged from pynq-z2-pair-flip-all (still the
### flip-pair pinout; the 200 Ω external series resistor is on-board and
### can't be removed; this change reduces only the internal load).
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
###   0x4000_0000 .. 0x43FF_FFFF  ahb_sub   (64 MB — transparent chiplet window)
###   0x4400_0000 .. 0x4400_FFFF  ahb_tx    (64 KB — TX aperture, RAM_ADDR_W=14)
###   0x4401_0000 .. 0x4401_FFFF  ahb_fifo  (64 KB — RX FIFO window)
###   0x4402_0000 .. 0x4402_0FFF  ahb_ptp   (4 KB  — PTP TX write port)
###   0x4403_0000 .. 0x4403_7FFF  apb       (32 KB — unified config registers)
###   0x4404_0000 .. 0x4404_0FFF  strap     (4 KB  — AXI GPIO; bit 0 = role_strap_i)
###   0x4404_1000 .. 0x4404_1FFF  dbg_unlk  (4 KB  — AXI GPIO; bit 0 = debug-unlock)
###   0x4404_2000 .. 0x4404_2FFF  pmod_trig (4 KB  — AXI GPIO; PMOD-B trig out+in)
###   0x4405_0000 .. 0x4405_0FFF  phc       (4 KB  — PHC hardware clock APB)
###
### NOTE (PHC integration — 2026-05-22 feat/phc-hw-test, -all mirror 2026-05-23):
###   The PHC hardware clock IP (soclabs.org:user:phc_vivado_wrapper:1.0)
###   replaces the previous xlconstant tie-offs. APB slave on SmartConnect
###   M07; PMOD-B trigger GPIO on M08; pmod_b_trig_i OR'd into PHC
###   hw_capture_0_i alongside tidelink_0/phc_hw_capture. See
###   pynq-z2-pair-all for full rationale and docs/PTP_HW_TEST_PLAN.md §3.1.
###
### NOTE (PMOD-B cross-board trigger):
###   PMOD-B pin 1 (FPGA ball Y16, JB1 on PYNQ-Z2 v1.0) is wired as a
###   board-to-board jumper between the two PYNQ-Z2s. Same pin BOTH driven
###   (output) and sensed (input) via axi_gpio at 0x4404_2000. The signal
###   is OR'd into PHC hw_capture_0_i so the trigger edge latches the local
###   PHC time on both sides simultaneously (Option A, §3.1).
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

    # PMOD-B cross-board trigger (Option A capture mechanism).
    # Bidirectional — same pin is driven AND sensed via an IOBUF in the
    # board wrapper. The BD exposes separate _o (drive) and _i (sense)
    # ports; the board wrapper allocates one PMOD pin to a tristate I/O
    # with the _t = '0' when this board is the trigger driver.
    create_bd_port -dir O           pmod_b_trig_o
    create_bd_port -dir I           pmod_b_trig_i

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
    # SoC Labs §9 structural fix (2026-05-18): CLKOUT3 = 200 MHz added as the
    # IDELAYCTRL reference clock for the per-lane IDELAYE2 RX delay elements
    # (tidelink_idelay_rx, USE_IDELAY=1). One MMCM with three synchronous
    # outputs: 25 / 25 / 200 MHz from a 100 MHz input is well inside the
    # xc7z020-1 MMCM range (VCO settles ~1000 MHz: ÷40→25, ÷5→200). The
    # 200 MHz net is BD-internal so the clk_wiz IP emits its own
    # create_generated_clock — the *_idelay.xdc deliberately adds NO manual
    # create_clock for it (see that file's rationale).
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ              {100.000} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {25.000} \
        CONFIG.CLKOUT1_USED              {true} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {25.000} \
        CONFIG.CLKOUT2_USED              {true} \
        CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000} \
        CONFIG.CLKOUT3_USED              {true} \
        CONFIG.NUM_OUT_CLKS              {3} \
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
    # AXI SmartConnect: 1 PS master -> 9 slaves (PHC integration adds 2 ports)
    #   M00 -> axi_ahb_sub
    #   M01 -> axi_ahb_tx
    #   M02 -> axi_ahb_fifo
    #   M03 -> axi_ahb_ptp
    #   M04 -> axi_apb
    #   M05 -> axi_gpio_strap        (paired-only; selects role_strap_i at runtime)
    #   M06 -> axi_gpio_debug_unlock (debug strap; ungates slave Wlink APB writes)
    #   M07 -> axi_apb_phc           (PHC hardware clock APB)
    #   M08 -> axi_gpio_pmod_trig    (PMOD-B cross-board trigger: out+in)
    #--------------------------------------------------------------------------
    set smc [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    set_property -dict [list \
        CONFIG.NUM_SI   {1} \
        CONFIG.NUM_MI   {9} \
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
    # AXI GPIO — debug-unlock strap (paired-only).
    # Single channel, 1-bit output. POR default 0 (gate active per spec).
    # PYNQ runtime writes 1 via MMIO at 0x4404_1000 to ungate slave Wlink
    # APB writes. Bring-up debug only — production silicon assumes I2C.
    #--------------------------------------------------------------------------
    set dbg_gpio [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_debug_unlock]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH    {1} \
        CONFIG.C_ALL_OUTPUTS   {1} \
        CONFIG.C_DOUT_DEFAULT  {0x00000000} \
        CONFIG.C_IS_DUAL       {0} \
    ] $dbg_gpio

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
    # Target A clk_rx buffer wrapper (2026-05-28).
    # tidelink_clk_rx_buf.v is a tiny Verilog module containing one IBUFG +
    # one BUFG. It sits between the BD port pad_clk_rx and tidelink_0's
    # pad_clk_rx port so the slave-side capacitive load on the forwarded
    # clock pad is reduced from ~48 pF (8 per-lane BUFG inputs inside
    # WavD2DGpio) down to ~8 pF (one IBUFG input).
    #
    # The .v file lives alongside this BD TCL in the target directory;
    # FPGA_TARGET_DIR is exported by fpga/Makefile via build_design.tcl.
    #--------------------------------------------------------------------------
    if { [info exists ::env(FPGA_TARGET_DIR)] } {
        set _tgt_dir $::env(FPGA_TARGET_DIR)
    } else {
        # Fallback for ad-hoc TCL sourcing (no env var set).
        set _tgt_dir [file dirname [info script]]
    }
    set _clk_rx_buf_v [file join $_tgt_dir tidelink_clk_rx_buf.v]
    if { [llength [get_files -quiet $_clk_rx_buf_v]] == 0 } {
        add_files -norecurse $_clk_rx_buf_v
    }
    set _clk_tx_oddr_v [file join $_tgt_dir tidelink_clk_tx_oddr.v]
    if { [llength [get_files -quiet $_clk_tx_oddr_v]] == 0 } {
        add_files -norecurse $_clk_tx_oddr_v
    }
    update_compile_order -fileset sources_1

    set clk_rx_buf [create_bd_cell -type module \
        -reference tidelink_clk_rx_buf clk_rx_buf]

    #--------------------------------------------------------------------------
    # Target A + ODDR clk_tx ODDR wrapper (2026-05-28).
    # tidelink_clk_tx_oddr.v contains a SAME_EDGE ODDR that re-launches the
    # forwarded TX clock so the rising edge of pad_clk_tx is CENTRED in the
    # pad_tx[*] data eye. Per UG903 Example Six (D1=0, D2=1, SAME_EDGE) the
    # output clock is 180° out of phase with clk_in. The BD wires the gated
    # MMCM net out of tidelink_0/pad_clk_tx into clk_tx_oddr/clk_in, and
    # clk_tx_oddr/pad_out drives the BD-level pad_clk_tx port (Y7 master /
    # Y9 slave — flipped vs the straight target).
    #
    # reset is driven by proc_sys_reset_0/peripheral_reset (active-high).
    #--------------------------------------------------------------------------
    set clk_tx_oddr [create_bd_cell -type module \
        -reference tidelink_clk_tx_oddr clk_tx_oddr]

    #--------------------------------------------------------------------------
    # TideLink IP (packaged by Wave A3)
    # VLNV: soclabs.org:user:tidelink_vivado_wrapper:1.0
    #
    # Target A IPI parameter override (2026-05-28):
    #   USE_CAP_CLKBUF=0 — disable per-lane BUFG on io_pad_clk (8x). The BD
    #                     wires a global clock net (BUFG.O of clk_rx_buf) into
    #                     tidelink_0/pad_clk_rx, so per-instance cap BUFGs
    #                     would be illegal BUFG-cascades.
    #   USE_LNK_CLKBUF=1 — keep per-lane BUFG on the derived word clock
    #                     (~adj_count[3]); this fan-out is internal and still
    #                     wants a global clock buffer.
    # USE_IDELAY and USE_T3A retain their IP defaults (both 1'b1 in the
    # packaged component.xml); those features are independent of this change.
    # Both new params require the RTL split landing on feat/target-a-rtl —
    # if the IP is rebuilt without that split, these overrides are silently
    # ignored (component.xml has no matching parameter to override).
    #--------------------------------------------------------------------------
    set tl [create_bd_cell -type ip \
        -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_0]
    set_property -dict [list \
        CONFIG.USE_CAP_CLKBUF {1'b0} \
        CONFIG.USE_LNK_CLKBUF {1'b1} \
    ] $tl

    #--------------------------------------------------------------------------
    # PHC Hardware Clock IP — replaces the old xlconstant tie-offs.
    # APB slave on M07; outputs feed tidelink_0/phc_* inputs; inputs receive
    # tidelink_0/phc_hw_set_* and phc_hw_adj_* (autonomous servo).
    # Address: 4 KB at 0x4405_0000.
    #--------------------------------------------------------------------------
    set phc [create_bd_cell -type ip \
        -vlnv soclabs.org:user:phc_vivado_wrapper:1.0 phc_0]

    #--------------------------------------------------------------------------
    # AXI4-Lite -> APB bridge for the PHC. Separate from the existing apb
    # bridge so the PHC's 12-bit address space is decoded independently of
    # the unified TideLink config bus.
    #--------------------------------------------------------------------------
    set phc_apb_bridge [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb_phc]
    set_property -dict [list \
        CONFIG.C_APB_NUM_SLAVES  {1} \
        CONFIG.C_M_APB_PROTOCOL  {apb4} \
    ] $phc_apb_bridge

    #--------------------------------------------------------------------------
    # PMOD-B cross-board trigger GPIO. Single AXI GPIO, dual-channel.
    #   ch1 (1-bit OUTPUT) drives pmod_b_trig_o (the wire to the peer board).
    #   ch2 (1-bit INPUT)  senses pmod_b_trig_i (incoming from peer board).
    # Host software pulses ch1, the peer reads ch2 and/or its PHC HW_CAP.
    # The pmod_b_trig_i signal is ALSO OR'd into PHC hw_capture_0_i so the
    # local PHC latches its time when the peer pulses (Option A, §3.1).
    #--------------------------------------------------------------------------
    set pmod_gpio [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_pmod_trig]
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH    {1} \
        CONFIG.C_GPIO2_WIDTH   {1} \
        CONFIG.C_ALL_OUTPUTS   {1} \
        CONFIG.C_ALL_INPUTS_2  {1} \
        CONFIG.C_IS_DUAL       {1} \
        CONFIG.C_DOUT_DEFAULT  {0x00000000} \
    ] $pmod_gpio

    #--------------------------------------------------------------------------
    # PHC hw_capture_0_i is OR'd from two sources:
    #   * tidelink_0/phc_hw_capture (TideLink PTP FC handshake)
    #   * pmod_b_trig_i  (cross-board trigger, sense side)
    # Use a 2-input xlconcat + util_reduced_logic (OR) — or simply rely on
    # an xlslice combination. Simplest: xlconcat to gather, util_reduced_logic
    # to OR-reduce.
    #--------------------------------------------------------------------------
    set hw_cap_concat [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_phc_hw_cap]
    set_property -dict [list \
        CONFIG.NUM_PORTS  {2} \
        CONFIG.IN0_WIDTH  {1} \
        CONFIG.IN1_WIDTH  {1} \
    ] $hw_cap_concat

    set hw_cap_or [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:util_reduced_logic:2.0 util_reduced_logic_hw_cap]
    set_property -dict [list \
        CONFIG.C_OPERATION {or} \
        CONFIG.C_SIZE      {2} \
    ] $hw_cap_or

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

    # SoC Labs bring-up patch (2026-05-06, un-tied 2026-05-14):
    # mask_hs_bypass_i was previously tied HIGH; now driven LOW so the
    # autoneg-driven peer-mask handshake gates role_lock. The xlconstant
    # is retained so reverting is a one-line CONFIG.CONST_VAL change.
    # See pynq-z2-pair-all for full rationale and SW prerequisites.
    #
    # REQUIRES PHYSICAL I2C JUMPERS between the two Pynq-Z2 boards (SDA/SCL
    # + GND on the PMOD sideband — see PHYSICAL_WIRING.md). With bypass=0
    # and no jumpers the link HANGS waiting for the peer-mask handshake.
    # Also gated by the autoneg I2C wedge SHORTCOMINGS-14a until that fix
    # lands. Do NOT treat this bitstream as bring-up-ready without the
    # jumpers + 14a.
    set const_mask_bypass [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_mask_hs_bypass]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {1} \
        CONFIG.CONST_VAL   {0} \
    ] $const_mask_bypass

    #--------------------------------------------------------------------------
    # NOTE (2026-05-19): the ila_rx / ila_pad cores that used to probe the
    # raw pad_rx IBUF were REMOVED. They are vestigial — RO APB observability
    # (submodule 250f1cf, Region-8 SWI_LANE_STATUS) replaced them — and they
    # are fundamentally incompatible with the §9 real IDELAYE2 RX delay:
    # IDELAYE2 with DELAY_SRC("IDATAIN") needs the dedicated IBUF->IDELAYE2
    # route, so the pad_rx IBUF cannot also fan into ILA fabric (route_design
    # fails: all 8 pad_rx_IBUF nets unroutable). For an explicit pad-domain
    # ILA build use the dedicated `pynq-z2-pair-ila` target instead.
    #--------------------------------------------------------------------------

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
                   [get_bd_pins axi_apb_phc/s_axi_aclk] \
                   [get_bd_pins axi_gpio_strap/s_axi_aclk] \
                   [get_bd_pins axi_gpio_debug_unlock/s_axi_aclk] \
                   [get_bd_pins axi_gpio_pmod_trig/s_axi_aclk] \
                   [get_bd_pins tidelink_0/hclk] \
                   [get_bd_pins tidelink_0/user_ref_clk] \
                   [get_bd_pins tidelink_0/scan_clk]

    #-- phc_clk: clk_wiz clk_out2 (50 MHz, same MMCM — phase-aligned to hclk)
    #   Drives both the tidelink PHC CDC bridge and the PHC IP itself.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] \
                   [get_bd_pins tidelink_0/phc_clk] \
                   [get_bd_pins phc_0/clk]

    #-- SoC Labs §9 structural fix: clk_wiz clk_out3 (200 MHz) -> IDELAYCTRL
    #   reference clock for the per-lane IDELAYE2 RX delay elements.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] \
                   [get_bd_pins tidelink_0/idelay_ref_clk]

    #-- Reset fan-out (active-low peripheral_aresetn)
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins axi_smc/aresetn] \
                   [get_bd_pins axi_ahb_sub/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_ptp/s_axi_aresetn] \
                   [get_bd_pins axi_apb/s_axi_aresetn] \
                   [get_bd_pins axi_apb_phc/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_strap/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_debug_unlock/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_pmod_trig/s_axi_aresetn] \
                   [get_bd_pins tidelink_0/hresetn] \
                   [get_bd_pins tidelink_0/poresetn] \
                   [get_bd_pins tidelink_0/phc_resetn] \
                   [get_bd_pins phc_0/resetn]

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

    #-- AXI: SmartConnect M06 -> AXI GPIO debug-unlock (1-bit -> apb_debug_unlock_i)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M06_AXI] \
                        [get_bd_intf_pins axi_gpio_debug_unlock/S_AXI]
    connect_bd_net [get_bd_pins axi_gpio_debug_unlock/gpio_io_o] \
                   [get_bd_pins tidelink_0/apb_debug_unlock_i]

    #-- AXI: SmartConnect M07 -> APB bridge -> phc_0/apb
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M07_AXI] \
                        [get_bd_intf_pins axi_apb_phc/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_apb_phc/APB_M] \
                        [get_bd_intf_pins phc_0/apb]

    #-- AXI: SmartConnect M08 -> AXI GPIO PMOD-B trigger (out + sense)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M08_AXI] \
                        [get_bd_intf_pins axi_gpio_pmod_trig/S_AXI]
    connect_bd_net [get_bd_pins axi_gpio_pmod_trig/gpio_io_o] \
                   [get_bd_ports pmod_b_trig_o]
    connect_bd_net [get_bd_ports pmod_b_trig_i] \
                   [get_bd_pins axi_gpio_pmod_trig/gpio2_io_i]

    #-- GPIO PHY pads -> external ports
    #-- pad_clk_tx routing (Target A + ODDR, 2026-05-28):
    #--   tidelink_0/pad_clk_tx -> clk_tx_oddr/clk_in (SAME_EDGE ODDR D1=0 D2=1)
    #--   -> clk_tx_oddr/pad_out -> pad_clk_tx (port)
    #-- This re-launches the forwarded TX clock CENTRE-aligned to pad_tx[*].
    #-- See tidelink_clk_tx_oddr.v in this target dir.
    connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_pins clk_tx_oddr/clk_in]
    connect_bd_net [get_bd_pins clk_tx_oddr/pad_out]   [get_bd_ports pad_clk_tx]
    # Tie ODDR reset low via xlconstant — ODDR INIT=1'b0 already provides POR
    # state. Avoids depending on proc_sys_reset_0/peripheral_reset pin name.
    set _const_zero_tx [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_tx_oddr]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $_const_zero_tx
    connect_bd_net [get_bd_pins const_zero_tx_oddr/dout] [get_bd_pins clk_tx_oddr/reset]
    connect_bd_net [get_bd_pins tidelink_0/pad_tx]     [get_bd_ports pad_tx]

    #-- pad_clk_rx routing (Target A, 2026-05-28):
    #--   pad_clk_rx (port) -> clk_rx_buf/pad_in (IBUFG) -> BUFG ->
    #--   clk_rx_buf/clk_out -> tidelink_0/pad_clk_rx
    #-- See tidelink_clk_rx_buf.v in this target dir and the IPI override
    #-- on $tl (USE_CAP_CLKBUF=0) above.
    connect_bd_net [get_bd_ports pad_clk_rx]           [get_bd_pins clk_rx_buf/pad_in]
    connect_bd_net [get_bd_pins clk_rx_buf/clk_out]    [get_bd_pins tidelink_0/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx]                [get_bd_pins tidelink_0/pad_rx]

    #-- (ila_rx / ila_pad probes removed 2026-05-19 — see NOTE above; the
    #--  raw-pad ILA is incompatible with the real IDELAYE2 IDATAIN route.
    #--  RO APB SWI_LANE_STATUS is the observability path now.)

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

    #-- PHC IP <-> tidelink_0 wiring (replaces former xlconstant tie-offs)
    #
    # Counter outputs: PHC -> tidelink (HW sync initiator timing + PPS)
    connect_bd_net [get_bd_pins phc_0/nanoseconds_o] \
                   [get_bd_pins tidelink_0/phc_nanoseconds]
    connect_bd_net [get_bd_pins phc_0/seconds_o] \
                   [get_bd_pins tidelink_0/phc_seconds]
    connect_bd_net [get_bd_pins phc_0/pps_o] \
                   [get_bd_pins tidelink_0/phc_pps]

    # HW capture readouts: PHC -> tidelink
    connect_bd_net [get_bd_pins phc_0/hw_cap_seconds_0_o] \
                   [get_bd_pins tidelink_0/phc_hw_cap_seconds]
    connect_bd_net [get_bd_pins phc_0/hw_cap_nanoseconds_0_o] \
                   [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds]
    connect_bd_net [get_bd_pins phc_0/hw_cap_sub_nanoseconds_0_o] \
                   [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds]

    # Servo phase-step + frequency-steer: tidelink -> PHC
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_time] \
                   [get_bd_pins phc_0/hw_set_time_0_i]
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_seconds] \
                   [get_bd_pins phc_0/hw_set_seconds_0_i]
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_set_nanoseconds] \
                   [get_bd_pins phc_0/hw_set_nanoseconds_0_i]
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_valid] \
                   [get_bd_pins phc_0/hw_adj_valid_0_i]
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_adj_ns_incr_frac] \
                   [get_bd_pins phc_0/hw_adj_ns_incr_frac_0_i]

    # hw_capture_0_i = tidelink_0/phc_hw_capture OR pmod_b_trig_i
    connect_bd_net [get_bd_pins tidelink_0/phc_hw_capture] \
                   [get_bd_pins xlconcat_phc_hw_cap/In0]
    connect_bd_net [get_bd_ports pmod_b_trig_i] \
                   [get_bd_pins xlconcat_phc_hw_cap/In1]
    connect_bd_net [get_bd_pins xlconcat_phc_hw_cap/dout] \
                   [get_bd_pins util_reduced_logic_hw_cap/Op1]
    connect_bd_net [get_bd_pins util_reduced_logic_hw_cap/Res] \
                   [get_bd_pins phc_0/hw_capture_0_i]

    #-- Misc tie-offs (discrete scalar 1-bit values handled in wrapper,
    #   but multi-bit constants are easier as xlconstant in the BD)
    connect_bd_net [get_bd_pins xlconst_nego_priority/dout] \
                   [get_bd_pins tidelink_0/nego_priority_i]
    connect_bd_net [get_bd_pins xlconst_puf_seed/dout] \
                   [get_bd_pins tidelink_0/puf_seed]
    connect_bd_net [get_bd_pins xlconst_mask_hs_bypass/dout] \
                   [get_bd_pins tidelink_0/mask_hs_bypass_i]

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

    # debug-unlock GPIO: 4 KB at 0x4404_1000 (paired-only)
    assign_bd_address -offset 0x44041000 -range 0x00001000 \
        [get_bd_addr_segs {axi_gpio_debug_unlock/S_AXI/Reg}]

    # pmod-trig GPIO: 4 KB at 0x4404_2000 (cross-board trigger out+in)
    assign_bd_address -offset 0x44042000 -range 0x00001000 \
        [get_bd_addr_segs {axi_gpio_pmod_trig/S_AXI/Reg}]

    # phc apb: 4 KB at 0x4405_0000 (APB_ADDR_W=12)
    assign_bd_address -offset 0x44050000 -range 0x00001000 \
        [get_bd_addr_segs {phc_0/apb/Reg}]

    ###########################################################################
    # VALIDATE AND SAVE
    ###########################################################################
    regenerate_bd_layout
    validate_bd_design
    save_bd_design

    current_bd_instance $oldCurInst
}
