#!/bin/bash
# v37_data_test.sh - after bilateral fcsm=4, prove a data word crosses both ways.
# A->B: master die_a 0x44000000 <- VAL ; read slave die_b 0x44010000 (expect VAL)
# B->A: master die_b 0x44000000 <- VAL2; read slave die_a 0x44010000 (expect VAL2)
# Single-word, safe per runbook.
VAL=${1:-0x57A40001}
VAL2=${2:-0x57A40002}

echo "== state before =="
echo "a:"; ~/tl37.sh a probe 1
echo "b:"; ~/tl37.sh b probe 1

echo "== A->B: die_a TX 0x44000000 <- $VAL =="
~/tl37.sh a txword $VAL
sleep 0.3
echo -n "die_b RX 0x44010000 = "; ~/tl37.sh b rxword

echo "== B->A: die_b TX 0x44000000 <- $VAL2 =="
~/tl37.sh b txword $VAL2
sleep 0.3
echo -n "die_a RX 0x44010000 = "; ~/tl37.sh a rxword
