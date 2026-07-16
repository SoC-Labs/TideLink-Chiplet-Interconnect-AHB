#!/bin/bash
# =============================================================================
# fake_board_model.sh — tl39-emulating PYNQ-pair model (sourced by the fake
# sshpass in tests/fake_bin/). NO hardware: models the zero-poke autonomous
# bring-up as a per-die timeline keyed off the arm write, so
# zeropoke_proof.sh (incl. --trace) can be validated end-to-end offline.
#
# State lives in $FAKE_STATE:
#   <die>.arm   epoch of the NEGO_TRAIN_CFG arm write (timeline t=0)
#   <die>.wr    every host write, "0xaddr 0xval" per line (last wins)
#   <die>.gp1   the die's GP1 RX FIFO (pop-on-read), one hex word per line
#
# Timeline (seconds after arm; per-die winscan time differs so the trace
# discriminator has a real ordering to detect):
#   t>=1 role_locked; t>=2 lanes 0xE4 + train ok; t>=3 SYNC config + R8=0x1D;
#   t>=4 cal_done + cstate 4; t>=5 tx_sync/sync_det/sync_seen;
#   t>=WS_T winscan_done (die_a FAKE_WS_T_A=8, die_b FAKE_WS_T_B=10);
#   t>=WS_T+1 reanchored; t>=max(12,WS_T+2) FCSM=4 + cr/crack + credit 0x20.
# FAKE_WS_NEVER="die_x[,die_y]" — those dies never finish winscan (done=0,
# reanchored=0, FCSM stuck 1, credit 0) => steps f/g FAIL: the failure path.
# =============================================================================

: "${FAKE_STATE:?FAKE_STATE dir must be exported by the test runner}"

_elapsed(){ local f="$FAKE_STATE/$1.arm"
  if [ -f "$f" ]; then echo $(( $(date +%s) - $(cat "$f") )); else echo -1; fi; }

_peer(){ [ "$1" = die_a ] && echo die_b || echo die_a; }

# last host-written value for an address (fallback for unmodeled regs)
_wrval(){ local f="$FAKE_STATE/$1.wr"
  [ -f "$f" ] || { echo 0; return; }
  awk -v a="$2" '$1==a{v=$2} END{print (v=="")?0:v}' "$f"; }

# GP1 RX FIFO pop (any read in the aperture pops the head — matches silicon)
_gp1_pop(){ local f="$FAKE_STATE/$1.gp1" v=0x00000000
  if [ -s "$f" ]; then v=$(head -1 "$f"); sed -i 1d "$f"; fi
  echo "$v"; }

# raw register value (echoes 0x%08x, may mutate the GP1 queue)
model_rdval(){ local die=$1 addr=$(($2)) t v=0 ws_t rea_t fc_t never=0
  # GP1 RX data aperture: pop-on-read
  if [ "$addr" -ge $((0x84010000)) ] && [ "$addr" -lt $((0x84020000)) ]; then
    printf '0x%08x' "$(( $(_gp1_pop "$die") ))"; return; fi
  t=$(_elapsed "$die")
  if [ "$die" = die_a ]; then ws_t=${FAKE_WS_T_A:-8}; else ws_t=${FAKE_WS_T_B:-10}; fi
  case ",${FAKE_WS_NEVER:-}," in *,"$die",*) never=1;; esac
  rea_t=$(( ws_t + 1 ))
  fc_t=12; [ $(( ws_t + 2 )) -gt $fc_t ] && fc_t=$(( ws_t + 2 ))
  case "$(printf '0x%08x' "$addr")" in
    0x44032084) [ "$t" -ge 1 ] && v=$((0x3));;                       # ROLE_STATUS: locked+role
    0x44032110) if [ "$t" -ge 2 ]; then v=$((0x41))                  # NEGO_TRAIN_STATUS: ok, state4
                elif [ "$t" -ge 0 ]; then v=$((0x24)); fi;;          #   in_prog, state2
    0x44032100) if [ "$t" -ge 3 ]; then v=$((0x1d)); else v=$((0x01)); fi;;  # R8
    0x44032128) [ "$t" -ge 3 ] && v=$((0x5e4));;                     # SYNCTOL
    0x44030214) [ "$t" -ge 3 ] && v=$((0xe4e4));;                    # LANEMASK
    0x44032198) if [ "$t" -ge 4 ]; then v=$((0x4)); else v=$((0x100001)); fi;;  # OBSCAL cstate
    0x44032108)                                                      # OBS / SWI_LANE_STATUS
      [ "$t" -ge 2 ] && v=$(( v | 0xe4 ))                            #   lk[7:0]
      [ "$t" -ge 4 ] && v=$(( v | (1<<16) ))                         #   cal_done
      if [ "$t" -ge "$fc_t" ] && [ $never -eq 0 ]; then
        v=$(( v | (4<<17) | (1<<23) | (1<<24) ))                     #   fcsm=4 cr crack
      elif [ "$t" -ge 2 ]; then v=$(( v | (1<<17) )); fi;;           #   fcsm=1
    0x44032120) v=$((0x5c000000)); [ "$t" -ge 5 ] && v=$(( v | 0x64 ));;   # TXSYNC ins cnt
    0x44032114) [ "$t" -ge 5 ] && v=$(( 200 << 16 ));;               # SYNCCNT sync_det
    0x4403215c) v=$((0x5f000000)); [ "$t" -ge 5 ] && v=$(( v | 0xe4 ));;   # SYNC_SEEN
    0x440321b8) v=$((0x57000000))                                    # WINSCAN_OBS presence
      [ "$t" -ge "$ws_t" ] && [ $never -eq 0 ] && v=$(( v | 1 ));;   #   winscan_done
    0x44032140) [ "$t" -ge "$rea_t" ] && [ $never -eq 0 ] && v=1;;   # REANCHORED
    0x44032118) [ "$t" -ge "$ws_t" ] && v=$((0x66252577));;          # PHASE taps
    0x4403219c) v=$((0xfc000000))                                    # FCCRED presence
      [ "$t" -ge "$fc_t" ] && [ $never -eq 0 ] && v=$(( v | 0x20 ));;#   credit_max
    0x44032010) v=$((0x10));;                                        # FIFO_STATUS committed
    0x44032008) v=0;;                                                # PKTLEN idle
    *) v=$(( $(_wrval "$die" "$(printf '0x%08x' "$addr")") ));;      # write-through fallback
  esac
  printf '0x%08x' "$v"; }

