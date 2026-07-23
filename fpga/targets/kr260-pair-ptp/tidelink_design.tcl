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
### Address map — GP1 control/data-path split (2026-06-12, ARCH_ANALYSIS §4):
###
###   The high-rate data apertures (ahb_tx, ahb_fifo) ride PS7 M_AXI_GP1 in
###   their OWN ordering domain so a backpressured/wedged AHB_TX write can no
###   longer stall control-plane (APB) polls behind it on GP0. Zynq-7000 GP
###   master windows are HARD (GP0 = 0x4000_0000..0x7FFF_FFFF, GP1 =
###   0x8000_0000..0xBFFF_FFFF), so the data apertures RELOCATE:
###   *** NEW DATA ADDRESSES: aperture = old + 0x4000_0000 ***
###
### PS7 M_AXI_GP0 address space (control plane + low-rate paths — unchanged):
###   0x4000_0000 .. 0x43FF_FFFF  ahb_sub   (64 MB — transparent chiplet window)
###   0x4402_0000 .. 0x4402_0FFF  ahb_ptp   (4 KB  — PTP TX write port)
###   0x4403_0000 .. 0x4403_7FFF  apb       (32 KB — unified config registers)
###   0x4404_0000 .. 0x4404_0FFF  strap     (4 KB  — AXI GPIO; bit 0 = role_strap_i)
###   0x4404_1000 .. 0x4404_1FFF  dbg_unlk  (4 KB  — AXI GPIO; bit 0 = debug-unlock)
###   0x4404_2000 .. 0x4404_2FFF  pmod_trig (4 KB  — AXI GPIO; PMOD-B trig out+in)
###   0x4405_0000 .. 0x4405_0FFF  phc       (4 KB  — PHC hardware clock APB)
###
### PS7 M_AXI_GP1 address space (data plane — RELOCATED, was 0x4400_xxxx):
###   0x8400_0000 .. 0x8400_FFFF  ahb_tx    (64 KB — TX aperture, RAM_ADDR_W=14)
###   0x8401_0000 .. 0x8401_FFFF  ahb_fifo  (64 KB — RX FIFO window)
###
### NOTE (GP1 split residual): ahb_sub stays on GP0 — its full address is
###   forwarded over the link for peer-side decode, so relocating it to the
###   GP1 window would change the forwarded address bits (NOT a BD-only
###   change) and break the 0x4000_0000 peer-aperture contract everywhere.
###   A wedged ahb_sub access can therefore still stall GP0; the bench
###   wedge/backpressure path (AHB_TX, T6 class) is fully isolated.
###   Host scripts: export TIDELINK_TX_BASE=0x84000000 and
###   TIDELINK_RXFIFO_BASE=0x84010000 against bitstreams built from this BD
###   (defaults remain the old 0x4400_0000/0x4401_0000 for old bitstreams).
###
### NOTE (PHC integration — 2026-05-22 feat/phc-hw-test, -all mirror 2026-05-23):
###   The PHC hardware clock IP (soclabs.org:user:phc_vivado_wrapper:1.0,
###   packaged from ~/SoCLabs/ptp-hardware-clock-ahb by fpga/vivado_ip/phc)
###   is instantiated in this BD and replaces the previous xlconstant
###   tie-offs. Connections:
###     phc_clk           = clk_wiz clk_out1 (25 MHz, == hclk; R1 fix 2026-07-17,
###                         was clk_out2 which resolved to a near-identical 24.955
###                         MHz and created 1673 false hclk<->phc_clk crossings)
###     phc_resetn        = proc_sys_reset peripheral_aresetn
###     phc/apb           = AXI SmartConnect M05 -> axi_apb_bridge -> phc.apb
###     hw_capture_0_i    = tidelink_0/phc_hw_capture OR pmod_b_trig_i  (one-shot OR)
###     hw_cap_*_0_o      -> tidelink_0/phc_hw_cap_*
###     hw_set_*_0_i      <- tidelink_0/phc_hw_set_*  (servo phase step)
###     hw_adj_*_0_i      <- tidelink_0/phc_hw_adj_*  (servo freq steer)
###     seconds_o / nanoseconds_o -> tidelink_0/phc_seconds, phc_nanoseconds
###     pps_o             -> tidelink_0/phc_pps
###     pps_irq / alarm_irq  -> aggregated alongside ptp_irq (future expansion)
###   The default NS_INCR (4) is for 250 MHz ASIC silicon. FPGA bring-up
###   scripts MUST program NS_INCR=20 before CTRL.EN — see
###   docs/PTP_HW_TEST_PLAN.md §7 R2.
###
### NOTE (PMOD-B cross-board trigger):
###   PMOD-B pin 1 (FPGA ball Y16, JB1 on PYNQ-Z2 v1.0) is wired as a
###   board-to-board jumper between the two PYNQ-Z2s. The same pin is BOTH
###   driven (output) and sensed (input) via an axi_gpio at 0x4404_2000 —
###   one board pulses, the other captures. The signal is ALSO OR'd into the
###   PHC's hw_capture_0_i so the trigger edge latches the local PHC time on
###   both sides simultaneously. See docs/PTP_HW_TEST_PLAN.md §3.1 (Option A).
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

    # Inter-board I2C sideband (BD Edit 1, SHORTCOMINGS-14a/14b) — expose
    # the chiplet's I2C tristate pins as external BD ports so the board
    # wrapper can IOBUF them onto J13 W9/V7. Mirrors the proven mps3
    # target (tidelink_ip_0 -> here tidelink_0). Previously the pins were
    # left unconnected (Vivado default); no constant driver existed, so
    # this is purely additive (no tie-off removed, no double-drive).
    create_bd_port -dir I           i2c_scl_i
    create_bd_port -dir O           i2c_scl_o
    create_bd_port -dir O           i2c_scl_t
    create_bd_port -dir I           i2c_sda_i
    create_bd_port -dir O           i2c_sda_o
    create_bd_port -dir O           i2c_sda_t

    # Board LEDs (accent green, active-high)
    create_bd_port -dir O           led0
    create_bd_port -dir O           led1
    create_bd_port -dir O           led2
    create_bd_port -dir O           led3

    # PMOD-B cross-board trigger + PHC subsystem REMOVED (2026-06-19) to free
    # ~97%-packed xc7z020 slices so phys_opt_design can place the critical
    # RX-capture net. The link/PHY/Wlink datapath is untouched. See the PHC
    # NOTE block above (kept for historical reference only).

    # KR260 (Zynq UltraScale+ / K26 SOM): the PS DDR4 + MIO are driven by the
    # zynq_ultra_ps_e board preset and are NOT brought out as PL wrapper ports
    # (the Z2 PS7 DDR/FIXED_IO pass-through does not exist on MPSoC).

    # PTP inclusion gate. FPGA_TIDELINK_PTP=1 (set per-target in fpga/Makefile)
    # instantiates the PHC hardware clock (soclabs.org:user:phc_vivado_wrapper)
    # + its APB bridge + the ahb_ptp TX-write port; otherwise the tidelink_0
    # phc_* inputs are tied to zero (link-only, no live PTP time base). One BD
    # tcl serves both the -ptp and -nptp targets so they never drift.
    set tl_ptp [expr {[info exists ::env(FPGA_TIDELINK_PTP)] && $::env(FPGA_TIDELINK_PTP) == 1}]
    puts "TideLink KR260 BD: PTP (PHC hardware clock) = $tl_ptp"

    ###########################################################################
    # CREATE IP INSTANCES
    ###########################################################################

    #--------------------------------------------------------------------------
    # Zynq UltraScale+ Processing System (KR260 / K26 SOM).
    # DDR4 + MIO come from the KR260 board preset (apply_board_preset needs the
    # BOARD_PART set on the project — done in fpga/build_design.tcl from
    # FPGA_BOARD_PART). We then override only the PL-facing config:
    #   pl_clk0  = 100 MHz  -> feeds the Clocking Wizard (as FCLK_CLK0 did).
    #   M_AXI_HPM0_LPD = control-plane master (APB/config/GPIO), 0x8000_0000 win.
    #   M_AXI_HPM0_FPD = data-plane master (ahb_tx + ahb_fifo),  0xA000_0000 win.
    #     Two independent AXI master ports keep the GP0/GP1 ordering-domain split
    #     the Z2 design relies on (a wedged data write cannot stall control).
    #   pl_ps_irq0[7:0] <- 8-wide xlconcat (6 TideLink IRQs + 2 tie-low).
    #--------------------------------------------------------------------------
    set ps [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
    # DDR/MIO/clock defaults for the KR260 SOM.
    apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset "1"} $ps
    set_property -dict [list \
        CONFIG.PSU__USE__M_AXI_GP0          {1} \
        CONFIG.PSU__USE__M_AXI_GP1          {0} \
        CONFIG.PSU__USE__M_AXI_GP2          {1} \
        CONFIG.PSU__MAXIGP0__DATA_WIDTH     {32} \
        CONFIG.PSU__MAXIGP2__DATA_WIDTH     {32} \
        CONFIG.PSU__USE__IRQ0               {1} \
        CONFIG.PSU__FPGA_PL0_ENABLE         {1} \
        CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
        CONFIG.PSU__NUM_FABRIC_RESETS       {1} \
    ] $ps

    #--------------------------------------------------------------------------
    # Clocking Wizard: 100 MHz -> 6.25 / 25 / 200 MHz
    # Single MMCM, three synchronous outputs:
    #   clk_out1 = hclk + user_ref_clk (PHY hi-speed bit clock) + scan_clk
    #              -> 6.25 MHz (v36 LINK-RATE DROP 2026-06-12). Was 25 MHz.
    #              The PHY pad clock == user_ref_clk (1:1), so the link/pad
    #              rate is 6.25 MHz / 160 ns — matching the silicon-validated
    #              PHY-BIST config (pynq-z2-phy-bist-pair clk_out1 = 6.250),
    #              which ran autonomous bilateral link_up 3/3 + 30-min soak on
    #              THESE boards. v35 (25 MHz / 40 ns, 4x faster) could not
    #              close the marginal B->A eye for the new PHY's exact-16-bit
    #              WORD_PIN_AUTO aligner (WavD2DGpioRx wpa_match). Dropping the
    #              link 4x re-opens that eye. hclk/AHB/APB also drop to 6.25 MHz
    #              -- the BIST runs its whole stack at 6.25 MHz, proven fine.
    #   clk_out2 = SPARE (2026-07-17 R1 fix). Formerly drove phc_clk/phc_0/clk at a
    #              requested 25 MHz, but the MMCM resolved it to 24.955 MHz (integer
    #              CLKOUTn) vs clk_out1's 25.011 MHz (fractional CLKOUT0) — a
    #              near-common period that made every hclk<->phc_clk path a failing
    #              inter-clock crossing. phc now rides clk_out1; this output is left
    #              enabled-but-unconnected (harmless spare; see phc_clk note below).
    #   clk_out3 = 200 MHz IDELAYCTRL reference (per-lane IDELAYE2).
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
    # KR260: clk_out1 = 25 MHz (well inside the MPSoC MMCME4 range; the Z2's
    # 4.687 MHz needs an out-of-range output divider on US+). hclk/AXI run at
    # 25 MHz; the PHY bit clock is 25/8 = 3.125 MHz via tidelink_phy_clk_div2.
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
    # PHY link/pad clock /2 divider (toggle-FF + BUFG, module reference).
    # The clk_wiz MMCM floor is 4.687 MHz (valid range 4.687-800), so the PHY
    # pad/link rate cannot be lowered at the MMCM. To WIDEN the marginal A->B
    # receive eye we halve ONLY the PHY clock (user_ref_clk + scan_clk) to
    # 2.343 MHz / 426.666 ns via a post-MMCM /2 divider, while hclk and every
    # AXI ACLK stay on clk_out1 at 4.687 MHz (system/SW speed unchanged).
    #
    # The divider is tidelink_phy_clk_div2.v: a toggle flip-flop on clk_out1 +
    # an explicit BUFG (a GLOBAL clock net for the divided clock). BUFGCE_DIV is
    # UltraScale-only and is NOT supported on this Zynq-7000 part (Vivado
    # Netlist 29-180 blackboxes it); util_ds_buf:2.2 has no divide mode (BUFGCE
    # only gates). The .v is added to the fileset by build_design.tcl BEFORE
    # create_root_design and pulled in here as a module reference.
    # clk_in <- clk_wiz_0/clk_out1 (4.687); clk_out -> user_ref_clk + scan_clk.
    # The hclk<->PHY paths are 2-flop CDC'd in RTL and declared asynchronous in
    # the timing XDC, so a separate /2 user_ref_clk domain is safe.
    #--------------------------------------------------------------------------
    set phy_clk_div [create_bd_cell -type module \
        -reference tidelink_phy_clk_div2 phy_clk_div]

    #--------------------------------------------------------------------------
    # Processor System Reset — synchronised to 50 MHz (hclk) domain.
    # peripheral_aresetn drives hresetn, poresetn, and phc_resetn on the IP.
    #--------------------------------------------------------------------------
    set psr [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    #--------------------------------------------------------------------------
    # AXI SmartConnect (control plane, GP0): 1 PS master -> 4 slaves.
    # GP1 split 2026-06-12: ahb_tx + ahb_fifo moved off this interconnect to
    # axi_smc_data on M_AXI_GP1 (own ordering domain — see header NOTE).
    # PHC/PTP/PMOD-trigger removal 2026-06-19: dropped axi_ahb_ptp,
    # axi_apb_phc and axi_gpio_pmod_trig masters (NUM_MI 7 -> 4) to free slices.
    #   M00 -> axi_ahb_sub           (transparent chiplet window — see residual NOTE)
    #   M01 -> axi_apb               (TideLink unified config — THE control surface)
    #   M02 -> axi_gpio_strap        (paired-only; selects role_strap_i at runtime)
    #   M03 -> axi_gpio_debug_unlock (debug strap; ungates slave Wlink APB writes)
    #--------------------------------------------------------------------------
    set smc [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    # 4 control-plane slaves (M00 ahb_sub, M01 apb, M02 strap, M03 debug_unlock);
    # +2 when PTP is in (M04 ahb_ptp bridge, M05 phc APB bridge).
    set_property -dict [list \
        CONFIG.NUM_SI   {1} \
        CONFIG.NUM_MI   [expr {$tl_ptp ? 6 : 4}] \
        CONFIG.NUM_CLKS {1} \
    ] $smc

    #--------------------------------------------------------------------------
    # AXI SmartConnect (data plane, GP1): 1 PS master -> 2 slaves.
    #   M00 -> axi_ahb_tx    (TX aperture  — 0x8400_0000, was 0x4400_0000)
    #   M01 -> axi_ahb_fifo  (RX FIFO      — 0x8401_0000, was 0x4401_0000)
    # A stalled/wedged AHB_TX write now only blocks GP1; APB polls on GP0
    # keep flowing (ARCH_ANALYSIS_2026_06_12.md §4 / roadmap item 5).
    #--------------------------------------------------------------------------
    set smc_data [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_data]
    set_property -dict [list \
        CONFIG.NUM_SI   {1} \
        CONFIG.NUM_MI   {2} \
        CONFIG.NUM_CLKS {1} \
    ] $smc_data

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
    # Single channel, 1-bit output. Default value 0 = MASTER (die_a).
    # POLARITY (RTL truth, axi_chiplet_controller.sv:134): role_strap_i 0=master, 1=slave.
    # An earlier comment here said "0 (slave/die_a)" — WRONG, and it cost a debug session.
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
    # 8-wide to match MPSoC pl_ps_irq0[7:0]: In0..In5 = the 6 TideLink IRQs,
    # In6/In7 tied low (Z2 PS7 IRQ_F2P was sized to 6; MPSoC IRQ0 is 8).
    set irq_concat [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
    set_property -dict [list \
        CONFIG.NUM_PORTS {8} \
    ] $irq_concat
    set const_irq_pad [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_irq_pad]
    set_property -dict [list \
        CONFIG.CONST_WIDTH {1} \
        CONFIG.CONST_VAL   {0} \
    ] $const_irq_pad

    #--------------------------------------------------------------------------
    # TideLink IP (packaged by Wave A3)
    # VLNV: soclabs.org:user:tidelink_vivado_wrapper:1.0
    #--------------------------------------------------------------------------
    set tl [create_bd_cell -type ip \
        -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_0]
    # Peer flow-control target (credit-return / doorbell frames are addressed to
    # the REMOTE die's TideLink APB). On KR260 the APB aperture relocates from
    # 0x4403_0000 -> 0x8403_0000 (MPSoC PL window), so pair_base = 0x8403_2000
    # (APB base + 0x2000). This is the only absolute base baked at build time;
    # the RTL address decode is otherwise base-agnostic (identity CAM at reset).
    #
    # USE_IDELAY=0 is MANDATORY on KR260, not a tuning choice. The IP defaults to
    # USE_IDELAY=1, giving a per-lane IDELAY on each pad_rx (IDELAYE2 on 7-series,
    # IDELAYE3 on US+). The KR260 RPi-header pins are all HDIO (bank 44), and HDIO
    # banks cannot host I/ODELAY or I/OSERDES. Leaving it at 1 fails the build
    # three ways: Vivado 12-1411 (can't place IDELAYE3 in HDIO), DRC ADEF-911
    # (SIM_DEVICE unset on IDELAYE3), and then DRC UCIO-1 because the failed
    # placement drops the pad_rx LOCs. USE_IDELAY=0 prunes the generate branch to
    # a pure combinational passthrough (pad_rx_o = pad_rx_i), which places cleanly
    # in HDIO; eye centring is still done by the Wlink calibrator's bit-slip x
    # phase sweep. pynq-z2-pair / -pair-flip ship this same override.
    # HARDEN_SWI_ENABLE=0 (R6, 2026-07-17): KR260 bakes NEGO_CFG_RESET=0x61, so
    # role_locked latches at PL load and the FCSM exits reset into training
    # garbage, parking at CR-seen (fcsm=2). The only SW-reachable LL reset is
    # 0x208 bit[3] swreset, which HARDEN_SWI_ENABLE=1 masks; the internal FCH
    # bypass is gated on winscan_done, which never asserts with USE_IDELAY=0.
    # Z2/ASIC keep the =1 default. See docs/R6_HARDEN_SWI_OPTIONS.md.
    set_property -dict [list \
        CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
        CONFIG.USE_IDELAY         {0} \
        CONFIG.HARDEN_SWI_ENABLE  {0} \
    ] $tl

    #--------------------------------------------------------------------------
    # AHB-Lite BRAM terminus for TideLink's ahb_mng manager port (2026-07-04).
    # Far side of the XHB500 transparent window: a peer die's remote-initiated
    # access into aperture 0x4000_0000 transits the FC link, exits the local
    # ahb_mng manager, and lands in this 4 KB BlockRAM so writes store and reads
    # return data. Without it the window's return path floats. Module reference
    # (tidelink_ahb_mng_bram.v, added to sources_1 by build_design.tcl BEFORE
    # create_root_design exactly like tidelink_phy_clk_div2). Wraps the
    # silicon-proven cmsdk_ahb_to_sram + cmsdk_fpga_sram (hclk domain, one
    # RAMB36). ahb_mng packages as a REVERSED spirit:slave with no master
    # address space, so its member pins are wired DISCRETELY in the CONNECTIONS
    # section below (no connect_bd_intf_net, no assign_bd_address).
    #--------------------------------------------------------------------------
    set ahb_mng_bram [create_bd_cell -type module \
        -reference tidelink_ahb_mng_bram ahb_mng_bram]

    #--------------------------------------------------------------------------
    # PHC subsystem REMOVED 2026-06-19 (phc_0, axi_apb_phc, axi_gpio_pmod_trig,
    # xlconcat_phc_hw_cap, util_reduced_logic_hw_cap). These occupied slices on
    # the ~97%-packed xc7z020 and are not needed for a link bring-up test.
    # tidelink_0's PHC *inputs* (phc_nanoseconds / phc_seconds / phc_pps /
    # phc_hw_cap_*) are now driven by zero xlconstants below; tidelink_0's PHC
    # *outputs* (phc_hw_set_* / phc_hw_adj_* / phc_hw_capture / ptp_irq) are
    # left unconnected (legal — they are outputs). ahb_ptp bridge also dropped.
    #--------------------------------------------------------------------------

    # PHC subsystem — instantiated (PTP) OR tied off (link-only). On the K26
    # SOM there is ample slice headroom (the xc7z020 removal was a slice fix),
    # so the "with PTP" image restores the full PHC hardware clock: the
    # phc_vivado_wrapper (IEEE-1588 counter + APB regs), an AXI4-Lite->APB
    # bridge for it, and the ahb_ptp AXI->AHB TX-write bridge. hw_capture is
    # driven directly from tidelink_0/phc_hw_capture (no cross-board PMOD-B
    # trigger wire on KR260 — keeps the ribbon at 18 conductors).
    if {$tl_ptp} {
        set phc [create_bd_cell -type ip \
            -vlnv soclabs.org:user:phc_vivado_wrapper:1.0 phc_0]

        set phc_apb_bridge [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:axi_apb_bridge:3.0 axi_apb_phc]
        set_property -dict [list \
            CONFIG.C_APB_NUM_SLAVES {1} \
            CONFIG.C_M_APB_PROTOCOL {apb4} \
        ] $phc_apb_bridge

        set ahb_ptp_bridge [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_ptp]
    } else {
        # PHC input tie-offs (value 0). One xlconstant per distinct width; the
        # 30-bit and 48-bit constants each fan out to two tidelink_0 inputs.
        #   phc_nanoseconds            [29:0]  <- const30
        #   phc_hw_cap_nanoseconds     [29:0]  <- const30
        #   phc_seconds                [47:0]  <- const48
        #   phc_hw_cap_seconds         [47:0]  <- const48
        #   phc_hw_cap_sub_nanoseconds [31:0]  <- const32
        #   phc_pps                    1-bit   <- const1
        set const_phc_30 [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_30]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {30} \
            CONFIG.CONST_VAL   {0} \
        ] $const_phc_30

        set const_phc_48 [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_48]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {48} \
            CONFIG.CONST_VAL   {0} \
        ] $const_phc_48

        set const_phc_32 [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_32]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {32} \
            CONFIG.CONST_VAL   {0} \
        ] $const_phc_32

        set const_phc_1 [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_1]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {1} \
            CONFIG.CONST_VAL   {0} \
        ] $const_phc_1
    }

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
    # mask_hs_bypass_i was previously tied HIGH so the peer-mask handshake
    # gate stayed open and role_lock_reg latched immediately on ROLE_CFG
    # write. With the autoneg FSM + autocal §9 work landed in trunk we now
    # drive this LOW so the actual autoneg-driven mask-handshake path
    # gets exercised on hardware. The xlconstant is intentionally retained
    # (not removed) so reverting to bypass is a one-line CONFIG.CONST_VAL
    # change rather than a BD topology edit.
    #
    # NOTE: with bypass=0, role_lock will NOT latch until the peer-mask
    # handshake reports a match — that requires either (a) SW writing
    # link_lane_mask_hs_result @ 0x21C with peer_says_match=1, or (b) the
    # autoneg FSM (NEGO_CFG[6] mask_hs_auto_en=1) running end-to-end with
    # the I2C sideband physically wired between the two boards. Until the
    # I2C jumpers are in place, the link will hang waiting for the
    # handshake. Use apb_debug_unlock_i (existing strap) for emergency
    # local bring-up that doesn't require peer coordination.
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

    #-- (No PS DDR/FIXED_IO pass-through on MPSoC — handled by the board preset.)

    #-- Clock: PS pl_clk0 (~100 MHz) -> clk_wiz input
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
                   [get_bd_pins clk_wiz_0/clk_in1]

    #-- The MPSoC PLL resolves a "100 MHz" PL0 request to 99.999001 MHz (not
    #   exactly 100), which trips BD 41-238 (FREQ_HZ mismatch) against the
    #   clk_wiz's declared 100 MHz input. Match the clk_wiz input frequency to
    #   whatever the PS actually produces (queried, not hard-coded, so it stays
    #   correct if the board preset's PL0 frequency ever changes).
    set _pl0_hz [get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]]
    set_property CONFIG.PRIM_IN_FREQ [expr {$_pl0_hz / 1000000.0}] [get_bd_cells clk_wiz_0]

    #-- Reset: PS pl_resetn0 -> clk_wiz resetn and proc_sys_reset ext_reset_in
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
                   [get_bd_pins clk_wiz_0/resetn] \
                   [get_bd_pins proc_sys_reset_0/ext_reset_in]

    #-- clk_wiz locked -> proc_sys_reset dcm_locked
    connect_bd_net [get_bd_pins clk_wiz_0/locked] \
                   [get_bd_pins proc_sys_reset_0/dcm_locked]

    #-- Clock fan-out: clk_wiz clk_out1 (4.687 MHz) drives hclk + ALL AXI logic.
    #   user_ref_clk + scan_clk are NO LONGER on this net — they run at 2.343 MHz
    #   off the phy_clk_div /2 (see below) to widen the PHY A->B eye. hclk and
    #   every AXI ACLK stay here at 4.687 MHz (system/SW speed unchanged).
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                   [get_bd_pins proc_sys_reset_0/slowest_sync_clk] \
                   [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk] \
                   [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
                   [get_bd_pins axi_smc/aclk] \
                   [get_bd_pins axi_smc_data/aclk] \
                   [get_bd_pins axi_ahb_sub/s_axi_aclk] \
                   [get_bd_pins axi_ahb_tx/s_axi_aclk] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aclk] \
                   [get_bd_pins axi_apb/s_axi_aclk] \
                   [get_bd_pins axi_gpio_strap/s_axi_aclk] \
                   [get_bd_pins axi_gpio_debug_unlock/s_axi_aclk] \
                   [get_bd_pins tidelink_0/hclk]

    #-------------------------------------------------------------------------
    # PHY link-clock source: LOCAL (default) or COMMON EXTERNAL REF (mesochronous)
    #-------------------------------------------------------------------------
    # Default (FPGA_TIDELINK_EXTREFCLK unset): phy_clk_div/clk_in <- clk_wiz
    # clk_out1. Each board then derives its link clock from its OWN PS
    # oscillator => the two dies are PLESIOCHRONOUS (independent crystals,
    # ppm offset).
    #
    # FPGA_TIDELINK_EXTREFCLK=1: phy_clk_div/clk_in <- an EXTERNAL reference
    # arriving on a Pi-header HDGC ball => both dies frequency-lock to ONE
    # clock => MESOCHRONOUS, which is the regime this PHY was actually built
    # for (it is forwarded-clock with NO CDR/DLL/PI: the calibrator latches
    # (slip,phase) once at S_DONE and freezes, so a frozen-phase link is only
    # reliable when the two dies are frequency-locked). See
    # fpga/docs/KR260_NEXT_WEEK_PLAN.md.
    #
    # HDIO NOTE: the RPi header is HDIO bank 44, which has NO MMCM/PLL sites.
    # An HDGC pin can drive a BUFG but NOT an MMCM. That is fine here because
    # the link clock is divided by a BUFG-based /8 (tidelink_phy_clk_div2.v),
    # so the external ref feeds that BUFG directly and never touches an MMCM.
    #
    # ROBUSTNESS: clk_wiz stays on pl_clk0 and keeps driving hclk/AXI/PHC, so
    # the HOST ALWAYS BOOTS even when the peer's clock is absent. Only the PHY
    # domain (user_ref_clk + scan_clk) depends on the external ref. Do NOT gate
    # proc_sys_reset on it — a board whose peer is off would be unreachable at
    # the bus level (the ZynqMP undecoded-AXI hang class).
    set tl_extref [expr {[info exists ::env(FPGA_TIDELINK_EXTREFCLK)] && $::env(FPGA_TIDELINK_EXTREFCLK) == 1}]

    if { $tl_extref } {
        # External common reference in on an HDGC ball -> explicit BUFG -> /8.
        create_bd_port -dir I -type clk pad_refclk_in
        set_property CONFIG.FREQ_HZ 25000000 [get_bd_ports pad_refclk_in]
        set refbuf [create_bd_cell -type ip \
            -vlnv xilinx.com:ip:util_ds_buf:2.2 refclk_bufg]
        set_property CONFIG.C_BUF_TYPE {BUFG} $refbuf
        connect_bd_net [get_bd_ports pad_refclk_in] \
                       [get_bd_pins refclk_bufg/BUFG_I]
        connect_bd_net [get_bd_pins refclk_bufg/BUFG_O] \
                       [get_bd_pins phy_clk_div/clk_in]
        puts "EXTREFCLK: phy_clk_div/clk_in <- pad_refclk_in (BUFG) - MESOCHRONOUS"
    } else {
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                       [get_bd_pins phy_clk_div/clk_in]
        puts "EXTREFCLK: off - phy_clk_div/clk_in <- clk_wiz clk_out1 (local, plesiochronous)"
    }

    # Optional reference OUTPUT (topology (a): this die sources the common ref
    # for its peer over one extra ribbon conductor). Driven from clk_out1, the
    # SAME node this board's own /8 divides, so source and sink are frequency-
    # locked. Not needed for topology (b) (external generator into both boards).
    if { [info exists ::env(FPGA_TIDELINK_REFCLK_OUT)] && $::env(FPGA_TIDELINK_REFCLK_OUT) == 1 } {
        create_bd_port -dir O -type clk pad_refclk_out
        connect_bd_net [get_bd_ports pad_refclk_out] \
                       [get_bd_pins clk_wiz_0/clk_out1]
        puts "REFCLK_OUT: pad_refclk_out <- clk_wiz clk_out1 (this die sources the common ref)"
    }

    #-- PHY link clock: phy_clk_div /8 -> user_ref_clk + scan_clk (3.125 MHz).
    #   user_ref_clk IS the GPIO-PHY hi-speed bit clock (the serializer and the
    #   forwarded pad_clk_tx both run off it), so it sets the pad/link rate.
    connect_bd_net [get_bd_pins phy_clk_div/clk_out] \
                   [get_bd_pins tidelink_0/user_ref_clk] \
                   [get_bd_pins tidelink_0/scan_clk]

    #-- phc_clk: DRIVEN FROM clk_wiz clk_out1 (== hclk), NOT clk_out2 (2026-07-17,
    #   R1 timing fix). clk_out1 and clk_out2 BOTH request 25 MHz, but the single
    #   MMCM resolves them to DIFFERENT actual frequencies: clk_out1 rides the
    #   fractional-capable CLKOUT0 (25.011 MHz, 39.982 ns) while clk_out2 rides an
    #   integer-only CLKOUTn (24.955 MHz, 40.072 ns). The tool then treats every
    #   hclk<->phc_clk path as a near-common-period INTER-clock crossing with only
    #   ~0.09 ns of setup requirement => 1673 failing endpoints, WNS -2.427 ns on
    #   the deployed build (imp/.../kr260-pair-ptp/*timing_summary_routed.rpt: ALL
    #   setup failures are the clk_out1<->clk_out2 group). The PHC is a 25 MHz
    #   timebase either way and its hclk<->phc_clk boundary is CDC'd in RTL, so
    #   collapsing both consumers onto ONE physical net makes the crossing
    #   single-clock (intra-clk_out1 WNS +28.8 ns) with ZERO functional change
    #   (same 25 MHz, same NS_INCR budget; 24.955->25.011 MHz is a 0.2% shift,
    #   actually closer to nominal). This does NOT touch the pad_tx source-
    #   synchronous forwarded-clock outputs (the separate benign WHS artifact).
    #   clk_wiz CLKOUT2 is intentionally left enabled-but-unconnected (a spare MMCM
    #   output is harmless and lower-risk than renumbering CLKOUT3=200 MHz IDELAY);
    #   DO NOT reconnect phc_clk or phc_0/clk to it.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                   [get_bd_pins tidelink_0/phc_clk]

    #-- SoC Labs §9 structural fix: clk_wiz clk_out3 (200 MHz) -> IDELAYCTRL
    #   reference clock for the per-lane IDELAYE2 RX delay elements.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] \
                   [get_bd_pins tidelink_0/idelay_ref_clk]

    #-- Reset fan-out (active-low peripheral_aresetn)
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins axi_smc/aresetn] \
                   [get_bd_pins axi_smc_data/aresetn] \
                   [get_bd_pins axi_ahb_sub/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aresetn] \
                   [get_bd_pins axi_apb/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_strap/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_debug_unlock/s_axi_aresetn] \
                   [get_bd_pins tidelink_0/hresetn] \
                   [get_bd_pins tidelink_0/poresetn] \
                   [get_bd_pins tidelink_0/phc_resetn]

    #-- AXI: PS M_AXI_HPM0_LPD -> control-plane SmartConnect slave (0x8000_0000)
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] \
                        [get_bd_intf_pins axi_smc/S00_AXI]

    #-- AXI: PS M_AXI_HPM0_FPD -> data-plane SmartConnect slave (0xA000_0000,
    #   own ordering domain — the MPSoC equivalent of the Z2 GP1 split)
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
                        [get_bd_intf_pins axi_smc_data/S00_AXI]

    #-- AXI: SmartConnect M00 -> AHB sub bridge -> tidelink ahb_sub
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] \
                        [get_bd_intf_pins axi_ahb_sub/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_sub/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_sub]

    #-- AXI: data SmartConnect M00 -> AHB tx bridge -> tidelink ahb_tx (GP1)
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M00_AXI] \
                        [get_bd_intf_pins axi_ahb_tx/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_tx/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_tx]

    #-- AXI: data SmartConnect M01 -> AHB fifo bridge -> tidelink ahb_fifo (GP1)
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M01_AXI] \
                        [get_bd_intf_pins axi_ahb_fifo/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_fifo/M_AHB] \
                        [get_bd_intf_pins tidelink_0/ahb_fifo]

    #-- (ahb_ptp bridge / SmartConnect M01 REMOVED 2026-06-19 with PHC subsystem)

    #-- AXI: SmartConnect M01 -> APB bridge -> tidelink apb
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] \
                        [get_bd_intf_pins axi_apb/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_apb/APB_M] \
                        [get_bd_intf_pins tidelink_0/apb]

    #-- AXI: SmartConnect M02 -> AXI GPIO strap (1-bit -> role_strap_i)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] \
                        [get_bd_intf_pins axi_gpio_strap/S_AXI]
    connect_bd_net [get_bd_pins axi_gpio_strap/gpio_io_o] \
                   [get_bd_pins tidelink_0/role_strap_i]

    #-- AXI: SmartConnect M03 -> AXI GPIO debug-unlock (1-bit -> apb_debug_unlock_i)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] \
                        [get_bd_intf_pins axi_gpio_debug_unlock/S_AXI]
    connect_bd_net [get_bd_pins axi_gpio_debug_unlock/gpio_io_o] \
                   [get_bd_pins tidelink_0/apb_debug_unlock_i]

    #-- (SmartConnect M05 axi_apb_phc and M06 axi_gpio_pmod_trig REMOVED
    #--  2026-06-19 with the PHC subsystem)

    #-- GPIO PHY pads -> external ports
    connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_ports pad_clk_tx]
    connect_bd_net [get_bd_pins tidelink_0/pad_tx]     [get_bd_ports pad_tx]
    connect_bd_net [get_bd_ports pad_clk_rx]            [get_bd_pins tidelink_0/pad_clk_rx]
    connect_bd_net [get_bd_ports pad_rx]                [get_bd_pins tidelink_0/pad_rx]

    #-- BD Edit 1: chiplet I2C sideband -> external BD ports (mirrors mps3
    #   tidelink_design.tcl:631-636). Wrapper IOBUFs these onto P15/P16
    #   (Arduino dedicated I2C — repinned off W9/V7 by 3de5ebe).
    connect_bd_net [get_bd_ports i2c_scl_i] [get_bd_pins tidelink_0/i2c_scl_i]
    connect_bd_net [get_bd_pins tidelink_0/i2c_scl_o] [get_bd_ports i2c_scl_o]
    connect_bd_net [get_bd_pins tidelink_0/i2c_scl_t] [get_bd_ports i2c_scl_t]
    connect_bd_net [get_bd_ports i2c_sda_i] [get_bd_pins tidelink_0/i2c_sda_i]
    connect_bd_net [get_bd_pins tidelink_0/i2c_sda_o] [get_bd_ports i2c_sda_o]
    connect_bd_net [get_bd_pins tidelink_0/i2c_sda_t] [get_bd_ports i2c_sda_t]

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
    connect_bd_net [get_bd_pins xlconst_irq_pad/dout] \
                   [get_bd_pins xlconcat_irq/In6]
    connect_bd_net [get_bd_pins xlconst_irq_pad/dout] \
                   [get_bd_pins xlconcat_irq/In7]

    connect_bd_net [get_bd_pins xlconcat_irq/dout] \
                   [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

    #-- PHC datapath: live PHC hardware clock (PTP) OR zero tie-offs (link-only).
    if {$tl_ptp} {
        # Clocks/resets for the PHC IP + its bridges. Re-connecting an already-
        # driven clk/reset pin to new sinks merges them onto the existing net.
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                       [get_bd_pins axi_apb_phc/s_axi_aclk] \
                       [get_bd_pins axi_ahb_ptp/s_axi_aclk]
        #-- phc_0/clk on clk_out1 (== hclk), NOT clk_out2 — see the R1 timing-fix
        #   note at the phc_clk connection above. This also collapses the
        #   axi_apb_phc(clk_out1) -> phc_0/apb(phc_0/clk) APB crossing to a single
        #   clock, so the PHC APB registers are reliably accessible.
        connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                       [get_bd_pins phc_0/clk]
        connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                       [get_bd_pins axi_apb_phc/s_axi_aresetn] \
                       [get_bd_pins axi_ahb_ptp/s_axi_aresetn] \
                       [get_bd_pins phc_0/resetn]

        #-- AXI: control SmartConnect M04 -> AHB ptp bridge -> tidelink ahb_ptp
        connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] \
                            [get_bd_intf_pins axi_ahb_ptp/AXI4]
        connect_bd_intf_net [get_bd_intf_pins axi_ahb_ptp/M_AHB] \
                            [get_bd_intf_pins tidelink_0/ahb_ptp]
        #-- AXI: control SmartConnect M05 -> APB bridge -> phc_0/apb
        connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] \
                            [get_bd_intf_pins axi_apb_phc/AXI4_LITE]
        connect_bd_intf_net [get_bd_intf_pins axi_apb_phc/APB_M] \
                            [get_bd_intf_pins phc_0/apb]

        #-- PHC counter/capture outputs -> tidelink_0 inputs
        connect_bd_net [get_bd_pins phc_0/nanoseconds_o] \
                       [get_bd_pins tidelink_0/phc_nanoseconds]
        connect_bd_net [get_bd_pins phc_0/seconds_o] \
                       [get_bd_pins tidelink_0/phc_seconds]
        connect_bd_net [get_bd_pins phc_0/pps_o] \
                       [get_bd_pins tidelink_0/phc_pps]
        connect_bd_net [get_bd_pins phc_0/hw_cap_seconds_0_o] \
                       [get_bd_pins tidelink_0/phc_hw_cap_seconds]
        connect_bd_net [get_bd_pins phc_0/hw_cap_nanoseconds_0_o] \
                       [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds]
        connect_bd_net [get_bd_pins phc_0/hw_cap_sub_nanoseconds_0_o] \
                       [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds]

        #-- tidelink_0 servo outputs -> PHC inputs (phase step + freq steer)
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

        #-- hw_capture driven directly by tidelink (no cross-board PMOD-B wire)
        connect_bd_net [get_bd_pins tidelink_0/phc_hw_capture] \
                       [get_bd_pins phc_0/hw_capture_0_i]
    } else {
        #-- link-only: tie tidelink_0 PHC *inputs* to 0. (tidelink_0 PHC outputs
        #   phc_hw_set_*/phc_hw_adj_*/phc_hw_capture/ptp_irq stay unconnected.)
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_30/dout] \
                       [get_bd_pins tidelink_0/phc_nanoseconds]
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_30/dout] \
                       [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds]
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_48/dout] \
                       [get_bd_pins tidelink_0/phc_seconds]
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_48/dout] \
                       [get_bd_pins tidelink_0/phc_hw_cap_seconds]
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_32/dout] \
                       [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds]
        connect_bd_net [get_bd_pins xlconst_phc_tieoff_1/dout] \
                       [get_bd_pins tidelink_0/phc_pps]
    }

    #-- Misc tie-offs (discrete scalar 1-bit values handled in wrapper,
    #   but multi-bit constants are easier as xlconstant in the BD)
    connect_bd_net [get_bd_pins xlconst_nego_priority/dout] \
                   [get_bd_pins tidelink_0/nego_priority_i]
    connect_bd_net [get_bd_pins xlconst_puf_seed/dout] \
                   [get_bd_pins tidelink_0/puf_seed]
    connect_bd_net [get_bd_pins xlconst_mask_hs_bypass/dout] \
                   [get_bd_pins tidelink_0/mask_hs_bypass_i]

    #-- AHB manager terminus: TideLink ahb_mng <-> BRAM slave (discrete member
    #   pins — ahb_mng is a REVERSED slave interface with no bus-intf object, so
    #   there is no connect_bd_intf_net and no assign_bd_address). HCLK/HRESETn
    #   share the hclk (clk_out1, 4.687 MHz) + peripheral_aresetn domain used by
    #   ahb_sub/apb. The IP drives the 7 request pins; the BRAM drives the 3
    #   response pins back.
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out1] \
                   [get_bd_pins ahb_mng_bram/HCLK]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins ahb_mng_bram/HRESETn]
    #   IP outputs -> BRAM inputs
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_haddr]  [get_bd_pins ahb_mng_bram/HADDR]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hburst] [get_bd_pins ahb_mng_bram/HBURST]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hprot]  [get_bd_pins ahb_mng_bram/HPROT]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hsize]  [get_bd_pins ahb_mng_bram/HSIZE]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_htrans] [get_bd_pins ahb_mng_bram/HTRANS]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hwdata] [get_bd_pins ahb_mng_bram/HWDATA]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hwrite] [get_bd_pins ahb_mng_bram/HWRITE]
    #   BRAM outputs -> IP inputs
    connect_bd_net [get_bd_pins ahb_mng_bram/HREADY] [get_bd_pins tidelink_0/ahb_mng_hready]
    connect_bd_net [get_bd_pins ahb_mng_bram/HRDATA] [get_bd_pins tidelink_0/ahb_mng_hrdata]
    connect_bd_net [get_bd_pins ahb_mng_bram/HRESP]  [get_bd_pins tidelink_0/ahb_mng_hresp]

    ###########################################################################
    # ADDRESS MAP
    #
    # GP1 split (2026-06-12): control plane on M_AXI_GP0 (hard window
    # 0x4000_0000..0x7FFF_FFFF), data plane on M_AXI_GP1 (hard window
    # 0x8000_0000..0xBFFF_FFFF). The PS7 windows are FIXED in silicon, so
    # the data apertures relocate: NEW = OLD + 0x4000_0000.
    # Vivado SmartConnect requires power-of-two ranges >= 4 KB.
    #
    #   GP0 (control, unchanged):
    #   ahb_sub  : 0x4000_0000   64 MB — transparent chiplet data window
    #   ahb_ptp  : 0x4402_0000    4 KB — PTP TX write port (16 B internal)
    #   apb      : 0x4403_0000   32 KB — unified config registers (15-bit PADDR)
    #
    #   GP1 (data, RELOCATED — was 0x4400_0000 / 0x4401_0000):
    #   ahb_tx   : 0x8400_0000   64 KB — TX aperture (RAM_ADDR_W=14)
    #   ahb_fifo : 0x8401_0000   64 KB — RX FIFO window
    ###########################################################################

    # KR260 (MPSoC) relocation — 0x0000_0000..0x7FFF_FFFF is DDR on MPSoC, so the
    # Z2 GP0 apertures (0x40.., 0x4403.., 0x4404..) MUST move into a PL window.
    # Control plane -> M_AXI_HPM0_LPD window (0x8000_0000, 512 MB): top nibble
    # 0x4 -> 0x8, all low bits preserved. Data plane -> M_AXI_HPM0_FPD window
    # (0xA000_0000, 256 MB): top byte 0x84 -> 0xA4. Host software rebases by the
    # same top-nibble/top-byte swap (see fpga/docs/KR260_PORT.md).
    #
    #   Control (HPM0_LPD):
    #   ahb_sub  : 0x8000_0000   64 MB  (was 0x4000_0000) — transparent window
    #   ahb_ptp  : 0x8402_0000    4 KB  (PTP only; was 0x4402_0000)
    #   apb      : 0x8403_0000   32 KB  (was 0x4403_0000)
    #   strap    : 0x8404_0000    4 KB  (was 0x4404_0000)
    #   debug    : 0x8404_1000    4 KB  (was 0x4404_1000)
    #   phc apb  : 0x8405_0000    4 KB  (PTP only; was 0x4405_0000)
    #   Data (HPM0_FPD):
    #   ahb_tx   : 0xA400_0000   64 KB  (was 0x8400_0000)
    #   ahb_fifo : 0xA401_0000   64 KB  (was 0x8401_0000)

    # ahb_sub: 64 MB at 0x8000_0000
    assign_bd_address -offset 0x80000000 -range 0x04000000 \
        [get_bd_addr_segs {tidelink_0/ahb_sub/Reg}]

    # ahb_tx: 64 KB at 0xA400_0000 (data plane, HPM0_FPD)
    assign_bd_address -offset 0xA4000000 -range 0x00010000 \
        [get_bd_addr_segs {tidelink_0/ahb_tx/Reg}]

    # ahb_fifo: 64 KB at 0xA401_0000 (data plane, HPM0_FPD)
    assign_bd_address -offset 0xA4010000 -range 0x00010000 \
        [get_bd_addr_segs {tidelink_0/ahb_fifo/Reg}]

    # apb: 32 KB at 0x8403_0000 (15-bit PADDR)
    assign_bd_address -offset 0x84030000 -range 0x00008000 \
        [get_bd_addr_segs {tidelink_0/apb/Reg}]

    # strap GPIO: 4 KB at 0x8404_0000
    assign_bd_address -offset 0x84040000 -range 0x00001000 \
        [get_bd_addr_segs {axi_gpio_strap/S_AXI/Reg}]

    # debug-unlock GPIO: 4 KB at 0x8404_1000
    assign_bd_address -offset 0x84041000 -range 0x00001000 \
        [get_bd_addr_segs {axi_gpio_debug_unlock/S_AXI/Reg}]

    # PTP-only apertures: ahb_ptp (0x8402_0000) + phc apb (0x8405_0000).
    if {$tl_ptp} {
        assign_bd_address -offset 0x84020000 -range 0x00001000 \
            [get_bd_addr_segs {tidelink_0/ahb_ptp/Reg}]
        assign_bd_address -offset 0x84050000 -range 0x00001000 \
            [get_bd_addr_segs {phc_0/apb/Reg}]
    }

    ###########################################################################
    # VALIDATE AND SAVE
    ###########################################################################
    regenerate_bd_layout
    validate_bd_design
    save_bd_design

    current_bd_instance $oldCurInst
}
