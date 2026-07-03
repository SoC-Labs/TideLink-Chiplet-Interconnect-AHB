#!/bin/bash
# fake deploy_pair backend — a reflash IS the fresh POR, so wipe the die's
# model state (arm time, writes, GP1 FIFO). Args mirror deploy_pair.sh:
#   <ip> <board> <die_a|die_b> <dir> --no-verify
set -u
: "${FAKE_STATE:?}"
die=${3:-}
[ -n "$die" ] && rm -f "$FAKE_STATE/$die".arm "$FAKE_STATE/$die".wr "$FAKE_STATE/$die".gp1
exit 0
