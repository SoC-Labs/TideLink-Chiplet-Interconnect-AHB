###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 - DRC waivers
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
###-----------------------------------------------------------------------------
### Sole purpose: contain DRC severity overrides + ALLOW_COMBINATORIAL_LOOPS
### waivers in a SEPARATE XDC file so they survive `save_constraints` round-trips
### (which rewrites *_timing.xdc and tends to drop these properties).
###
### Applied during BOTH synthesis and implementation (default).
###-----------------------------------------------------------------------------

# IP-Integrator AHB-Lite HSEL=1 + HREADY loopback creates an intentional
# combinatorial loop on the HREADY net. Downgrade the DRC severity globally
# AND apply per-net waiver — write_bitstream's pre-DRC has historically
# ignored the severity downgrade in Vivado 2024.1.
set_property ALLOW_COMBINATORIAL_LOOPS true [get_nets -hierarchical -filter {NAME =~ "*u_xhb_sub/u_core/u_resp/*"}]
# Debug core stanzas stripped — insert_debug_core.tcl will recreate them





create_debug_core u_dbg_int ila
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_dbg_int]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_dbg_int]
set_property C_ADV_TRIGGER false [get_debug_cores u_dbg_int]
set_property C_DATA_DEPTH 4096 [get_debug_cores u_dbg_int]
set_property C_EN_STRG_QUAL false [get_debug_cores u_dbg_int]
set_property C_INPUT_PIPE_STAGES 1 [get_debug_cores u_dbg_int]
set_property C_TRIGIN_EN false [get_debug_cores u_dbg_int]
set_property C_TRIGOUT_EN false [get_debug_cores u_dbg_int]
set_property port_width 1 [get_debug_ports u_dbg_int/clk]
connect_debug_port u_dbg_int/clk [get_nets [list tidelink_design_i/clk_wiz_0_clk_out1]]
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe0]
set_property port_width 1 [get_debug_ports u_dbg_int/probe0]
connect_debug_port u_dbg_int/probe0 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrupted]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe1]
set_property port_width 1 [get_debug_ports u_dbg_int/probe1]
connect_debug_port u_dbg_int/probe1 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/valid]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe2]
set_property port_width 2 [get_debug_ports u_dbg_int/probe2]
connect_debug_port u_dbg_int/probe2 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/state[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/state[1]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe3]
set_property port_width 8 [get_debug_ports u_dbg_int/probe3]
connect_debug_port u_dbg_int/probe3 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte0_reg[7]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe4]
set_property port_width 24 [get_debug_ports u_dbg_int/probe4]
connect_debug_port u_dbg_int/probe4 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[7]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[8]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[9]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[10]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[11]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[12]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[13]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[14]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[15]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[16]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[17]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[18]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[19]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[20]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[21]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[22]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected_ph[23]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe5]
set_property port_width 1 [get_debug_ports u_dbg_int/probe5]
connect_debug_port u_dbg_int/probe5 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/is_long_pkt]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe6]
set_property port_width 8 [get_debug_ports u_dbg_int/probe6]
connect_debug_port u_dbg_int/probe6 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/byte1_reg[7]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe7]
set_property port_width 24 [get_debug_ports u_dbg_int/probe7]
connect_debug_port u_dbg_int/probe7 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[7]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[8]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[9]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[10]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[11]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[12]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[13]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[14]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[15]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[16]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[17]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[18]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[19]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[20]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[21]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[22]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/corrected_ph[23]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe8]
set_property port_width 1 [get_debug_ports u_dbg_int/probe8]
connect_debug_port u_dbg_int/probe8 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/is_short_pkt_prev]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe9]
set_property port_width 9 [get_debug_ports u_dbg_int/probe9]
connect_debug_port u_dbg_int/probe9 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[7]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/bytesPerCycle[8]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe10]
set_property port_width 1 [get_debug_ports u_dbg_int/probe10]
connect_debug_port u_dbg_int/probe10 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/is_short_pkt]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe11]
set_property port_width 8 [get_debug_ports u_dbg_int/probe11]
connect_debug_port u_dbg_int/probe11 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_0[7]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe12]
set_property port_width 8 [get_debug_ports u_dbg_int/probe12]
connect_debug_port u_dbg_int/probe12 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_1[7]}]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe13]
set_property port_width 1 [get_debug_ports u_dbg_int/probe13]
connect_debug_port u_dbg_int/probe13 [get_nets [list tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ecc_check_corrected]]
create_debug_port u_dbg_int probe
set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_dbg_int/probe14]
set_property port_width 8 [get_debug_ports u_dbg_int/probe14]
connect_debug_port u_dbg_int/probe14 [get_nets [list {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[0]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[1]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[2]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[3]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[4]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[5]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[6]} {tidelink_design_i/tidelink_0/inst/u_tidelink_top/u_chiplet_controller/u_wlink/llrx/ll_byte_index_2[7]}]]
set_property C_CLK_INPUT_FREQ_HZ 300000000 [get_debug_cores dbg_hub]
set_property C_ENABLE_CLK_DIVIDER false [get_debug_cores dbg_hub]
set_property C_USER_SCAN_CHAIN 1 [get_debug_cores dbg_hub]
connect_debug_port dbg_hub/clk [get_nets pad_clk_rx_IBUF]
