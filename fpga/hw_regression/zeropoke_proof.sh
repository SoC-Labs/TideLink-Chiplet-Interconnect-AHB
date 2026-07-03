#!/bin/bash
# =============================================================================
# zeropoke_proof.sh — ONE fresh-POR zero-poke autonomous bring-up, scored a-h
#
# Codifies the exact proof every L3/L4 debug loop has been re-deriving by hand:
# fresh POR on both dies -> arm ONLY the autonomy registers (NEGO_CFG=0x61 +
# NEGO_TRAIN_CFG=0x0001, nothing else) in the requested order -> poll the
# whole autonomous chain with per-step timestamps -> print a machine-parseable
# a-h SCORECARD. Exit code 0 iff step (h) — byte-exact data BOTH ways — passed.
#
#   (a) role_locked both dies              ROLE_STATUS[1]
#   (b) lane_locked (active mask 0xE4)     SWI_LANE_STATUS lk[7:0]
#   (c) SYNC config landed                 SYNCTOL==0x5e4 + LANEMASK==0xe4e4 (R8 logged)
#   (d) cal_done + cstate==4 both          SWI_LANE_STATUS[16] + OBSCAL[3:0]
#   (e) tx_sync_ins / sync_det / sync_seen TXSYNC, SYNCCNT[31:16], 0x215C[7:0]
#   (f) winscan done clean + reanchored    WINSCAN_OBS 0x21B8 + taps 0x2118 + 0x2140[0]
#   (g) FCSM=4 + cr + crack + credit>0     SWI_LANE_STATUS + OBS_FC_CREDIT both
#   (h) 3x A->B txburst byte-exact + B->A  GP1 0x84010000 vs 0x00240000/0xcafe0001/0xcafe0002
#       + post-burst credit / long / underrun / PKTLEN dump
#
# USAGE (on the lab host that can SSH the PYNQ pair, e.g. mapstone-dev):
#   ./zeropoke_proof.sh <first:a|b|both> [--stagger SEC] [--no-deploy]
#                       [--budget SEC] [--no-lease] [--trace] [--trace-file F]
#     first        arm-order: which die gets NEGO_CFG/NEGO_TRAIN_CFG first
#                  (both = near-simultaneous, a then b back-to-back)
#     --stagger    seconds between the two arms (default 0; ignored for both)
#     --budget     total watch budget in seconds (default 240 — the current
#                  build's FINALIZE+settle add ~1s/die to the 6.4s scan and
#                  steps d-g land minutes in)
#     --no-deploy  skip the bitstream reflash. WARNING: reflash IS the fresh
#                  POR (role_lock is W1S with POR-only clear) — without it the
#                  run scores a WARM state, not a zero-poke proof.
#     --no-lease   caller already holds the fpgahub lease
#     --trace      time-series telemetry: during the a-g watch phase, one
#                  on-board sampler per die streams the standard register set
#                  (R8/SWI_LANE_STATUS/NEGO_TRAIN_STATUS/OBSCAL/WINSCAN_OBS/
#                  REANCHORED/SYNC_SEEN/SYNCCNT/FCCRED) every ~TD_TRACE_PERIOD
#                  (default 0.8s) into a CSV (timestamp,die,reg,name,value)
#                  alongside the scorecard, then reports the ordering
#                  discriminator: which die's WINSCAN_OBS[0] (winscan_done)
#                  rose first/second, with timestamps. Snapshots can't answer
#                  ordering questions (e.g. the starvation polarity); this can.
#     --trace-file CSV path (default ./zeropoke_trace_<UTC-stamp>.csv)
#
# HARDWARE SAFETY: never writes 0x21B0/0x21B4 (winscan FSM owns them); all
# reads throttled (TD_THROTTLE) — dense mmap loops wedge the PYNQ PS.
# First-use validation pending (written without boards; idioms from
# td_v2_hwlib.sh / td_v2_regress.sh which ARE silicon-proven).
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./td_v2_hwlib.sh
source "$HERE/td_v2_hwlib.sh"

