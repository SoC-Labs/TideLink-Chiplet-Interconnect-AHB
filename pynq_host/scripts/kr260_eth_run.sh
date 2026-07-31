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
    xfer_send|xfer_recv|xfer_readback|xfer_link|xfer_mbox_send|xfer_mbox_recv|\
    xfer_soak|xfer_soak_recv|xfer_fc_health|xfer_decerr|xfer_decerr_verify|\
    xfer_boundary|xfer_boundary_verify|xfer_errinject|xfer_errinject_verify)
        # Cross-die transfer + corner tests over the live link (kr260_eth_xfer.py).
        #   send=die_a CAM+peer-write; recv=die_b read local SRAM; readback=die_a
        #   read over link; mbox_send/mbox_recv=cross-die IPC mailbox (0x2F->0x23);
        #   soak=N write beats + health (+KR260_XFER_ADVERSARIAL=1); soak_recv=die_b
        #   verify adversarial soak; fc_health=GATING per-node FC + Region F check.
        # !! ATTENDED / WEDGE-PRONE (JTAG-POR staged): decerr*, boundary*, errinject*
        #    traverse the PEER window and can wedge the PS bus on current silicon —
        #    run attended, one board pair, ready to JTAG-POR.
        #   decerr/decerr_verify=inbound confinement (excluded byte must DECERR);
        #   boundary/boundary_verify=8 KB-alias last-writer-wins sweep;
        #   errinject/errinject_verify=single-bit AXI-node recovery-gap probe.
        # Env: KR260_XFER_PAYLOAD(0xC0FFEE01), KR260_XFER_ITERS(500),
        #      KR260_XFER_SEED(1), KR260_XFER_WIN(16), KR260_XFER_ADVERSARIAL(0/1),
        #      KR260_XFER_NODE(B/R/W), KR260_XFER_STREAM, KR260_XFER_EXCL,
        #      KR260_XFER_INJ_BIT, KR260_XFER_INJ_BYTE.
        xmode=${MODE#xfer_}; [ "$xmode" = "send" ] && xmode=sender
        pl=${KR260_XFER_PAYLOAD:-0xC0FFEE01}
        extra="--seed ${KR260_XFER_SEED:-1} --win ${KR260_XFER_WIN:-16}"
        [ "${KR260_XFER_ADVERSARIAL:-0}" = 1 ] && extra="$extra --adversarial"
        [ -n "${KR260_XFER_NODE:-}" ]     && extra="$extra --node ${KR260_XFER_NODE}"
        [ -n "${KR260_XFER_STREAM:-}" ]   && extra="$extra --stream ${KR260_XFER_STREAM}"
        [ -n "${KR260_XFER_EXCL:-}" ]     && extra="$extra --excl ${KR260_XFER_EXCL}"
        [ -n "${KR260_XFER_INJ_BIT:-}" ]  && extra="$extra --inj-bit ${KR260_XFER_INJ_BIT}"
        [ -n "${KR260_XFER_INJ_BYTE:-}" ] && extra="$extra --inj-byte ${KR260_XFER_INJ_BYTE}"
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_eth_xfer.py --mode $xmode --payload $pl --iters ${KR260_XFER_ITERS:-500} $extra"
        ;;
    soak_write|soak_verify)
        # Wedge-safe multi-address soak (kr260_eth_soak_fwd.py). write=die_a (arms
        # CAM 0x2F->0x2D itself + FCSM=4 link guard, then N distinct isolated
        # writes); verify=die_b LOCAL read of shared_sram_0 (no link traversal ->
        # cannot wedge). N via KR260_SOAK_N (default 200), base via KR260_SOAK_BASE.
        smode=${MODE#soak_}
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_eth_soak_fwd.py $smode ${KR260_SOAK_N:-200} ${KR260_SOAK_BASE:-A5A50000}"
        ;;
    xfer_health)
        # RO one-shot health snapshot (health_snapshot.py): SWI_LANE/STATUS/credit/
        # OBS_FC_CREDIT/Region F. Wedge-safe, in-window; exits 1 on a fault bit.
        SSH "cd $KR260_DEST && $SUDO python3 scripts/health_snapshot.py"
        ;;
    xfer_dbg_gate|xfer_dbg_halt|xfer_dbg_resume)
        # Cross-die SWD debug (kr260_eth_xfer.py). REQUIRES the batch RTL (0b+0c);
        # wedge-prone until the FCSM fix. gate=die_b REMOTE_DBG_EN; halt/resume=die_a
        # far core via KR260_DBG_CORE (net|chip). gate-off via KR260_DBG_GATE_OFF=1.
        xmode=${MODE#xfer_}
        extra="--core ${KR260_DBG_CORE:-net}"; [ "${KR260_DBG_GATE_OFF:-0}" = 1 ] && extra="$extra --gate-off"
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_eth_xfer.py --mode $xmode $extra"
        ;;
    tc_status|tc_prep|tc_elect|tc_enum|tc_route|tc_telemetry|tc_reset)
        # TideChart (chiplet identity/routing bootstrap) via kr260_tidechart.py.
        # tc_elect must run on BOTH boards together. peer id via KR260_TC_PEER_ID.
        tcmode=${MODE#tc_}
        SSH "cd $KR260_DEST && $SUDO python3 scripts/kr260_tidechart.py --mode $tcmode --peer-id ${KR260_TC_PEER_ID:-0} --sync-at ${KR260_TC_SYNC_AT:-0}"
        ;;
    *)
        echo "ERROR: unknown MODE '$MODE'." >&2
        echo "  modes: status|bringup|xfer_{send,recv,readback,link,mbox_send," >&2
        echo "         mbox_recv,soak,soak_recv,fc_health,health,decerr,decerr_verify," >&2
        echo "         boundary,boundary_verify,errinject,errinject_verify," >&2
        echo "         dbg_gate,dbg_halt,dbg_resume}|soak_write|soak_verify|tc_*" >&2
        exit 2 ;;
esac
