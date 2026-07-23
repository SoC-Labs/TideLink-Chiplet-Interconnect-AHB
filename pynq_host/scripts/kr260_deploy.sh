#!/usr/bin/env bash
# kr260_deploy.sh — deploy a TideLink bitstream to a plain-Ubuntu KR260 board.
#
# THE REAL KR260 LOAD PATH (NOT pynq). These boards run plain Ubuntu 22.04 with
# NO PYNQ framework, login `ubuntu` (home /home/ubuntu), password auth by
# default. The Makefile's Z2 `pynq_overlay` deploy branch (`from pynq import
# Overlay`) does not work here. See docs/KR260_BOARD_ENV.md.
#
# This script, invoked by `make -C fpga deploy` when DEPLOY_STYLE=fpgautil:
#   1. scp the pre-converted .bin + the pynq_host scripts to ubuntu@<board>:~/td/
#      in a MIRRORED layout (scripts under ~/td/scripts, tl_socmap.py at ~/td/
#      so tl39.py's `sys.path.insert(0, ..)` import resolves — the flat-staging
#      landmine).
#   2. `sudo fpgautil -b ~/td/tidelink.bin -f Full`   (the ZynqMP PL load).
#   3. verify /sys/class/fpga_manager/fpga0/state == "operating".
#   4. `sudo sh ~/td/scripts/kr260_afi.sh fix` — the AFI PS-master-port width
#      re-poke, MANDATORY after every PL load (afi_fs is not persisted; the stock
#      SOM firmware reprograms it every boot). This also prints the canaries.
#
# The .bin MUST be produced by fpga/scripts/bit2bin_zynqmp.py (header-strip, NO
# byte-swap). NEVER bit2bin.py here — its byte-swap corrupts a ZynqMP load.
#
# NEVER `sudo reboot` a KR260 (it wedges — JTAG POR only). This script does not.
#
# Inputs (env, set by the Makefile `deploy_kr260` target):
#   KR260_HOST      board address: "10.22.24.159" or "ubuntu@10.22.24.159" (req)
#   KR260_USER      login user (default: ubuntu) — used if KR260_HOST has no '@'
#   KR260_PROXY     optional ssh ProxyJump host
#   KR260_DEST      remote staging dir, relative to home (default: td)
#   KR260_PASSWORD  optional; if set + sshpass present -> password ssh/scp; also
#                   used for `sudo -S` on the board. Unset -> key auth + sudo -n.
#   BIN             path to the .bin to load (required)
#   BITSTREAM       path to the source .bit (informational)
#   HWH             path to the .hwh (staged for reference; unused by fpgautil)
#   TIDELINK_HOME   repo root (to find pynq_host/ + tl_socmap.py)
#   TIDELINK_SOC    passed through for on-board tooling (kr260)
#   TARGET          build target name (informational, e.g. kr260-pair-ptp)
#   RUN_AFI         1 (default) to run the AFI fix + canaries after load; 0 skips
set -eu

# --------------------------------------------------------------------------
# Resolve inputs
# --------------------------------------------------------------------------
KR260_USER=${KR260_USER:-ubuntu}
KR260_HOST=${KR260_HOST:-}
KR260_PROXY=${KR260_PROXY:-}
KR260_DEST=${KR260_DEST:-td}
KR260_PASSWORD=${KR260_PASSWORD:-}
BIN=${BIN:-}
BITSTREAM=${BITSTREAM:-}
HWH=${HWH:-}
TIDELINK_HOME=${TIDELINK_HOME:-}
TIDELINK_SOC=${TIDELINK_SOC:-kr260}
TARGET=${TARGET:-}
RUN_AFI=${RUN_AFI:-1}

if [ -z "$KR260_HOST" ]; then
    echo "ERROR: KR260_HOST not set (board ip or user@ip)." >&2; exit 2
fi
if [ -z "$BIN" ]; then
    echo "ERROR: BIN not set (path to the ZynqMP .bin)." >&2; exit 2
