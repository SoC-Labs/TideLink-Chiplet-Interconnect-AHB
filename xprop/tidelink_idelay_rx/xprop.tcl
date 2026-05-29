# VC Formal X-propagation script for tidelink_idelay_rx
# Verifies no X-state can propagate to pad_rx_o under ASIC default
# (USE_IDELAY=0) — pure passthrough mode. The USE_IDELAY=1 arm
# instantiates Xilinx IDELAYE2 and is outside ASIC sign-off scope.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_idelay_rx.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
# USE_IDELAY=0 is the ASIC default and selects the passthrough branch;
# the IDELAYE2/IDELAYCTRL primitives are not elaborated.
elaborate -top tidelink_idelay_rx \
    -parameter USE_IDELAY 0 \
    -parameter NUM_LANES 8 \
    -parameter REFCLK_MHZ 200

# ── No clock/reset ──────────────────────────────────────────────────────────
# In passthrough mode the module is purely combinational
# (pad_rx_o = pad_rx_i). idelay_ref_clk / idelay_rst / phase_tap_i are
# unused inputs in this configuration.

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Pad inputs from the top-level FPGA input pads are assumed defined.
assume -name pad_rx_valid {(^pad_rx_i) !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 300

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
