#!/bin/bash
# Canned deploy_pair.sh stand-in for tests. Emits the same recognisable
# markers the real script does, then exits.
#
# Args: BOARD_IP LABEL ROLE [ARTEFACTS] [--manifest path] [--no-verify] ...
# Env: FAKE_DEPLOY_FAIL=1 -> emit DEPLOY-FAIL line and exit non-zero
#      FAKE_DEPLOY_UNREACHABLE=1 -> emit unreachable line
BOARD_IP="$1"; LABEL="$2"; ROLE="$3"
echo "==== $LABEL @ $BOARD_IP — role=$ROLE strap=0 ctrl=0x2 bitstream=tidelink.bin ===="
if [ "${FAKE_DEPLOY_FAIL:-0}" = "1" ]; then
  echo "DEPLOY-FAIL: $LABEL @ $BOARD_IP: scp .bin attempt 1/2 failed" >&2
  exit 3
fi
if [ "${FAKE_DEPLOY_UNREACHABLE:-0}" = "1" ]; then
  echo "board $BOARD_IP unreachable over SSH (check lease GRANTED + board up)" >&2
  exit 2
fi
echo "  fpga_manager: operating"
echo "  PHY_CTRL       = 0x00000000 (swi_phase_offset=0)"
echo "  PAIR_BASE_ADDR = 0x44032000"
echo "  ROLE_CFG       = 0x02 (lock=1, cfg=0)"
echo "==== $LABEL done (sha256=deadbeefdead… label=test-A) ===="
exit 0