FIRST=""; STAGGER=0; DO_DEPLOY=1; BUDGET=240; DO_LEASE=1; TRACE=0; TRACE_FILE=""
while [ $# -gt 0 ]; do case "$1" in
  a|b|both) FIRST=$1;;
  --stagger) STAGGER=$2; shift;;
  --budget)  BUDGET=$2; shift;;
  --no-deploy) DO_DEPLOY=0;;
  --no-lease)  DO_LEASE=0;;
  --trace)      TRACE=1;;
  --trace-file) TRACE_FILE=$2; shift;;
  -h|--help) sed -n '2,53p' "$0"; exit 0;;
  *) echo "unknown arg: $1 (usage: $0 <a|b|both> [--stagger SEC])"; exit 2;;
esac; shift; done
[ -n "$FIRST" ] || { echo "usage: $0 <first:a|b|both> [--stagger SEC]"; exit 2; }

T0=$(date +%s)
now(){ echo $(( $(date +%s) - T0 )); }
left(){ echo $(( BUDGET - $(now) )); }
say(){ printf '[%4ds] %s\n' "$(now)" "$*"; }

# step ledger -----------------------------------------------------------------
declare -A ZP_ST ZP_T ZP_INFO
step_set(){ ZP_ST[$1]=$2; ZP_T[$1]=$(now); ZP_INFO[$1]=${3:-};
  printf 'ZP_STEP %s %s t=%ss %s\n' "$1" "$2" "${ZP_T[$1]}" "${ZP_INFO[$1]}"; }

# poll <step> <label> <cond-fn> — poll cond-fn until true or budget exhausted
poll(){ local st=$1 label=$2 fn=$3
  say "waiting: ($st) $label"
  while [ "$(left)" -gt 0 ]; do
    if $fn; then step_set "$st" PASS "$($fn info 2>/dev/null || true)"; return 0; fi
    sleep 2
  done
  step_set "$st" FAIL "budget-exhausted"; return 1; }

# ----- condition functions (each also answers "$1 = info" with detail) --------
c_role(){ local ra rb
  ra=$(( $(rd_d a $R_ROLE_STATUS) )); rb=$(( $(rd_d b $R_ROLE_STATUS) ))
  [ "${1:-}" = info ] && { printf 'role_status a=0x%x b=0x%x' "$ra" "$rb"; return 0; }
  [ $(( (ra>>1)&1 )) -eq 1 ] && [ $(( (rb>>1)&1 )) -eq 1 ]; }

c_lanes(){ local la lb
  la=$(( $(rd_d a $R_OBS) & 0xff )); lb=$(( $(rd_d b $R_OBS) & 0xff ))
  [ "${1:-}" = info ] && { printf 'lk a=0x%02x b=0x%02x (need mask 0xe4)' "$la" "$lb"; return 0; }
  [ $(( la & 0xe4 )) -eq $(( 0xe4 )) ] && [ $(( lb & 0xe4 )) -eq $(( 0xe4 )) ]; }

c_synccfg(){ local ta tb ma mb r8a r8b
  ta=$(( $(rd_d a $R_SYNCTOL) )); tb=$(( $(rd_d b $R_SYNCTOL) ))
  ma=$(( $(rd_d a $R_LANEMASK) )); mb=$(( $(rd_d b $R_LANEMASK) ))
  r8a=$(( $(rd_d a $R_R8) )); r8b=$(( $(rd_d b $R_R8) ))
  [ "${1:-}" = info ] && { printf 'R8 a=0x%02x b=0x%02x synctol a=0x%x b=0x%x lanemask a=0x%x b=0x%x' \
      "$r8a" "$r8b" "$ta" "$tb" "$ma" "$mb"; return 0; }
  [ "$ta" -eq $(( 0x5e4 )) ] && [ "$tb" -eq $(( 0x5e4 )) ] && \
  [ "$ma" -eq $(( 0xe4e4 )) ] && [ "$mb" -eq $(( 0xe4e4 )) ]; }

c_cal(){ local oa ob ca cb
  oa=$(( $(rd_d a $R_OBS) )); ob=$(( $(rd_d b $R_OBS) ))
  ca=$(( $(rd_d a $R_OBSCAL) & 0xf )); cb=$(( $(rd_d b $R_OBSCAL) & 0xf ))
  [ "${1:-}" = info ] && { printf 'cal_done a=%d b=%d cstate a=%d b=%d' \
      $(( (oa>>16)&1 )) $(( (ob>>16)&1 )) "$ca" "$cb"; return 0; }
  [ $(( (oa>>16)&1 )) -eq 1 ] && [ $(( (ob>>16)&1 )) -eq 1 ] && \
  [ "$ca" -eq 4 ] && [ "$cb" -eq 4 ]; }

