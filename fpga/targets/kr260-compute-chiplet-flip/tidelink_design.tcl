###-----------------------------------------------------------------------------
### nanoSoC compute-chiplet - KR260 Block Design TCL (die_b / FLIP)
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Builds the "tidelink_design" block design for the KR260 compute-chiplet target
### (xck26, K26 SOM). Two-link sibling of the kr260-eth-chiplet BD: TideLink is
### INTERNAL to the packaged nanosoc_compute_chiplet IP; the on-chip Cortex-M
### cores drive TWO D2D links. The PS role here is:
###
###   - provide clocks + reset (PL0_REF 100 MHz -> clk_wiz),
###   - reach the SoC AHB matrix through the ps_ahb_s backdoor (G2) via
###     M_AXI_HPM0 -> AXI-SmartConnect -> axi_ahblite_bridge (firmware load +
###     register poke; KR260 HPM0 base 0x8000_0000),
###   - aggregate the (single) TideChart interrupt into pl_ps_irq0.
###
### The LINK-0 GPIO-PHY pads go to the J21 ribbon (kr260_compute_chiplet_tidelink.xdc),
### LINK 1 is TIED OFF inside this BD (no second ribbon on this single-board bring-up),
### and the FULL CoreSight SWJ-DP (SWD + JTAG TAP) goes to PMOD2 (3.3V) via the board
### wrapper IOBUFs.
###
### DELTAS vs the eth-chiplet BD (see BUILD_NOTES.md):
###   - backdoor is ps_ahb_s (G2), NOT eth_ss_0.
###   - TWO tidelinks: link 0 -> board; link 1 tied off (G8).
###   - NO ethernet (no RMII/MDIO).
###   - FULL SWJ-DP (adds JTAG tdi/tdo/ntrst) vs eth SWD-only.
###   - SEPARATE user_ref_clk_0 / user_ref_clk_1 (eth aliased one).
###   - only interrupt at the boundary is tidechart_irq (no eth/phc-alarm).
###
### ┌── SCOPING STATUS ─────────────────────────────────────────────────────────
### │ FIRST-CUT scaffold. The OOC IP synth (make package_compute_chiplet_ip) is the
### │ scoping gate that proves the SoC fits xck26; THIS block-design build is the
### │ next phase and WILL need Vivado-interactive iteration on the items marked
### │ `SCOPING-TODO` below (exact PS8 preset, ps_ahb_s clock association since the
### │ SoC derives its own hclk from sys_fclk, the HPM0 address assignment, the
### │ link-1 tie-off clock, and the dual user_ref_clk frequencies).
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
    # LINK 0 GPIO-PHY pads -> J21 ribbon
    create_bd_port -dir O           pad_clk_tx_0
    create_bd_port -dir O -from 7 -to 0 pad_tx_0
    create_bd_port -dir I           pad_clk_rx_0
    create_bd_port -dir I -from 7 -to 0 pad_rx_0

    # LINK 0 I2C sideband -> J21 (open-drain; SCL/SDA IOBUFs live in board wrapper).
    # The BD exposes the raw tristate trio (i/o/t); i2c_*_t is IOBUF-T sense (1=float).
    create_bd_port -dir I           i2c0_scl_i
    create_bd_port -dir O           i2c0_scl_o
    create_bd_port -dir O           i2c0_scl_t
    create_bd_port -dir I           i2c0_sda_i
    create_bd_port -dir O           i2c0_sda_o
    create_bd_port -dir O           i2c0_sda_t

    # CoreSight SWJ-DP -> PMOD2, 3.3V. SWDIO + JTAG_TDO IOBUFs live in the board
    # wrapper. swdio_oe is active-high (T=~oe); jtag_tdo_t is IOBUF-T sense (1=float).
    create_bd_port -dir I           swclk
    create_bd_port -dir I           swdio_i
    create_bd_port -dir O           swdio_o
    create_bd_port -dir O           swdio_oe
    create_bd_port -dir I           jtag_tdi
    create_bd_port -dir O           jtag_tdo_o
    create_bd_port -dir O           jtag_tdo_t
    create_bd_port -dir I           jtag_ntrst

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
    #   portability; the compute-chiplet's idelay_ref_clk consumes it harmlessly.
    #   SCOPING-TODO: pick sys_fclk to match the SoC's timing budget on xck26.
    #   SCOPING-TODO: the compute chiplet has SEPARATE user_ref_clk_0/user_ref_clk_1
    #   (the eth chiplet aliased them). Link 0 is the /8-divided PHY clock; link 1
    #   is tied off (see below) and only needs a valid PL clock. Confirm the exact
    #   per-link user_ref frequency against the SoC timing budget when link 1 is
    #   ever brought up (it would then want its OWN /8 divider + a link-1 timing XDC).
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

    # PHY link/pad clock /8 divider (per-target RTL, added by build_design.tcl)
    set phy_clk_div [create_bd_cell -type module -reference tidelink_phy_clk_div2 phy_clk_div2_0]

    set psr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

    ###########################################################################
    # PS -> SoC AHB backdoor: M_AXI_HPM0 -> SmartConnect -> axi_ahblite_bridge
    #   -> nanosoc_compute_chiplet/ps_ahb_s (G2). KR260 HPM0 aperture base
    #   0x8000_0000. Replaces the eth-chiplet's eth_ss_0.
    ###########################################################################
    set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {1}] $smc

    set ahb_bridge [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_ahblite_bridge:3.0 axi_ahb_ps_s]

    ###########################################################################
    # Role strap constants. Link 0 die_a default 0; the flip target overrides
    # CONST_VAL to 1. Link 1 is tied off -> fixed role (const 0) too.
    ###########################################################################
    set strap_const [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 role_strap_const]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $strap_const
    ;# die_b (FLIP): role strap defaults to 1 (vs die_a 0). Only delta vs die_a
    ;# other than the XDC TX/RX ball swap.

    ###########################################################################
    # LINK 1 TIE-OFF (G8). There is no second ribbon on this single-board bring-up,
    # so link 1's RX/I2C inputs are parked and its role strap fixed. Link 1's TX
    # pads and status outputs are simply left unconnected (no board pins).
    #   - pad_rx_1      <- const 0 (8-bit)
    #   - pad_clk_rx_1  <- const 0 (1-bit, parked/driven — not floating)
    #   - i2c_*_i_1     <- const 1 (open-drain idle high)
    #   - role_strap_i_1<- const 0 (fixed role)
    #   - user_ref_clk_1<- a valid PL clock (clk_out1) so the link-1 domain has a
    #                      clock and does not X-propagate. SCOPING-TODO: if link 1
    #                      is ever activated, give it its own /8 divider to match a
    #                      link-1 source-synchronous timing XDC (as link 0 has).
    ###########################################################################
    set const_rx1     [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 link1_pad_rx_const]
    set_property -dict [list CONFIG.CONST_WIDTH {8} CONFIG.CONST_VAL {0}] $const_rx1
    set const_clkrx1  [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 link1_pad_clk_rx_const]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_clkrx1
    set const_strap1  [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 link1_role_strap_const]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $const_strap1
    set const_i2c1_hi [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 link1_i2c_idle_const]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const_i2c1_hi

    ###########################################################################
    # IRQ aggregation. FINDING: the compute SoC routes all TideLink/D2D IRQ
    # vectors to the on-chip dual-NVIC INTERNALLY; the ONLY interrupt output at the
    # chiplet boundary is tidechart_irq. So exactly one line reaches the concat.
    #   SCOPING-TODO: confirm no additional PL-visible IRQ is needed. If the PS
    #   must see link/D2D events, those vectors have to be surfaced in the SoC RTL
    #   first (a finding-style gap), then added as extra concat inputs here.
    ###########################################################################
    set irq_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_irq]
    set_property CONFIG.NUM_PORTS {1} $irq_concat

    ###########################################################################
    # The packaged compute-chiplet IP (whole multicore SoC + 2x TideLink + TideChart)
    ###########################################################################
    set soc [create_bd_cell -type ip -vlnv soclabs.org:user:nanosoc_compute_chiplet_vivado_wrapper:1.0 nanosoc_compute_chiplet_0]

    ###########################################################################
    # CONNECTIONS
    ###########################################################################
    # Clocks
    connect_bd_net [get_bd_pins $ps/pl_clk0]        [get_bd_pins $clk_wiz/clk_in1]
    # PS pl_clk0 is ~99.999 MHz (not exactly 100) -> match clk_wiz PRIM_IN_FREQ
    # to the actual pin freq after connecting, else BD 41-238 FREQ_HZ mismatch.
    set _pl0_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk0]]
    set_property CONFIG.PRIM_IN_FREQ [expr {$_pl0_hz / 1000000.0}] [get_bd_cells clk_wiz_0]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]  [get_bd_pins $soc/sys_fclk]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]  [get_bd_pins $ps/maxihpm0_fpd_aclk]
    # PHY divider MUST derive from clk_out1: the timing XDC declares
    # pad_clk_tx_fwd as 'clk_wiz_0/clk_out1 -divide_by 8'. Feeding the divider
    # from clk_out2 makes the TX launch clock (user_ref_clk_div2) and the
    # forwarded output clock unrelated near-equal-period clocks -> beat-frequency
    # analysis, 0.728ns requirement, WNS -31ns. Matches the eth/bare-link target.
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]  [get_bd_pins $phy_clk_div/clk_in]
    connect_bd_net [get_bd_pins $phy_clk_div/clk_out] [get_bd_pins $soc/user_ref_clk_0]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out3]  [get_bd_pins $soc/idelay_ref_clk]
    # Link 1 user_ref (tied-off link): a valid PL clock. SCOPING-TODO (see above).
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]  [get_bd_pins $soc/user_ref_clk_1]

    # Reset chain: clk_wiz locked -> proc_sys_reset -> sys_sysresetn
    connect_bd_net [get_bd_pins $ps/pl_resetn0]        [get_bd_pins $clk_wiz/resetn]
    connect_bd_net [get_bd_pins $clk_wiz/locked]       [get_bd_pins $psr/dcm_locked]
    connect_bd_net [get_bd_pins $ps/pl_resetn0]        [get_bd_pins $psr/ext_reset_in]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1]     [get_bd_pins $psr/slowest_sync_clk]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $soc/sys_sysresetn]

    # PS M_AXI_HPM0 -> SmartConnect -> AHB bridge -> ps_ahb_s
    connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $smc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins $smc/M00_AXI]       [get_bd_intf_pins $ahb_bridge/AXI4]
    connect_bd_intf_net [get_bd_intf_pins $ahb_bridge/M_AHB]  [get_bd_intf_pins $soc/ps_ahb_s]
    # SmartConnect + bridge clocks/resets on the SoC clock (ps_ahb_s domain)
    #   SCOPING-TODO: ps_ahb_s is synchronous to the SoC's INTERNAL hclk (derived
    #   from sys_fclk). If the SoC divides fclk, the bridge must run on sys_hclk
    #   (a chiplet OUTPUT) instead of clk_out1. Wire whichever matches. Same open
    #   question the eth-chiplet flagged for eth_ss_0.
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1] [get_bd_pins $smc/aclk]
    connect_bd_net [get_bd_pins $clk_wiz/clk_out1] [get_bd_pins $ahb_bridge/s_axi_aclk]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $smc/aresetn]
    connect_bd_net [get_bd_pins $psr/peripheral_aresetn] [get_bd_pins $ahb_bridge/s_axi_aresetn]

    # Role straps. Link 0 from the (flip-overridable) constant; link 1 fixed.
    #   SCOPING-TODO: to make link-0 role runtime-settable, add an AXI-GPIO off a
    #   2-MI SmartConnect and drive role_strap_i_0 from bit0 instead of a constant.
    connect_bd_net [get_bd_pins $strap_const/dout] [get_bd_pins $soc/role_strap_i_0]
    connect_bd_net [get_bd_pins $const_strap1/dout] [get_bd_pins $soc/role_strap_i_1]

    # Link 1 tie-off (G8): park RX + I2C inputs.
    connect_bd_net [get_bd_pins $const_rx1/dout]     [get_bd_pins $soc/pad_rx_1]
    connect_bd_net [get_bd_pins $const_clkrx1/dout]  [get_bd_pins $soc/pad_clk_rx_1]
    connect_bd_net [get_bd_pins $const_i2c1_hi/dout] [get_bd_pins $soc/i2c_scl_i_1]
    connect_bd_net [get_bd_pins $const_i2c1_hi/dout] [get_bd_pins $soc/i2c_sda_i_1]
    # Link 1 pad_tx_1 / pad_clk_tx_1 / i2c_*_o_1 / i2c_*_t_1 / status_1 outputs are
    # intentionally left unconnected (no board pins).

    # Interrupt -> concat -> pl_ps_irq0 (only tidechart_irq exists at the boundary)
    connect_bd_net [get_bd_pins $soc/tidechart_irq] [get_bd_pins $irq_concat/In0]
    connect_bd_net [get_bd_pins $irq_concat/dout]   [get_bd_pins $ps/pl_ps_irq0]

    # LINK 0 pads, I2C, SWJ-DP, UART, LEDs to external ports
    connect_bd_net [get_bd_ports pad_clk_tx_0] [get_bd_pins $soc/pad_clk_tx_0]
    connect_bd_net [get_bd_ports pad_tx_0]     [get_bd_pins $soc/pad_tx_0]
    connect_bd_net [get_bd_ports pad_clk_rx_0] [get_bd_pins $soc/pad_clk_rx_0]
    connect_bd_net [get_bd_ports pad_rx_0]     [get_bd_pins $soc/pad_rx_0]

    connect_bd_net [get_bd_ports i2c0_scl_i]   [get_bd_pins $soc/i2c_scl_i_0]
    connect_bd_net [get_bd_pins $soc/i2c_scl_o_0] [get_bd_ports i2c0_scl_o]
    connect_bd_net [get_bd_pins $soc/i2c_scl_t_0] [get_bd_ports i2c0_scl_t]
    connect_bd_net [get_bd_ports i2c0_sda_i]   [get_bd_pins $soc/i2c_sda_i_0]
    connect_bd_net [get_bd_pins $soc/i2c_sda_o_0] [get_bd_ports i2c0_sda_o]
    connect_bd_net [get_bd_pins $soc/i2c_sda_t_0] [get_bd_ports i2c0_sda_t]

    connect_bd_net [get_bd_ports swclk]        [get_bd_pins $soc/swclk]
    connect_bd_net [get_bd_ports swdio_i]      [get_bd_pins $soc/swdio_i]
    connect_bd_net [get_bd_pins $soc/swdio_o]  [get_bd_ports swdio_o]
    connect_bd_net [get_bd_pins $soc/swdio_oe] [get_bd_ports swdio_oe]
    connect_bd_net [get_bd_ports jtag_tdi]     [get_bd_pins $soc/jtag_tdi]
    connect_bd_net [get_bd_pins $soc/jtag_tdo_o] [get_bd_ports jtag_tdo_o]
    connect_bd_net [get_bd_pins $soc/jtag_tdo_t] [get_bd_ports jtag_tdo_t]
    connect_bd_net [get_bd_ports jtag_ntrst]   [get_bd_pins $soc/jtag_ntrst]

    connect_bd_net [get_bd_ports uart_rxd]     [get_bd_pins $soc/uart_rxd]
    connect_bd_net [get_bd_pins $soc/uart_txd] [get_bd_ports uart_txd]
    connect_bd_net [get_bd_pins $soc/link_active_0]    [get_bd_ports led0]
    connect_bd_net [get_bd_pins $soc/role_is_master_0] [get_bd_ports led1]

    ###########################################################################
    # ADDRESS MAP — KR260 HPM0 aperture. SCOPING-TODO: confirm the offset/range
    # the firmware expects for the ps_ahb_s backdoor window; the packaged IP's .hwh
    # aperture is authoritative (the eth precedent used base 0x8000_0000, 1 GB).
    ###########################################################################
    assign_bd_address -offset 0x80000000 -range 0x40000000 \
        [get_bd_addr_segs {nanosoc_compute_chiplet_0/ps_ahb_s/Reg}] -quiet
    assign_bd_address -quiet

    regenerate_bd_layout
    save_bd_design
}