fi
if [ ! -f "$BIN" ]; then
    echo "ERROR: BIN='$BIN' not found. Build it first (make build_design) — the" >&2
    echo "       Makefile converts .bit->.bin with bit2bin_zynqmp.py automatically." >&2
    exit 2
fi
if [ -z "$TIDELINK_HOME" ] || [ ! -d "$TIDELINK_HOME/pynq_host" ]; then
    echo "ERROR: TIDELINK_HOME='$TIDELINK_HOME' does not contain pynq_host/." >&2; exit 2
fi

# Compose the ssh destination: honour an explicit user@host, else USER@HOST.
case "$KR260_HOST" in
    *@*) DEST="$KR260_HOST" ;;
    *)   DEST="$KR260_USER@$KR260_HOST" ;;
esac

# --------------------------------------------------------------------------
# ssh/scp auth. Prefer key auth; sshpass only if KR260_PASSWORD is set AND
# sshpass is on PATH. sudo on the board uses `echo <pw> | sudo -S` when a
# password is given (mirrors kr260_afi_fix), else `sudo -n` (NOPASSWD).
# --------------------------------------------------------------------------
SSHPASS_PREFIX=""
SUDO="sudo -n"
if [ -n "$KR260_PASSWORD" ]; then
    if command -v sshpass >/dev/null 2>&1; then
        # sshpass -e reads the password from $SSHPASS: keeps it out of the
        # local process list (`ps`), unlike `sshpass -p <pw>`.
        export SSHPASS="$KR260_PASSWORD"
        SSHPASS_PREFIX="sshpass -e"
        echo "auth: sshpass password login (KR260_PASSWORD set)."
        echo "      Key auth is preferred — stage keys with: ssh-copy-id $DEST"
    else
        echo "auth: KR260_PASSWORD set but sshpass not found — using SSH key auth"
        echo "      for login; password will still be used for on-board sudo -S."
    fi
    # Single-quoted so a password with spaces/globs survives word-splitting.
    # NOTE: the expansion still appears in the remote command line (remote ps)
    # — NOPASSWD sudo + key auth is the recommended configuration.
    SUDO="echo '${KR260_PASSWORD}' | sudo -S"
else
    echo "auth: SSH key auth (no KR260_PASSWORD). On-board privilege via sudo -n"
    echo "      (needs NOPASSWD, or pass KR260_PASSWORD for sudo -S)."
fi

SSH_COMMON="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=15"
if [ -n "$KR260_PROXY" ]; then
    SSH_COMMON="$SSH_COMMON -o ProxyJump=$KR260_PROXY"
fi
# shellcheck disable=SC2086
SSH()  { $SSHPASS_PREFIX ssh  $SSH_COMMON "$DEST" "$@"; }
# shellcheck disable=SC2086
SCP()  { $SSHPASS_PREFIX scp  $SSH_COMMON "$@"; }

echo "=========================================================================="
echo " KR260 deploy  (DEPLOY_STYLE=fpgautil)"
echo "   target : ${TARGET:-?}"
echo "   board  : $DEST${KR260_PROXY:+  via $KR260_PROXY}"
echo "   bin    : $BIN ($(wc -c <"$BIN" 2>/dev/null || echo '?') bytes)"
echo "   dest   : ~/$KR260_DEST/  (mirrored: scripts/ + tl_socmap.py at parent)"
echo "=========================================================================="
echo "!! PAIR SAFETY: bring a two-die link up as  POWER-CYCLE -> deploy BOTH   !!"
echo "!! dies -> bring up.  NEVER PL-reload one side of a LIVE link (the other !!"
echo "!! die desyncs). NEVER 'sudo reboot' a KR260 (wedges; JTAG POR only).    !!"
echo "=========================================================================="