c_sync(){ local ia ib da db sa sb
  ia=$(( $(rd_d a $R_TXSYNC) & 0xffff )); ib=$(( $(rd_d b $R_TXSYNC) & 0xffff ))
  da=$(( $(rd_d a $R_SYNCCNT) >> 16 ));   db=$(( $(rd_d b $R_SYNCCNT) >> 16 ))
  sa=$(( $(rd_d a $R_SYNCSEEN) & 0xff )); sb=$(( $(rd_d b $R_SYNCSEEN) & 0xff ))
  [ "${1:-}" = info ] && { printf 'tx_sync_ins a=%d b=%d sync_det a=%d b=%d sync_seen a=0x%02x b=0x%02x' \
      "$ia" "$ib" "$da" "$db" "$sa" "$sb"; return 0; }
  [ "$ia" -gt 0 ] && [ "$ib" -gt 0 ] && [ "$da" -gt 0 ] && [ "$db" -gt 0 ] && \
  [ "$sa" -ne 0 ] && [ "$sb" -ne 0 ]; }

c_winscan(){ local wa wb ra rb pa pb
  wa=$(( $(rd_d a $R_WINSCAN_OBS) )); wb=$(( $(rd_d b $R_WINSCAN_OBS) ))
  ra=$(reanchored_d a); rb=$(reanchored_d b)
  pa=$(( $(rd_d a $R_PHASE) )); pb=$(( $(rd_d b $R_PHASE) ))
  [ "${1:-}" = info ] && { printf 'ws_obs a=0x%08x b=0x%08x (done/degen/anch_to) taps a=0x%08x b=0x%08x reanchored a=%d b=%d' \
      "$wa" "$wb" "$pa" "$pb" "$ra" "$rb"; return 0; }
  # presence 0x57, done=1, degenerate=0, anchor-timeout=0 on BOTH + reanchored
  [ $(( (wa>>24)&0xff )) -eq $(( 0x57 )) ] && [ $(( (wb>>24)&0xff )) -eq $(( 0x57 )) ] && \
  [ $(( wa&1 )) -eq 1 ] && [ $(( wb&1 )) -eq 1 ] && \
  [ $(( (wa>>1)&1 )) -eq 0 ] && [ $(( (wb>>1)&1 )) -eq 0 ] && \
  [ $(( (wa>>2)&1 )) -eq 0 ] && [ $(( (wb>>2)&1 )) -eq 0 ] && \
  [ "$ra" -eq 1 ] && [ "$rb" -eq 1 ]; }

c_fc(){ local oa ob ka kb
  oa=$(( $(rd_d a $R_OBS) )); ob=$(( $(rd_d b $R_OBS) ))
  ka=$(( $(rd_d a $R_FCCRED) )); kb=$(( $(rd_d b $R_FCCRED) ))
  [ "${1:-}" = info ] && { printf 'fcsm a=%d b=%d cr a=%d b=%d crack a=%d b=%d fccred a=0x%08x b=0x%08x' \
      $(( (oa>>17)&7 )) $(( (ob>>17)&7 )) $(( (oa>>23)&1 )) $(( (ob>>23)&1 )) \
      $(( (oa>>24)&1 )) $(( (ob>>24)&1 )) "$ka" "$kb"; return 0; }
  [ $(( (oa>>17)&7 )) -eq 4 ] && [ $(( (ob>>17)&7 )) -eq 4 ] && \
  [ $(( (oa>>23)&1 )) -eq 1 ] && [ $(( (ob>>23)&1 )) -eq 1 ] && \
  [ $(( (oa>>24)&1 )) -eq 1 ] && [ $(( (ob>>24)&1 )) -eq 1 ] && \
  [ $(( ka & 0xff )) -gt 0 ] && [ $(( kb & 0xff )) -gt 0 ]; }

