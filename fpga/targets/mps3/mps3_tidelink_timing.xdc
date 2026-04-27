################################################################################
# TideLink Chiplet Bridge — ARM MPS3 Timing Constraints
#
# Implementation-only constraints.  Loaded with USED_IN_SYNTHESIS=false by
# fpga/build_design.tcl so they do not fire CRITICAL WARNING 12-4739 during
# synthesis (clk_wiz output clocks are not visible at that stage).
#
# Pin assignments and I/O standards live in mps3_tidelink.xdc which is loaded
# for BOTH synthesis and implementation.
#
# Target: xcku115-flvb1760-1-c / Vivado 2025.2
################################################################################

################################################################################
## Async clock groups
##
## The 50 MHz hclk (clk_wiz_0 clk_out1) is asynchronous to:
##   - The 24 MHz OSCCLK[0] driving the clk_wiz input
##   - The TideLink PHY RX clock (pad_clk_rx), sourced from the remote chiplet
##
## Pin-based lookup keeps this robust across Vivado BD renames.
################################################################################
set_clock_groups -name async_hclk_phy -asynchronous \
    -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ "*clk_wiz_0*/clk_out1"}]] \
    -group [get_clocks osc_24mhz]

## TODO: Add PHY RX clock group once pad_clk_rx pin is confirmed and
## its create_clock is uncommented in mps3_tidelink.xdc:
# set_clock_groups -name async_hclk_phy_rx -asynchronous \
#     -group [get_clocks -of_objects [get_pins -hierarchical -filter {NAME =~ "*clk_wiz_0*/clk_out1"}]] \
#     -group [get_clocks tl_phy_clk_rx]

################################################################################
## PHY I/O delays
##
## TideLink GPIO PHY uses a source-synchronous forwarded clock scheme.
## TX outputs are launched on hclk; RX inputs are captured on pad_clk_rx.
##
## Placeholder delay budget — update once the board-side timing spec
## (trace length, level-shifter delay if applicable) is known.
##
## TODO: Fill in real numbers after board bring-up; use the oscilloscope /
## link-error-rate method to close timing on the physical channel.
################################################################################
## TX output delays (relative to hclk, conservative hold-first budget)
# set_output_delay -clock [get_clocks -of_objects \
#     [get_pins -hierarchical -filter {NAME =~ "*clk_wiz_0*/clk_out1"}]] \
#     -min -2.0 [get_ports {pad_tx[*] pad_clk_tx}]
# set_output_delay -clock [get_clocks -of_objects \
#     [get_pins -hierarchical -filter {NAME =~ "*clk_wiz_0*/clk_out1"}]] \
#     -max  5.0 [get_ports {pad_tx[*] pad_clk_tx}]

## RX input delays (relative to pad_clk_rx)
# set_input_delay -clock [get_clocks tl_phy_clk_rx] \
#     -min  1.0 [get_ports {pad_rx[*]}]
# set_input_delay -clock [get_clocks tl_phy_clk_rx] \
#     -max  8.0 [get_ports {pad_rx[*]}]

################################################################################
## False paths — static and asynchronous signals
################################################################################

## LEDs — combinatorial from IRQ/status; timing irrelevant
set_false_path -to [get_ports {USER_nLED[*]}]

## Push button — async reset input; synchronised inside proc_sys_reset IP
set_false_path -from [get_ports USER_nPB]

## I2C sideband — low-speed (<400 kHz), false-path from timing analysis
## TODO: Uncomment once I2C pin assignments are confirmed.
# set_false_path -from [get_ports i2c_scl]
# set_false_path -from [get_ports i2c_sda]
# set_false_path -to   [get_ports i2c_scl]
# set_false_path -to   [get_ports i2c_sda]
