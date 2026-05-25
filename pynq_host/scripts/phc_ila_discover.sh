#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# phc_ila_discover.sh — list JTAG targets visible to hw_server + sanity probe.
# Use this BEFORE running phc_ila_capture.sh to confirm:
#   (a) hw_server is reachable
#   (b) all expected Z2_NN cables are enumerated
#   (c) Vivado batch mode launches cleanly
# Does NOT touch any device.
#-----------------------------------------------------------------------------
set -euo pipefail

HW_URL="${TIDELINK_HW_URL:-localhost:3121}"
VIVADO_BIN="${VIVADO_BIN:-/tools/Xilinx/2025.2/Vivado/bin/vivado}"

TCL="$(mktemp --suffix=.tcl)"
cat > "$TCL" <<'EOF'
open_hw_manager
connect_hw_server -url [lindex $argv 0]
set targets [get_hw_targets]
puts "==================== JTAG TARGETS ===================="
if { [llength $targets] == 0 } {
    puts "  (none — hw_server up but no cables enumerated)"
} else {
    foreach t $targets { puts "  $t" }
}
puts "======================================================"
disconnect_hw_server
close_hw_manager
EOF

trap 'rm -f "$TCL"' EXIT

"$VIVADO_BIN" -mode batch -nojournal -nolog \
    -source "$TCL" -tclargs "$HW_URL" 2>&1 | \
    grep -E 'TARGETS|^  |hw_server|cs_server|ERROR|WARNING' | head -40