# one scored burst: send from $1, read back on $2; echoes PASS/FAIL detail
burst_once(){ local src=$1 dst=$2 i w exp got=() ok=1
  for i in 0 1 2 3; do gp1_rx_d "$dst" "$i" >/dev/null; done   # drain stale (pops on read)
  sleep "$TD_THROTTLE"
  zp_txburst "$src"; sleep 1
  for i in 0 1 2; do
    w=$(printf '0x%08x' "$(( $(gp1_rx_d "$dst" "$i") ))"); got+=("$w"); sleep "$TD_THROTTLE"
  done
  for i in 0 1 2; do
    exp=$(printf '0x%08x' "$(( ${ZP_TX_WORDS[$i]} ))")
    [ "${got[$i]}" = "$exp" ] || ok=0
  done
  echo "rx=${got[*]} $( [ $ok -eq 1 ] && echo BYTE-EXACT || echo MISMATCH )"
  [ $ok -eq 1 ]; }

# ===== --trace: time-series telemetry (a-g watch phase) ========================
# One background sampler PER DIE (shipped base64, same idiom as the hwlib
# winscan): a single SSH connection streams "die,reg,name,value" lines; the
# host prepends its own arrival timestamp (COMMON clock — board RTCs are not
# NTP-synced, and the discriminator needs cross-die ordering) and appends to
# the CSV. PS-safety: mmap is READ-ONLY, 30ms between register reads inside a
# sweep (the proven winscan spacing), one sweep per TD_TRACE_PERIOD; never
# touches 0x21B0/0x21B4 or the pop-on-read GP1 aperture. The sampler
# self-terminates after BUDGET+60s even if the host-side kill is lost.
TRACE_PERIOD=${TD_TRACE_PERIOD:-0.8}
# Sampled register set — extend with "$R_VAR:NAME" pairs (hwlib names).
trace_regtab(){ local e out=""
  for e in \
    "$R_R8:R8" \
    "$R_OBS:SWI_LANE_STATUS" \
    "$R_NEGO_TRAIN_STATUS:NEGO_TRAIN_STATUS" \
    "$R_OBSCAL:OBSCAL" \
    "$R_WINSCAN_OBS:WINSCAN_OBS" \
    "$R_REANCHORED:REANCHORED" \
    "$R_SYNCSEEN:SYNC_SEEN" \
    "$R_SYNCCNT:SYNCCNT" \
    "$R_FCCRED:FCCRED"; do
    out+="$(printf '%x' $(( ${e%%:*} - 0x44032000 ))):${e##*:} "
  done
  printf '%s' "${out% }"; }

