# shellcheck shell=bash
# shellcheck disable=SC2034  # library: consumed by the sourcing scripts
# =============================================================================
# td_socmap.sh — shell twin of pynq_host/tl_socmap.py. Single source of truth
#                for SoC address relocation in the hw_regression suite.
#                SOURCED, never executed.
#
# WHY (hardware-safety, 2026-07-16): see the long rationale in
# pynq_host/tl_socmap.py. Short version: the KR260 control plane lives at
# 0x8403_xxxx, not the Z2 0x4403_xxxx. An unrelocated Z2 control literal on a
# KR260 is an UNDECODED AXI access with NO timeout -> hard PS hang, power-cycle
# to recover. `TIDELINK_TX_BASE`/`TIDELINK_RXFIFO_BASE` move ONLY the data
# plane and are therefore NOT sufficient on their own — `TIDELINK_SOC` is the
# authoritative switch.
#
# Z2 IS BYTE-IDENTICAL BY CONSTRUCTION: on z2 (default) td_remap is `echo $1`,
# a literal identity — no table, no validation. Selecting the default cannot
# change a Z2 address.
#
# API:
#   td_soc                  -> echoes "z2" | "kr260"; exits 1 on a bad value
#   td_remap 0x44032100     -> relocated address (identity on z2)
#   td_soc_banner           -> one-line summary for logs
#   td_reconcile VAR_A VAR_B DESC -> loud-fatal on two-vocabulary mismatch
# =============================================================================

# ----- aperture table: name  z2_base  kr260_base  size ----------------------
# Sizes are the KR260_PORT.md aperture sizes. ahb_sub is 64 MB so it spans
# 0x4000_0000..0x43FF_FFFF and does NOT swallow the 0x4403_xxxx APB aperture:
# no address matches two rows.
_TD_APERTURES=(
  "ahb_sub           0x40000000 0x80000000 0x04000000"
  "ahb_tx_legacy     0x44000000 0xA4000000 0x00010000"
  "ahb_fifo_legacy   0x44010000 0xA4010000 0x00010000"
  "ahb_ptp           0x44020000 0x84020000 0x00001000"
  "apb               0x44030000 0x84030000 0x00008000"
  "strap_gpio        0x44040000 0x84040000 0x00001000"
  "debug_unlock_gpio 0x44041000 0x84041000 0x00001000"
  "phc_apb           0x44050000 0x84050000 0x00001000"
  "ahb_tx            0x84000000 0xA4000000 0x00010000"
  "ahb_fifo          0x84010000 0xA4010000 0x00010000"
)

_TD_KR260_ALIASES=" kr260 kria mpsoc zynqmp kv260 "
_TD_Z2_ALIASES=" z2 pynq-z2 pynq_z2 zynq7 zynq "

# td_die — print a loud, unmissable fatal and stop. Never returns.
td_die() {
  printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
  printf '!! TIDELINK ADDRESS-MAP CONFIG ERROR — REFUSING TO TOUCH HARDWARE\n' >&2
  printf '!!\n' >&2
  while IFS= read -r _l; do printf '!! %s\n' "$_l" >&2; done <<< "$1"
  printf '!!\n' >&2
  printf '!! A wrong base address on ZynqMP is an UNRECOVERABLE bus hang.\n' >&2
  printf '!! Fix the config; do NOT let this fall back to a default map.\n' >&2
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n' >&2
  exit 1
}

# td_soc — resolve TIDELINK_SOC to a canonical name. Unset -> z2 (today's
# behaviour). Unrecognised -> loud fatal, NEVER a silent z2 fallback.
td_soc() {
  local v
  v=$(printf '%s' "${TIDELINK_SOC:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  if [ -z "$v" ]; then echo "z2"; return 0; fi
  case "$_TD_KR260_ALIASES" in *" $v "*) echo "kr260"; return 0;; esac
  case "$_TD_Z2_ALIASES"    in *" $v "*) echo "z2";    return 0;; esac
  td_die "TIDELINK_SOC='${TIDELINK_SOC}' is not a recognised SoC.
  KR260 aliases:$_TD_KR260_ALIASES
  Z2 aliases   :$_TD_Z2_ALIASES
