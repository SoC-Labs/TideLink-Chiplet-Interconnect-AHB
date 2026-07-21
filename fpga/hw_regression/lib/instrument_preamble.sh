# shellcheck shell=bash
# =============================================================================
# instrument_preamble.sh — the MANDATORY L1 instrument self-check that every
# TideLink hardware run must pass BEFORE it trusts any register read.
#
# Direct countermeasure to the campaign's fifteen "the INSTRUMENT was broken,
# not the DUT" nights (docs/TIDELINK_FPGA_VERIFICATION_PLAN.md §2.1, RULE #1).
# It implements the 7-step preamble:
#
#   1. reader self-test  — a well-formed read from an always-answering PS reg
#                          (defends class J: missing script rc=2 == DECERR both
#                          look like "chip dead").
#   2. width probe       — two ADJACENT, KNOWN-DISTINCT words read back their
#                          own distinct constants (defends class D: a 128-bit
#                          AFI port silently drops 3/4 of every APB word).
#   3. KR260 AFI check   — REUSES pynq_host/scripts/kr260_afi.sh (never dup'd).
#   4. control canaries  — hardwired constants must match (KR 0x..0204/0214/0200,
#                          Z2 ID regs) (defends D and proves the control plane).
#   5. RW-scratch litmus — write/readback the +0x2160 per-nibble-masked scratch,
#                          then RESTORE it exactly (defends A/C: a zero from a
#                          register not proven live is not a measurement).
#   6. trust guard       — is_trustworthy_reg(): the V2 retired-register
#                          deny-list, so scripts never feed a read-0-by-
#                          construction reg into a verdict (defends A).
#   7. wedge-safety      — preamble_addr_is_safe(): refuse the CPU-stalling
#                          offsets 0x21AC/0x21B0/0x21B4 and the undecoded
#                          0x4403_xxxx aperture on ZynqMP (hard PS hang).
#
# ---------------------------------------------------------------------------
# INTERFACE
# ---------------------------------------------------------------------------
#   source instrument_preamble.sh
#   preamble_run_all <soc> <host> [RD_CMD] [WR_CMD]
#       <soc>  = kr260 | z2         <host> = informational label (logged)
#       returns 0 on all-pass; on the FIRST failure returns non-zero AND prints
#       exactly one line  "PREAMBLE_FAIL: <NAME>"  (NAME is machine-parseable).
#
#   Individual checks are all callable on their own after `preamble_config`:
#       preamble_reader_selftest   preamble_width_probe   preamble_afi_check
#       preamble_canaries          preamble_rw_litmus     preamble_trust_selftest
#       preamble_wedge_selftest
#   Query helpers (side-effect-free, for the L2/L3 scripts to gate on):
#       is_trustworthy_reg <addr>      -> 0 trustworthy / 1 quarantined
#       preamble_addr_is_safe <soc> <addr> -> 0 safe / 1 wedge-unsafe
#
# ---------------------------------------------------------------------------
# TRANSPORT IS A PARAMETER, NOT HARDCODED
# ---------------------------------------------------------------------------
# The library never assumes ssh/tl39/devmem. It reads via the command in
# $PREAMBLE_RD_CMD and writes via $PREAMBLE_WR_CMD, invoked as:
#       $PREAMBLE_RD_CMD <abs-addr>              -> must echo 0xXXXXXXXX
#       $PREAMBLE_WR_CMD <abs-addr> <value>      -> performs one aligned u32 store
# Because the caller `source`s this file, PREAMBLE_RD_CMD may name a shell
# FUNCTION (e.g. a board-local `mrd`) — command-substitution subshells inherit
# functions — or an external tool (e.g. "sudo /home/xilinx/tl_poke.py rd").
#
#   *** IMPORTANT: the reader must take ABSOLUTE physical addresses ***
#   (tl_poke.py / devmem style). Do NOT wire a tl39.py canonical-Z2 reader here:
#   tl39 RELOCATES canonical addresses per SoC, whereas this preamble already
#   carries the absolute per-SoC address table below. Feeding a relocating
#   reader absolute addresses would double-map on KR260.
#
# ALL diagnostic output goes to STDOUT (the harness discards stderr). Every
# read logs addr / expected / actual.
# =============================================================================

