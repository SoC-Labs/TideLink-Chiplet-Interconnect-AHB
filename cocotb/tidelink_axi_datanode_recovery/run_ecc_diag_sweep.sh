#!/usr/bin/env bash
# Header-ECC instrument-proof + blast-radius sweep (wip/axirec-header-ecc-probe).
# Runs the existing DIAG test (test_diag_byte0_detection_path) for byte 3 (the
# header-ECC byte = the instrument CONTROL that MUST move a live ECC counter),
# byte 1 (word_count) and byte 0 (data_id). Reuses one sim_build so VCS compiles
# once.
cd "$(dirname "$0")"
source /home/dam1n19/SoCLabs/tidelink-wip-ecc/set_env.sh >/dev/null 2>&1
export PATH="$VCS_HOME/bin:$PATH"
export TIDELINK_PHY_V2=1
LOG=/tmpdir/claude-74755/-home-dam1n19-SoCLabs-tidelink/991ee143-c452-4b4c-802d-d32480d9458a/scratchpad/ecc_diag
mkdir -p "$LOG"
for B in 3 1 0; do
  echo "############## DIAG_BYTE=$B ##############"
  DIAG_BYTE=$B make MODULE=test_axi_datanode_gaps \
      TESTCASE=test_diag_byte0_detection_path \
      SIM_BUILD=sim_build_diag > "$LOG/byte_$B.log" 2>&1
  echo "--- byte $B exit=$? ---"
  grep -E "DETECTION PATH|probes live|byte-.* injection|TEST=.*PASS|TEST=.*FAIL|Error|Fatal" "$LOG/byte_$B.log" | tail -20
done
echo "ALL DONE"
