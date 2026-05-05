###-----------------------------------------------------------------------------
### TideLink Chiplet Bridge - Pynq-Z2 Single-Board Loopback Timing
###
### No source-synchronous clock constraints needed: pad_clk_tx /
### pad_clk_rx are internal wires (loopback), not FPGA pads, so there
### are no IO timing paths. Same for pad_tx[*] / pad_rx[*]. The
### CLOCK_DEDICATED_ROUTE FALSE workaround that the pair targets need
### is also dropped — there's no clock pad to constrain.
###
### LUTLP-1 waiver and LED false-paths kept (same as pair target).
###-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# False paths
#-----------------------------------------------------------------------------

# LEDs are human-visible; no functional timing path needed.
set_false_path -to [get_ports {led0 led1 led2 led3}]

#-----------------------------------------------------------------------------
# Combinational loop waiver
#-----------------------------------------------------------------------------

# IP-Integrator AHB-Lite slaves drive HREADYOUT back to HREADY_IN with
# HSEL=1 hardwired. This is intentional and functionally correct for
# always-selected single-master AHB-Lite slaves but trips LUTLP-1.
# Downgrade to a warning so it doesn't block bitstream generation.
set_property SEVERITY {Warning} [get_drc_checks LUTLP-1]
