#!/usr/bin/env bash
# kr260_sync_bringup.sh — catch a BILATERAL anchor window on the KR260 bare-link
# pair by loading both PLs in PARALLEL (tight role_lock skew), then prove
# byte-exact cross-die delivery. Built 2026-08-10 (bilateral-anchor scope §4-A).
#
# WHY PARALLEL (not NTP): the S_HOLD skew budget is HOLD_CYCLES = 8*128*64 = 65536
# cycles of the /16 RX word clock (~195 kHz, pad_clk_rx 320 ns) ~= 336 ms. A plain
# parallel `fpgautil` (fan-out skew ~10-50 ms) is well INSIDE that budget, so
# nego+role_lock on both dies land within S_HOLD and the peer converges. The
# ~1-min SEQUENTIAL deploy skew (>>336 ms) is what breaks bilateral anchor.
#
# THE FIX vs the earlier failed concurrent attempt: WAIT for BOTH boards' sshd
# after POR before launching the loads (die_b `Connection refused` was a boot
# race, not skew).
#
# Cand-2 (TRAIN_ENTRY_FALLBACK=1) must already be in the staged bitstreams; this
# tool does NOT poke the SYNC config — the beacon arms autonomously (confirmed
# 2026-08-10). role_lock is W1S/POR-only-clear, so each re-roll needs a POR.
#
# Usage (from repo root, boards LEASED):
#   source ./set_env.sh
#   KR260_PASSWORD=<board-password> [ATTEMPTS=6] [STAGE=1] \
#     bash pynq_host/scripts/kr260_sync_bringup.sh
#   STAGE=1 (default) does a one-time sequential `make deploy_pair_role` to put
#   ~/td/tidelink.bin + scripts on both boards; set STAGE=0 if already staged.
#
# NEVER `reboot` a KR260 (JTAG POR only). Requires: leases held, mapstone-dev
# reachable for kpor, sshpass, both dies reachable (10.22.24.159/.153).
set -u
DA=10.22.24.159; DB=10.22.24.153
PW="${KR260_PASSWORD:?KR260_PASSWORD is not set. Export the board ssh password before running this script; it is deliberately not hardcoded (this repository is public).}"
ATTEMPTS="${ATTEMPTS:-6}"
STAGE="${STAGE:-1}"
FPGA_DIR="${TIDELINK_HOME:-$(pwd)}/fpga"
TAGS_A="$(python3 -c 'print(",".join("0x%08X"%(0xDA7A0001+i) for i in range(12)))')"
TAGS_B="$(python3 -c 'print(",".join("0x%08X"%(0x5A1E0001+i) for i in range(12)))')"

SSHO="-o StrictHostKeyChecking=no -o ConnectTimeout=8"
sshb() { timeout 40 sshpass -p "$PW" ssh $SSHO "ubuntu@$1" "$2" 2>&1; }
por()  { timeout 340 ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev \
           '~/bin/kpor kr260-01 --wait; ~/bin/kpor kr260-02 --wait' 2>&1 | grep -E 'back up'; }
probe_anc() { sshb "$1" "cd td && echo $PW | sudo -S TIDELINK_SOC=kr260 python3 scripts/tl39.py probe 2>/dev/null" \
                | grep -oE 'fcsm=[0-9].*anc=[0-9]+ span=[0-9]+'; }
wait_sshd() { local ip=$1 i=0; while [ $i -lt 30 ]; do
                sshpass -p "$PW" ssh $SSHO "ubuntu@$ip" true 2>/dev/null && return 0; sleep 5; i=$((i+1)); done; return 1; }
load_afi() { # parallel PL load + AFI (bin persists in ~/td across POR)
  sshb "$1" "echo $PW | sudo -S fpgautil -b ~/td/tidelink.bin -f Full >/dev/null 2>&1; \
             echo $PW | sudo -S sh ~/td/scripts/kr260_afi.sh fix 2>&1 | grep -E '0x84030214|state ='"; }

if [ "$STAGE" = "1" ]; then
  echo "== one-time stage (sequential deploy puts ~/td/tidelink.bin on both) =="
  make -C "$FPGA_DIR" deploy_pair_role SOC=kr260 PTP=0 ROLE=die_a KR260_DIEA_IP=$DA KR260_USER=ubuntu KR260_PASSWORD="$PW" >/dev/null 2>&1 && echo "  die_a staged"
  make -C "$FPGA_DIR" deploy_pair_role SOC=kr260 PTP=0 ROLE=die_b KR260_DIEB_IP=$DB KR260_USER=ubuntu KR260_PASSWORD="$PW" >/dev/null 2>&1 && echo "  die_b staged"
fi

for a in $(seq 1 "$ATTEMPTS"); do
  echo "========== SYNC ATTEMPT $a/$ATTEMPTS  $(date -u +%H:%M:%SZ) =========="
  echo "-- POR both (clears role_lock) --"; por
  echo "-- wait for BOTH sshd (the fix vs the earlier boot race) --"
  wait_sshd $DA && echo "  die_a sshd up" || { echo "  die_a sshd TIMEOUT"; continue; }
  wait_sshd $DB && echo "  die_b sshd up" || { echo "  die_b sshd TIMEOUT"; continue; }
  echo "-- PARALLEL PL load + AFI (tight role_lock skew) --"
  load_afi $DA & pa=$!
  load_afi $DB & pb=$!
  wait $pa; wait $pb
  echo "-- settle 30s (autonomous converge) --"; sleep 30
  A=$(probe_anc $DA); B=$(probe_anc $DB)
  echo "  die_a: $A"; echo "  die_b: $B"
  anca=$(echo "$A" | grep -oE 'anc=[0-9]+' | grep -oE '[0-9]+$'); anca=${anca:-0}
  ancb=$(echo "$B" | grep -oE 'anc=[0-9]+' | grep -oE '[0-9]+$'); ancb=${ancb:-0}
  echo "  >> anc: die_a=$anca die_b=$ancb (need both>=1)"
  if [ "$anca" -ge 1 ] && [ "$ancb" -ge 1 ]; then
    echo "===== BILATERAL ANCHOR (attempt $a) — DELIVERY TEST BOTH DIRECTIONS ====="
    echo "-- die_a -> die_b (12 pkts) --"
    sshb $DA "cd td && echo $PW | sudo -S python3 scripts/kr260_credit_tx.py 0xDA7A0001 12 2>&1" | tail -2
    sshb $DB "cd td && echo $PW | sudo -S python3 scripts/kr260_data_rx.py check $TAGS_A 2>&1" | tail -2
    echo "-- die_b -> die_a (12 pkts) --"
    sshb $DB "cd td && echo $PW | sudo -S python3 scripts/kr260_credit_tx.py 0x5A1E0001 12 2>&1" | tail -2
    sshb $DA "cd td && echo $PW | sudo -S python3 scripts/kr260_data_rx.py check $TAGS_B 2>&1" | tail -2
    echo "===== DONE (bilateral + delivery attempted) ====="
    exit 0
  fi
  echo "  attempt $a: no bilateral window — re-roll"
done
echo "===== EXHAUSTED $ATTEMPTS attempts — no bilateral window."
echo "      Per-attempt anc above: if die_a NEVER hit 1, the residual is die_a's"
echo "      marginal RX eye (scope §4-C: IDELAY tune / MIN_LOCK_DWELLS=1), not skew."
exit 1