# ---- global config (populated by preamble_config) --------------------------
PRE_SOC=""            # normalized soc id: kr260 | z2
PRE_HOST=""           # informational host label
PRE_BLOCK=""          # APB block base (0x..30000); offsets add onto this
PRE_PS_ALIVE=""       # always-answering PS register (absolute)
PRE_IS_KR=0
# canary addr/expected triples filled per soc
PRE_CAN1_A=""; PRE_CAN1_E=""
PRE_CAN2_A=""; PRE_CAN2_E=""
PRE_CANN_A=""; PRE_CANN_E=""     # negative-control / anchor (INFO only)
PRE_WA=""; PRE_WA_E=""           # width-probe word A
PRE_WB=""; PRE_WB_E=""           # width-probe word B (adjacent, distinct)
PRE_SCRATCH=""                   # +0x2160 RW-scratch (absolute)

# Retired-in-V2 register OFFSETS (low-16 of the absolute addr). These read 0 by
# construction or silently ignore writes; a verdict must NEVER read them.
# (docs/TIDELINK_FPGA_VERIFICATION_PLAN.md §1 trust table; memory:
#  reference_v2_retired_obs_regs_sync_seen_void.md)
PRE_RETIRED_OFFSETS="0x215C 0x2144 0x2174 0x2164 0x2168 0x2178 0x217C"
# CPU hard-stall offsets — never issue ANY access here.
PRE_WEDGE_OFFSETS="0x21AC 0x21B0 0x21B4"

# ---- tiny logging + numeric helpers (all stdout) ---------------------------
_ip_log(){ echo "  $*"; }
_ip_hex(){ printf '0x%08X' "$(( $1 ))"; }             # normalize a numeric to 0x%08X
_ip_is_word(){ case "$1" in 0x[0-9A-Fa-f]* ) return 0;; [0-9]* ) return 0;; * ) return 1;; esac; }
_ip_no_reader(){ echo ""; return 42; }                 # default: no transport wired

# safe numeric read: returns "" on refusal/empty/malformed so callers can detect
# a dead instrument instead of a bogus 0.
preamble_read(){ # $1 = absolute addr
  local a="$1" v
  if ! preamble_addr_is_safe "$PRE_SOC" "$a"; then
    echo ""   # refuse; the guard already logged WEDGE_UNSAFE
    return 3
  fi
  v="$(${PREAMBLE_RD_CMD:-_ip_no_reader} "$a" 2>/dev/null)"
  v="${v//[[:space:]]/}"
  echo "$v"
}

preamble_write(){ # $1 = absolute addr, $2 = value
  local a="$1" val="$2"
  if ! preamble_addr_is_safe "$PRE_SOC" "$a"; then return 3; fi
  # never blind-write the TX data aperture (a store to a down link hangs the PS)
  case "$a" in
    0x84[0-1][0-9A-Fa-f][0-9A-Fa-f]0000|0x8400????|0x8401????)
      if [ "${PREAMBLE_ALLOW_TX:-0}" != "1" ]; then
        _ip_log "REFUSED write to TX/data aperture $a (set PREAMBLE_ALLOW_TX=1 only after cal=1+fcsm=4 bilateral)"
        return 3
      fi ;;
  esac
  ${PREAMBLE_WR_CMD:-_ip_no_reader} "$a" "$val" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# preamble_config <soc> <host> [RD_CMD] [WR_CMD]
