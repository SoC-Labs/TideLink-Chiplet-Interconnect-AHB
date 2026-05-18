#!/bin/bash
# =============================================================================
# determinism_metric.sh — objective lane-lock determinism metric for the
# TideLink GPIO source-sync PHY, computed across N supervisor-run builds.
#
# WHAT THIS IS / IS NOT
#   - It does NOT build, run Vivado, deploy, or touch a board.
#   - It is a pure log-ingest + analysis tool. The supervising session
#     produces N independent builds, runs `phase_recal_sweep.sh` against
#     each pair (and optionally `wlink_probe.sh` for the Region-8 RO
#     credit-path mirror), and feeds the resulting logs to this script.
#   - It emits ONE objective verdict so a candidate constraint / IDELAY /
#     clock-path fix can be judged against the current ~1-in-N luck.
#
# THE METRIC  (see docs/DETERMINISM_VALIDATION.md for the rationale)
#   Per build b (= one sweep log), parse every (mp,sp) row's MASTER and
#   SLAVE locked-popcount. Define a point "both-sides-good" (BSG) iff
#   master#==8 AND slave#==8 at that (mp,sp) (configurable via
#   LOCK_TARGET, default 8 = all lanes). For each build derive:
#       hasBSG[b]   : 1 if ANY (mp,sp) is BSG in build b, else 0
#       bestpt[b]   : the (mp,sp) with the highest master#+slave# total
#       bsgset[b]   : the SET of (mp,sp) that are BSG in build b
#
#   The determinism metric D is the triple:
#
#     (1) BSG-yield      = (#builds with hasBSG==1) / N
#                          "does a both-sides-good operating point reliably
#                           exist at all, build to build"
#     (2) common-BSG     = | intersection of bsgset over all builds |
#                          divided by | union of bsgset over all builds |
#                          (Jaccard). "is it the SAME operating point every
#                           build, or does the good (mp,sp) wander"
#     (3) best-pt spread = number of DISTINCT bestpt[b] across builds,
#                          and the max Chebyshev distance between any two
#                          bestpt in (mp,sp) grid steps. "how far does the
#                          best operating point move build to build"
#
#   Scalar determinism score (0..100, higher = more deterministic):
#       D_score = round( 100 * BSG-yield * common-BSG-Jaccard )
#   with a hard floor of 0 if BSG-yield==0 (no build ever had a BSG point).
#
#   PASS/FAIL (default thresholds, override via env):
#       PASS  iff  BSG-yield      >= YIELD_PASS   (default 1.00 — every
#                                                   build must have a BSG)
#             AND  common-BSG-Jac >= JACCARD_PASS (default 0.50 — the good
#                                                   set is majority-stable)
#             AND  bestpt distinct count          <= BESTPT_PASS (default 1
#                                                   — the single best point
#                                                   is identical every build)
#   The "current ~1-in-N luck" baseline fails on BSG-yield alone
#   (yield ≈ 1/N << 1.00). A real fix must lift yield to ~1.0 AND keep the
#   good set/point stable; raising WNS without doing both does not pass.
#
# INPUTS  (the supervisor feeds these — script consumes, never produces)
#   determinism_metric.sh LOG1 [LOG2 ... LOGN]
#     where each LOGk is the captured stdout of one independent build's
#     phase_recal_sweep.sh run (the table + "BEST total=" footer).
#   OR
#   determinism_metric.sh -d LOGDIR
#     ingest every *.log / *.txt in LOGDIR as one build each.
#
#   Optional Region-8 RO credit-path corroboration: if a sibling file
#   "<LOGk>.probe" exists (captured `wlink_probe.sh BOARD_IP` output for
#   that build at its best (mp,sp)), the script cross-checks that the
#   probe's SWI_LANE_STATUS locked byte and FCSM/cr_pkt_seen agree with
#   the sweep's reported lock for that build, and flags disagreement
#   (a build that "sweep-locked" but whose credit path is wedged is NOT
#   counted BSG — lock without a moving credit path is not determinism).
#
# RECOMMENDED PROCEDURE (documented; supervisor executes)
#   N >= 5 independent builds (more is better; 5 is the minimum to
#   distinguish 1-in-N luck from a real fix at the default thresholds).
#   Each build: full place&route from clean, deploy the pair, run
#     MP_LIST="0 2" SP_LIST="0 1 2 3 4 5 6 8 10 12" phase_recal_sweep.sh
#   capture stdout to buildK.log. Optionally also capture wlink_probe.sh
#   at the build's BEST (mp,sp) to buildK.log.probe. Then:
#     determinism_metric.sh build1.log build2.log ... buildN.log
#
# Board ssh, IF a caller wants this script to also pull a fresh probe
# (it does not by default), is:
#     SSH_AUTH_SOCK=/tmp/dam1n19-agent.sock ssh mapstone-dev ...
#   scp is broken on these hosts; copy with:  ssh 'cat >dst' <src
#   (This script does NOT do that — it only ingests files already on disk.)
#
# A joint work commissioned on behalf of SoC Labs, under Arm Academic
# Access license.  David Mapstone (d.a.mapstone@soton.ac.uk)
# Copyright 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

