#!/bin/bash
# shellcheck disable=SC2034  # library: register/const vars are consumed by the sourcing scripts
# =============================================================================
# td_v2_hwlib.sh — TideLink V2 hardware regression LIBRARY (sourced, not run)
#
# Shared helpers + the PROVEN bring-up / data recipe + an assert framework for
# the on-silicon regression suite (td_v2_regress.sh). Runs ON the lab host that
# can SSH directly to the PYNQ pair (mapstone-dev); each helper SSHes one hop to
# a board and drives tl39.py.
#
# PROVEN PATH (2026-06-26, first byte-exact V2 A->B data on silicon):
#   deploy -> rcp (bring-up) -> bilateral(fcsm=4) -> winscan (IDELAY centre,
#   reanchored=1) -> handoff -> SYNC off (R8=0x10) -> FC CTRL 0x00027f07 ->
#   txburst -> read GP1 RX data aperture 0x84010000 for the byte-exact payload.
#
# IMPORTANT counter note: RXW (0x440320D4) is the FC-REPLAY pointer, NOT the app
# RX data. Committed A->B data lands in the GP1 aperture 0x84010000. Check THAT.
#
# Hardware-safety lessons baked in:
#   * THROTTLE register reads (sleeps, no tight mmap loops) — dense reads wedge
#     the PYNQ PS kernel (requires a physical power-cycle to recover).
#   * A->B (die_a sends) is the SAFE direction. B->A (die_b sends) risks wedging
#     die_b's PS (credmax=0) — not exercised here by default.
#   * Acquire the bridge1 lease before, release when idle.
# =============================================================================
set -u

# ----- SoC address map -------------------------------------------------------
# Z2 is the default and is an exact identity (see td_socmap.sh). Every literal
# in this file stays Z2-CANONICAL: the a()/b() helpers hand them to tl39.py,
# which owns the single remap in the chain. Do NOT pre-relocate them here or
# they will be remapped twice. The ONE exception is winscan()'s embedded raw
# /dev/mem python, which bypasses tl39 and so relocates its own base below.
_TD_HERE_SOCMAP=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=fpga/hw_regression/td_socmap.sh
source "$_TD_HERE_SOCMAP/td_socmap.sh"

# ----- board / topology config (override via env) ----------------------------
# TD_A_IP/TD_B_IP (this library's vocabulary) and TD_MASTER_IP/TD_SLAVE_IP
# (td_v2_channels.sh's, and the one several wrappers document — e.g.
# proven_method_soak.sh's header lists TD_MASTER_IP while sourcing THIS file)
# name the same two boards. Historically only TD_A_IP was read here, so a
# wrapper exporting TD_MASTER_IP alone silently fell back to the Z2 defaults
# and drove the Z2 pair. Both are now accepted; if both are set and DISAGREE
# that is fatal, never a silent pick.
A_IP=$(td_reconcile TD_A_IP TD_MASTER_IP "die_a / master board IP")
A_IP=${A_IP:-192.168.4.101}      # die_a = z2_02, master / non-flip  (A->B sender)
B_IP=$(td_reconcile TD_B_IP TD_SLAVE_IP "die_b / slave board IP")
B_IP=${B_IP:-192.168.2.101}      # die_b = z2_01, slave  / flip      (A->B receiver)
A_BOARD=$(td_reconcile TD_A_BOARD TD_MASTER_BOARD "die_a / master board name")
A_BOARD=${A_BOARD:-z2_02}
B_BOARD=$(td_reconcile TD_B_BOARD TD_SLAVE_BOARD "die_b / slave board name")
B_BOARD=${B_BOARD:-z2_01}
DEPLOY_DIR=${TD_DEPLOY_DIR:-/tmp/tidelink_deploy_l7}   # tidelink.bin (die_a) + tidelink-flip.bin (die_b)
DEPLOY_SH=${TD_DEPLOY_SH:-$HOME/deploy_pair.sh}
LEASE_NAME=${TD_LEASE:-bridge1}
TL39=${TD_TL39:-/home/xilinx/tl39.py}

