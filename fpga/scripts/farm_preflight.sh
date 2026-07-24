#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### TideLink FPGA build-farm preflight
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Validates the four hard prerequisites for Vivado-native `launch_runs -host`
### remote farming against FARM_HOST, using the EXACT ssh options Vivado uses
### by default (-remote_cmd). Run this from an authenticated shell on the
### launching host (the harness's own ssh is not credentialed). Exit 0 only if
### all checks pass; otherwise prints the precise blocker.
###
###   FARM_HOST=farm-host-a BUILD_DIR=/home/.../imp/fpga ./farm_preflight.sh
###-----------------------------------------------------------------------------
set -u

FARM_HOST="${FARM_HOST:?set FARM_HOST=<remote host>}"
BUILD_DIR="${BUILD_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/imp/fpga}"

# Mirror Vivado 2024.1 launch_runs default -remote_cmd exactly.
SSH=(ssh -q -o ConnectTimeout=30 -o ConnectionAttempts=3 -o BatchMode=yes)

VIVADO_BIN="$(command -v vivado || true)"
LOCAL_HOST="$(hostname -s)"
fail=0

note() { printf '  %-4s %s\n' "$1" "$2"; }
ok()   { note "OK"   "$1"; }
bad()  { note "FAIL" "$1"; fail=1; }

echo "=============================================================="
echo " TideLink farm preflight:  $LOCAL_HOST  ->  $FARM_HOST"
echo " Vivado:    ${VIVADO_BIN:-<not found locally>}"
echo " BuildDir:  $BUILD_DIR"
echo "=============================================================="

## 1. Passwordless SSH (BatchMode=yes — Vivado will NOT answer a prompt) -------
echo "[1/4] Passwordless SSH (BatchMode)"
if "${SSH[@]}" "$FARM_HOST" true 2>/dev/null; then
    ok "ssh $FARM_HOST works non-interactively"
else
    bad "ssh $FARM_HOST failed under BatchMode — run scripts/setup_farm_ssh.sh"
fi

## 2. Identical Vivado path + same version ------------------------------------
echo "[2/4] Vivado at identical path + matching version"
if [ -z "$VIVADO_BIN" ]; then
    bad "no 'vivado' on local PATH — cannot compare"
else
    LV="$(vivado -version 2>/dev/null | head -1)"
    RV="$("${SSH[@]}" "$FARM_HOST" \
          "test -x '$VIVADO_BIN' && '$VIVADO_BIN' -version 2>/dev/null | head -1" \
          2>/dev/null)"
    if [ -z "$RV" ]; then
        bad "$VIVADO_BIN absent/not executable on $FARM_HOST (it is local-disk here)"
    elif [ "$LV" != "$RV" ]; then
        bad "version mismatch: local '$LV' vs $FARM_HOST '$RV'"
    else
        ok "$VIVADO_BIN — $RV (identical)"
    fi
fi

## 3. Shared filesystem: build tree at the IDENTICAL absolute path ------------
echo "[3/4] Project tree visible at identical path on $FARM_HOST (NFS export)"
mkdir -p "$BUILD_DIR" 2>/dev/null
ABS_BUILD="$(cd "$BUILD_DIR" && pwd -P)"
SENTINEL="$ABS_BUILD/.farm_sentinel.$$"
STAMP="farm-$(date +%s)-$RANDOM"
if echo "$STAMP" > "$SENTINEL" 2>/dev/null; then
    RSEEN="$("${SSH[@]}" "$FARM_HOST" "cat '$SENTINEL' 2>/dev/null" 2>/dev/null)"
    rm -f "$SENTINEL"
    if [ "$RSEEN" = "$STAMP" ]; then
        ok "$ABS_BUILD is the same filesystem on both hosts"
    else
        bad "$ABS_BUILD NOT shared with $FARM_HOST — NFS export not in place yet"
        echo "       (see fpga/docs/FARM_NFS_EXPORT_REQUEST.md)"
    fi
else
    bad "cannot write sentinel under $ABS_BUILD"
fi

## 4. Clock skew (NFS + Vivado timestamps) + reachable hostname ---------------
echo "[4/4] Clock skew / host identity"
LT="$(date +%s)"
RT="$("${SSH[@]}" "$FARM_HOST" 'date +%s' 2>/dev/null || echo 0)"
RHN="$("${SSH[@]}" "$FARM_HOST" 'hostname -s' 2>/dev/null || echo '?')"
if [ "$RT" -eq 0 ]; then
    bad "could not read remote clock (ssh failed)"
else
    SKEW=$(( LT > RT ? LT - RT : RT - LT ))
    if [ "$SKEW" -le 30 ]; then
        ok "$FARM_HOST=$RHN, clock skew ${SKEW}s (<=30s)"
    else
        bad "$FARM_HOST=$RHN, clock skew ${SKEW}s (>30s — NFS/make rebuild hazard)"
    fi
fi

echo "=============================================================="
if [ "$fail" -eq 0 ]; then
    echo " RESULT: PASS — safe to use FPGA_REMOTE_HOSTS with $FARM_HOST"
    echo "   make TARGET=<t> build_design \\"
    echo "        FPGA_REMOTE_HOSTS=\"$LOCAL_HOST 4 $FARM_HOST 8\""
else
    echo " RESULT: FAIL — fix the blockers above before farming"
fi
echo "=============================================================="
exit "$fail"
