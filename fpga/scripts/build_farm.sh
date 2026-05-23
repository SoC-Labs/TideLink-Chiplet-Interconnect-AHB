#!/usr/bin/env bash
###-----------------------------------------------------------------------------
### TideLink FPGA concurrent farm — N-job orchestrator
### A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
### license.
###
### Contributors
###
### David Mapstone (d.a.mapstone@soton.ac.uk)
###
### Copyright (C) 2026, SoC Labs (www.soclabs.org)
###-----------------------------------------------------------------------------
### Runs a set of whole-TARGET Vivado builds CONCURRENTLY, each pinned to a
### host. This is independent-job farming — it does NOT need the NFS export
### that Vivado `launch_runs -host` (FPGA_REMOTE_HOSTS) requires; the only
### dependency for a remote host is passwordless ssh (setup_farm_ssh.sh) +
### Vivado 2024.1 at the same path + the shared /research IP mount.
###
###   build_farm.sh  TARGET@HOST  [TARGET@HOST ...]
###     HOST = local                      build on this box
###     HOST = <farm hostname>            ssh+rsync to that host
###
###   e.g.  build_farm.sh pynq-z2-pair-all@local pynq-z2-pair-flip-all@srv04936
###
### Sequence:
###   1. package_ip ONCE locally (shared IP repo) iff any job is local —
###      so the parallel build_design fan-out can't race the IP repo.
###   2. one farm_build.sh per job, all in parallel, per-job logfile.
###   3. join; print a status table; non-zero exit if any job failed.
### Artefacts land at imp/fpga/output/<TARGET>/ (identical for local & farmed)
### so `make deploy` / deploy_pair consume them with no change.
###-----------------------------------------------------------------------------
set -u

[ "$#" -ge 1 ] || { echo "usage: build_farm.sh TARGET@HOST [TARGET@HOST ...]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIDELINK_HOME="$(cd "$SCRIPT_DIR/../.." && pwd)"
FPGA_DIR="$TIDELINK_HOME/fpga"
FARM_BUILD="$SCRIPT_DIR/farm_build.sh"
LOG_DIR="$TIDELINK_HOME/imp/fpga/run/farm"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ---- parse + validate jobs --------------------------------------------------
declare -a JOB_T JOB_H
declare -A SEEN_TARGET
ANY_LOCAL=0
for job in "$@"; do
    case "$job" in
        *@*) : ;;
        *) echo "ERROR: job '$job' is not TARGET@HOST" >&2; exit 2 ;;
    esac
    t="${job%@*}"; h="${job##*@}"
    [ -n "$t" ] && [ -n "$h" ] || { echo "ERROR: job '$job' malformed" >&2; exit 2; }
    # One artefact dir per TARGET (imp/fpga/output/<TARGET>): the same TARGET
    # on two hosts would race that dir — reject it explicitly.
    if [ -n "${SEEN_TARGET[$t]:-}" ]; then
        echo "ERROR: TARGET '$t' appears twice — outputs would collide" >&2; exit 2
    fi
    SEEN_TARGET[$t]=1
    JOB_T+=("$t"); JOB_H+=("$h")
    case "$h" in local|localhost|"$(hostname -s)"|"$(hostname -f)") ANY_LOCAL=1 ;; esac
