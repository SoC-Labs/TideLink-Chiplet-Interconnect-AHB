#!/usr/bin/env bash
# reextract_signatures.sh — rebuild the signature table from the per-run logs.
#
# The live table written by repeat_ab.sh is UNRELIABLE from r2 onward: I added a
# LOCALMEM line that also contains "pre_inject die_b" and trailing hex, so the
# `grep ... | tail -1` extractor started picking the verify line's expected value
# (0xa5a50000) instead of the Region F word. The raw data is intact in each run's
# 00_run.log; this re-derives the table from it, anchored on OBS_AXI_NODES.
#
# It also marks runs where NO INJECT OCCURRED. errinject_rc=2 is the sweep's
# require_pair_fcsm4 abort — the link was not up when the sweep started, so the
# post-inject word is a NO-INJECT state and the run is not an A/B data point.
set -u
BASE="${1:-/tmpdir/claude-74755/-home-dam1n19-SoCLabs-tidelink/029fa128-e7f4-41b2-a3bf-6880af5cca50/scratchpad/hw_gate/repeats}"
printf "%-6s %-9s %-12s %-12s %-6s %-8s %s\n" RUN ARM DIE_B_PRE DIE_B_POST RC VALID NOTE
for d in "$BASE"/r*_*/; do
  tag=$(basename "$d"); arm=${tag#*_}; run=${tag%%_*}
  log=$(ls "$d"/tl035_*/00_run.log 2>/dev/null | head -1)
  [ -f "$log" ] || continue
  pre=$(grep -E "pre_inject die_b OBS_AXI_NODES"  "$log" | tail -1 | grep -oE "0x[0-9a-f]{8}" | tail -1)
  post=$(grep -E "post_inject die_b OBS_AXI_NODES" "$log" | tail -1 | grep -oE "0x[0-9a-f]{8}" | tail -1)
  rc=$(grep -h "^errinject_rc=" "$d"/tl035_*/99_verdict.txt 2>/dev/null | cut -d= -f2)
  note=""; valid="yes"
  if [ "${rc:-}" = "2" ]; then valid="NO"; note="sweep aborted (link not up) -> NO INJECT"; fi
  if grep -qE "RESULT: FAIL — mis-delivery|mis-delivery/bit-error" "$log" 2>/dev/null; then
    valid="NO"; note="${note:+$note; }data-plane FAIL during pre-inject soak"
  fi
  printf "%-6s %-9s %-12s %-12s %-6s %-8s %s\n" "$run" "$arm" "${pre:-?}" "${post:-?}" "${rc:-?}" "$valid" "$note"
done
echo
echo "VALID post-inject signature tally (ini_aw = 0xad408020, all-clean = 0xad800000):"
for d in "$BASE"/r*_*/; do
  log=$(ls "$d"/tl035_*/00_run.log 2>/dev/null | head -1); [ -f "$log" ] || continue
  rc=$(grep -h "^errinject_rc=" "$d"/tl035_*/99_verdict.txt 2>/dev/null | cut -d= -f2)
  [ "${rc:-}" = "2" ] && continue
  grep -qE "mis-delivery/bit-error" "$log" 2>/dev/null && continue
  tag=$(basename "$d"); arm=${tag#*_}
  post=$(grep -E "post_inject die_b OBS_AXI_NODES" "$log" | tail -1 | grep -oE "0x[0-9a-f]{8}" | tail -1)
  echo "$arm $post"
done | sort | uniq -c | sed 's/^/  /'
