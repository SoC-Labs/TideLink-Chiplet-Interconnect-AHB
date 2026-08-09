#!/usr/bin/env bash
# =============================================================================
# run_categoryA_goodeye.sh  --  Wave-0 GOOD-EYE harness + Category-A battery.
#
# Off-rig authored, on-rig runnable. Leases BOTH KR260 dies (token-scoped),
# establishes a GOOD-EYE cross-die link, then runs the Category-A validation
# battery IN ORDER on that same link, recording a per-test PASS/FAIL/WEDGE
# matrix. Wedge-safe by construction: every ssh is timeout-wrapped, the board
# password is masked in all output, JTAG-POR recovery on any wedge, and the
# whole run is bounded by a time budget.
#
# GOOD-EYE LOOP (up to MAX_EYE_TRIES, default 8) -- each try:
#     POR both dies  ->  redeploy both (RUN_AFI=0)  ->  turnkey pair bring-up
#     ->  8-word cross-die write canary (eth_sysval_board.py write/verify).
#   A GOOD eye = the canary lands byte-exact (8/8) on die_b. The marginal-eye
#   lottery (FCSM=4 + deskew re-anchor) is re-rolled each try by re-bringing-up.
#
# CATEGORY-A BATTERY (in order, on the confirmed good-eye link):
#     1. kr260_sysval.py            (provenance + obs + delivery + READ soak +
#                                    endurance)
#     2. cov_injector_liveness.py   (CRC-free proof ERR_INJECT is a live corruptor)
#     3. cov_mbox_irq_source.py     (host orchestrator that drives the board-side
#                                    cov_mbox_doorbell_irq.py: cross-die interrupt
#                                    SOURCE latch proof)
#     4. cov_errinject_sweep.py     (directional err-inject matrix + W-byte0 rate)
#
# SAFETY / CONTRACT
#   * Token-scoped release ONLY (fpgahub lease release --token). NEVER
#     `board lease revoke` -- that would nuke the shared dam1n19 user's leases.
#   * JTAG-POR = POST to the fpgahubd unix socket on mapstone-dev
#     (/api/v1/targets/<t>/reset). NEVER `sudo reboot` a KR260.
#   * Every ssh/scp is `timeout`-wrapped; a hang past the timeout == a PS-bus
#     wedge -> POR-recover + re-establish the eye before the next test.
#   * Idempotent: truncates its log/matrix and removes its .done sentinel at
#     start; re-leases fresh each run.
#   * Emits  <OUT_DIR>/run_categoryA_goodeye.done  sentinel and
#            <OUT_DIR>/run_categoryA_goodeye_matrix.txt  matrix.
#
# ENV OVERRIDES (all optional):
#   MAX_EYE_TRIES (8)  TIME_BUDGET_S (14400)  LEASE_TTL (14400)
#   BRINGUP_TRIES (6)  CATA_OUT (<scratchpad>)
#
# A joint work commissioned on behalf of SoC Labs.
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
# =============================================================================
set -u

ROOT=/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet
SC="$ROOT/tidelink/pynq_host/scripts"
SCR="/tmpdir/claude-74755/-home-dam1n19-SoCLabs-nanosoc-ethernet-chiplet/e31cf0db-becf-4762-a881-c1c17e74fb93/scratchpad"
cd "$SC" || { echo "cannot cd $SC" >&2; exit 1; }

OUT_DIR="${CATA_OUT:-$SCR}"
mkdir -p "$OUT_DIR" 2>/dev/null || { OUT_DIR="$ROOT/verif/hw_runs"; mkdir -p "$OUT_DIR"; }
LOG="$OUT_DIR/run_categoryA_goodeye.log"
MATRIX="$OUT_DIR/run_categoryA_goodeye_matrix.txt"
DONE="$OUT_DIR/run_categoryA_goodeye.done"
: > "$LOG"; : > "$MATRIX"; rm -f "$DONE"