model_rd(){ printf '%s\n' "$(model_rdval "$1" "$2")"; }              # tl39 "rd" output shape

model_wr(){ local die=$1 addr val
  read -r addr val <<< "$2"
  printf '%s %s\n' "$(printf '0x%08x' "$((addr))")" "$(printf '0x%08x' "$((val))")" \
    >> "$FAKE_STATE/$die.wr"
  # the arm write (NEGO_TRAIN_CFG != 0) starts this die's autonomy timeline
  if [ "$((addr))" -eq "$((0x4403210c))" ] && [ "$((val))" -ne 0 ] \
     && [ ! -f "$FAKE_STATE/$die.arm" ]; then
    date +%s > "$FAKE_STATE/$die.arm"
  fi; }

model_txburst(){ local die=$1 w peer; peer=$(_peer "$die")
  for w in $2; do printf '0x%08x\n' "$((w))" >> "$FAKE_STATE/$peer.gp1"; done
  echo "txburst done"; }

# the shipped-base64 trace sampler: decode it, pull REGTAB out of the real
# python source (honest about WHAT the sampler reads), stream CSV rows from
# the same model until the DUR limit or until killed with the ssh pipeline
model_trace(){ local die=$1 cmd=$2 b64 py regtab args per dur e off nm tend
  b64=${cmd#*echo }; b64=${b64%% | base64*}
  py=$(printf '%s' "$b64" | base64 -d)
  regtab=$(printf '%s\n' "$py" | sed -n 's/^REGTAB="\(.*\)"$/\1/p')
  args=${cmd##*td_trace.py }
  read -r _ per dur <<< "$args"
  tend=$(( $(date +%s) + ${dur%.*} ))
  while [ "$(date +%s)" -lt "$tend" ]; do
    for e in $regtab; do
      off=${e%%:*}; nm=${e##*:}
      printf '%s,0x%08x,%s,%s\n' "$die" "$(( 0x44032000 + 0x$off ))" "$nm" \
        "$(model_rdval "$die" "$(( 0x44032000 + 0x$off ))")"
    done
    sleep "$per"
  done; }

# entry: die + the remote command string the script would have ssh'd
model_dispatch(){ local die=$1 cmd=$2
  case "$cmd" in
    *td_trace.py*)       model_trace "$die" "$cmd";;
    *tl39.py\ rd\ *)     model_rd "$die" "${cmd##*tl39.py rd }";;
    *tl39.py\ wr\ *)     model_wr "$die" "${cmd##*tl39.py wr }";;
    *tl39.py\ txburst\ *) model_txburst "$die" "${cmd##*tl39.py txburst }";;
    *) : ;;   # anything else: succeed silently (deploy chatter etc.)
  esac; }
