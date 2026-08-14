#!/usr/bin/env bash
# repeat_ab.sh — signature-consistency check for the TL-035 A/B.
#
# n=1 cannot separate "TL-035 deterministically CONVERTS the die_b signature"
# from "the recovery path is nondeterministic and the two arms happened to draw
# different signatures". This campaign has repeatedly shown per-POR lottery
# behaviour, so the conversion claim is gated on WITHIN-ARM CONSISTENCY:
#
#   baseline must reliably read all-clean   (0xad800000)
#   tl035    must reliably read ini_aw      (0xad408020)
#
# If baseline EVER shows ini_aw, or tl035 EVER shows all-clean, the delta is
# draw-noise and the conversion evaporates.
#
# Arms are ALTERNATED (B,A,B,A,...) rather than blocked, so any slow drift in
# rig state (thermal, lease churn, accumulated POR count) is shared between the
# arms instead of being confounded with them.
#
#   usage: KR260_PASSWORD=... repeat_ab.sh [reps_per_arm]
set -u
REPS="${1:-4}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/hw_gate/repeats"
mkdir -p "$BASE"
SUMMARY="$BASE/SIGNATURES.tsv"
[ -f "$SUMMARY" ] || printf "iter\tarm\tdie_b_pre\tdie_b_post\tdie_a_post\terrinject_rc\n" > "$SUMMARY"

for i in $(seq 1 "$REPS"); do
  for arm in tl035 baseline; do
    tag="r${i}_${arm}"
    echo "=== [$(date -u +%H:%M:%S)] repeat $i arm=$arm ==="
    OUTDIR="$BASE/$tag" LIVEPOLLS=0 KR260_PASSWORD="$KR260_PASSWORD" \
      bash "$HERE/run_arm.sh" "$arm" > "$BASE/$tag.driver.log" 2>&1
    d="$BASE/$tag/tl035_$arm"
    pre=$(grep -h "pre_inject die_b"  "$d/00_run.log" 2>/dev/null | tail -1 | grep -oE "0x[0-9a-f]{8}|UNREADABLE.*" | tail -1)
    post=$(grep -h "post_inject die_b" "$d/00_run.log" 2>/dev/null | tail -1 | grep -oE "0x[0-9a-f]{8}|UNREADABLE.*" | tail -1)
    diea=$(grep -h "post_inject die_a" "$d/00_run.log" 2>/dev/null | tail -1 | grep -oE "0x[0-9a-f]{8}|UNREADABLE.*" | tail -1)
    rc=$(grep -h "^errinject_rc=" "$d/99_verdict.txt" 2>/dev/null | cut -d= -f2)
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$i" "$arm" "${pre:-?}" "${post:-?}" "${diea:-?}" "${rc:-?}" >> "$SUMMARY"
    tail -1 "$SUMMARY"
  done
done

echo
echo "=== SIGNATURE CONSISTENCY ==="
column -t "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
awk -F'\t' 'NR>1{k=$2" "$4; c[k]++} END{for(x in c) printf "  %-28s %d\n", x, c[x]}' "$SUMMARY" | sort
echo
awk -F'\t' 'NR>1 && $2=="baseline" && $4=="0xad408020"{b++} NR>1 && $2=="tl035" && $4=="0xad800000"{t++}
END{ if(b||t) printf "  VERDICT: CONVERSION EVAPORATES — baseline showed ini_aw %d time(s), tl035 showed all-clean %d time(s)\n", b+0, t+0;
     else printf "  VERDICT: signatures CONSISTENT within each arm across all repeats\n" }' "$SUMMARY"