# ----- expected golden values (the proven good state) ------------------------
# LANE MASK is now a PARAMETER (2026-07-17, 8-lane campaign). Everything golden
# below is DERIVED from it, so the same lib drives the 4-lane baseline and the
# 8-lane build without hand-editing four places that can silently disagree.
#   TD_MASK=0xe4  -> 4 lanes (2,5,6,7)  = the historical/certified bridge1 set
#   TD_MASK=0xff  -> 8 lanes            = the 8-lane build (LANE_MASK_RESET=8'hFF)
# NB the mask must match the BITSTREAM's LANE_MASK_RESET: Wlink derives
# bytesPerCycle = popcount(lane_mask)*2 (Wlink.v:996-1014), and on the
# autonomous path the mask handshake latches the POR value at bring-up.
# DEFAULT = 0xe4 (the historical/certified 4-lane set) so that merely sourcing
# this lib is bit-identical to the pre-2026-07-17 behaviour for every existing
# caller. The 8-lane runs pass TD_MASK=0xff EXPLICITLY. Defaulting to 0xff here
# would silently re-point every unrelated script at a different link width —
# and the mask MUST match the bitstream's LANE_MASK_RESET (a 0xff recipe on a
# 0xE4 bitstream does not negotiate 8 lanes; see the measured note below).
TD_MASK=${TD_MASK:-0xe4}
_mask_d=$(( TD_MASK ))
MASK_ACTIVE_LANES=""                  # active lanes, derived from TD_MASK
for _l in 0 1 2 3 4 5 6 7; do [ $(( (_mask_d >> _l) & 1 )) -eq 1 ] && MASK_ACTIVE_LANES="$MASK_ACTIVE_LANES $_l"; done
MASK_ACTIVE_LANES=${MASK_ACTIVE_LANES# }
EXP_SYNC_SEEN=$(printf '0x%02x' $_mask_d)   # 0x4403215C [7:0] = every active lane armed
TD_LANE_COUNT=$(echo "$MASK_ACTIVE_LANES" | wc -w)
TD_BYTES_PER_CYCLE=$(( TD_LANE_COUNT * 2 )) # Wlink: (active_lanes+1)*2 = popcount*2
# 32-bit 0x214 value ({rx_mask[15:8], tx_mask[7:0]}) and 0x2128 ({tol[12:8],mask[7:0]})
TD_LANEMASK32=$(printf '0x%08x' $(( (_mask_d << 8) | _mask_d )))
R_SYNCTOL_VAL=$(printf '0x%08x' $(( (5 << 8) | _mask_d )))   # tol=5
# per-lane SYNC slice (TIDELINK_SYNC_WORD[16*lane +: 16]); RX must read these
# EXACTLY. SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00
# (WlinkRxLinkLayer.v:341). ALL EIGHT listed; only the active ones are checked.
declare -A EXP_SLICE=( [0]=0x1F00 [1]=0x3D2E [2]=0x5B4C [3]=0x796A \
                       [4]=0x9788 [5]=0xB5A6 [6]=0xD3C4 [7]=0xF1E2 )
# A->B test packet (header + payload); GP1 0x84010000.. must read these back
TX_HDR=0x00240000
TX_PAYLOAD=( 0xCAFE0001 0xCAFE0002 0xCAFE0003 )

# ----- key registers (SoC APB @ 0x44032000 base, + GP1 data aperture) --------
R_R8=0x44032100          # PHY control: [0]train [1]recal [2]SYNC_EN [3]force_always [4]robust [5]sync_obs_clr
R_FCSM=0x44032108        # [19:17]=fcsm (4=bilateral) [31]=fe_full
R_REANCHORED=0x44032140  # [0]=reanchored (deskew aligned)
R_SYNCSEEN=0x4403215C    # [7:0]=per-lane sync_seen ; [31:24]=0x5F marker
R_LANEMASK=0x44030214    # rx/tx lane mask (0x0000e4e4)
R_SYNCTOL=0x44032128     # [12:8]=SYNC tol (5) ; [7:0]=mask
R_FCCTRL=0x44030208      # FC node control (CTRL_FULL=0x00027f07)
R_RAW0=0x4403212C; R_RAW1=0x44032130; R_RAW2=0x44032134; R_RAW3=0x44032138  # post-deskew 128b word
R_PHASE_NIB=0x44032118   # per-lane IDELAY tap coarse nibble (4b/lane)
R_PHASE_LSB=0x440321B4   # per-lane IDELAY tap LSB (1b/lane) -> full 0..31
R_DIST_SEL=0x440321B0    # winscan: select lane for dist read
R_DIST=0x440321AC        # winscan: selected lane's SYNC Hamming dist [4:0]
GP1_RX=0x84010000        # GP1 RX DATA aperture — the REAL committed A->B data

# ----- SSH plumbing ----------------------------------------------------------
# BOARD_USER: the login on the board. Was hardcoded `xilinx@` in ~7 places,
# which is right for the PYNQ-Z2 image and not portable to others (KR260 images
# commonly use a different login). Now one knob, DEFAULTING TO xilinx so every
# existing Z2 invocation is unchanged. Set TD_BOARD_USER to override. Exported
# so the scripts that source this lib inherit it without re-deriving it.
BOARD_USER=${TD_BOARD_USER:-xilinx}
export BOARD_USER
SSH="sshpass -p ${TD_BOARD_PW:-xilinx} ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=12"
# TIDELINK_SOC must cross the ssh hop: tl39.py runs ON THE BOARD and resolves
# the address map from its OWN environment. ssh does not forward env, and sudo
# scrubs it, so it is passed explicitly as a sudo-side assignment (same idiom as
# pynq_host/scripts/char_session.sh). WITHOUT THIS a KR260 run would reach tl39
# with TIDELINK_SOC unset, silently fall back to the z2 identity map, and poke
# Z2 control addresses on ZynqMP — the exact undecoded-access hang this change
# exists to prevent. On z2 this passes TIDELINK_SOC=z2, which resolves to the
# same identity map as unset (proven equal), so Z2 behaviour is unchanged.
_PY="echo ${TD_BOARD_PW:-xilinx} | sudo -S TIDELINK_SOC=$(td_soc) python3 $TL39"
a(){ $SSH $BOARD_USER@$A_IP "$_PY $*" 2>/dev/null; }     # tl39 on die_a
b(){ $SSH $BOARD_USER@$B_IP "$_PY $*" 2>/dev/null; }     # tl39 on die_b
# raw mmap python on a board (arg1=ip, arg2=python body)
braw(){ $SSH $BOARD_USER@$1 "echo ${TD_BOARD_PW:-xilinx}|sudo -S python3 -c '$2'" 2>/dev/null; }

TD_THROTTLE=${TD_THROTTLE:-0.25}     # sleep between board reads (PS-wedge guard)
rd_b(){ local v; v=$(b rd $1); sleep "$TD_THROTTLE"; echo "$v"; }   # throttled die_b read

# ----- property readers ------------------------------------------------------
fcsm(){ local s; s=$($1 rd $R_FCSM); echo $(( (s>>17)&7 )); }        # 4 = bilateral
reanchored(){ echo $(( $(b rd $R_REANCHORED)&1 )); }
sync_seen(){ printf "0x%02x" $(( $(b rd $R_SYNCSEEN)&0xff )); }
livematch(){ echo $(( $($1 livematch 2>/dev/null|grep -oE 'per_lane=0x[0-9a-f]+'|cut -d= -f2) )); }
# post-deskew received slice for a lane: 0x212C(l0,1) 0x2130(l2,3) 0x2134(l4,5) 0x2138(l6,7)
rx_slice(){ local L=$1 reg sh
  case $L in 0|1) reg=$R_RAW0;; 2|3) reg=$R_RAW1;; 4|5) reg=$R_RAW2;; 6|7) reg=$R_RAW3;; esac
  [ $((L%2)) -eq 0 ] && sh=0 || sh=16
  printf "0x%04X" $(( ($(b rd $reg)>>sh)&0xffff )); }
