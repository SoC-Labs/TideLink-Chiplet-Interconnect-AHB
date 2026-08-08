#!/bin/bash
# =============================================================================
# run_all.sh — Top-level orchestrator for the TideLink HW test suite.
#
# Runs the 13 category scripts in order, aggregates pass/fail/skip, and emits
# a single coverage matrix + verdict at the end. Each category script returns
# 0 on all-pass, !=0 on any failure; this orchestrator records each one and
# continues (unless a fatal AHB_TX-wedge exit code is seen, in which case it
# stops immediately to avoid further damage).
#
# Configuration (env):
#   HWTEST_INCLUDE        comma-list of category numbers (e.g. "1,2,12")
#                         default = "1,2,3,4,6,7,8,10,11,12" (safe-no-AHBTX set)
#                         "all" = 1..13 (includes AHB_TX-storm)
#                         "safe" = exclude 5 (AHB_TX) and 13 (soak)
#   HWTEST_EXCLUDE        comma-list to exclude (applied after include)
#   HWTEST_ACQUIRE_LEASE  if 1, acquire bridge1 fpgahub lease at start +
#                         release on exit (default 0 — caller manages lease)
#   HWTEST_LEASE_TTL      seconds (default 3600)
#   HWTEST_BAIL_ON_FAIL   if 1, stop at first category failure (default 0)
#
# Exit codes:
#   0   all selected categories passed
#   1   one or more categories had a sub-test failure
#   3   AHB_TX gate refused — link not 16/16 (test 5 only)
#   4   AHB_TX write timed out — board possibly wedged (test 5 only)
#   5   setup error (lease, deploy bins, ssh)
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/lib_hwtest.sh"

: "${HWTEST_INCLUDE:=1,2,3,4,6,7,8,10,11,12}"
: "${HWTEST_EXCLUDE:=}"
: "${HWTEST_BAIL_ON_FAIL:=0}"
: "${HWTEST_ACQUIRE_LEASE:=0}"
: "${HWTEST_LEASE_TTL:=3600}"

CATEGORIES=(
    "1:01_wlink_layer.sh:Wlink layer (PHY-ID, lanes, ECC, retrain, fault-inject)"
    "2:02_tidelink_top_regs.sh:Region 0 top-system regs"
    "3:03_ahb_sub_e2e.sh:AHB SUB end-to-end (XHB500+Wlink+FC, safe path)"
    "4:04_ahb_mng_incoming.sh:AHB MNG incoming credit/doorbell accounting"
    "5:05_ahb_tx_storm.sh:AHB TX (the wedge-hazard path) — GATED"
    "6:06_ahb_fifo.sh:AHB FIFO (overrun/underrun/CTRL.FLUSH/RELEASE_THRESH)"
    "7:07_addr_translation.sh:PAIR_BASE_ADDR / addr-translator"
    "8:08_ptp_basic.sh:PTP basic (R1 0x034/0x038/0x03C)"
    "9:09_ptp_hw_sync.sh:PTP HW sync (R2; GATED on PHC image)"
    "10:10_servo_mailbox.sh:Servo cfg + timestamp mailbox"
    "11:11_perf_counters.sh:Performance counters (R5/R6/R7)"
    "12:12_chiplet_phyalign.sh:Chiplet ext (R8: PHY-align/I2C-train)"
    "13:13_long_soak.sh:Long soak (safe-ops only)"
    "14:14_rx_fifo_phantom_pop.sh:RX-FIFO empty-read phantom-pop guard (TL-022, credit<=MAX)"
)

# Resolve include/exclude.
if [ "$HWTEST_INCLUDE" = "all" ]; then HWTEST_INCLUDE="1,2,3,4,5,6,7,8,9,10,11,12,13"; fi
if [ "$HWTEST_INCLUDE" = "safe" ]; then HWTEST_INCLUDE="1,2,3,4,6,7,8,9,10,11,12"; fi

want_cat() {  # NUM -> 0 if included, 1 if not
    local num=$1
    case ",$HWTEST_INCLUDE," in *,$num,*) ;; *) return 1 ;; esac
    case ",$HWTEST_EXCLUDE," in *,$num,*) return 1 ;; *) ;; esac
    return 0
}