TRACE_PY='import mmap,struct,os,sys,time
DIE=sys.argv[1];PER=float(sys.argv[2]);DUR=float(sys.argv[3])
REGTAB="@REGTAB@"
P=4096;BASE=0x44032000
fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
bb=BASE&~(P-1);o=BASE-bb
m=mmap.mmap(fd,((0x400+o+P-1)//P)*P,mmap.MAP_SHARED,mmap.PROT_READ,offset=bb)
def rd(x):return struct.unpack_from("<I",m,o+x)[0]
REGS=[(int(e.split(":")[0],16),e.split(":")[1]) for e in REGTAB.split()]
tend=time.time()+DUR
while time.time()<tend:
 t0=time.time()
 for off,nm in REGS:
  sys.stdout.write("%s,0x%08x,%s,0x%08x\n"%(DIE,BASE+off,nm,rd(off)))
  time.sleep(0.03)
 sys.stdout.flush()
 rem=PER-(time.time()-t0)
 if rem>0:time.sleep(rem)'

TRACE_PIDS=()
tracer_launch(){ local die=$1 ip=$2 regtab=$3 dur=$4 py b64
  py=${TRACE_PY/@REGTAB@/$regtab}
  b64=$(printf '%s\n' "$py" | base64 -w0)
  ( $SSH "xilinx@$ip" "echo $b64 | base64 -d > /tmp/td_trace.py && echo ${TD_BOARD_PW:-xilinx}|sudo -S python3 -u /tmp/td_trace.py $die $TRACE_PERIOD $dur" 2>/dev/null \
    | while IFS= read -r l; do printf '%s,%s\n' "$(date +%s.%N)" "$l"; done >> "$TRACE_FILE" ) &
  TRACE_PIDS+=("$!"); }

tracer_start(){
  [ -n "$TRACE_FILE" ] || TRACE_FILE="./zeropoke_trace_$(date -u +%Y%m%d-%H%M%SZ).csv"
  echo "timestamp,die,reg,name,value" > "$TRACE_FILE"
  local regtab dur=$(( BUDGET + 60 ))
  regtab=$(trace_regtab)
  say "trace: period=${TRACE_PERIOD}s csv=$TRACE_FILE regs=[$regtab]"
  tracer_launch die_a "$A_IP" "$regtab" "$dur"
  tracer_launch die_b "$B_IP" "$regtab" "$dur"; }

# kill the local ssh pipelines (children first — parent-only leaves orphans);
# the on-board python exits on the next write (SIGPIPE) or at its DUR limit.
tracer_stop(){ local p
  for p in ${TRACE_PIDS[@]+"${TRACE_PIDS[@]}"}; do
    pkill -TERM -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  wait ${TRACE_PIDS[@]+"${TRACE_PIDS[@]}"} 2>/dev/null
  TRACE_PIDS=(); }

trace_rel(){ [ -n "${1:-}" ] || { echo ""; return 0; }
  awk -v t="$1" -v z="$T0" 'BEGIN{printf "t+%.1fs", t-z}'; }

# summary + the FIRST-CLASS ordering discriminator: which die'"'"'s WINSCAN_OBS
# bit0 (winscan_done, 0x21B8[0]) rose first/second — the starvation-polarity
# question every debug loop has needed a timeline for.
trace_summary(){ local n ts die reg name val ta="" tb=""
  n=$(( $(wc -l < "$TRACE_FILE") - 1 )); [ "$n" -lt 0 ] && n=0
  printf 'ZP_TRACE csv=%s samples=%d period=%ss\n' "$TRACE_FILE" "$n" "$TRACE_PERIOD"
  while IFS=, read -r ts die reg name val; do
    [ "$name" = WINSCAN_OBS ] || continue
    [ $(( val & 1 )) -eq 1 ] || continue
    case "$die" in
      die_a) [ -n "$ta" ] || ta=$ts;;
      die_b) [ -n "$tb" ] || tb=$ts;;
    esac
    [ -n "$ta" ] && [ -n "$tb" ] && break
  done < "$TRACE_FILE"
  local first second delta=n/a
  if   [ -z "$ta" ] && [ -z "$tb" ]; then first=none; second=none
  elif [ -z "$tb" ]; then first=die_a; second="none(die_b_never_rose)"
  elif [ -z "$ta" ]; then first=die_b; second="none(die_a_never_rose)"
  else
    if awk -v a="$ta" -v b="$tb" 'BEGIN{exit !(a<=b)}'; then first=die_a; second=die_b
    else first=die_b; second=die_a; fi
    delta=$(awk -v a="$ta" -v b="$tb" 'BEGIN{d=b-a; if(d<0)d=-d; printf "%.2fs", d}')
  fi
  printf 'ZP_TRACE_DISCRIMINATOR winscan_done(0x21B8[0]) a=%s b=%s first=%s second=%s delta=%s\n' \
    "$(trace_rel "$ta")" "$(trace_rel "$tb")" "$first" "$second" "$delta"
  : "$reg"; }

# ----- preflight ---------------------------------------------------------------
echo "======== zeropoke_proof first=$FIRST stagger=${STAGGER}s budget=${BUDGET}s ($(date)) ========"
echo "  die_a=$A_IP($A_BOARD)  die_b=$B_IP($B_BOARD)  deploy=$DO_DEPLOY dir=$DEPLOY_DIR"
boards_up || { echo "### ABORT: a board is unreachable ($A_IP / $B_IP)"; exit 3; }
if [ "$DO_LEASE" = 1 ]; then
  lease_acquire 1800 || { echo "### ABORT: could not acquire $LEASE_NAME lease"; exit 3; }
fi
zp_cleanup(){ [ "$TRACE" = 1 ] && tracer_stop; [ "$DO_LEASE" = 1 ] && lease_release; return 0; }
trap zp_cleanup EXIT

# ----- fresh POR ----------------------------------------------------------------
if [ "$DO_DEPLOY" = 1 ]; then
  say "fresh POR: reflashing both dies (deploy_pair)"
  deploy_pair; sleep 2