#   Resolves the per-SoC absolute address table. Must run before any check.
# ---------------------------------------------------------------------------
preamble_config(){
  local soc="$1" host="$2" rd="${3:-}" wr="${4:-}"
  PRE_HOST="$host"
  [ -n "$rd" ] && PREAMBLE_RD_CMD="$rd"
  [ -n "$wr" ] && PREAMBLE_WR_CMD="$wr"
  case "$soc" in
    kr260|kria|zynqmp|kr)
      PRE_SOC="kr260"; PRE_IS_KR=1
      PRE_BLOCK=0x84030000
      # ZynqMP LPD GPIO bank0 DATA_0_RO: read-only input-data mirror, no side
      # effect, LPD always powered/decoded regardless of PL state. Overridable.
      PRE_PS_ALIVE="${PREAMBLE_PS_ALIVE_ADDR:-0xFF0A0060}"
      PRE_CAN1_A=0x84030204; PRE_CAN1_E=0x00000001     # role/build id
      PRE_CAN2_A=0x84030214; PRE_CAN2_E=0x0000E4E4     # LANEMASK POR (0xE4E4)
      PRE_CANN_A=0x84030200; PRE_CANN_E=0x00000088     # hardwired slave id (INFO)
      # width probe: 0x200 (0x88) and adjacent 0x204 (0x01) are distinct+nonzero.
      PRE_WA=0x84030200; PRE_WA_E=0x00000088
      PRE_WB=0x84030204; PRE_WB_E=0x00000001
      PRE_SCRATCH=0x84032160
      ;;
    z2|pynqz2|pynq_z2|zynq7|zynq7000|zynq)
      PRE_SOC="z2"; PRE_IS_KR=0
      PRE_BLOCK=0x44030000
      # Zynq-7000 GPIO bank0 DATA_RO (0xE000_A068): read-only, no side effect,
      # PS GPIO clock always on. This is the address the plan names.
      PRE_PS_ALIVE="${PREAMBLE_PS_ALIVE_ADDR:-0xE000A068}"
      PRE_CAN1_A=0x4403211C; PRE_CAN1_E=0x50410100     # PHY_ALIGN_ID
      PRE_CAN2_A=0x44032190; PRE_CAN2_E=0x4F420100     # OBS_OBS_ID
      PRE_CANN_A=0x44032014; PRE_CANN_E=0x544C0100     # peripheral id (anchor)
      PRE_WA=0x4403211C; PRE_WA_E=0x50410100
      PRE_WB=0x44032190; PRE_WB_E=0x4F420100
      PRE_SCRATCH=0x44032160
      ;;
    *)
      echo "PREAMBLE_FAIL: UNKNOWN_SOC"
      _ip_log "soc='$soc' — expected kr260 | z2"
      return 2 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# STEP 6 helper — is_trustworthy_reg <addr>  (side-effect-free query)
#   0 = trustworthy on a V2 build; 1 = quarantined (reads 0 / lies / ignores wr).
# ---------------------------------------------------------------------------
is_trustworthy_reg(){
  local a="$1" off r
  _ip_is_word "$a" || { echo "not-a-word:$a"; return 1; }
  off=$(( a & 0xFFFF ))
  for r in $PRE_RETIRED_OFFSETS; do
    if [ "$off" -eq "$(( r ))" ]; then
      echo "QUARANTINED $(_ip_hex "$off"): V2-retired (reads 0 / ignores writes) — never use as a verdict"
      return 1
    fi
  done
  if [ "$off" -eq "$(( 0x2108 ))" ]; then
    echo "TRUST $(_ip_hex "$off"): fcsm[19:17]/cal[16] OK — but lane_locked[7:0] reads 0x00 healthy, do NOT trust that field"
    return 0
  fi
  echo "TRUST $(_ip_hex "$off")"
  return 0
}