# --- password: derive from the bring-up default; NEVER echo it unmasked -------
PW=$(sed -n 's/.*KR260_PASSWORD:-\([^}]*\)}.*/\1/p' kr260_eth_bringup_pair.sh | head -1)
mask(){ if [ -n "$PW" ]; then sed "s/${PW}/***/g" | grep -vaE 'password for|\[sudo\]'
        else grep -vaE 'password for|\[sudo\]'; fi; }

A=ubuntu@10.22.24.159            # die_a = kr260_01 = initiator
B=ubuntu@10.22.24.153            # die_b = kr260_02 = target
DEP="$SC/kr260_deploy.sh"
OUT="$ROOT/tidelink/imp/fpga/output"
export TIDELINK_HOME="$ROOT/tidelink"
# cov_mbox_irq_source.py does `import cov_common` with no sys.path insert.
export PYTHONPATH="$SC/coverage${PYTHONPATH:+:$PYTHONPATH}"

MAX_EYE_TRIES="${MAX_EYE_TRIES:-8}"
TIME_BUDGET_S="${TIME_BUDGET_S:-14400}"
LEASE_TTL="${LEASE_TTL:-14400}"
BRINGUP_TRIES="${BRINGUP_TRIES:-6}"
START=$(date +%s)

# --- timeout-wrapped remote helpers (a hang past the timeout == a wedge) ------
up(){ ping -c1 -W2 "${1#*@}" >/dev/null 2>&1 \
      && timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=6 "$1" true 2>/dev/null \
      && echo up; }
MS(){ timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 mapstone-dev "/opt/fpgahub/bin/fpgahub $*" 2>&1; }
por_one(){ timeout 120 ssh -o BatchMode=yes -o ConnectTimeout=12 mapstone-dev \
             "curl -sS --max-time 90 --unix-socket /run/fpgahub/fpgahub.sock -X POST \
              http://localhost/api/v1/targets/$1/reset \
              -H 'Content-Type: application/json' -d '{\"method\":\"default\",\"confirm\":true}'" \
             >/dev/null 2>&1; }