# --------------------------------------------------------------------------
# 1. Stage — mirrored layout so tl39.py's parent-dir import of tl_socmap works.
#    ~/td/tidelink.bin
#    ~/td/tl_socmap.py            (importable from ~/td/scripts/tl39.py)
#    ~/td/scripts/*               (tl39.py, tl_poke.py, kr260_afi.sh, ...)
# --------------------------------------------------------------------------
echo "--- staging to $DEST:~/$KR260_DEST/ ---"
SSH "mkdir -p $KR260_DEST/scripts"
SCP "$BIN" "$DEST:$KR260_DEST/tidelink.bin"
[ -n "$HWH" ] && [ -f "$HWH" ] && SCP "$HWH" "$DEST:$KR260_DEST/tidelink.hwh" || true
# tl_socmap.py must land at the PARENT of scripts/ (tl39.py does
# sys.path.insert(0, dirname(__file__)/..) then `from tl_socmap import ...`).
SCP "$TIDELINK_HOME/pynq_host/tl_socmap.py" "$DEST:$KR260_DEST/tl_socmap.py"
# The bring-up tool surface + the AFI fixer.
SCP -r "$TIDELINK_HOME/pynq_host/scripts/." "$DEST:$KR260_DEST/scripts/"

# --------------------------------------------------------------------------
# 2. Load the PL via fpgautil (the real ZynqMP path).
# --------------------------------------------------------------------------
echo "--- loading PL: fpgautil -b ~/$KR260_DEST/tidelink.bin -f Full ---"
SSH "$SUDO fpgautil -b $KR260_DEST/tidelink.bin -f Full"

# --------------------------------------------------------------------------
# 3. Verify fpga_manager state.
# --------------------------------------------------------------------------
echo "--- verifying fpga_manager state ---"
state=$(SSH "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null" || true)
state=$(printf '%s' "$state" | tr -d '\r\n')
echo "    fpga0/state = '$state'"
if [ "$state" != "operating" ]; then
    echo "DEPLOY-FAIL: $TARGET @ $DEST: fpga_manager state='$state' (expected 'operating')." >&2
    echo "  If ENOMEM: check CmaTotal (needs cma=512M — see docs/KR260_BOARD_ENV.md)." >&2
    exit 3
fi

# --------------------------------------------------------------------------
# 4. AFI width re-poke + canaries (MANDATORY after every PL load).
# --------------------------------------------------------------------------
if [ "$RUN_AFI" = "1" ]; then
    echo "--- AFI PS-master-port width fix + canaries (kr260_afi.sh fix) ---"
    if SSH "$SUDO sh $KR260_DEST/scripts/kr260_afi.sh fix"; then
        echo "    AFI fix + canaries: PASS"
    else
        rc=$?
        echo "DEPLOY-WARN: $TARGET @ $DEST: kr260_afi.sh fix exited $rc — the PL loaded" >&2
        echo "  but the control/data plane canaries did not pass. Do NOT run AXI" >&2
        echo "  traffic; see docs/KR260_AFI_CHECK.md (escalate to the BD/SmartConnect" >&2
        echo "  trace if widths read 32-bit but canaries still fail)." >&2
        exit "$rc"
    fi
else
    echo "--- AFI fix SKIPPED (RUN_AFI=0) — you MUST run it before any AXI traffic:"
    echo "      make -C fpga kr260_afi_fix PYNQ_HOST=$DEST"
fi

echo ""
echo "=========================================================================="
echo " KR260 deploy OK: $TARGET loaded on $DEST (state=operating, AFI re-poked)."
echo " On-board tooling staged at ~/$KR260_DEST/ :"
echo "   TIDELINK_SOC=$TIDELINK_SOC TD_TL39=~/$KR260_DEST/scripts/tl39.py"
echo " Bring-up (repeat on BOTH dies after power-cycle):"
echo "   ssh $DEST 'cd $KR260_DEST && sudo TIDELINK_SOC=$TIDELINK_SOC python3 scripts/tl39.py probe'"
echo "=========================================================================="