# ---------------------------------------------------------------------------
# STEP 7 helper — preamble_addr_is_safe <soc> <addr>  (side-effect-free query)
#   0 = safe to access; 1 = wedge-unsafe (would hard-stall the PS).
# ---------------------------------------------------------------------------
preamble_addr_is_safe(){
  local soc="$1" a="$2" off r
  _ip_is_word "$a" || { _ip_log "WEDGE_UNSAFE: '$a' is not an address"; return 1; }
  off=$(( a & 0xFFFF ))
  for r in $PRE_WEDGE_OFFSETS; do
    if [ "$off" -eq "$(( r ))" ]; then
      _ip_log "WEDGE_UNSAFE $a: offset $(_ip_hex "$off") HARD-STALLS the CPU thread — refused"
      return 1
    fi
  done
  # Undecoded 0x4403_xxxx aperture on ZynqMP hangs the PS with no timeout.
  if [ "$soc" = "kr260" ] && [ "$(( (a >> 16) & 0xFFFF ))" -eq "$(( 0x4403 ))" ]; then
    _ip_log "WEDGE_UNSAFE $a: 0x4403_xxxx is UNDECODED on ZynqMP (KR260) — refused"
    return 1
  fi
  return 0
}

# ===========================================================================
# THE SEVEN CHECKS
# ===========================================================================

# STEP 1 -----------------------------------------------------------------
preamble_reader_selftest(){
  echo "[1] reader self-test — always-answering PS register"
  local v
  v="$(${PREAMBLE_RD_CMD:-_ip_no_reader} "$PRE_PS_ALIVE" 2>/dev/null)"
  v="${v//[[:space:]]/}"
  _ip_log "read PS-alive $PRE_PS_ALIVE -> '${v:-<empty>}'"
  if [ -z "$v" ]; then
    echo "PREAMBLE_FAIL: READER_DEAD"
    _ip_log "the reader returned NOTHING — host/ssh/tool path is broken (NOT the chip)."
    return 1
  fi
  if ! _ip_is_word "$v"; then
    echo "PREAMBLE_FAIL: READER_MALFORMED"
    _ip_log "reader returned a non-hex token '$v' — tool staged wrong / wrong transport."
    return 1
  fi
  _ip_log "PASS: reader path answers with a well-formed word ($(_ip_hex "$v"))."
  return 0
}

# STEP 2 -----------------------------------------------------------------
preamble_width_probe(){
  echo "[2] access-width probe — two adjacent, known-distinct words"
  local a b
  a="$(preamble_read "$PRE_WA")"; b="$(preamble_read "$PRE_WB")"
  _ip_log "read $PRE_WA expect $PRE_WA_E got '${a:-<empty>}'"
  _ip_log "read $PRE_WB expect $PRE_WB_E got '${b:-<empty>}'"
  if [ -z "$a" ] || [ -z "$b" ]; then
    echo "PREAMBLE_FAIL: WIDTH_PROBE_DEAD"; return 1; fi
  if [ "$(( a ))" -ne "$(( PRE_WA_E ))" ] || [ "$(( b ))" -ne "$(( PRE_WB_E ))" ]; then
    echo "PREAMBLE_FAIL: WIDTH_PROBE_MISMATCH"
    _ip_log "adjacent words did not read back their own distinct constants — a wide"
    _ip_log "PS master port (128-bit AFI) is smearing/dropping words (class D)."
    return 1
  fi
  # optional independent cross-check via a second reader (e.g. raw devmem)
  if [ -n "${PREAMBLE_DEVMEM_CMD:-}" ]; then
    local a2 b2; a2="$($PREAMBLE_DEVMEM_CMD "$PRE_WA" 2>/dev/null)"; b2="$($PREAMBLE_DEVMEM_CMD "$PRE_WB" 2>/dev/null)"
    _ip_log "devmem cross-check $PRE_WA='$a2' $PRE_WB='$b2'"
    if [ -n "$a2" ] && [ "$(( a2 ))" -ne "$(( a ))" ]; then
      echo "PREAMBLE_FAIL: WIDTH_PROBE_XCHECK"; return 1; fi
  else
    _ip_log "(no PREAMBLE_DEVMEM_CMD set — second-path cross-check skipped)"
  fi
  _ip_log "PASS: single-aligned-u32 semantics confirmed (distinct words distinct)."
  return 0
}

