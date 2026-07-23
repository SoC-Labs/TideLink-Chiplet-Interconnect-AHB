###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - KR260 ON-CHIP PAIR Block Design TCL (Workstream W5)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Creates a Vivado block design named "tidelink_design" for the Kria KR260
### (xck26-sfvc784-2LV-c) carrying TWO complete TideLink instances in ONE
### bitstream, cross-connected ENTIRELY through the FPGA fabric (no PHY signal
### and no I2C signal reaches a pin).
###
###   tidelink_0 = die_a  (role-strap 0, master-by-priority)
###   tidelink_1 = die_b  (role-strap 1, slave-by-priority)
###
### Forked from kr260-pair-nptp/tidelink_design.tcl. Differences (plan
### KR260_PAIR_ONCHIP_PLAN.md sections 3-5):
###   * SECOND full instance (tidelink_1 + _1-suffixed bridges/GPIOs/BRAM).
###   * Data + forwarded-clock cross-connect: 4 discrete connect_bd_net between
###     the two cells (both directions) -- NO external pad ports (sec 3.7).
###   * I2C wired-AND sideband: two util_vector_logic AND cells modelling the
###     open-drain bus -- NO external i2c ports (sec 3.6). Polarity DERIVED from
###     the vendor RTL, NOT assumed (see the I2C section below).
###   * Two /8 dividers with DISTINCT power-up phase (inst0 INIT 0 via module
###     tidelink_phy_clk_div2 ; inst1 INIT 3 via module tidelink_phy_clk_div2_b)
###     -- defeats the zero-skew trap (sec 4).
###   * Widened SmartConnects: control 8 MI, data 4 MI (4 + 4 / 2 + 2 slaves).
###   * IP config bakes NEGO_CFG_RESET=0x61 (autoneg-on-at-POR, zero-poke) and
###     HONEST_MASK_HS=1 (the peer-mask handshake runs for real). Both are
###     spirit:format="bitString" and MUST use the {N'b...} form; a post-set
###     assertion catches a silent coercion (sec 3.3 / W5 landmine).
###   * External boundary: EXACTLY led0..led3 (sec 3.1). Nothing else.
###
### HARDWARE AUTONOMY (sec 5, hard requirement): the proof MUST NOT rely on
### mask_hs_bypass_i or apb_debug_unlock_i. Both are held 0 here:
###   * mask_hs_bypass_i  <- xlconstant CONST_VAL 0  (both instances)
###   * apb_debug_unlock_i <- axi_gpio_debug_unlock*/gpio_io_o, C_DOUT_DEFAULT 0
### With HONEST_MASK_HS=1 (W1 un-hack, tidelink_top.sv:2075-2076) these pins are
### LIVE for the first time; tying either high would silently void the autonomy
### deliverable (sec 5.4). The GPIO default-0 is now correct and LOAD-BEARING.
###
### PTP: OFF for phase-1 (plan sec 3.1). This target is nptp-only; the phc
### inputs are tied to zero exactly as the -nptp fork does. A build with
### FPGA_TIDELINK_PTP=1 is rejected (the SmartConnect MI counts and addrmap.tcl
### carry no PTP apertures).
###
### Address map: SINGLE SOURCE OF TRUTH is addrmap.tcl (Workstream W2), sourced
### below. Its self-check runs at source time (pure Tcl, aborts the build on any
### overlap / window / PAIR_BASE violation) and its tl_emit_assign_bd_address
### emits the 12 assign_bd_address segments this file executes -- so the BD and
### the spec can never drift.
###-----------------------------------------------------------------------------

# ===========================================================================
# Address spec (W2). Sourced explicitly per the W5 contract. addrmap.tcl is
# pure Tcl (no Vivado commands): safe to source here, runs tl_addr_selfcheck +
# tl_addr_print immediately, and defines tl_emit_assign_bd_address for the
# ADDRESS MAP section inside create_root_design.
# ===========================================================================
set _tl_onchip_dir [file dirname [info script]]
source [file join $_tl_onchip_dir addrmap.tcl]