bssh(){ # bssh <host> <remote-cmd> <timeout> : root over ssh, pw on stdin (masked)
  local h="$1" cmd="$2" t="${3:-30}"
  timeout "$t" ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$h" \
    "cd td && echo '$PW' | sudo -S $cmd 2>/dev/null"; }

# --- lease bookkeeping: TOKEN-SCOPED release only -----------------------------
TA=""; TB=""
rel(){
  [ -n "$TA" ] && MS lease release kr260_01 --token "$TA" >/dev/null 2>&1
  [ -n "$TB" ] && MS lease release kr260_02 --token "$TB" >/dev/null 2>&1
  # NOTE: deliberately NO `board lease revoke` -- that nukes the shared user's leases.
  echo "leases released (token-scoped; no revoke)"
}
finish(){
  rel
  echo; echo "===== CATEGORY-A GOOD-EYE MATRIX ====="; cat "$MATRIX"
  echo DONE > "$DONE"; echo "SENTINEL DONE -> $DONE"
}
trap 'finish' EXIT

echo "logging to $LOG (matrix: $MATRIX)" >&2
exec >>"$LOG" 2>&1

echo "==== CATEGORY-A GOOD-EYE START $(date) (budget ${TIME_BUDGET_S}s, eye tries ${MAX_EYE_TRIES}) ===="
[ -z "$PW" ] && { echo "ERROR: could not derive board password"; exit 1; }

# --- deploy both dies (RUN_AFI=0) + refresh the board-side sysval primitive ---
deploy_both(){
  # RUN_AFI=1: for kr260-eth-chiplet* the deploy auto-prefixes KR260_AFI_NO_CANARY=1
  # (kr260_deploy.sh:66 -> kr260_afi.sh:260), so the AFI PS-port width fix runs but the
  # PS-wedging bare-link canary is SKIPPED. Matches the tidelink agent's proven-tonight
  # deploy (1112d63 doc). Canary-safe; do NOT set RUN_AFI without that eth-chiplet prefix.
  RUN_AFI=1 KR260_HOST="$A" TARGET=kr260-eth-chiplet \
    BIN="$OUT/kr260-eth-chiplet/tidelink.bin" BITSTREAM="$OUT/kr260-eth-chiplet/tidelink.bit" \
    KR260_PASSWORD="$PW" timeout 220 bash "$DEP" 2>&1 | mask | grep -iaE 'operating|deploy|AFI|ERROR|FAIL' | tail -3
  RUN_AFI=1 KR260_HOST="$B" TARGET=kr260-eth-chiplet \
    BIN="$OUT/kr260-eth-chiplet-flip/tidelink.bin" BITSTREAM="$OUT/kr260-eth-chiplet-flip/tidelink.bit" \
    KR260_PASSWORD="$PW" timeout 220 bash "$DEP" 2>&1 | mask | grep -iaE 'operating|deploy|AFI|ERROR|FAIL' | tail -3
  for h in "$A" "$B"; do
    timeout 25 scp -q -o BatchMode=yes -o StrictHostKeyChecking=no \
      "$SC/eth_sysval_board.py" "$h:td/scripts/eth_sysval_board.py" 2>/dev/null
  done
}

# --- 8-word cross-die write canary: GOOD eye iff it lands 8/8 byte-exact ------
canary(){
  bssh "$A" "python3 scripts/eth_sysval_board.py write 8 0xEE110000" 30 >/dev/null 2>&1 || return 1
  local out; out=$(bssh "$B" "python3 scripts/eth_sysval_board.py verify 8 0xEE110000" 30 2>&1 | mask)
  echo "$out" | grep -qa "8/8 byte-exact"
}

# --- GOOD-EYE loop: POR + redeploy + bring-up + canary, up to MAX_EYE_TRIES ---
ensure_good_eye(){
  local e now
  for e in $(seq 1 "$MAX_EYE_TRIES"); do
    now=$(date +%s); [ $((now-START)) -ge "$TIME_BUDGET_S" ] && { echo "  [eye] budget exhausted"; return 2; }
    echo "  [eye] try $e/$MAX_EYE_TRIES $(date +%H:%M:%S): POR both + redeploy + bring-up"
    por_one kr260_01; por_one kr260_02
    local k
    for k in $(seq 1 18); do sleep 10; [ "$(up "$A")" = up ] && [ "$(up "$B")" = up ] && break; done
    if [ "$(up "$A")" != up ] || [ "$(up "$B")" != up ]; then
      echo "  [eye] boards not both up after POR (try $e) -- retry"; continue
    fi
    deploy_both
    DIE_A="$A" DIE_B="$B" KR260_PASSWORD="$PW" MAX_TRIES="$BRINGUP_TRIES" \
      timeout 480 bash kr260_eth_bringup_pair.sh 2>&1 | mask | tail -2
    # let AUTO_ANCHOR settle (RO poll; wedge-safe)
    local t da
    for t in $(seq 1 12); do
      da=$(bssh "$A" "python3 scripts/eth_tlapb_poke.py anchorobs" 20 2>&1 | mask | grep -oiE 'done=[01]' | head -1)
      [ "$da" = "done=1" ] && break; sleep 2
    done
    if canary; then echo "  [eye] GOOD eye confirmed on try $e (8/8 cross-die write landed)"; return 0; fi
    echo "  [eye] BAD eye (try $e) -- canary did not land; POR + re-roll"
  done
  echo "  [eye] FAILED to confirm a good eye in $MAX_EYE_TRIES tries"; return 1
}

# --- per-test matrix + verdict classifier ------------------------------------
record(){ printf '%-26s %s\n' "$1" "$2" >> "$MATRIX"; echo "  [MATRIX] $1 => $2"; }

classify(){ # classify <rc> ; reads global $out ; echoes a verdict
  local rc="$1" r
  if [ "$rc" = 124 ]; then echo "WEDGE(timeout)"; return; fi
  # kr260_sysval.py prints an authoritative "N PASS / M FAIL / K INCONCLUSIVE" line
  if echo "$out" | grep -qaE '[0-9]+ PASS / 0 FAIL'; then echo "PASS"; return; fi
  if echo "$out" | grep -qa 'SYSVAL SUMMARY'; then echo "FAIL"; return; fi
  r=$(echo "$out" | grep -aE 'RESULT:')
  if echo "$r" | grep -qai 'VACUOUS';      then echo "VACUOUS"; return; fi
  if echo "$r" | grep -qai 'WEDGE';        then echo "WEDGE"; return; fi
  if echo "$r" | grep -qai ' FAIL';        then echo "FAIL"; return; fi
  if echo "$r" | grep -qai 'INCONCLUSIVE'; then echo "INCONCLUSIVE"; return; fi
  if echo "$r" | grep -qai ' PASS';        then echo "PASS"; return; fi
  # scripts without a RESULT: line (cov_mbox_irq_source uses SUMMARY: + rc)
  if echo "$out" | grep -qa 'SUMMARY:'; then
    case "$rc" in 0) echo "PASS";; 3) echo "WEDGE";; *) echo "FAIL(rc$rc)";; esac; return
  fi
  case "$rc" in 0) echo "PASS";; 2) echo "INCONCLUSIVE(rc2)";; 3) echo "WEDGE(rc3)";; *) echo "FAIL(rc$rc)";; esac
}

