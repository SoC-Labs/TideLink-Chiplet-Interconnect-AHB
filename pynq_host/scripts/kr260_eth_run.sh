#!/usr/bin/env bash
# kr260_eth_run.sh — run the eth-chiplet-native PS-side tools on a KR260 over SSH.
#
# The RUN companion to kr260_deploy.sh (deploy stages these tools at
# ~/td/scripts/; this runs them as root on the board). Auth handling mirrors
# kr260_deploy.sh exactly: sshpass -e for password login when KR260_PASSWORD is
# set + sshpass is present, else key auth; on-board privilege via
# `echo <pw> | sudo -S` (or `sudo -n` when NOPASSWD/key-only).
#
# MODE:
#   status   (default) — READ-ONLY. Runs eth_ss_probe.py (boot-ROM backdoor
#              aliveness) then kr260_eth_bringup.py --status (TideLink config
#              plane). Touches only RO/combinational addresses; cannot wedge.
#   bringup  — writes the TideLink bring-up recipe (needs KR260_ETH_ROLE=die_a|
#              die_b). Run on BOTH boards together; cal_done gates on the peer +
#              ribbon, so the two runs self-synchronise. See docs/KR260_BENCH_RUNBOOK.md §6.
#
# Env (as set by the Makefile / operator):
#   KR260_HOST      board address "10.22.24.159" or "ubuntu@10.22.24.159" (req)
#   KR260_USER      login user (default ubuntu), used if KR260_HOST has no '@'
#   KR260_DEST      remote staging dir under home (default td)
#   KR260_PASSWORD  optional; password login (sshpass) + on-board sudo -S
#   KR260_ETH_ROLE  die_a|die_b (bringup mode only)
#   KR260_PROXY     optional ssh ProxyJump
set -eu

MODE=${1:-status}
KR260_USER=${KR260_USER:-ubuntu}
KR260_HOST=${KR260_HOST:-}
KR260_DEST=${KR260_DEST:-td}
KR260_PASSWORD=${KR260_PASSWORD:-}
KR260_ETH_ROLE=${KR260_ETH_ROLE:-}
KR260_PROXY=${KR260_PROXY:-}

if [ -z "$KR260_HOST" ]; then
    echo "ERROR: KR260_HOST not set (board ip or user@ip)." >&2; exit 2
fi
case "$KR260_HOST" in
    *@*) DEST="$KR260_HOST" ;;
    *)   DEST="$KR260_USER@$KR260_HOST" ;;
esac

SSHPASS_PREFIX=""
SUDO="sudo -n"
if [ -n "$KR260_PASSWORD" ]; then
    if command -v sshpass >/dev/null 2>&1; then
        export SSHPASS="$KR260_PASSWORD"
        SSHPASS_PREFIX="sshpass -e"
    fi
    SUDO="echo '${KR260_PASSWORD}' | sudo -S"
fi

SSH_COMMON="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=15"
if [ -n "$KR260_PROXY" ]; then
    SSH_COMMON="$SSH_COMMON -o ProxyJump=$KR260_PROXY"
fi
# shellcheck disable=SC2086
SSH() { $SSHPASS_PREFIX ssh $SSH_COMMON "$DEST" "$@"; }

echo "=== kr260_eth_run: $MODE on $DEST (dest ~/$KR260_DEST) ==="

case "$MODE" in
    status)
        SSH "cd $KR260_DEST && $SUDO python3 scripts/eth_ss_probe.py; echo '----'; \
             $SUDO python3 scripts/kr260_eth_bringup.py --status"
        ;;
    bringup)
        case "$KR260_ETH_ROLE" in
            die_a|die_b) ;;
            *) echo "ERROR: bringup needs KR260_ETH_ROLE=die_a|die_b." >&2; exit 2 ;;
        esac
        echo "!! Run this on BOTH boards together — cal_done gates on the peer+ribbon."
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_eth_bringup.py --bringup --role $KR260_ETH_ROLE"
        ;;
    xfer_send|xfer_recv|xfer_readback|xfer_link)
        # Cross-die transfer over the live link (kr260_eth_xfer.py). send=die_a
        # CAM+peer-write; recv=die_b read local SRAM; readback=die_a read over
        # link; link=status. Payload via KR260_XFER_PAYLOAD (default 0xC0FFEE01).
        xmode=${MODE#xfer_}; [ "$xmode" = "send" ] && xmode=sender
        pl=${KR260_XFER_PAYLOAD:-0xC0FFEE01}
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_eth_xfer.py --mode $xmode --payload $pl"
        ;;
    *)
        echo "ERROR: MODE must be status|bringup|xfer_send|xfer_recv|xfer_readback|xfer_link (got '$MODE')." >&2
        exit 2 ;;
esac
