# shellcheck shell=bash
# =============================================================================
# mock_reader.sh — a canned "fake board" transport for instrument_preamble.sh.
#
# Purpose: exercise the preamble with NO hardware — unit tests + future CI.
# Provides two functions matching the preamble's transport contract:
#     mock_rd <abs-addr>          -> echoes 0xXXXXXXXX
#     mock_wr <abs-addr> <value>  -> stores into the fake register file
# Wire them in with:
#     PREAMBLE_RD_CMD=mock_rd  PREAMBLE_WR_CMD=mock_wr  PREAMBLE_AFI_CMD=mock_afi
#
# The fake register file (MOCK_REG) is seeded per-SoC with the hardwired
# constants the preamble checks. Behaviour is perturbed by env FAULT knobs so a
# test can drive every FAIL mode:
#     MOCK_FAULT=reader_dead   -> PS-alive reg returns empty (host/ssh dead)
#     MOCK_FAULT=width         -> adjacent word smeared (128-bit AFI defect)
#     MOCK_FAULT=canary        -> a control canary reads wrong
#     MOCK_FAULT=rw_dead       -> scratch ignores writes (dead APB RW)
#     MOCK_FAULT=afi           -> mock_afi returns non-zero (AFI mismatch)
#     MOCK_FAULT=<empty>       -> healthy board (all pass)
# =============================================================================

declare -gA MOCK_REG

mock_seed(){ # $1 = soc
  MOCK_REG=()
  case "$1" in
    kr260|kria|zynqmp|kr)
      MOCK_REG[0xFF0A0060]=0x000012AB   # PS-alive (GPIO DATA_0_RO; live pin state)
      MOCK_REG[0x84030200]=0x00000088   # hardwired slave id / width word A
      MOCK_REG[0x84030204]=0x00000001   # role / width word B / canary1
      MOCK_REG[0x84030214]=0x0000E4E4   # LANEMASK POR / canary2
      MOCK_REG[0x84032160]=0x33333333   # RW scratch POR (R_LOCKTHR)
      MOCK_REG[0x84032140]=0x00000001   # EPOCH (trust reg — anchored,span=0)
      ;;
    z2|pynqz2|pynq_z2|zynq7|zynq7000|zynq)
      MOCK_REG[0xE000A068]=0x0000DEAD   # PS-alive (GPIO DATA_RO; live pin state)
      MOCK_REG[0x4403211C]=0x50410100   # PHY_ALIGN_ID / width word A / canary1
      MOCK_REG[0x44032190]=0x4F420100   # OBS_OBS_ID   / width word B / canary2
      MOCK_REG[0x44032014]=0x544C0100   # peripheral id / anchor
      MOCK_REG[0x44032160]=0x33333333   # RW scratch POR
      MOCK_REG[0x44032140]=0x00000001   # EPOCH (trust reg)
      ;;
  esac
}

_mock_key(){ printf '0x%08X' "$(( $1 ))"; }   # normalize addr to a table key

mock_rd(){ # $1 = abs addr
  local k; k="$(_mock_key "$1")"
  # reader_dead: the always-answering PS reg returns nothing (broken host path)
  if [ "${MOCK_FAULT:-}" = "reader_dead" ] && [ "$(( $1 ))" -eq "$(( ${PRE_PS_ALIVE:-0xFF0A0060} ))" ]; then
    echo ""; return 0
  fi
  # width: smear the adjacent width word B onto width word A's value
  if [ "${MOCK_FAULT:-}" = "width" ] && [ "$(( $1 ))" -eq "$(( ${PRE_WB:-0} ))" ]; then
    echo "${MOCK_REG[$(_mock_key "${PRE_WA}")]}"; return 0    # B reads A's word
  fi
  # canary: corrupt canary2 (LANEMASK / OBS id)
  if [ "${MOCK_FAULT:-}" = "canary" ] && [ "$(( $1 ))" -eq "$(( ${PRE_CAN2_A:-0} ))" ]; then
    echo "0xDEADBEEF"; return 0
  fi
  echo "${MOCK_REG[$k]:-0x00000000}"
}

mock_wr(){ # $1 = abs addr, $2 = value
  local k; k="$(_mock_key "$1")"
  # rw_dead: the scratch silently ignores writes (retired/dead RW bus)
  if [ "${MOCK_FAULT:-}" = "rw_dead" ] && [ "$(( $1 ))" -eq "$(( ${PRE_SCRATCH:-0} ))" ]; then
    return 0
  fi
  # model the +0x2160 scratch per-nibble 0x7 write mask; other regs store raw.
  if [ "$(( $1 ))" -eq "$(( ${PRE_SCRATCH:-0} ))" ]; then
    MOCK_REG[$k]="$(printf '0x%08X' "$(( $2 & 0x77777777 ))")"
  else
    MOCK_REG[$k]="$(printf '0x%08X' "$(( $2 ))")"
  fi
}

mock_afi(){ # stand-in for `kr260_afi.sh check`
  if [ "${MOCK_FAULT:-}" = "afi" ]; then
    echo "  [MISMATCH] HPM0_LPD (control) [9:8]=2 -> 128-bit (want 32-bit)"
    return 1
  fi
  echo "  AFI: PASS — both used PS master ports are 32-bit. (mock)"
  return 0
}