# STEP 3 -----------------------------------------------------------------
preamble_afi_check(){
  echo "[3] KR260 AFI PS-master-port width health"
  if [ "$PRE_IS_KR" != "1" ]; then
    _ip_log "SKIP: not KR260 (AFI afi_fs regs are ZynqMP-only)."
    return 0
  fi
  local cmd="${PREAMBLE_AFI_CMD:-}"
  if [ -z "$cmd" ]; then
    # default location relative to this library
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    cmd="$here/../../../pynq_host/scripts/kr260_afi.sh check"
  fi
  _ip_log "invoking AFI check: $cmd"
  if $cmd; then
    _ip_log "PASS: AFI ports 32-bit (kr260_afi.sh check rc=0)."
    return 0
  fi
  echo "PREAMBLE_FAIL: AFI_WIDTH"
  _ip_log "AFI mismatch — run 'kr260_afi.sh fix' (RMW [9:8]->00) before trusting APB."
  return 1
}

# STEP 4 -----------------------------------------------------------------
preamble_canaries(){
  echo "[4] control-plane canaries — hardwired constants"
  local v rc=0
  v="$(preamble_read "$PRE_CAN1_A")"; _ip_log "read $PRE_CAN1_A expect $PRE_CAN1_E got '${v:-<empty>}'"
  { [ -n "$v" ] && [ "$(( v ))" -eq "$(( PRE_CAN1_E ))" ]; } || rc=1
  v="$(preamble_read "$PRE_CAN2_A")"; _ip_log "read $PRE_CAN2_A expect $PRE_CAN2_E got '${v:-<empty>}'"
  { [ -n "$v" ] && [ "$(( v ))" -eq "$(( PRE_CAN2_E ))" ]; } || rc=1
  # negative control / anchor: INFO only (decodes regardless of AFI width).
  v="$(preamble_read "$PRE_CANN_A")"; _ip_log "anchor  $PRE_CANN_A expect $PRE_CANN_E got '${v:-<empty>}' (INFO only)"
  if [ "$rc" != 0 ]; then
    echo "PREAMBLE_FAIL: CANARY_MISMATCH"
    _ip_log "a hardwired control constant is wrong — control plane not decoding."
    return 1
  fi
  _ip_log "PASS: control-plane canaries match."
  return 0
}

# STEP 5 -----------------------------------------------------------------
preamble_rw_litmus(){
  echo "[5] RW-scratch write/readback litmus (+0x2160, per-nibble 0x7 mask)"
  if [ -z "${PREAMBLE_WR_CMD:-}" ]; then
    echo "PREAMBLE_FAIL: RW_NO_WRITER"
    _ip_log "no PREAMBLE_WR_CMD wired — cannot prove APB RW is live."
    return 1
  fi
  local orig r1 r2
  orig="$(preamble_read "$PRE_SCRATCH")"
  _ip_log "SAVE $PRE_SCRATCH = '${orig:-<empty>}' (will be restored exactly)"
  if [ -z "$orig" ]; then echo "PREAMBLE_FAIL: RW_READ_DEAD"; return 1; fi
  preamble_write "$PRE_SCRATCH" 0x55555555; r1="$(preamble_read "$PRE_SCRATCH")"
  _ip_log "wr 0x55555555 -> expect 0x55555555 got '${r1:-<empty>}'"
  preamble_write "$PRE_SCRATCH" 0xAAAAAAAA; r2="$(preamble_read "$PRE_SCRATCH")"
  _ip_log "wr 0xAAAAAAAA -> expect 0x22222222 got '${r2:-<empty>}' (0xA&0x7=0x2 per nibble)"
  # restore exactly as found, ALWAYS, before returning any verdict.
  preamble_write "$PRE_SCRATCH" "$orig"
  local back; back="$(preamble_read "$PRE_SCRATCH")"
  _ip_log "RESTORE $PRE_SCRATCH -> '${back:-<empty>}' (was '$orig')"
  if [ -z "$r1" ] || [ -z "$r2" ] || \
     [ "$(( r1 ))" -ne "$(( 0x55555555 ))" ] || [ "$(( r2 ))" -ne "$(( 0x22222222 ))" ]; then
    echo "PREAMBLE_FAIL: RW_LITMUS"
    _ip_log "APB RW is NOT live — a subsequent zero from a data reg is not a measurement."
    return 1
  fi
  if [ -n "$back" ] && [ "$(( back ))" -ne "$(( orig ))" ]; then
    echo "PREAMBLE_FAIL: RW_RESTORE"
    _ip_log "scratch was NOT restored to '$orig' — refusing to leave the reg perturbed."
    return 1
  fi
  _ip_log "PASS: APB RW live and scratch restored."
  return 0
}