done
N=${#JOB_T[@]}

echo "=============================================================="
echo " TideLink concurrent farm — $N job(s)  ($(ts))"
for i in "${!JOB_T[@]}"; do printf '   %-26s -> %s\n' "${JOB_T[$i]}" "${JOB_H[$i]}"; done
echo "=============================================================="

# ---- shared package_ip (once, locally) for any local job -------------------
# package_ip writes the TARGET-independent IP repo imp/fpga/tidelink_ip;
# farm_build.sh runs the local builds with SKIP_PACKAGE_IP=1 so they reuse
# this one repo instead of N concurrent writers corrupting it. Remote jobs
# package_ip in their own rsync'd tree, so this is skipped if all-remote.
if [ "$ANY_LOCAL" -eq 1 ]; then
    echo "[$(ts)] package_ip (once, local) ..."
    export ARM_IP_LIBRARY_PATH="${ARM_IP_LIBRARY_PATH:-/research/AAA/ip_library}"
    export CMSDK_DIR="${CMSDK_DIR:-$ARM_IP_LIBRARY_PATH/BP210/BP210-BU-00000-r1p1-00rel0}"
    export CMSDK_FPGA_SRAM_V="${CMSDK_FPGA_SRAM_V:-$CMSDK_DIR/logical/models/memories/cmsdk_fpga_sram.v}"
    # shellcheck disable=SC1091
    source "$TIDELINK_HOME/set_env.sh" >/dev/null 2>&1 || true
    PKG_LOG="$LOG_DIR/package_ip.$STAMP.log"
    if ! make -C "$FPGA_DIR" package_ip > "$PKG_LOG" 2>&1; then
        echo "ERROR: local package_ip failed — see $PKG_LOG" >&2
        tail -n 25 "$PKG_LOG" >&2
        exit 1
    fi
    echo "[$(ts)] package_ip OK"
    # Also package the PHC IP (sibling repo) once. The BD on -all + base
    # targets uses the PHC IP from the local PHC_IP_OUTPUT_DIR; per-target
    # builds run with SKIP_PACKAGE_IP=1 and would otherwise hit
    # `[BD 5-390] IP definition not found for VLNV soclabs.org:user:phc_vivado_wrapper:1.0`
    # at create_bd_cell time. Skipped if PHC_REPO_DIR isn't set/present
    # (older trees without the PHC integration still build).
    PHC_REPO_DIR_DEFAULT="${PHC_REPO_DIR:-$HOME/SoCLabs/ptp-hardware-clock-ahb}"
    if [ -d "$PHC_REPO_DIR_DEFAULT" ]; then
        echo "[$(ts)] package_phc_ip (once, local) ..."
        PHC_PKG_LOG="$LOG_DIR/package_phc_ip.$STAMP.log"
        if ! PHC_REPO_DIR="$PHC_REPO_DIR_DEFAULT" \
             make -C "$FPGA_DIR" package_phc_ip > "$PHC_PKG_LOG" 2>&1; then
            echo "ERROR: local package_phc_ip failed — see $PHC_PKG_LOG" >&2
            tail -n 25 "$PHC_PKG_LOG" >&2
            exit 1
        fi
        echo "[$(ts)] package_phc_ip OK"
    else
        echo "[$(ts)] package_phc_ip skipped (PHC_REPO_DIR=$PHC_REPO_DIR_DEFAULT not present)"
    fi
fi

# ---- fan out: one farm_build.sh per job, all concurrent --------------------
declare -a JOB_PID JOB_LOG JOB_START
for i in "${!JOB_T[@]}"; do
    t="${JOB_T[$i]}"; h="${JOB_H[$i]}"
    log="$LOG_DIR/${t}@${h}.$STAMP.log"
    JOB_LOG[$i]="$log"
    JOB_START[$i]=$(date +%s)
    echo "[$(ts)] launch  $t@$h   (log: ${log#$TIDELINK_HOME/})"
    # FPGA_INSERT_DEBUG_CORE / FPGA_NUM_JOBS / REMOTE_ROOT / SSH_OPTS flow
    # through from the caller's environment into farm_build.sh.
    ( "$FARM_BUILD" "$t" "$h" ) > "$log" 2>&1 &
    JOB_PID[$i]=$!
done

# ---- join -------------------------------------------------------------------
declare -a JOB_RC JOB_WALL
fail=0
for i in "${!JOB_T[@]}"; do
    if wait "${JOB_PID[$i]}"; then JOB_RC[$i]=0; else JOB_RC[$i]=$?; fail=1; fi
    JOB_WALL[$i]=$(( $(date +%s) - JOB_START[$i] ))
done

# ---- summary ----------------------------------------------------------------
echo ""
echo "=============================================================="
echo " Concurrent farm summary   ($(ts))"
echo "=============================================================="
printf ' %-26s %-12s %-7s %-8s %s\n' TARGET HOST STATUS WALL ARTEFACT
for i in "${!JOB_T[@]}"; do
    t="${JOB_T[$i]}"; h="${JOB_H[$i]}"
    mm=$(( JOB_WALL[$i] / 60 )); ss=$(( JOB_WALL[$i] % 60 ))
    if [ "${JOB_RC[$i]}" -eq 0 ]; then
        st="PASS"
        art="imp/fpga/output/$t/tidelink.bit"
    else
        st="FAIL"
        art="${JOB_LOG[$i]#$TIDELINK_HOME/}"
    fi
    printf ' %-26s %-12s %-7s %2dm%02ds  %s\n' "$t" "$h" "$st" "$mm" "$ss" "$art"
done
echo "=============================================================="

if [ "$fail" -ne 0 ]; then
    echo ""
    for i in "${!JOB_T[@]}"; do
        [ "${JOB_RC[$i]}" -eq 0 ] && continue
        echo "----- tail ${JOB_LOG[$i]#$TIDELINK_HOME/} (${JOB_T[$i]}@${JOB_H[$i]}) -----"
        tail -n 20 "${JOB_LOG[$i]}"
        echo ""
    done
    echo " RESULT: FAIL — $(( $(printf '%s\n' "${JOB_RC[@]}" | grep -cv '^0$') )) of $N job(s) failed"
    exit 1
fi
echo " RESULT: PASS — all $N job(s) built"
exit 0
