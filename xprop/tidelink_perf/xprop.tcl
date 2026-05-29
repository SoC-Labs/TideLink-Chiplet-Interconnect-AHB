# VC Formal X-propagation script for tidelink_perf
# Verifies that no X-state can propagate from valid reset to the
# register-read data, IRQ, ewma/link-state outputs, or any internal
# performance counter under normal operation.

# ── Analyze design ──────────────────────────────────────────────────────────
set TIDELINK_HOME [file normalize [file dirname [info script]]/../..]

analyze -format sverilog ${TIDELINK_HOME}/src/rtl/tidelink_perf.sv

# ── Elaborate ───────────────────────────────────────────────────────────────
elaborate -top tidelink_perf \
    -parameter SYS_DATA_W           32 \
    -parameter RAM_ADDR_W           14 \
    -parameter FC_DATA_W            48 \
    -parameter EWMA_ALPHA_SHIFT     4 \
    -parameter DERIV_WINDOW_LOG     8 \
    -parameter LOCAL_LINK_STATE_WIDTH 5

# ── Clock and reset ─────────────────────────────────────────────────────────
clock hclk
reset -expression {!hresetn}

# ── X-propagation checks ───────────────────────────────────────────────────
set_xprop_check -effort high

# Register-port handshake from tidelink_apb_regs is well-formed
assume -name reg_write_valid  {perf_reg_write  !== 1'bx}
assume -name reg_region_valid {(^perf_reg_region) !== 1'bx}

# FC-tap handshakes are produced by tidelink_fc_adapter — never X
assume -name fc_tx_handshake_valid {fc_tx_handshake !== 1'bx}
assume -name fc_tx_is_data_valid   {fc_tx_is_data   !== 1'bx}
assume -name fc_rx_handshake_valid {fc_rx_handshake !== 1'bx}
assume -name fc_rx_is_data_valid   {fc_rx_is_data   !== 1'bx}
assume -name fc_rx_is_first_valid  {fc_rx_is_first  !== 1'bx}

# TX/RX observation pulses originate from synchronous logic
assume -name tx_pkt_start_valid    {tx_pkt_start    !== 1'bx}
assume -name rx_pkt_committed_valid {rx_pkt_committed !== 1'bx}

# Link-status taps
assume -name tx_router_idle_valid {tx_router_idle !== 1'bx}
assume -name fc_tx_valid_valid    {fc_tx_valid    !== 1'bx}
assume -name fc_tx_ready_valid    {fc_tx_ready    !== 1'bx}
assume -name fc_rx_valid_valid    {fc_rx_valid    !== 1'bx}
assume -name fc_rx_accept_valid   {fc_rx_accept   !== 1'bx}

# Congestion estimator inputs
assume -name credit_count_valid   {(^credit_count) !== 1'bx}
assume -name bcast_ack_valid      {bcast_ack_i !== 1'bx}

# ── Run ─────────────────────────────────────────────────────────────────────
check_xprop -type {hold reset_value} -time_limit 600

# ── Report ──────────────────────────────────────────────────────────────────
report_xprop -verbose -file xprop_results.rpt
report_xprop -summary -file xprop_summary.rpt

exit