Refusing to guess an address map."
}

# td_remap ADDR [WHAT] — relocate a Z2 literal onto the selected SoC.
# On z2: pure identity (no table lookup, no validation).
td_remap() {
  local addr_s="$1" what="${2:-address}" soc addr row name z2b socb size
  soc=$(td_soc) || exit 1
  if [ "$soc" = "z2" ]; then printf '%s' "$addr_s"; return 0; fi

  addr=$((addr_s))
  for row in "${_TD_APERTURES[@]}"; do
    # shellcheck disable=SC2086
    set -- $row; name=$1; z2b=$(($2)); socb=$(($3)); size=$(($4))
    if [ "$addr" -ge "$z2b" ] && [ "$addr" -lt $((z2b + size)) ]; then
      printf '0x%08X' $((socb + addr - z2b)); return 0
    fi
  done
  td_die "TIDELINK_SOC=$soc but $what $addr_s is not inside any known Z2
aperture, so it cannot be relocated. On the KR260 an unrelocated Z2
literal is UNDECODED -> AXI hang with no timeout."
}

td_soc_banner() { echo "TIDELINK_SOC=$(td_soc) (address map: $(td_remap 0x44030000 apb) apb base)"; }

# ---------------------------------------------------------------------------
# td_data_base VAR Z2_DEFAULT WHAT — resolve a data-plane base, honouring the
# legacy TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE overrides but CROSS-CHECKING
# them against TIDELINK_SOC. Shell twin of tl_socmap.py::_data_base.
#
# This closes the exact trap KR260_PORT.md used to set: exporting
# TIDELINK_TX_BASE=0xA4000000 with TIDELINK_SOC unset would sail a KR260 data
# address straight through the z2 identity path and into an undecoded poke.
# Now it aborts.
# ---------------------------------------------------------------------------
td_data_base() {
  local var="$1" z2def="$2" what="$3" expected raw
  expected=$(td_remap "$z2def" "$what") || exit 1
  raw=${!var:-}
  if [ -z "$raw" ]; then printf '%s' "$expected"; return 0; fi
  if [ $((raw)) -ne $((expected)) ] 2>/dev/null; then
    td_die "$var='$raw' contradicts TIDELINK_SOC=$(td_soc), which puts $what at
$expected.
Refusing to run half-configured. $var moves ONLY the data plane; the
control plane is resolved from TIDELINK_SOC. Mixing them is how an
operator ends up poking Z2 control addresses on a KR260.
Fix: unset $var and let TIDELINK_SOC drive the whole map."
  fi
  printf '%s' "$raw"
}

# ---------------------------------------------------------------------------
# td_reconcile PRIMARY_VAR ALIAS_VAR DESC — reconcile two env vocabularies for
# one concept (TD_A_IP vs TD_MASTER_IP etc).
#
# Echoes the agreed value. Rules:
#   neither set -> echo nothing (caller applies its own default)
#   one set      -> that value
#   both set, equal    -> that value
#   both set, DIFFERENT -> loud fatal. Two vocabularies naming one board that
#                          disagree means half the tooling is pointed at other
#                          hardware; a silent pick would drive the wrong board.
# ---------------------------------------------------------------------------
td_reconcile() {
  local pvar="$1" avar="$2" desc="$3" pval avval
  pval=${!pvar:-}; avval=${!avar:-}
  if [ -n "$pval" ] && [ -n "$avval" ] && [ "$pval" != "$avval" ]; then
    td_die "$pvar='$pval' and $avar='$avval' disagree ($desc).
These are two vocabularies for ONE piece of hardware. Set ONE, or set
both to the same value. Guessing would silently drive the wrong board."
  fi
  [ -n "$pval" ] && { printf '%s' "$pval"; return 0; }
  [ -n "$avval" ] && { printf '%s' "$avval"; return 0; }
  return 0
}