# ---- Tunables (env-overridable) --------------------------------------------
LOCK_TARGET="${LOCK_TARGET:-8}"        # popcount considered a fully-locked side
YIELD_PASS="${YIELD_PASS:-1.00}"       # min fraction of builds with a BSG point
JACCARD_PASS="${JACCARD_PASS:-0.50}"   # min stability of the BSG (mp,sp) set
BESTPT_PASS="${BESTPT_PASS:-1}"        # max #distinct best (mp,sp) across builds

usage() {
    sed -n '2,70p' "$0"
    echo
    echo "Usage: $0 LOG1 [LOG2 ... LOGN]"
    echo "       $0 -d LOGDIR"
    echo "Env: LOCK_TARGET($LOCK_TARGET) YIELD_PASS($YIELD_PASS)" \
         "JACCARD_PASS($JACCARD_PASS) BESTPT_PASS($BESTPT_PASS)"
    exit "${1:-2}"
}

[ $# -ge 1 ] || usage 2
case "${1:-}" in
    -h|--help) usage 0 ;;
    -d) [ $# -eq 2 ] || usage 2
        LOGDIR="$2"
        [ -d "$LOGDIR" ] || { echo "ERR: not a dir: $LOGDIR" >&2; exit 2; }
        # shellcheck disable=SC2207
        LOGS=($(ls -1 "$LOGDIR"/*.log "$LOGDIR"/*.txt 2>/dev/null))
        ;;
    *)  LOGS=("$@") ;;
esac

N=${#LOGS[@]}
[ "$N" -ge 1 ] || { echo "ERR: no logs found" >&2; exit 2; }
if [ "$N" -lt 5 ]; then
    echo "WARN: only $N build log(s); >=5 recommended to separate" \
         "a real fix from 1-in-N luck at the default thresholds." >&2
fi

# Workspace for per-build derived facts.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/td_det.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# ---- Parse each build log --------------------------------------------------
# phase_recal_sweep.sh table row format (printf in that script):
#   "%-4s %-4s | %-22s | %-22s | %s"
#   MP  SP  | <Mlk Mft M#>          | <Slk Sft S#>          | total
# We extract: mp, sp, master#(field after 2nd '|' group, 3rd token),
#             slave#(after 3rd '|' group, 3rd token).
# Footer line: "BEST total=<n>  @ mp=<m> sp=<s> (...)" — used as a sanity
# cross-check only; bestpt is recomputed from the table for robustness.

bsg_union="$TMP/bsg_union"; : > "$bsg_union"
declare -a HASBSG BESTPT
build_idx=0

for LG in "${LOGS[@]}"; do
    if [ ! -r "$LG" ]; then
        echo "ERR: cannot read log: $LG" >&2; exit 2
    fi
    bsg_b="$TMP/bsg.$build_idx"; : > "$bsg_b"
    best_tot=-1; best_pt=""
    bsg_count=0; row_count=0

    # Read only well-formed data rows: "<int> <int> | ... | ... | <int>"
    while IFS= read -r line; do
        case "$line" in
            *"|"*"|"*"|"*) : ;;        # has the 3 pipe separators
            *) continue ;;
        esac
        # Split on '|'
        f0=${line%%|*}; rest=${line#*|}
        mfield=${rest%%|*}; rest=${rest#*|}
        sfield=${rest%%|*}; tfield=${rest##*|}
        # mp sp from f0
        set -- $f0; mp=${1:-}; sp=${2:-}
        case "$mp$sp" in *[!0-9]*|"") continue ;; esac
        # master# = 3rd token of mfield ("0x.. 0x.. N"), slave# likewise
        set -- $mfield; mnum=${3:-}
        set -- $sfield; snum=${3:-}
        set -- $tfield; tot=${1:-}
        case "$mnum$snum" in *[!0-9]*|"") continue ;; esac
        row_count=$((row_count+1))
        # bestpt = max (master#+snum); recompute, do not trust footer
        sum=$((mnum + snum))
        if [ "$sum" -gt "$best_tot" ]; then
            best_tot=$sum; best_pt="$mp,$sp"
        fi
        # both-sides-good?
        if [ "$mnum" -ge "$LOCK_TARGET" ] && [ "$snum" -ge "$LOCK_TARGET" ]; then
            echo "$mp,$sp" >> "$bsg_b"
            bsg_count=$((bsg_count+1))
        fi
    done < "$LG"

    if [ "$row_count" -eq 0 ]; then
        echo "ERR: $LG has no parseable phase_recal_sweep rows" >&2
        echo "     (is this the captured stdout of phase_recal_sweep.sh?)" >&2
        exit 2
    fi

    sort -u "$bsg_b" -o "$bsg_b"
    cat "$bsg_b" >> "$bsg_union"

    if [ "$bsg_count" -gt 0 ]; then HASBSG[$build_idx]=1
    else HASBSG[$build_idx]=0; fi
    BESTPT[$build_idx]="$best_pt"

    # Optional Region-8 RO credit-path corroboration.
    probe="$LG.probe"; probe_note=""
    if [ -r "$probe" ]; then
        # Pull the SWI_LANE_STATUS locked= byte and the FCSM state +
        # cr_pkt_seen_rx that wlink_probe.sh prints. A build whose sweep
        # claimed lock but whose credit path is wedged is downgraded.
        lk=$(grep -o 'locked=0x[0-9a-fA-F]*' "$probe" | head -1 | cut -d= -f2)
        fcsm=$(grep -o 'FCSM state[ ]*: [0-9]*' "$probe" | head -1 \
                 | grep -o '[0-9]*$')
        crpkt=$(grep -o 'cr_pkt_seen_rx[ ]*: [0-9]*' "$probe" | head -1 \
                 | grep -o '[0-9]*$')
        lkpop=0
        if [ -n "${lk:-}" ]; then
            v=$((lk)); while [ "$v" -ne 0 ]; do
                lkpop=$((lkpop + (v & 1))); v=$((v >> 1)); done
        fi
        # FCSM wedged at 1 (per wlink_probe.sh note) OR no cr_pkt seen =>
        # credit path not actually moving; revoke this build's BSG.
        if [ "${HASBSG[$build_idx]}" = "1" ]; then
            if [ "${fcsm:-9}" = "1" ] || [ "${crpkt:-1}" = "0" ] \
               || { [ -n "${lk:-}" ] && [ "$lkpop" -lt "$LOCK_TARGET" ]; }
            then
                HASBSG[$build_idx]=0
                : > "$bsg_b"   # its BSG set is invalid for stability calc
                probe_note=" [PROBE REVOKED BSG: fcsm=${fcsm:-?} cr_pkt=${crpkt:-?} probe_lockpop=$lkpop]"
            else
                probe_note=" [probe OK: lockpop=$lkpop fcsm=${fcsm:-?}]"
            fi
        fi
    fi

    printf 'build %2d  %-32s  hasBSG=%s  best=(%s) tot=%d  bsgpts=%d%s\n' \
        "$build_idx" "$(basename "$LG")" "${HASBSG[$build_idx]}" \
        "${best_pt:-none}" "$best_tot" "$bsg_count" "$probe_note"

    build_idx=$((build_idx+1))
done

# ---- Aggregate the metric --------------------------------------------------
sort -u "$bsg_union" -o "$bsg_union"
UNION_SZ=$(wc -l < "$bsg_union" | tr -d ' ')

# BSG-yield
yes=0
for i in $(seq 0 $((N-1))); do
    [ "${HASBSG[$i]}" = "1" ] && yes=$((yes+1))
done
YIELD=$(awk -v y="$yes" -v n="$N" 'BEGIN{printf "%.4f", (n? y/n:0)}')

# common-BSG = | intersection over builds with hasBSG | / | union |
# Intersection: a point that is BSG in EVERY build that had any BSG.
qual=0; : > "$TMP/inter"
first=1
for i in $(seq 0 $((N-1))); do
    [ "${HASBSG[$i]}" = "1" ] || continue
    qual=$((qual+1))
    bsg_b="$TMP/bsg.$i"
    if [ "$first" = "1" ]; then
        cp "$bsg_b" "$TMP/inter"; first=0
    else
        comm -12 "$TMP/inter" "$bsg_b" > "$TMP/inter.n" 2>/dev/null
        mv "$TMP/inter.n" "$TMP/inter"
    fi
done
INTER_SZ=0
[ -s "$TMP/inter" ] && INTER_SZ=$(wc -l < "$TMP/inter" | tr -d ' ')
JACCARD=$(awk -v i="$INTER_SZ" -v u="$UNION_SZ" \
            'BEGIN{printf "%.4f", (u? i/u:0)}')

# best-pt spread
: > "$TMP/best"
for i in $(seq 0 $((N-1))); do
    [ -n "${BESTPT[$i]}" ] && echo "${BESTPT[$i]}" >> "$TMP/best"
done
DISTINCT_BEST=$(sort -u "$TMP/best" | grep -c , || true)
# max Chebyshev distance between any two best points (grid steps)
MAXCHEB=$(sort -u "$TMP/best" | awk -F, '
    {mp[NR]=$1; sp[NR]=$2; n=NR}
    END{m=0; for(a=1;a<=n;a++)for(b=a+1;b<=n;b++){
        dmp=mp[a]-mp[b]; if(dmp<0)dmp=-dmp;
        dsp=sp[a]-sp[b]; if(dsp<0)dsp=-dsp;
        d=(dmp>dsp?dmp:dsp); if(d>m)m=d;}
        print m+0}')

# Scalar score
D_SCORE=$(awk -v y="$YIELD" -v j="$JACCARD" \
            'BEGIN{printf "%d", (y>0 ? 100*y*j + 0.5 : 0)}')

# ---- Verdict ---------------------------------------------------------------
PASS=1
awk -v a="$YIELD"   -v b="$YIELD_PASS"   'BEGIN{exit !(a+0 >= b+0)}' || PASS=0
awk -v a="$JACCARD" -v b="$JACCARD_PASS" 'BEGIN{exit !(a+0 >= b+0)}' || PASS=0
[ "$DISTINCT_BEST" -le "$BESTPT_PASS" ] 2>/dev/null || PASS=0

echo
echo "================ TideLink lane-lock determinism ================"
echo "  builds ingested (N)        : $N"
echo "  builds with a BSG point    : $yes  (qualifying for stability: $qual)"
echo "  LOCK_TARGET (per side)     : $LOCK_TARGET lanes"
echo "  -- metric --"
printf "  (1) BSG-yield              : %s   (pass >= %s)\n" "$YIELD" "$YIELD_PASS"
printf "  (2) common-BSG Jaccard     : %s   (|inter|=%s / |union|=%s; pass >= %s)\n" \
        "$JACCARD" "$INTER_SZ" "$UNION_SZ" "$JACCARD_PASS"
printf "  (3) best-pt distinct count : %s   (pass <= %s; max Chebyshev=%s steps)\n" \
        "$DISTINCT_BEST" "$BESTPT_PASS" "$MAXCHEB"
printf "  D_score (0..100)           : %s\n" "$D_SCORE"
echo "  ----------------------------------------------------------------"
if [ "$PASS" = "1" ]; then
    echo "  VERDICT: PASS — a both-sides-good operating point reliably"
    echo "           exists AND is stable across builds. The change"
    echo "           improved determinism over 1-in-N luck."
    echo "================================================================"
    exit 0
else
    echo "  VERDICT: FAIL — determinism not demonstrated. The good"
    echo "           operating point does not reliably exist and/or"
    echo "           wanders build-to-build (still ~luck, not a fix)."
    echo "================================================================"
    exit 1
fi