# ===========================================================================
# Post-set CONFIG assertions (W5 landmine: bitString params). A CONFIG that
# silently coerces to 0000000 leaves autoneg OFF / the mask gate wrong at POR
# and the pair simply never links, with NO error anywhere. These helpers make
# that failure LOUD at BD-build time.
#
# get_property on a spirit:format="bitString" param returns the bit string,
# possibly with a Verilog sized-literal prefix (e.g. "7'b1100001" or
# "1100001"). Normalise the prefix away, then compare the NUMERIC value.
# ===========================================================================
proc _tl_bitstr_norm {v} {
    # Strip a leading Verilog sized-literal prefix like  7'b  or  1'b .
    if {[regexp {^[0-9]+'[bB](.*)$} $v -> bits]} { return $bits }
    return $v
}

proc _tl_bitval {v} {
    set b [_tl_bitstr_norm $v]
    # Tolerate a bool-format return (some CONFIG params package as bool).
    if {[string equal -nocase $b "true"]}  { return 1 }
    if {[string equal -nocase $b "false"]} { return 0 }
    if {[regexp {^[01]+$} $b]} {
        # Binary string -> integer (Tcl 8.5+ 0b literal).
        return [expr "0b$b"]
    }
    if {[string is integer -strict $b]} { return [expr {$b}] }
    return -1
}

proc _tl_assert_bitcfg {cell prop want_int} {
    set raw [get_property CONFIG.$prop [get_bd_cells $cell]]
    set got [_tl_bitval $raw]
    if {$got != $want_int} {
        error "W5 CONFIG ASSERTION FAILED: $cell CONFIG.$prop raw='$raw'\
               parsed=$got expected=$want_int -- bitString likely coerced\
               (autoneg / mask-handshake gate silently WRONG). ABORTING BUILD."
    }
    puts "W5 assert OK: $cell CONFIG.$prop = '$raw' (== $want_int)"
}

proc _tl_assert_strcfg {cell prop want_substr} {
    set raw [get_property CONFIG.$prop [get_bd_cells $cell]]
    if {![string match -nocase "*${want_substr}*" $raw]} {
        error "W5 CONFIG ASSERTION FAILED: $cell CONFIG.$prop = '$raw'\
               does not contain '$want_substr'. ABORTING BUILD."
    }
    puts "W5 assert OK: $cell CONFIG.$prop = '$raw' (contains '$want_substr')"
}

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

    # This target is phase-1 nptp-only. Reject a PTP build early: the widened
    # SmartConnect MI counts (control 8, data 4) and addrmap.tcl carry NO PTP
    # apertures, so FPGA_TIDELINK_PTP=1 here would silently mis-size the fabric.
    if {[info exists ::env(FPGA_TIDELINK_PTP)] && $::env(FPGA_TIDELINK_PTP) == 1} {
        error "kr260-pair-onchip is phase-1 nptp-only (PTP off, plan sec 3.1);\
               FPGA_TIDELINK_PTP=1 is unsupported on this target."
    }
    puts "TideLink KR260 on-chip PAIR BD: two full instances, fabric cross-connect, PTP=off"

    ###########################################################################
    # EXTERNAL PORTS  --  the on-chip-pair contract: EXACTLY led0..led3.
    #
    # NO PHY channel ports and NO I2C ports: the TX->RX data/forwarded-clock
    # cross-connect and the I2C open-drain wired-AND live INSIDE this BD (see
    # the CROSS-CONNECT and I2C sections). Surfacing any of them here would
    # break the W4 wrapper bind (.led0..led3 only) and the autonomy contract.
    ###########################################################################
    # Board status LEDs (active-high). led0/1 = die_a, led2/3 = die_b (sec 3.1).
    create_bd_port -dir O led0
    create_bd_port -dir O led1
    create_bd_port -dir O led2
    create_bd_port -dir O led3

    ###########################################################################
    # SHARED PS / CLOCK / RESET  (one each -- both instances sit behind them)
    ###########################################################################

    #--------------------------------------------------------------------------
    # Zynq UltraScale+ PS (KR260 / K26 SOM). DDR4 + MIO from the board preset.
    # Two PL-facing master ports keep the control/data ordering-domain split:
    #   M_AXI_HPM0_LPD (0x8000_0000, 512 MB) -> control-plane SmartConnect
    #   M_AXI_HPM0_FPD (0xA000_0000, 256 MB) -> data-plane SmartConnect
    # Identical to the -nptp fork (one shared PS for the whole board).
    #--------------------------------------------------------------------------
    set ps [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0]
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
    # Clocking Wizard: 100 MHz -> 25 / 25 / 200 MHz (single MMCM). Same as fork.
    #   clk_out1 = 25 MHz : hclk + ALL AXI ACLK + BOTH /8 divider inputs.
    #   clk_out2 = 25 MHz : phc_clk (PHC off in nptp, but the input must be
    #                       driven on both instances).
    #   clk_out3 = 200 MHz: idelay_ref_clk (kept alive -- USE_IDELAY=0 prunes
    #                       the delay path, but the input pin still exists; this
    #                       is also the phase-2 W11 injector clock, sec 3.4).
    #--------------------------------------------------------------------------
    set clk_wiz [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0]
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
    # TWO /8 dividers with DISTINCT power-up phase (the zero-skew trap, sec 4).
    #
    # Both fed from clk_wiz clk_out1, each on its OWN net + BUFG (inside each
    # module). The phase offset is carried STRUCTURALLY by the DISTINCT module:
    #   phy_clk_div_0 -> tidelink_phy_clk_div2   (INIT_PHASE default 3'b000)
    #   phy_clk_div_1 -> tidelink_phy_clk_div2_b (INIT_PHASE default 3'b011)
    # => div_cnt_1(t) = div_cnt_0(t) + 3 (mod 8): a constant 120 ns (0.375 UI)
    # static offset. NO CONFIG.INIT_PHASE override is used (a sized-vector
    # param on a -type module cell can silently fail to propagate and resurrect
    # zero skew -- OQ3/AR4). keep+dont_touch on both counters (in the .v) stops
    # opt_design merging them. Both .v are added to sources_1 by
    # build_design.tcl (:255 and :278) BEFORE create_root_design.
    #--------------------------------------------------------------------------
    set phy_clk_div_0 [create_bd_cell -type module \
        -reference tidelink_phy_clk_div2   phy_clk_div_0]
    set phy_clk_div_1 [create_bd_cell -type module \
        -reference tidelink_phy_clk_div2_b phy_clk_div_1]

    #-- Processor System Reset (one shared reset; phase-1 accepts 0 POR skew,
    #   staggered reset is phase-2 W12).
    set psr [create_bd_cell -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    ###########################################################################
    # SMARTCONNECTS  (widened in place -- do NOT add a third SmartConnect)
    ###########################################################################

    #--------------------------------------------------------------------------
    # Control plane (M_AXI_HPM0_LPD): 1 SI, 8 MI. Justification -- 4 control
    # slaves per instance x 2 instances:
    #   M00 axi_ahb_sub  M01 axi_apb  M02 axi_gpio_strap  M03 axi_gpio_debug_unlock
    #   M04 axi_ahb_sub_1 M05 axi_apb_1 M06 axi_gpio_strap_1 M07 axi_gpio_debug_unlock_1
    # 8 <= 16-MI PG247 limit.
    #--------------------------------------------------------------------------
    set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {8} CONFIG.NUM_CLKS {1}] $smc

    #--------------------------------------------------------------------------
    # Data plane (M_AXI_HPM0_FPD): 1 SI, 4 MI. Justification -- 2 data slaves
    # per instance x 2 instances:
    #   M00 axi_ahb_tx  M01 axi_ahb_fifo  M02 axi_ahb_tx_1  M03 axi_ahb_fifo_1
    # 4 <= 16-MI PG247 limit.
    #--------------------------------------------------------------------------
    set smc_data [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_data]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {4} CONFIG.NUM_CLKS {1}] $smc_data

    ###########################################################################
    # PER-INSTANCE BRIDGES  (axi_ahblite_bridge:3.0 slave=AXI4 master=M_AHB ;
    #                        axi_apb_bridge:3.0 slave=AXI4_LITE master=APB_M)
    ###########################################################################
    # -- inst0 (die_a) --
    set ahb_sub_bridge  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_sub]
    set ahb_tx_bridge   [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_tx]
    set ahb_fifo_bridge [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_fifo]
    set apb_bridge      [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_apb_bridge:3.0    axi_apb]
    set_property -dict [list CONFIG.C_APB_NUM_SLAVES {1} CONFIG.C_M_APB_PROTOCOL {apb4}] $apb_bridge
    # -- inst1 (die_b) --
    set ahb_sub_bridge_1  [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_sub_1]
    set ahb_tx_bridge_1   [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_tx_1]
    set ahb_fifo_bridge_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_fifo_1]
    set apb_bridge_1      [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_apb_bridge:3.0    axi_apb_1]
    set_property -dict [list CONFIG.C_APB_NUM_SLAVES {1} CONFIG.C_M_APB_PROTOCOL {apb4}] $apb_bridge_1

    ###########################################################################
    # PER-INSTANCE STRAP + DEBUG-UNLOCK GPIOs
    #
    # role_strap: AXI GPIO (addressable -- addrmap has strap segments at
    # 0x8404_0000 / 0x8C04_0000). C_DOUT_DEFAULT sets the POR output value, so
    # the strap is CORRECT AT POR with NO host write (zero-poke):
    #   inst0 (die_a) default 0 ; inst1 (die_b) default 1.
    # The strap seeds nego_priority_reg (local_overrides:657 role_strap ? 2 : 1),
    # so it must be RIGHT, not merely present -- it decides which die claims
    # master under autoneg.
    #
    # debug-unlock: AXI GPIO, C_DOUT_DEFAULT 0 on BOTH. With HONEST_MASK_HS=1
    # this default-0 is LOAD-BEARING (sec 5.4): a 1 would re-open mask_hs_gate
    # and void the autonomy proof. NEVER default it high.
    ###########################################################################
    set strap_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_strap]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_DOUT_DEFAULT {0x00000000} CONFIG.C_IS_DUAL {0}] $strap_gpio
    set dbg_gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_debug_unlock]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_DOUT_DEFAULT {0x00000000} CONFIG.C_IS_DUAL {0}] $dbg_gpio

    set strap_gpio_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_strap_1]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_DOUT_DEFAULT {0x00000001} CONFIG.C_IS_DUAL {0}] $strap_gpio_1
    set dbg_gpio_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_debug_unlock_1]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_DOUT_DEFAULT {0x00000000} CONFIG.C_IS_DUAL {0}] $dbg_gpio_1

    ###########################################################################
    # IRQ aggregation. The PS has one pl_ps_irq0[7:0]; 12 IRQs (6/instance) do
    # not fit. Interrupts are NOT on the phase-1 critical path (the autonomy /
    # data proof is poll-based, sec 5.3). Keep the fork's aggregation of
    # tidelink_0's 6 IRQs; tidelink_1's IRQ OUTPUTS are intentionally left
    # unconnected (legal for outputs). Widening to pl_ps_irq1 is a phase-2
    # nicety, not needed for link-up.
    ###########################################################################
    set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
    set_property -dict [list CONFIG.NUM_PORTS {8}] $irq_concat
    set const_irq_pad [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_irq_pad]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_irq_pad

    ###########################################################################
    # THE TWO TIDELINK INSTANCES
    #   soclabs.org:user:tidelink_vivado_wrapper:1.0
    #
    # CONFIG (both cells), sec 3.3 / W5 landmine:
    #   NEGO_CFG_RESET  {7'b1100001}  (== 0x61: nego_en | nego_force_lock |
    #                                   mask_hs_auto_en ; pri_sel[3:2]=00 selects
    #                                   the strap-derived nego_priority_reg)
    #                                   => autoneg ON at POR => zero-poke.
    #   HONEST_MASK_HS  {1'b1}        (mask handshake runs for real; the two
    #                                   bypass pins are live -- both held 0).
    #   USE_IDELAY      {0}           (MANDATORY: no I/ODELAY on an internal net;
    #                                   IP default is 1, so the override matters).
    #   TIDELINK_PAIR_BASE            (peer apb base + 0x2000: inst0 -> 0x8C032000,
    #                                   inst1 -> 0x84032000).
    # USE_CLKBUF / USE_T3A left at packaged default 1 (real recovered-clock BUFG).
    # NEGO_CFG_RESET / HONEST_MASK_HS are packaged spirit:format="bitString" --
    # use the {N'b...} form and ASSERT it took (a silent 0000000 coercion leaves
    # autoneg off / the gate wrong with no error anywhere).
    ###########################################################################
    set tl0 [create_bd_cell -type ip -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_0]
    set_property -dict [list \
        CONFIG.NEGO_CFG_RESET     {7'b1100001} \
        CONFIG.HONEST_MASK_HS     {1'b1}       \
        CONFIG.USE_IDELAY         {0}          \
        CONFIG.TIDELINK_PAIR_BASE {0x8C032000} \
    ] $tl0
    _tl_assert_bitcfg tidelink_0 NEGO_CFG_RESET 97
    _tl_assert_bitcfg tidelink_0 HONEST_MASK_HS 1
    _tl_assert_bitcfg tidelink_0 USE_IDELAY     0
    puts "W5 info: tidelink_0 CONFIG.TIDELINK_PAIR_BASE =\
          '[get_property CONFIG.TIDELINK_PAIR_BASE [get_bd_cells tidelink_0]]' (want 0x8C032000)"

    set tl1 [create_bd_cell -type ip -vlnv soclabs.org:user:tidelink_vivado_wrapper:1.0 tidelink_1]
    set_property -dict [list \
        CONFIG.NEGO_CFG_RESET     {7'b1100001} \
        CONFIG.HONEST_MASK_HS     {1'b1}       \
        CONFIG.USE_IDELAY         {0}          \
        CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
    ] $tl1
    _tl_assert_bitcfg tidelink_1 NEGO_CFG_RESET 97
    _tl_assert_bitcfg tidelink_1 HONEST_MASK_HS 1
    _tl_assert_bitcfg tidelink_1 USE_IDELAY     0
    puts "W5 info: tidelink_1 CONFIG.TIDELINK_PAIR_BASE =\
          '[get_property CONFIG.TIDELINK_PAIR_BASE [get_bd_cells tidelink_1]]' (want 0x84032000)"

    #--------------------------------------------------------------------------
    # AHB-Lite BRAM termini for each instance's ahb_mng manager port (far side
    # of the XHB500 window). Module-ref tidelink_ahb_mng_bram (added to
    # sources_1 by build_design.tcl); wired DISCRETELY (reversed slave, no
    # assign_bd_address). One per instance.
    #--------------------------------------------------------------------------
    set ahb_mng_bram   [create_bd_cell -type module -reference tidelink_ahb_mng_bram ahb_mng_bram]
    set ahb_mng_bram_1 [create_bd_cell -type module -reference tidelink_ahb_mng_bram ahb_mng_bram_1]

    ###########################################################################
    # SHARED CONSTANT TIE-OFFS  (one cell each, fanned out to both instances)
    ###########################################################################
    #-- PHC input tie-offs (PTP off). One xlconstant per distinct width, each
    #   fanned to BOTH instances (2 pins per instance for the 30/48-bit ones).
    set const_phc_30 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_30]
    set_property -dict [list CONFIG.CONST_WIDTH {30} CONFIG.CONST_VAL {0}] $const_phc_30
    set const_phc_48 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_48]
    set_property -dict [list CONFIG.CONST_WIDTH {48} CONFIG.CONST_VAL {0}] $const_phc_48
    set const_phc_32 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_32]
    set_property -dict [list CONFIG.CONST_WIDTH {32} CONFIG.CONST_VAL {0}] $const_phc_32
    set const_phc_1  [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_phc_tieoff_1]
    set_property -dict [list CONFIG.CONST_WIDTH {1}  CONFIG.CONST_VAL {0}] $const_phc_1

    #-- nego_priority_i (16-bit 0x8000). DEAD input under pri_sel=0 (the FSM
    #   uses the strap-derived nego_priority_reg), but the pin must be driven.
    set const_nego [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_nego_priority]
    set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {32768}] $const_nego

    #-- puf_seed (16-bit 0xA5A5).
    set const_puf_seed [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_puf_seed]
    set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {42405}] $const_puf_seed

    #-- mask_hs_bypass_i (1-bit). MUST BE 0 (autonomy contract sec 5.4). With
    #   HONEST_MASK_HS=1 this is live; a 1 would re-open the mask gate. Retained
    #   as an xlconstant so a bench revert is a one-line CONST_VAL change, but it
    #   is 0 here and MUST stay 0 for the autonomy proof.
    set const_mask_bypass [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconst_mask_hs_bypass]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_mask_bypass

    ###########################################################################
    # I2C OPEN-DRAIN WIRED-AND  (fabric sideband, sec 3.6 -- NO external ports)
    #
    # Polarity DERIVED from the vendor RTL, NOT assumed:
    #   deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master.v
    #     :264  reg scl_o_reg = 1'b1        (reset = released, bus pulled high)
    #     :283  assign scl_o = scl_o_reg    (o = 1 release / 0 drive-low)
    #     :284  assign scl_t = scl_o_reg    (t == o; the (t?1:o) tristate
    #                                        collapses to o -- no 'z', no loop)
    #     interconnect example (same file): scl_1_i = scl_1_o & scl_2_o ;
    #                                        scl_2_i = scl_1_o & scl_2_o
    #   and the note "scl_o should not be connected directly to scl_i, only via
    #   AND logic ... this would prevent devices from stretching the clock".
    # => bus = AND(die0.i2c_*_o, die1.i2c_*_o); feed the result back to BOTH
    #    i2c_*_i; leave i2c_*_t unconnected. This is EXACTLY the vendor model and
    #    preserves slave clock-stretch. Both i2c engines run on hclk (clk_out1,
    #    25 MHz) so the bus is a synchronous same-clock net (no create_clock).
    # No zero-delay loop: i2c_*_o is a registered output, i2c_*_i a registered
    # input, so the AND sits purely between two flops on the same clock.
    ###########################################################################
    foreach nm {scl sda} {
        set wand [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 i2c_${nm}_wand]
        set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] $wand
        connect_bd_net [get_bd_pins tidelink_0/i2c_${nm}_o] [get_bd_pins i2c_${nm}_wand/Op1]
        connect_bd_net [get_bd_pins tidelink_1/i2c_${nm}_o] [get_bd_pins i2c_${nm}_wand/Op2]
        connect_bd_net [get_bd_pins i2c_${nm}_wand/Res] \
                       [get_bd_pins tidelink_0/i2c_${nm}_i] \
                       [get_bd_pins tidelink_1/i2c_${nm}_i]
        # i2c_${nm}_t on both instances: intentionally UNCONNECTED (t == o).
    }

    ###########################################################################
    # CONNECTIONS
    ###########################################################################

    #-- Clock: PS pl_clk0 (~100 MHz) -> clk_wiz input
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_pins clk_wiz_0/clk_in1]

    #-- The MPSoC PLL resolves "100 MHz" PL0 to 99.999001 MHz; match the clk_wiz
    #   input FREQ_HZ to what the PS actually produces (queried, not hard-coded)
    #   so BD 41-238 does not trip.
    set _pl0_hz [get_property CONFIG.FREQ_HZ [get_bd_pins zynq_ultra_ps_e_0/pl_clk0]]
    set_property CONFIG.PRIM_IN_FREQ [expr {$_pl0_hz / 1000000.0}] [get_bd_cells clk_wiz_0]

    #-- Reset: PS pl_resetn0 -> clk_wiz resetn + proc_sys_reset ext_reset_in
    connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
                   [get_bd_pins clk_wiz_0/resetn] \
                   [get_bd_pins proc_sys_reset_0/ext_reset_in]
    connect_bd_net [get_bd_pins clk_wiz_0/locked] \
                   [get_bd_pins proc_sys_reset_0/dcm_locked]

    #-- clk_out1 (25 MHz) -> hclk of both instances + ALL AXI ACLK + both
    #   divider inputs + PS master ACLKs + both BRAM HCLK + proc_sys_reset.
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
                   [get_bd_pins axi_ahb_sub_1/s_axi_aclk] \
                   [get_bd_pins axi_ahb_tx_1/s_axi_aclk] \
                   [get_bd_pins axi_ahb_fifo_1/s_axi_aclk] \
                   [get_bd_pins axi_apb_1/s_axi_aclk] \
                   [get_bd_pins axi_gpio_strap_1/s_axi_aclk] \
                   [get_bd_pins axi_gpio_debug_unlock_1/s_axi_aclk] \
                   [get_bd_pins tidelink_0/hclk] \
                   [get_bd_pins tidelink_1/hclk] \
                   [get_bd_pins phy_clk_div_0/clk_in] \
                   [get_bd_pins phy_clk_div_1/clk_in] \
                   [get_bd_pins ahb_mng_bram/HCLK] \
                   [get_bd_pins ahb_mng_bram_1/HCLK]

    #-- Each instance's /8 divider -> its OWN user_ref_clk + scan_clk. Distinct
    #   nets, distinct BUFGs, distinct power-up phase (the zero-skew mitigation).
    connect_bd_net [get_bd_pins phy_clk_div_0/clk_out] \
                   [get_bd_pins tidelink_0/user_ref_clk] \
                   [get_bd_pins tidelink_0/scan_clk]
    connect_bd_net [get_bd_pins phy_clk_div_1/clk_out] \
                   [get_bd_pins tidelink_1/user_ref_clk] \
                   [get_bd_pins tidelink_1/scan_clk]

    #-- clk_out2 (25 MHz) -> phc_clk of both instances (PHC off, but pin driven).
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] \
                   [get_bd_pins tidelink_0/phc_clk] \
                   [get_bd_pins tidelink_1/phc_clk]

    #-- clk_out3 (200 MHz) -> idelay_ref_clk of both instances (keeps clk_out3
    #   loaded; USE_IDELAY=0 prunes the delay logic but the input pin remains).
    connect_bd_net [get_bd_pins clk_wiz_0/clk_out3] \
                   [get_bd_pins tidelink_0/idelay_ref_clk] \
                   [get_bd_pins tidelink_1/idelay_ref_clk]

    #-- Reset fan-out (active-low peripheral_aresetn) to everything.
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
                   [get_bd_pins axi_smc/aresetn] \
                   [get_bd_pins axi_smc_data/aresetn] \
                   [get_bd_pins axi_ahb_sub/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo/s_axi_aresetn] \
                   [get_bd_pins axi_apb/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_strap/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_debug_unlock/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_sub_1/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_tx_1/s_axi_aresetn] \
                   [get_bd_pins axi_ahb_fifo_1/s_axi_aresetn] \
                   [get_bd_pins axi_apb_1/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_strap_1/s_axi_aresetn] \
                   [get_bd_pins axi_gpio_debug_unlock_1/s_axi_aresetn] \
                   [get_bd_pins tidelink_0/hresetn] \
                   [get_bd_pins tidelink_0/poresetn] \
                   [get_bd_pins tidelink_0/phc_resetn] \
                   [get_bd_pins tidelink_1/hresetn] \
                   [get_bd_pins tidelink_1/poresetn] \
                   [get_bd_pins tidelink_1/phc_resetn] \
                   [get_bd_pins ahb_mng_bram/HRESETn] \
                   [get_bd_pins ahb_mng_bram_1/HRESETn]

    #-- PS masters -> SmartConnect slaves
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] \
                        [get_bd_intf_pins axi_smc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
                        [get_bd_intf_pins axi_smc_data/S00_AXI]

    #-- Control SmartConnect MI -> bridges/GPIOs -> tidelink slaves (inst0)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_pins axi_ahb_sub/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_sub/M_AHB] [get_bd_intf_pins tidelink_0/ahb_sub]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins axi_apb/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_apb/APB_M] [get_bd_intf_pins tidelink_0/apb]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins axi_gpio_strap/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins axi_gpio_debug_unlock/S_AXI]
    #-- Control SmartConnect MI -> bridges/GPIOs -> tidelink slaves (inst1)
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M04_AXI] [get_bd_intf_pins axi_ahb_sub_1/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_sub_1/M_AHB] [get_bd_intf_pins tidelink_1/ahb_sub]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M05_AXI] [get_bd_intf_pins axi_apb_1/AXI4_LITE]
    connect_bd_intf_net [get_bd_intf_pins axi_apb_1/APB_M] [get_bd_intf_pins tidelink_1/apb]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M06_AXI] [get_bd_intf_pins axi_gpio_strap_1/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_smc/M07_AXI] [get_bd_intf_pins axi_gpio_debug_unlock_1/S_AXI]

    #-- Data SmartConnect MI -> bridges -> tidelink slaves (inst0 then inst1)
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M00_AXI] [get_bd_intf_pins axi_ahb_tx/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_tx/M_AHB] [get_bd_intf_pins tidelink_0/ahb_tx]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M01_AXI] [get_bd_intf_pins axi_ahb_fifo/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_fifo/M_AHB] [get_bd_intf_pins tidelink_0/ahb_fifo]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M02_AXI] [get_bd_intf_pins axi_ahb_tx_1/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_tx_1/M_AHB] [get_bd_intf_pins tidelink_1/ahb_tx]
    connect_bd_intf_net [get_bd_intf_pins axi_smc_data/M03_AXI] [get_bd_intf_pins axi_ahb_fifo_1/AXI4]
    connect_bd_intf_net [get_bd_intf_pins axi_ahb_fifo_1/M_AHB] [get_bd_intf_pins tidelink_1/ahb_fifo]

    #-- Strap + debug-unlock GPIO outputs -> role_strap_i / apb_debug_unlock_i
    connect_bd_net [get_bd_pins axi_gpio_strap/gpio_io_o]          [get_bd_pins tidelink_0/role_strap_i]
    connect_bd_net [get_bd_pins axi_gpio_debug_unlock/gpio_io_o]   [get_bd_pins tidelink_0/apb_debug_unlock_i]
    connect_bd_net [get_bd_pins axi_gpio_strap_1/gpio_io_o]        [get_bd_pins tidelink_1/role_strap_i]
    connect_bd_net [get_bd_pins axi_gpio_debug_unlock_1/gpio_io_o] [get_bd_pins tidelink_1/apb_debug_unlock_i]

    #-- PHC input tie-offs (0), fanned to both instances.
    connect_bd_net [get_bd_pins xlconst_phc_tieoff_30/dout] \
                   [get_bd_pins tidelink_0/phc_nanoseconds] \
                   [get_bd_pins tidelink_0/phc_hw_cap_nanoseconds] \
                   [get_bd_pins tidelink_1/phc_nanoseconds] \
                   [get_bd_pins tidelink_1/phc_hw_cap_nanoseconds]
    connect_bd_net [get_bd_pins xlconst_phc_tieoff_48/dout] \
                   [get_bd_pins tidelink_0/phc_seconds] \
                   [get_bd_pins tidelink_0/phc_hw_cap_seconds] \
                   [get_bd_pins tidelink_1/phc_seconds] \
                   [get_bd_pins tidelink_1/phc_hw_cap_seconds]
    connect_bd_net [get_bd_pins xlconst_phc_tieoff_32/dout] \
                   [get_bd_pins tidelink_0/phc_hw_cap_sub_nanoseconds] \
                   [get_bd_pins tidelink_1/phc_hw_cap_sub_nanoseconds]
    connect_bd_net [get_bd_pins xlconst_phc_tieoff_1/dout] \
                   [get_bd_pins tidelink_0/phc_pps] \
                   [get_bd_pins tidelink_1/phc_pps]

    #-- Misc discrete tie-offs, fanned to both instances.
    connect_bd_net [get_bd_pins xlconst_nego_priority/dout] \
                   [get_bd_pins tidelink_0/nego_priority_i] \
                   [get_bd_pins tidelink_1/nego_priority_i]
    connect_bd_net [get_bd_pins xlconst_puf_seed/dout] \
                   [get_bd_pins tidelink_0/puf_seed] \
                   [get_bd_pins tidelink_1/puf_seed]
    connect_bd_net [get_bd_pins xlconst_mask_hs_bypass/dout] \
                   [get_bd_pins tidelink_0/mask_hs_bypass_i] \
                   [get_bd_pins tidelink_1/mask_hs_bypass_i]

    #-- ahb_mng BRAM termini (discrete member pins; reversed slave, no segment).
    #   inst0
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_haddr]  [get_bd_pins ahb_mng_bram/HADDR]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hburst] [get_bd_pins ahb_mng_bram/HBURST]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hprot]  [get_bd_pins ahb_mng_bram/HPROT]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hsize]  [get_bd_pins ahb_mng_bram/HSIZE]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_htrans] [get_bd_pins ahb_mng_bram/HTRANS]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hwdata] [get_bd_pins ahb_mng_bram/HWDATA]
    connect_bd_net [get_bd_pins tidelink_0/ahb_mng_hwrite] [get_bd_pins ahb_mng_bram/HWRITE]
    connect_bd_net [get_bd_pins ahb_mng_bram/HREADY] [get_bd_pins tidelink_0/ahb_mng_hready]
    connect_bd_net [get_bd_pins ahb_mng_bram/HRDATA] [get_bd_pins tidelink_0/ahb_mng_hrdata]
    connect_bd_net [get_bd_pins ahb_mng_bram/HRESP]  [get_bd_pins tidelink_0/ahb_mng_hresp]
    #   inst1
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_haddr]  [get_bd_pins ahb_mng_bram_1/HADDR]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_hburst] [get_bd_pins ahb_mng_bram_1/HBURST]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_hprot]  [get_bd_pins ahb_mng_bram_1/HPROT]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_hsize]  [get_bd_pins ahb_mng_bram_1/HSIZE]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_htrans] [get_bd_pins ahb_mng_bram_1/HTRANS]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_hwdata] [get_bd_pins ahb_mng_bram_1/HWDATA]
    connect_bd_net [get_bd_pins tidelink_1/ahb_mng_hwrite] [get_bd_pins ahb_mng_bram_1/HWRITE]
    connect_bd_net [get_bd_pins ahb_mng_bram_1/HREADY] [get_bd_pins tidelink_1/ahb_mng_hready]
    connect_bd_net [get_bd_pins ahb_mng_bram_1/HRDATA] [get_bd_pins tidelink_1/ahb_mng_hrdata]
    connect_bd_net [get_bd_pins ahb_mng_bram_1/HRESP]  [get_bd_pins tidelink_1/ahb_mng_hresp]

    ###########################################################################
    # DATA + FORWARDED-CLOCK CROSS-CONNECT (sec 3.7) -- entirely in-fabric.
    # The ONLY place pad_* pins appear: four connect_bd_net between the two
    # cells (both directions). No external port; the forwarded clock is a
    # direct phy_clk_div BUFG -> wire -> rxclk_buf BUFG cascade (CLOCK_
    # DEDICATED_ROUTE handled in the timing XDC, W6).
    #   die_a TX -> die_b RX   and   die_b TX -> die_a RX.
    ###########################################################################
    connect_bd_net [get_bd_pins tidelink_0/pad_clk_tx] [get_bd_pins tidelink_1/pad_clk_rx]
    connect_bd_net [get_bd_pins tidelink_0/pad_tx]     [get_bd_pins tidelink_1/pad_rx]
    connect_bd_net [get_bd_pins tidelink_1/pad_clk_tx] [get_bd_pins tidelink_0/pad_clk_rx]
    connect_bd_net [get_bd_pins tidelink_1/pad_tx]     [get_bd_pins tidelink_0/pad_rx]

    ###########################################################################
    # LEDs (sec 3.1 / W4 map). 2 per die: link_active + role_is_master.
    #   led0 = die_a link_active   led1 = die_a role_is_master (expect 1)
    #   led2 = die_b link_active   led3 = die_b role_is_master (expect 0)
    # (The forked -nptp wrapper's led2/led3 = tidelink_0 wlink_irq /
    # released_credits nets are NOT reproduced here -- these replace them.)
    ###########################################################################
    connect_bd_net [get_bd_pins tidelink_0/link_active]      [get_bd_ports led0]
    connect_bd_net [get_bd_pins tidelink_0/role_is_master_o] [get_bd_ports led1]
    connect_bd_net [get_bd_pins tidelink_1/link_active]      [get_bd_ports led2]
    connect_bd_net [get_bd_pins tidelink_1/role_is_master_o] [get_bd_ports led3]

    ###########################################################################
    # IRQ Concat -> PS pl_ps_irq0[7:0]. tidelink_0's 6 IRQs on In0..In5,
    # In6/In7 tied low. tidelink_1's IRQ outputs left unconnected (poll-based
    # phase-1 proof; see the IRQ note above).
    ###########################################################################
    connect_bd_net [get_bd_pins tidelink_0/released_credits_irq] [get_bd_pins xlconcat_irq/In0]
    connect_bd_net [get_bd_pins tidelink_0/doorbell_irq]         [get_bd_pins xlconcat_irq/In1]
    connect_bd_net [get_bd_pins tidelink_0/packet_committed_irq] [get_bd_pins xlconcat_irq/In2]
    connect_bd_net [get_bd_pins tidelink_0/ptp_irq]              [get_bd_pins xlconcat_irq/In3]
    connect_bd_net [get_bd_pins tidelink_0/perf_irq]             [get_bd_pins xlconcat_irq/In4]
    connect_bd_net [get_bd_pins tidelink_0/wlink_irq]            [get_bd_pins xlconcat_irq/In5]
    connect_bd_net [get_bd_pins xlconst_irq_pad/dout]            [get_bd_pins xlconcat_irq/In6]
    connect_bd_net [get_bd_pins xlconst_irq_pad/dout]            [get_bd_pins xlconcat_irq/In7]
    connect_bd_net [get_bd_pins xlconcat_irq/dout]              [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]

    ###########################################################################
    # ADDRESS MAP  --  emitted from addrmap.tcl (W2), the single source of
    # truth. tl_emit_assign_bd_address returns the 12 assign_bd_address commands
    # (control inst0/inst1, then data inst0/inst1). The ahb_mng BRAM termini
    # have NO segment (reversed slave). Print then execute so the build log
    # shows exactly what was assigned.
    ###########################################################################
    set _assign_block [tl_emit_assign_bd_address]
    puts "----- assign_bd_address (from addrmap.tcl W2) -----"
    puts $_assign_block
    puts "---------------------------------------------------"
    eval $_assign_block

    ###########################################################################
    # VALIDATE AND SAVE
    ###########################################################################
    regenerate_bd_layout
    validate_bd_design
    save_bd_design

    current_bd_instance $oldCurInst
}
