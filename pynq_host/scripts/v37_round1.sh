#!/bin/bash
# v37_round1.sh - v36 "park-and-freeze" recipe at 6.25 MHz, reaching the
# A->B-up / B->A-gap state, then leaving the link frozen so the word-pin
# sweep (tl37.py wpsweep on die_a) can walk the B->A RX capture window 0..15.
#   deploy both -> LOCK_THRESH 3->5 -> arm both -> bilateral S_HOLD park ->
#   freeze both (slot0=0x2) -> confirm die_b fcsm=4/cr=1, die_a fcsm=1/cr=0.
ART=~/tidelink_artefacts/v37
DEP=~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh

echo "== deploy both (parallel) $(date +%T) =="
( bash $DEP 192.168.4.101 z2_die_a die_a $ART --manifest $ART/tidelink.bin.manifest.json > /tmp/dep_a.log 2>&1 ) &
( bash $DEP 192.168.6.101 z2_die_b die_b $ART --manifest $ART/tidelink-flip.bin.manifest.json > /tmp/dep_b.log 2>&1 ) &
wait
grep -ch "done (sha256" /tmp/dep_a.log /tmp/dep_b.log | tr '\n' ' '; echo deploy-ok-count
sleep 2

echo "== PHY_ALIGN_ID check (expect 0x50410100 both) =="
~/tl37.sh both rd 0x4403211C

echo "== relax LOCK_THRESH=5 + arm both =="
~/tl37.sh both lockthresh >/dev/null
~/tl37.sh both arm >/dev/null

park=0
for it in 1 2 3 4 5 6; do
    sleep 2
    cs_a=$(~/tl37.sh a probe 1 2>/dev/null | grep -oE 'cstate=[0-9]+' | cut -d= -f2)
    cs_b=$(~/tl37.sh b probe 1 2>/dev/null | grep -oE 'cstate=[0-9]+' | cut -d= -f2)
    echo "H$it a_cs=$cs_a b_cs=$cs_b"
    if [ "$cs_a" = "6" ] && [ "$cs_b" = "6" ]; then park=1; break; fi
    ~/tl37.sh both recal >/dev/null
done
[ "$park" = "1" ] || echo "WARN: no bilateral park (continuing anyway to freeze)"

echo "== freeze both (slot0=0x2) =="
~/tl37.sh both freeze >/dev/null
for it in 1 2 3 4 5 6 7 8; do
    sleep 1
    echo "F$it a:"; ~/tl37.sh a probe 1
    echo "F$it b:"; ~/tl37.sh b probe 1
    fa=$(~/tl37.sh a probe 1 2>/dev/null | grep -oE 'fcsm=.' | cut -d= -f2)
    fb=$(~/tl37.sh b probe 1 2>/dev/null | grep -oE 'fcsm=.' | cut -d= -f2)
    if [ "$fb" = "4" ]; then
        echo "PARKED: die_b fcsm=4; die_a fcsm=$fa (B->A gap=$([ "$fa" = "4" ] && echo NO || echo YES))"
        break
    fi
done
echo "== round1 done; link is frozen, ready for word-pin sweep on die_a =="
