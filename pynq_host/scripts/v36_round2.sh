#!/bin/bash
# v36_round2.sh - one redeploy-lottery round, v35 "park-and-freeze" recipe at
# the v36 silicon-validated 6.25 MHz / 160 ns link rate:
#   deploy both -> relax LOCK_THRESH 3->5 -> arm both (hold+recal) ->
#   bilateral S_HOLD -> freeze both (slot0=0x2) -> poll bilateral fcsm=4.
# Same recipe as v35_round2.sh; only the artefact dir (v36) and helper (tl36)
# differ. The 4x-wider eye at 6.25 MHz is expected to close the marginal B->A
# direction that v35 (25 MHz) could not.
ART=~/tidelink_artefacts/v36
DEP=~/SoCLabs/tidelink/pynq_host/scripts/deploy_pair.sh

echo "== deploy both (parallel) $(date +%T) =="
( bash $DEP 192.168.4.101 z2_die_a die_a $ART --manifest $ART/tidelink.bin.manifest.json > /tmp/dep_a.log 2>&1 ) &
( bash $DEP 192.168.6.101 z2_die_b die_b $ART --manifest $ART/tidelink-flip.bin.manifest.json > /tmp/dep_b.log 2>&1 ) &
wait
grep -ch "done (sha256" /tmp/dep_a.log /tmp/dep_b.log | tr '\n' ' '; echo deploy-ok-count
sleep 2

echo "== relax LOCK_THRESH=5 + arm both =="
~/tl36.sh both lockthresh >/dev/null
~/tl36.sh both arm >/dev/null

park=0
for it in 1 2 3 4 5 6; do
    sleep 2
    cs_a=$(~/tl36.sh a probe 1 2>/dev/null | grep -oE 'cstate=[0-9]+' | cut -d= -f2)
    cs_b=$(~/tl36.sh b probe 1 2>/dev/null | grep -oE 'cstate=[0-9]+' | cut -d= -f2)
    echo "H$it a_cs=$cs_a b_cs=$cs_b"
    if [ "$cs_a" = "6" ] && [ "$cs_b" = "6" ]; then park=1; break; fi
    ~/tl36.sh both recal >/dev/null
done
[ "$park" = "1" ] || { echo "ROUND-RESULT: no bilateral park"; exit 1; }

echo "== freeze both (slot0=0x2) =="
~/tl36.sh both freeze >/dev/null
for it in 1 2 3 4 5 6 7 8; do
    sleep 1
    la=$(~/tl36.sh a probe 1 2>/dev/null | grep -oE 'fcsm=.|cr=.|ck=.|llv=.' | tr '\n' ' ')
    lb=$(~/tl36.sh b probe 1 2>/dev/null | grep -oE 'fcsm=.|cr=.|ck=.|llv=.' | tr '\n' ' ')
    echo "F$it a[$la] b[$lb]"
    fa=$(echo "$la" | grep -oE 'fcsm=.' | cut -d= -f2)
    fb=$(echo "$lb" | grep -oE 'fcsm=.' | cut -d= -f2)
    if [ "$fa" = "4" ] && [ "$fb" = "4" ]; then
        echo "ROUND-RESULT: BILATERAL FCSM=4 (LINK_IDLE)"
        exit 0
    fi
done
echo "ROUND-RESULT: no bilateral LINK_IDLE (a=$fa b=$fb)"
exit 1