else
  say "WARNING: --no-deploy — NOT a fresh POR (role_lock is POR-sticky)"
fi

# ----- arm (the ONLY writes of the whole proof) ----------------------------------
case "$FIRST" in
  a)    say "arm die_a"; zp_arm a; [ "$STAGGER" -gt 0 ] && { say "stagger ${STAGGER}s"; sleep "$STAGGER"; }
        say "arm die_b"; zp_arm b;;
  b)    say "arm die_b"; zp_arm b; [ "$STAGGER" -gt 0 ] && { say "stagger ${STAGGER}s"; sleep "$STAGGER"; }
        say "arm die_a"; zp_arm a;;
  both) say "arm both (near-simultaneous a,b)"; zp_arm a; zp_arm b;;
esac
T0=$(date +%s)   # timestamps count from arm-complete
[ "$TRACE" = 1 ] && tracer_start

# ----- the chain -----------------------------------------------------------------
poll a role_locked            c_role    || true
poll b lane_locked            c_lanes   || true
poll c sync_config            c_synccfg || true
poll d cal_done_cstate4       c_cal     || true
poll e sync_ins_det_seen      c_sync    || true
poll f winscan_reanchored     c_winscan || true
poll g fcsm4_cr_crack_credit  c_fc      || true
if [ "$TRACE" = 1 ]; then tracer_stop; trace_summary; fi

# ----- (h) data both ways ---------------------------------------------------------
H_ST=FAIL; A2B_PASS=0; B2A="not-run"
if [ "${ZP_ST[g]}" = PASS ]; then
  say "(h) 3x A->B txburst"
  for n in 1 2 3; do
    if d=$(burst_once a b); then A2B_PASS=$((A2B_PASS+1)); say "  a2b[$n] PASS $d"
    else say "  a2b[$n] FAIL $d"; fi
  done
  # B->A — guarded: die_b sending with credit 0 wedges die_b's PS (hwlib note)
  if [ $(( $(rd_d b $R_FCCRED) & 0xff )) -gt 0 ]; then
    say "(h) 1x B->A txburst"
    if d=$(burst_once b a); then B2A=PASS; say "  b2a PASS $d"
    else B2A=FAIL; say "  b2a FAIL $d"; fi
  else
    B2A=SKIP-nocredit; say "  b2a SKIPPED: die_b fe_rx_credit_max==0 (PS-wedge guard)"
  fi
  [ "$A2B_PASS" -eq 3 ] && [ "$B2A" = PASS ] && H_ST=PASS
  # post-burst evidence: credit / long / underrun / PKTLEN, both dies
  oa=$(( $(rd_d a $R_OBS) )); ob=$(( $(rd_d b $R_OBS) ))
  sa=$(( $(rd_d a $R_FIFO_STATUS) )); sb=$(( $(rd_d b $R_FIFO_STATUS) ))
  say "post-burst: fccred a=$(rdx a $R_FCCRED) b=$(rdx b $R_FCCRED)"
  say "post-burst: long[26] a=$(( (oa>>26)&1 )) b=$(( (ob>>26)&1 ))  underrun[2] a=$(( (sa>>2)&1 )) b=$(( (sb>>2)&1 ))  overrun[1] a=$(( (sa>>1)&1 )) b=$(( (sb>>1)&1 ))"
  say "post-burst: pktlen a=$(( $(rd_d a $R_PKTLEN) )) b=$(( $(rd_d b $R_PKTLEN) ))"
else
  say "(h) skipped — (g) never passed"
fi
ZP_ST[h]=$H_ST; ZP_T[h]=$(now)
printf 'ZP_STEP h data_bothways %s t=%ss a2b=%d/3 b2a=%s\n' "$H_ST" "${ZP_T[h]}" "$A2B_PASS" "$B2A"

# ----- scorecard -------------------------------------------------------------------
line="ZP_SCORECARD first=$FIRST stagger=${STAGGER}s"
for s in a b c d e f g h; do line="$line $s=${ZP_ST[$s]:-SKIP}(t=${ZP_T[$s]:-.}s)"; done
line="$line a2b=$A2B_PASS/3 b2a=$B2A total=$(now)s"
[ "$TRACE" = 1 ] && line="$line trace=$TRACE_FILE"
echo "$line"
[ "$H_ST" = PASS ]
