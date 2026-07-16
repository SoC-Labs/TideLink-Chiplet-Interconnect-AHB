#!/bin/bash
# Guarantee the bridge1 lease is released once a driver exits.
# A driver's `trap ... EXIT` covers normal exits and most signals -- but NOT
# SIGKILL, and not a hard host death. Without a reaper a killed driver holds both
# boards for the full TTL.
#
# BUG FIXED 2026-07-10: the first version treated an EMPTY state query (a
# transient `fpgahub` failure) as "held by someone else" and declined to release.
# An unknown state must be RETRIED, never silently interpreted as someone else's
# lease. It still refuses to touch a lease genuinely held by another host.
set -u
PAIR=${PAIR:-bridge1}
WATCH=${WATCH:-overnight_autonomy}
LOG=${LOG:-/tmp/lease_reaper.log}
ME=$(hostname)
say(){ echo "[$(date -u +%H:%M:%SZ)] $*" >> "$LOG"; }
state(){ fpgahub pair lease show "$PAIR" --json 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);m=(d.get('members') or [{}])[0].get('current') or {};print(f\"{d.get('state','?')}:{m.get('holder','-')}\")" 2>/dev/null; }

say "reaper armed (pair=$PAIR watch=$WATCH me=$ME)"
while pgrep -f "$WATCH" >/dev/null 2>&1; do sleep 60; done
say "watched process exited"
sleep 10

for attempt in 1 2 3 4 5; do
  s=$(state)
  case "$s" in
    "" |"?:"*)   say "state query failed/unknown (attempt $attempt) — RETRYING, not assuming"; sleep 10; continue;;
    free:*)      say "lease already free (released by the driver's trap). done."; exit 0;;
    held:"$ME")  tok=$(grep -o 'LEASE_TOKEN=.*' "$HOME/.td_regress_lease" 2>/dev/null | cut -d= -f2)
                 if [ -n "$tok" ]; then
                   fpgahub pair lease release "$PAIR" --token "$tok" >>"$LOG" 2>&1
                   say "force-released our lease; now: $(state)"; exit 0
                 fi
                 say "ERROR: held by us but no token on disk — cannot release cleanly"; exit 1;;
    held:*)      say "held by another host ($s) — NOT touching it."; exit 0;;
    *)           say "unrecognised state '$s' (attempt $attempt) — retrying"; sleep 10;;
  esac
done
say "gave up after 5 attempts; last state: $(state)"
exit 1