# ---------------------------------------------------------------------------
# Lease handling (optional)
# ---------------------------------------------------------------------------
lease_held=0
release_lease() {
    if [ "$lease_held" -eq 1 ]; then
        tt_info "releasing bridge1 lease..."
        ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease release bridge1" >/dev/null 2>&1 || \
            tt_warn "lease release failed"
        lease_held=0
    fi
}
trap release_lease EXIT INT TERM

if [ "$HWTEST_ACQUIRE_LEASE" = "1" ]; then
    tt_info "acquiring bridge1 lease (TTL ${HWTEST_LEASE_TTL}s)..."
    if ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease acquire bridge1 --user \$(whoami) --ttl $HWTEST_LEASE_TTL" 2>&1 | tee /tmp/hwtest_lease.log | grep -qi 'granted'; then
        lease_held=1
        tt_pass "bridge1 lease granted"
    else
        tt_err "could not acquire bridge1 lease — aborting"
        exit 5
    fi
fi

# ---------------------------------------------------------------------------
# Run loop
# ---------------------------------------------------------------------------
declare -A CAT_RC

T0=$(date +%s)
printf "\n=== TideLink HW test suite — run_all.sh ===\n"
printf "  include = %s\n" "$HWTEST_INCLUDE"
printf "  exclude = %s\n" "${HWTEST_EXCLUDE:-<none>}"
printf "  master  = %s\n  slave   = %s\n" "$MASTER_IP" "$SLAVE_IP"
printf "  logdir  = %s\n" "$HWTEST_LOGDIR"
printf "\n"

for entry in "${CATEGORIES[@]}"; do
    num="${entry%%:*}"
    rest="${entry#*:}"
    script="${rest%%:*}"
    desc="${rest#*:}"
    if ! want_cat "$num"; then
        CAT_RC[$num]="skip"
        continue
    fi
    logf="$HWTEST_LOGDIR/cat${num}_$(date +%Y%m%d_%H%M%S).log"
    printf "\n--- [%s] %s ---\n" "$num" "$desc"
    bash "$SCRIPT_DIR/$script" 2>&1 | tee "$logf"
    rc=${PIPESTATUS[0]}
    CAT_RC[$num]="$rc"
    if [ "$rc" -ne 0 ]; then
        tt_warn "category $num exited rc=$rc (log: $logf)"
        case "$rc" in
            3) tt_err "AHB_TX gate refused — stopping"; break ;;
            4) tt_err "AHB_TX wedge — STOPPING IMMEDIATELY"; break ;;
        esac
        [ "$HWTEST_BAIL_ON_FAIL" = "1" ] && break
    fi
done

T1=$(date +%s)
ELAPSED=$(( T1 - T0 ))

# ---------------------------------------------------------------------------
# Coverage matrix output
# ---------------------------------------------------------------------------
printf "\n=============================================================\n"
printf " COVERAGE MATRIX (elapsed %ds)\n" "$ELAPSED"
printf "=============================================================\n"
printf " %-3s | %-7s | %s\n" "Cat" "Result" "Description"
printf " %-3s-+-%-7s-+-%s\n" "---" "-------" "----------------------------------"
overall=0
for entry in "${CATEGORIES[@]}"; do
    num="${entry%%:*}"
    rest="${entry#*:}"
    desc="${rest#*:}"
    rc="${CAT_RC[$num]:-skip}"
    case "$rc" in
        0)    tag="PASS" ;;
        skip) tag="-" ;;
        3)    tag="GATE"; overall=1 ;;
        4)    tag="WEDGE"; overall=1 ;;
        *)    tag="FAIL"; overall=1 ;;
    esac
    printf " %-3s | %-7s | %s\n" "$num" "$tag" "$desc"
done
printf "=============================================================\n"
if [ "$overall" -eq 0 ]; then
    printf " VERDICT: PASS (all selected categories)\n"
else
    printf " VERDICT: FAIL (one or more categories failed)\n"
fi
printf "=============================================================\n"

exit "$overall"
