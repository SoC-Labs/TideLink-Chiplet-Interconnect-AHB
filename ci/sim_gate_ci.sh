#!/usr/bin/env bash
# CI driver for the self-hosted GitHub Actions runner (docs/CI_RUNNER.md).
#
#   ci/sim_gate_ci.sh quick|full|static
#
#   static  seconds: gate self-checks, registry coverage, host-address lint, registry HTML freshness
#   quick   static + FC-node CRC SVA (make fc_sva) + `make sim_gate_quick`            (pull_request)
#   full    static + `make sim_gate` + `make fc_sva_full` (+ VC Formal if TL_RUN_FORMAL=1)  (nightly)
#
# Writes $GATE_OUT (default imp/ci): GATE_EXIT (0 = green), summary.txt, per-step logs.
# The driver itself exits 0 once it got far enough to produce those files, so the workflow can
# upload artifacts before it fails the job from GATE_EXIT.  Exit 3 = runner mis-configuration.
#
# Runner environment (set in the runner's .env file, NOT in this repo):
#   CHIPLET_HOME, TIDECHART_HOME   pinned external trees (see docs/CI_RUNNER.md)
#   TL_SITE_ENV                    path to the lab's site.env (tool + IP roots; never committed)
#   TL_XHB500_GENERATED            (optional) dir to copy into deps/xhb500/generated if absent
#   TL_RUN_FORMAL=1                (optional) also run the VC Formal proof in `full`
set -u
MODE=${1:-}
case "$MODE" in quick|full|static) ;; *) echo "usage: $0 quick|full|static" >&2; exit 2;; esac
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
OUT=${GATE_OUT:-$ROOT/imp/ci}
rm -rf "$OUT"; mkdir -p "$OUT"; : > "$OUT/summary.txt"

say()  { echo "$*" | tee -a "$OUT/summary.txt"; }
die()  { echo "::error::$*"; echo "CI-SETUP-ERROR: $*" >> "$OUT/summary.txt"; echo 3 > "$OUT/GATE_EXIT"; exit 3; }

for v in CHIPLET_HOME TIDECHART_HOME TL_SITE_ENV; do
  [ -n "${!v:-}" ] || die "runner env var $v is not set (docs/CI_RUNNER.md, 'Environment')"
done
[ -d "$CHIPLET_HOME" ]   || die "CHIPLET_HOME is not a directory on this runner"
[ -d "$TIDECHART_HOME" ] || die "TIDECHART_HOME is not a directory on this runner"
if [ ! -f site.env ]; then
  [ -f "$TL_SITE_ENV" ] || die "TL_SITE_ENV does not point at a file"
  cp "$TL_SITE_ENV" site.env && chmod 600 site.env          # never printed, never uploaded
fi
if [ ! -d deps/xhb500/generated ] && [ -n "${TL_XHB500_GENERATED:-}" ]; then
  [ -d "$TL_XHB500_GENERATED" ] || die "TL_XHB500_GENERATED is not a directory"
  mkdir -p deps/xhb500 && cp -a "$TL_XHB500_GENERATED" deps/xhb500/generated
fi
[ -d deps/xhb500/generated ] || die "deps/xhb500/generated missing: set TL_XHB500_GENERATED on the runner"
export CHIPLET_HOME TIDECHART_HOME

# set_env.sh is not nounset-clean
{ set +u; source ./set_env.sh; } > "$OUT/set_env.out" 2>&1 || die "set_env.sh failed (see runner-side $OUT/set_env.out)"

rc_all=0
step() {   # name cmd...   -- runs, logs, records, never aborts the driver
  local name=$1; shift
  local t0=$(date +%s)
  "$@" > "$OUT/$name.log" 2>&1; local rc=$?
  say "STEP $name rc=$rc ($(( $(date +%s) - t0 ))s)"
  [ $rc = 0 ] || { rc_all=1; tail -n 25 "$OUT/$name.log" | sed 's/^/    | /' | tee -a "$OUT/summary.txt" >/dev/null; }
  return 0
}

# (quick/full run selfcheck_gates themselves as a prerequisite of sim_gate*, ~3 min: not repeated here)
[ "$MODE" = static ] && step selfcheck_gates make selfcheck_gates
step registry_coverage       make sim_gate_registry_coverage
step check_host_addrs        make check_host_addrs
step bug_registry_html_check make bug_registry_html_check
# NOTE: `make sim_gate_inventory` is deliberately NOT here: it exits 2 on main eb94efac (reports the
# whole suite list as ORPHAN). Re-enable once fixed.

case "$MODE" in
  quick)
    step fc_sva     make fc_sva
    step sim_gate   make sim_gate_quick ;;
  full)
    step sim_gate   make sim_gate
    step fc_sva     make fc_sva_full
    if [ "${TL_RUN_FORMAL:-0}" = 1 ]; then step formal verif/formal/ci_formal.sh; fi ;;
esac

# collect the per-suite one-liners and the aggregate table
if [ -d imp/sim_gate ]; then
  mkdir -p "$OUT/sim_gate"; cp imp/sim_gate/*.status imp/sim_gate/*.log "$OUT/sim_gate/" 2>/dev/null
  { echo; echo "== per-suite status =="; cat imp/sim_gate/*.status 2>/dev/null; } >> "$OUT/summary.txt"
fi
if [ -f imp/fc_sva/summary.txt ]; then
  mkdir -p "$OUT/fc_sva"; cp imp/fc_sva/summary.txt "$OUT/fc_sva/"
  { echo; echo "== fc_sva =="; cat imp/fc_sva/summary.txt; } >> "$OUT/summary.txt"
fi

echo "$rc_all" > "$OUT/GATE_EXIT"
say "GATE_EXIT=$rc_all mode=$MODE sha=$(git rev-parse --short HEAD 2>/dev/null)"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo '```'; cat "$OUT/summary.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
exit 0