# STEP 6 self-test -------------------------------------------------------
preamble_trust_selftest(){
  echo "[6] V2 retired-register trust guard"
  local off r bad=0
  for off in $PRE_RETIRED_OFFSETS; do
    if is_trustworthy_reg "$(_ip_hex "$(( PRE_BLOCK | (off & 0xFFFF) ))")" >/dev/null; then
      _ip_log "BUG: retired $off passed the trust guard"; bad=1
    else
      _ip_log "quarantined $off — OK"
    fi
  done
  # a genuine trust reg must pass
  if ! is_trustworthy_reg "$(_ip_hex "$(( PRE_BLOCK | 0x2140 ))")" >/dev/null; then
    _ip_log "BUG: 0x2140 EPOCH (a trust reg) was quarantined"; bad=1
  else
    _ip_log "0x2140 EPOCH trusted — OK"
  fi
  if [ "$bad" != 0 ]; then echo "PREAMBLE_FAIL: TRUST_GUARD"; return 1; fi
  _ip_log "PASS: retired regs quarantined, trust regs allowed."
  return 0
}

# STEP 7 self-test -------------------------------------------------------
preamble_wedge_selftest(){
  echo "[7] wedge-safety envelope"
  local off bad=0
  for off in $PRE_WEDGE_OFFSETS; do
    if preamble_addr_is_safe "$PRE_SOC" "$(_ip_hex "$(( PRE_BLOCK | (off & 0xFFFF) ))")" >/dev/null 2>&1; then
      _ip_log "BUG: stall offset $off deemed safe"; bad=1
    else
      _ip_log "stall $off refused — OK"
    fi
  done
  if [ "$PRE_SOC" = "kr260" ]; then
    if preamble_addr_is_safe kr260 0x44032140 >/dev/null 2>&1; then
      _ip_log "BUG: undecoded 0x4403_xxxx deemed safe on ZynqMP"; bad=1
    else
      _ip_log "0x4403_xxxx refused on ZynqMP — OK"
    fi
  fi
  # a normal reg must be allowed
  if ! preamble_addr_is_safe "$PRE_SOC" "$PRE_CAN1_A" >/dev/null 2>&1; then
    _ip_log "BUG: a normal canary reg was refused"; bad=1
  fi
  if [ "$bad" != 0 ]; then echo "PREAMBLE_FAIL: WEDGE_GUARD"; return 1; fi
  _ip_log "PASS: stall/undecoded addresses refused, normal regs allowed."
  return 0
}

# ===========================================================================
# preamble_run_all — run all seven in order, abort the RUN on first failure.
# ===========================================================================
preamble_run_all(){
  local soc="$1" host="$2" rd="${3:-}" wr="${4:-}"
  echo "=== instrument preamble (L1) — soc=$soc host=$host ==="
  preamble_config "$soc" "$host" "$rd" "$wr" || return $?
  local step
  for step in preamble_reader_selftest \
              preamble_width_probe \
              preamble_afi_check \
              preamble_canaries \
              preamble_rw_litmus \
              preamble_trust_selftest \
              preamble_wedge_selftest; do
    if ! "$step"; then
      echo "=== PREAMBLE ABORTED at $step — do NOT trust any DUT reading ==="
      return 1
    fi
  done
  echo "=== preamble PASS — the instrument is verified; DUT readings may be trusted ==="
  return 0
}
