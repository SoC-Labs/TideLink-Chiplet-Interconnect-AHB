#!/bin/bash
# v39_data_test.sh — full V2 (v39) bring-up + MEASURED-engagement data test.
# Runs ON mapstone-dev. Drives ~/tl39.sh (which ssh-hops to die_a/die_b and runs
# ~/tl39.py via sudo -S on each board).
#
# What v39 adds over v37/v38: the epoch-anchor multi-sample exit-confirm fix
# (no more marginal-eye mis-lock) AND a readable engagement instrument
# (SWI_EPOCH_STATUS 0x44032140). We GATE on measured anchor engagement before
# declaring a data result — instead of inferring it from garbled bytes.
#
# Recipe (2026-06-13 multi-agent recipe, per-lane-auto variant):
#   1. setup both: train_auto_en off (hold), lockthresh=5, wpauto (per-lane wp)
#   2. coordinated recal pulse (arm) both, settle
#   3. STAGGERED freeze: die_b FIRST (while die_a HOLDs), then die_a
#   4. READ epoch on BOTH (measure anchor engagement bilaterally)  <-- NEW GATE
#   5. data test A->B + B->A (4-word burst), check occ + bytes
set -u
TL=~/tl39.sh

echo "############ v39 bring-up + measured-engagement data test ############"

echo "== 1. setup both (hold, thresh5, per-lane-auto wp) =="
$TL both hold
$TL both lockthresh
$TL both wpauto

echo "== 2. coordinated recal (arm) both, settle 0.3s =="
$TL both arm
sleep 0.3
echo "  --- state after arm ---"; $TL both probe 1

echo "== 3. STAGGERED freeze: die_b first, then die_a =="
$TL b freeze
sleep 0.1
$TL a freeze
sleep 0.3

echo "== 4. MEASURE epoch-anchor engagement (NEW instrument) =="
$TL both epoch
echo "  --- full state ---"; $TL both probe 1

P0=${1:-0x00240000}; P1=${2:-0xDA7A0001}; P2=${3:-0xDA7A0002}; P3=${4:-0xDA7A0003}

echo "== 5a. DATA A->B: die_a TX 4-word burst -> die_b RX FIFO =="
echo -n "  occ before: "; $TL b occ
$TL a txburst $P0 $P1 $P2 $P3
sleep 0.4
echo -n "  occ after:  "; $TL b occ
echo -n "  RX words:   "; $TL b rxn 4
echo -n "  rx epoch:   "; $TL b epoch

echo "== 5b. DATA B->A: die_b TX 4-word burst -> die_a RX FIFO =="
echo -n "  occ before: "; $TL a occ
$TL b txburst $P0 $P1 $P2 $P3
sleep 0.4
echo -n "  occ after:  "; $TL a occ
echo -n "  RX words:   "; $TL a rxn 4
echo -n "  rx epoch:   "; $TL a epoch

echo "############ done ############"