NEED_EYE=1
run_test(){ # run_test <name> <timeout> <cmd...>
  local name="$1" tmo="$2"; shift 2
  local now; now=$(date +%s)
  if [ $((now-START)) -ge "$TIME_BUDGET_S" ]; then record "$name" "SKIP(budget)"; return; fi
  if [ "$NEED_EYE" = 1 ]; then
    if ensure_good_eye; then NEED_EYE=0; else record "$name" "SKIP(no-good-eye)"; return; fi
  fi
  echo "== RUN $name $(date +%H:%M:%S) =="
  local tf rc verdict
  tf=$(mktemp "$OUT_DIR/.cata.XXXXXX")
  DIE_A="$A" DIE_B="$B" KR260_HOST="$A" \
    KR260_DIEA_IP=10.22.24.159 KR260_DIEB_IP=10.22.24.153 \
    KR260_PASSWORD="$PW" timeout "$tmo" "$@" > "$tf" 2>&1
  rc=$?
  out=$(mask < "$tf"); rm -f "$tf"
  echo "$out" | tail -30
  verdict=$(classify "$rc")
  record "$name" "$verdict"
  case "$verdict" in
    *WEDGE*) echo "  $name WEDGED -- POR both + re-establish eye before next test"
             NEED_EYE=1; por_one kr260_01; por_one kr260_02 ;;
    INCONCLUSIVE\(rc2\)) echo "  $name aborted (link not healthy) -- re-establish eye"; NEED_EYE=1 ;;
  esac
}

# --- acquire both leases (token-scoped) --------------------------------------
TA=$(MS lease acquire kr260_01 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9]+' | cut -d= -f2)
TB=$(MS lease acquire kr260_02 --user dam1n19 --ttl "$LEASE_TTL" | grep -oE 'token=[A-Za-z0-9]+' | cut -d= -f2)
if [ -z "$TA" ] || [ -z "$TB" ]; then echo "ACQUIRE FAILED (TA='${TA:+set}' TB='${TB:+set}')"; exit 1; fi
echo "leases acquired (token-scoped) for kr260_01 + kr260_02"
for i in $(seq 1 30); do [ "$(up "$A")" = up ] && [ "$(up "$B")" = up ] && break; sleep 5; done

# --- establish the good eye up front, THEN run the Category-A battery in order -
echo "== establish GOOD-EYE link =="
if ensure_good_eye; then NEED_EYE=0; else echo "== no good eye up front; battery will attempt/skip per test =="; fi

echo "==== CATEGORY-A BATTERY (in order) $(date) ===="
run_test "kr260_sysval"          720 python3 "$SC/kr260_sysval.py"
run_test "cov_injector_liveness" 360 python3 "$SC/coverage/cov_injector_liveness.py"
run_test "cov_mbox_doorbell_irq" 360 python3 "$SC/coverage/cov_mbox_irq_source.py"
run_test "cov_errinject_sweep"   420 python3 "$SC/coverage/cov_errinject_sweep.py"

echo "==== CATEGORY-A GOOD-EYE END $(date) ===="