gp1_rx(){ b rd $(printf 0x%x $(( GP1_RX + ${1:-0}*4 ))); }   # GP1 RX data word index (tl39 needs hex addr)

# ----- bring-up / data recipe ------------------------------------------------
deploy_pair(){
  "$DEPLOY_SH" $A_IP $A_BOARD die_a "$DEPLOY_DIR" --no-verify >/dev/null 2>&1
  "$DEPLOY_SH" $B_IP $B_BOARD die_b "$DEPLOY_DIR" --no-verify >/dev/null 2>&1
}
rcp(){   # the proven V2 bring-up recipe (mask parameterised by TD_MASK)
  a wr 0x4403210C 0x0>/dev/null;       b wr 0x4403210C 0x0>/dev/null
  a wr $R_LANEMASK $TD_LANEMASK32>/dev/null; b wr $R_LANEMASK $TD_LANEMASK32>/dev/null
  a wr 0x44032080 0x2>/dev/null;       b wr 0x44032080 0x3>/dev/null
  a wr 0x44032160 0x55555555>/dev/null;b wr 0x44032160 0x55555555>/dev/null
  a wr 0x44032104 0x0>/dev/null;       b wr 0x44032104 0x0>/dev/null
  a wr $R_SYNCTOL $R_SYNCTOL_VAL>/dev/null;b wr $R_SYNCTOL $R_SYNCTOL_VAL>/dev/null
  a wr $R_R8 0x1D>/dev/null;           b wr $R_R8 0x1D>/dev/null
  a wr $R_R8 0x1F>/dev/null;           b wr $R_R8 0x1D>/dev/null; sleep 0.03
  a wr $R_R8 0x1D>/dev/null;           b wr $R_R8 0x1D>/dev/null
}
handoff(){
  a wr 0x44030230 0x0>/dev/null; b wr 0x44030230 0x0>/dev/null; sleep 0.1
  for v in 0x00027f09 0x00027f01 0x00027f07; do a wr $R_FCCTRL $v>/dev/null; b wr $R_FCCTRL $v>/dev/null; sleep 0.2; done; sleep 0.3
}
# wait for bilateral fcsm=4 (with POR retries); 0 = ok
wait_bilateral(){ local pors=${1:-6} secs=${2:-16} por t
  for por in $(seq 1 $pors); do
    for t in $(seq 1 $secs); do sleep 1; [ "$(fcsm a)" = 4 ] && [ "$(fcsm b)" = 4 ] && return 0; done
    deploy_pair; sleep 1; rcp
  done; return 1
}
# IDELAY winscan: centre each active lane to the arming tap -> reanchored. Needs
# force_always (SYNC every beat) for a stable dist read; shipped base64 (no quoting).
winscan(){
  a wr $R_R8 0x1C>/dev/null; b wr $R_R8 0x1C>/dev/null; sleep 0.6
  # This python mmaps /dev/mem DIRECTLY on the board — it does NOT go through
  # tl39.py, so it is the one place in this library that must relocate its own
  # base. Everything inside works off PAGE-relative offsets from WS_BASE, so
  # only the base moves. Identity on z2 => byte-identical Z2 behaviour.
  local WS_BASE; WS_BASE=$(td_remap 0x44032000 "winscan apb base") || return 1
  local PY='import mmap,struct,os,time,ctypes
P=4096;fd=os.open("/dev/mem",os.O_RDWR|os.O_SYNC)
bb='"$WS_BASE"'&~(P-1);o='"$WS_BASE"'-bb
m=mmap.mmap(fd,((0x400+o+P-1)//P)*P,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=bb)
# SoC Labs 2026-07-09: rd/wr MUST be single aligned 32-bit bus accesses.
# struct.pack_into/unpack_from did NOT compile to one access on this target
# (measured: 5 AHB beats per logical poke) -- the "TX 5x over-advance phantom".
# It corrupts the winscan itself: the dist read (0x1AC) is fine but the settap
# W1x taps and any POP/pulse aperture fire 5x. ctypes.c_uint32.from_buffer(m,o)
# is exactly one aligned load/store per .value. Do not revert to struct. (tl39.py)
def _u32(off):return ctypes.c_uint32.from_buffer(m,o+off)
def rd(x):return _u32(x).value
def wr(x,v):_u32(x).value=v&0xffffffff
def settap(L,t):
 n=(t>>1)&0xf;lb=t&1
 c=rd(0x118);c&=~(0xf<<(4*L));c|=n<<(4*L);wr(0x118,c)
 c=rd(0x1B4);c&=~(1<<L);c|=lb<<L;wr(0x1B4,c)
def dist(L):
 wr(0x1B0,L);time.sleep(0.003);return rd(0x1AC)&0x1f
for L in [__WS_LANES__]:
 best=(99,0)
 for t in range(32):
  settap(L,t);time.sleep(0.05);d=min(dist(L) for _ in range(5))
  if d<best[0]:best=(d,t)
  time.sleep(0.008)
 settap(L,best[1])
print("winscan_done")'
  # winscan only ever swept the ACTIVE lanes; derive them from TD_MASK so an
  # 8-lane build scans all 8 (the hardcoded [6,2,5,7] silently left lanes
  # 0/1/3/4 untrained on any wider mask).
  local _wsl; _wsl=$(echo "$MASK_ACTIVE_LANES" | tr ' ' ',')
  PY=${PY/__WS_LANES__/$_wsl}
  local B64; B64=$(echo "$PY" | base64 -w0)
  $SSH $BOARD_USER@$B_IP "echo $B64 | base64 -d > /tmp/td_ws.py && echo ${TD_BOARD_PW:-xilinx}|sudo -S python3 /tmp/td_ws.py" 2>/dev/null
  a wr $R_R8 0x14>/dev/null; b wr $R_R8 0x14>/dev/null   # idle-gated -> reanchored latches
  local w; for w in $(seq 1 6); do sleep 1.0; [ "$(reanchored)" = 1 ] && break; done
}
enter_data_mode(){     # after reanchored=1: re-establish FC node, open send-gate, strip SYNC so the framer runs packets to completion
  handoff                                                                     # re-do FC data-mode entry (prior tests toggled R8)
  a wr $R_FCCTRL 0x00027f07>/dev/null; b wr $R_FCCTRL 0x00027f07>/dev/null; sleep 0.5
  a wr $R_R8 0x10>/dev/null;           b wr $R_R8 0x10>/dev/null; sleep 0.5   # SYNC off (reanchored is sticky)
}
send_a2b(){ a txburst $TX_HDR ${TX_PAYLOAD[*]} >/dev/null 2>&1; }
fe_full(){ echo $(( ($(a rd $R_FCSM)>>31)&1 )); }              # die_a send-gate (0=open)
data_state(){ printf "reanchored=%s fe_full=%s fcsm_a=%s fcsm_b=%s FCCTRL_a=0x%x" \
  "$(reanchored)" "$(fe_full)" "$(fcsm a)" "$(fcsm b)" $(( $(a rd $R_FCCTRL) )); }

# ----- lease + board health --------------------------------------------------
lease_acquire(){ local ttl=${1:-2400} out tok
  out=$(fpgahub pair lease acquire $LEASE_NAME --ttl $ttl --json 2>/dev/null)
  tok=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null)
  echo "LEASE_TOKEN=$tok" > "$HOME/.td_regress_lease"; [ -n "$tok" ]
}
lease_release(){ local tok; tok=$(grep -o 'LEASE_TOKEN=.*' "$HOME/.td_regress_lease" 2>/dev/null|cut -d= -f2)
  [ -n "$tok" ] && fpgahub pair lease release $LEASE_NAME --token "$tok" >/dev/null 2>&1; }
board_up(){ ping -c1 -W2 $1 >/dev/null 2>&1; }
boards_up(){ board_up $A_IP && board_up $B_IP; }

# ----- assert framework ------------------------------------------------------
TD_PASS=0; TD_FAIL=0; TD_DETAIL=()
assert_eq(){ # label expected actual
  if [ "$2" = "$3" ]; then TD_PASS=$((TD_PASS+1)); TD_DETAIL+=("    ok   $1: $3")
  else TD_FAIL=$((TD_FAIL+1)); TD_DETAIL+=("    FAIL $1: got=$3 want=$2"); return 1; fi
}
flush_detail(){ printf '%s\n' "${TD_DETAIL[@]}"; TD_DETAIL=(); }

# =============================================================================
# ZERO-POKE AUTONOMY additions (L4 training-exit era, 2026-07)
# Named registers + helpers for zeropoke_proof.sh / zeropoke_soak.sh /
# snapshot.sh / linkhold_soak.sh. Addresses cross-checked against
# docs/REGISTER_MAP.md + pynq_host/scripts/tl39.py + the RTL region decode
# (axi_chiplet_controller.sv regionD, 2026-07-02 WINSCAN_OBS).
# =============================================================================

# ----- FIFO / packet obs (Region 0) ------------------------------------------
R_PKTLEN=0x44032008        # PACKET_WORD_LENGTH (RO, 14b; 0 when idle)
R_CREDIT_COUNT=0x4403200C  # CREDIT_COUNT (RO) — free credits in the LOCAL FIFO
R_FIFO_STATUS=0x44032010   # [1]=overrun(sticky) [2]=underrun(sticky) [3]=master_err [4]=committed

# ----- role / autoneg (Region 4) ----------------------------------------------
R_ROLE_CFG=0x44032080          # [0]=role [1]=role_lock (W1S, POR-only clear)
R_ROLE_STATUS=0x44032084       # [0]=effective_role [1]=locked [2]=i2c_busy [3]=i2c_addressed
R_NEGO_CFG=0x44032090          # [0]=nego_en [5]=force_lock [6]=mask_hs_auto_en
                               # POR IS 0x00000000 — *NOT* 0x61. Measured on silicon
                               # 2026-07-09. A run that does not read this back after
                               # arming is a NON-TEST: nego_en=0 => autonomy_armed=0 =>
                               # training never starts and the winscan never leaves
                               # WS_IDLE. The historical "die_a 42%" figure was exactly
                               # this. ALWAYS use zp_arm(), which verifies.
R_NEGO_STATUS=0x44032094       # [3:0]=state [4]=done [5]=err [6]=won [7]=lost
R_NEGO_TRAIN_CFG=0x4403210C    # [0]=train_auto_en [23:20]=MIN_LOCK_DWELLS
R_NEGO_TRAIN_STATUS=0x44032110 # [0]=ok [1]=fail [2]=in_prog [7:4]=train_state
# OBS_MASK_HS (regionC slot 5) — the autoneg role-lock chain. Live in every V2
# bitstream; never captured by the soak until 2026-07-09.
R_OBS_MASK_HS=0x44032194       # [22:21]=mask_hs_result [20]=gate_open [19]=match
                               # [18]=nego_lock_pending [17]=local_fail [16]=local_match
                               # [15:8]=peer_rx_mask [7:0]=peer_tx_mask

# ----- PHY / SYNC / winscan obs (Regions 8-D) ---------------------------------
R_OBS=0x44032108        # SWI_LANE_STATUS (alias of R_FCSM): lk[7:0] flt[15:8]
                        # cal[16] fcsm[19:17] llrx[22:21] cr[23] ck[24]
                        # long[26] llv[29] a2l[30] fe_full[31]
R_SLIPLO=0x44032104     # [23:0]=slip [27:24]=word_pin [28]=auto_dis
R_SYNCCNT=0x44032114    # [31:16]=sync_detected sat-cnt (coherent deskew health)
R_PHASE=0x44032118      # per-lane IDELAY coarse nibble (== R_PHASE_NIB, tap[4:1])
R_TXSYNC=0x44032120     # [15:0]=tx_sync_ins_cnt [16]=idle_lvl [17]=train_lvl [31:24]=0x5C
R_RXDET2=0x44032124     # [15:0]=sync_seen_cnt [23:16]=per-lane sticky [31:24]=0x5D
R_LIVEMATCH=0x44032144  # [7:0]=live per-lane SYNC match since clear [31:24]=0x5E
R_OBSCAL=0x44032198     # [3:0]=V2 calibrator FSM cstate [20]=live training_mode
R_FCCRED=0x4403219C     # OBS_FC_CREDIT: [7:0]=fe_rx_credit_max [15:8]=fe_rx_ptr
                        # [16]=is_full [31:24]=0xFC presence (credit by VALUE lives here)
R_RXCAP0=0x440321A0     # RX-framer long-DATA sticky capture word 0
R_RXCAP1=0x440321A4     # RX-framer long-DATA sticky capture word 1
R_FCSMCAP=0x440321A8    # FCSM transition sticky capture
R_WINSCAN_OBS=0x440321B8 # [0]=winscan_done [1]=ws_degenerate(sticky)
                         # [2]=ws_anchor_timeout(sticky) [3]=anchored-late
                         # [7:4]=abort cnt [9]=vfy-retry [13:11]=FIX-4 anchor-
                         # retry attempt cnt (per-episode; reads 0 pre-FIX-4)
                         # [31:24]=0x57 presence
GP1_TX=0x84000000        # GP1 TX DATA aperture (txburst target; GP0 0x44xxxxxx data hangs)

# HARDWARE-SAFETY: NEVER WRITE 0x440321B0 (SYNC_DIST_SEL) or 0x440321B4
# (SWI_PHASE_LSB) during/after an autonomous bring-up — the on-chip winscan
# FSM owns them; a host write mid-scan corrupts the tap walk. READS are fine.

# ----- zero-poke ARM values ----------------------------------------------------
ZP_NEGO_CFG_ARM=0x61        # nego_en + force_lock + mask_hs_auto_en
ZP_NEGO_TRAIN_CFG_ARM=0x0001  # train_auto_en (and NOTHING else — zero-poke)
# The a->b test packet for the (h) data gate.
#
# FIXED 2026-07-16 -- this was 3 words and the old comment called it "header + 2
# payload". That is a MISREADING of the frame: a packet is `length+2` words
# (word0=length<<20|type<<18, word1=dest_addr, then `length` payload words --
# see tidelink_fifo_ctrl / pair_v2_common.make_packet). Header 0x00240000
# declares length=2, so the packet is 2+2 = 4 words and only 3 were ever sent.
# Every zp_txburst therefore emitted a TRUNCATED packet that never completed.
#
# It hid because a reader can still see the words in the RX SRAM even though the
# packet never committed -- so a 3-word compare "passes". It bites the moment
# anything READS OFFSET 3: that is read_target_addr = (length+1)*4, which fires
# read_complete and pops `length+2` = 4 words while the writer only ever
# advanced write_ptr by 3, walking read_ptr 1 word PAST write_ptr on EVERY
# burst. That is what made linkhold_soak read all-zeros from burst 2 onward on a
# perfectly healthy link (fcsm 4/4, reanchored, credit 31).
#
# Now byte-identical to the CERTIFIED send_a2b frame (TX_HDR + TX_PAYLOAD, 4
# words) -- the one the N=40 zero-poke certification actually proved.
ZP_TX_WORDS=(0x00240000 0xcafe0001 0xcafe0002 0xcafe0003)

# ----- die-generic helpers (arg1 = a | b) --------------------------------------
rd_a(){ local v; v=$(a rd "$1"); sleep "$TD_THROTTLE"; echo "$v"; }   # throttled die_a read
rd_d(){ local v; v=$("$1" rd "$2"); sleep "$TD_THROTTLE"; echo "$v"; } # throttled read, either die
reanchored_d(){ echo $(( $("$1" rd $R_REANCHORED) & 1 )); }
gp1_rx_d(){ "$1" rd "$(printf 0x%x $(( GP1_RX + ${2:-0}*4 )))"; }      # GP1 RX word idx, either die
# arm one die for zero-poke autonomy: NEGO_CFG + NEGO_TRAIN_CFG, nothing else.
# READS BOTH BACK. NEGO_CFG's POR is 0x00, so an arm that silently fails leaves
# nego_en=0 => autonomy_armed=0 => the winscan never kicks and every per-episode
# counter reads 0. That is indistinguishable, at 0x21B8, from a genuine NODONE —
# which is how a whole campaign of "die_a 42%" runs turned out to be NON-TESTS.
# Returns 0 armed / 1 arm FAILED (caller MUST treat 1 as "cycle void", not FAIL).
zp_arm(){ local d="$1" cfg trn
  "$d" wr $R_NEGO_CFG $ZP_NEGO_CFG_ARM >/dev/null
  "$d" wr $R_NEGO_TRAIN_CFG $ZP_NEGO_TRAIN_CFG_ARM >/dev/null
  cfg=$("$d" rd $R_NEGO_CFG 2>/dev/null) || { echo "zp_arm($d): NEGO_CFG readback BUS ERROR" >&2; return 1; }
  trn=$("$d" rd $R_NEGO_TRAIN_CFG 2>/dev/null) || { echo "zp_arm($d): TRAIN_CFG readback BUS ERROR" >&2; return 1; }
  if [ $(( cfg & 1 )) -ne 1 ]; then
    echo "zp_arm($d): NON-TEST — NEGO_CFG=$(printf 0x%08x $cfg), nego_en=0 (POR is 0x00; the write did not stick)" >&2
    return 1
  fi
  if [ $(( trn & 1 )) -ne 1 ]; then
    echo "zp_arm($d): NON-TEST — NEGO_TRAIN_CFG=$(printf 0x%08x $trn), train_auto_en=0" >&2
    return 1
  fi
  return 0; }
# Arm with bounded retry. The arm is two APB writes; a transient failure (bus
# busy, a peer swreset window) is worth retrying, a persistent one is a real
# arm-path bug and must surface rather than be papered over. 3 attempts, then
# give up and let the caller score the cycle UNARMED.
# QUIESCE BEFORE RE-DEPLOY. Reloading the PL on a LIVE link has hard-hung a board
# (3x in 90 min, 2026-07-09). Disarm autonomy first: clearing NEGO_TRAIN_CFG[0]
# and NEGO_CFG[0] is the RTL's own escape hatch (axi_chiplet_controller.sv:4539) —
# the winscan parks and the SYNC beacons stop within a cycle. Safe here ONLY
# because a reflash follows immediately: the same write, left standing, springs
# the disarm-park ws_kicked_q trap (both re-kick paths need ~ws_kicked_q, cleared
# only at POR). Never call this without reflashing after. Best-effort: a die whose
# bus is already dead just fails the write, which is fine.
zp_quiesce(){ local d
  for d in a b; do
    "$d" wr $R_NEGO_TRAIN_CFG 0x0 >/dev/null 2>&1 || true
    "$d" wr $R_NEGO_CFG       0x0 >/dev/null 2>&1 || true
  done
  sleep 0.2; }
ZP_ARM_TRIES=${ZP_ARM_TRIES:-3}
zp_arm_retry(){ local d="$1" i
  for i in $(seq 1 "$ZP_ARM_TRIES"); do
    if zp_arm "$d" 2>/dev/null; then
      [ "$i" -gt 1 ] && echo "zp_arm($d): armed on attempt $i" >&2
      return 0
    fi
    sleep 0.3
  done
  echo "zp_arm($d): FAILED after $ZP_ARM_TRIES attempts — arm did not stick" >&2
  return 1; }
# the autoneg role-lock chain on one die: role_locked, and why (or why not).
maskhs_d(){ "$1" rd $R_OBS_MASK_HS; }
rolelocked_d(){ echo $(( ( $("$1" rd $R_ROLE_STATUS) >> 1 ) & 1 )); }
# autonomy_armed = nego_en & role_locked & train_auto_en — the exact RTL term
# (axi_chiplet_controller.sv:1143) that gates BOTH ws_kick_evt and the FIX-1
# reanchor-catchup. If this is 0 the winscan CANNOT run; 0x21B8 will read
# 0x57000000 and mean nothing.
armed_d(){ local d="$1"
  echo $(( ( $("$d" rd $R_NEGO_CFG) & 1 ) \
         & $(rolelocked_d "$d") \
         & ( $("$d" rd $R_NEGO_TRAIN_CFG) & 1 ) )); }
# send the standard 3-word test packet from one die (a = A->B, b = B->A)
zp_txburst(){ "$1" txburst "${ZP_TX_WORDS[@]}" >/dev/null 2>&1; }
# hex-print a register read (0 on unreachable/empty)
rdx(){ printf '0x%08x' "$(( $("$1" rd "$2" 2>/dev/null || echo 0) ))"; }
