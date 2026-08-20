#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# verify_fix_delivery.sh — does this gate netlist actually CONTAIN the fixes
# we think we shipped?
#
# WHY THIS EXISTS
# ---------------
# In August 2026 a week of TideLink fixes were landed on main, sim-proven,
# mutation-tested and confirmed on real KR260 silicon — and were then believed
# to be "shipped". They were not. "Landed in git" and "delivered into the
# synthesized netlist" are two DIFFERENT facts, and nothing in the flow checked
# the second one. A live GDS run was sitting on a tidelink pin (e6aaa82f) that
# was DIVERGENT from main and carried none of them. The gap was invisible
# because nobody ever asked the netlist.
#
# So: ask the netlist. That is all this script does.
#
# WHY IT IS NOT JUST `grep`
# -------------------------
# A naive grep over a gate netlist produces CONFIDENT FALSE NEGATIVES, and the
# investigation that prompted this script hit exactly that trap. Two reasons:
#
#   1. SYNTHESIS DELETES COMBINATIONAL NAMES. A `wire` has no gate to carry its
#      name, so it is collapsed into the cone around it and vanishes. Measured
#      on the real bscan-probe netlist: 12 of 12 arbitrary `wire` names taken
#      from tidelink_top.sv scored ZERO — while 6 of 7 arbitrary flop names
#      from the same file scored non-zero. A zero for a `wire` therefore means
#      NOTHING AT ALL. Three of the fix markers people were grepping for
#      (terminal_timeout, read_would_overmint, wr_hold_drain_release) are pure
#      wires, so they can never be found this way, in ANY netlist, fix present
#      or absent. This script refuses to score them rather than calling them
#      missing.
#
#   2. A ZERO WITH NO CONTROL IS UNINTERPRETABLE. If the path is wrong, the
#      file is a stub/symlink, the hierarchy was renamed, or the grep is
#      malformed, EVERY signature reads zero and the result looks like a
#      dramatic finding. So this script runs known-present controls first and
#      HARD-ERRORS if they come back zero: that means the search method is
#      broken, not that the netlist is empty.
#
# Only flops (survive as `<name>_reg`, possibly with a flattened hierarchy
# prefix) and module ports (survive as `.<name>` / `<name>`) are legitimately
# searchable. Everything else needs LEC (Conformal/Formality) against the RTL,
# which is the real answer to "is this logic in there" — this script is the
# cheap 2-second screen that catches the gross case.
#
# USAGE
#   verify_fix_delivery.sh <path-to-gate-netlist.v> [--list] [--quiet]
#   verify_fix_delivery.sh <netlist> --expect name:kind[:label] [--expect ...]
#
#   --list     print the built-in manifest and exit
#   --quiet    table only, no explanatory prose
#   --expect   add a signature; kind is one of:
#                flop  - a register; searchable, scored
#                port  - a module port; searchable, scored
#                comb  - a wire/combinational net; NOT searchable, reported
#                        as UNSEARCHABLE and excluded from pass/fail
#   --control  add a must-be-present control signal (kind is implied flop/port)
#
# EXIT CODES
#   0  every searchable expected signature was found
#   1  at least one searchable expected signature is MISSING (real gap)
#   2  a control returned zero -> SEARCH METHOD BROKEN, result untrustworthy
#   3  usage / unreadable netlist
#
# Read-only. Never writes to the build tree. Safe to run against a live run's
# outputs/ directory.
#-----------------------------------------------------------------------------

set -u
set -o pipefail

PROG="$(basename "$0")"

#-----------------------------------------------------------------------------
# Built-in manifest: name:kind:label
#
# kind=flop/port -> scored.  kind=comb -> reported UNSEARCHABLE, never scored.
#
# Provenance for the comb classifications (all measured, not assumed):
#   terminal_timeout      tidelink_top.sv          -- introduced by 2b84732f
#                         (TL-037); the commit's ONLY new flop is
#                         sub_mst_dphase_r, which is why that is the TL-037
#                         marker here and terminal_timeout is not.
#   read_would_overmint   tidelink_fifo_ctrl.sv:227 `wire read_would_overmint =`
#                         introduced by b1c0eace (N3/Hazard-4), which adds NO
#                         flops at all -> N3 has no netlist-searchable marker.
#   wr_hold_drain_release tidelink_top.sv:1999 `wire wr_hold_drain_release =`
#                         introduced by 2413aa60 (Hazard-1/TL-043), which adds
#                         NO flops at all -> likewise unsearchable.
#-----------------------------------------------------------------------------
EXPECTED=(
  # --- TideLink-side fixes -------------------------------------------------
  "sub_mst_dphase_r:flop:TL-037 ahb_sub terminal-timeout dead gate (2b84732f)"
  "terminal_timeout:comb:TL-037 (wire - unsearchable, use sub_mst_dphase_r)"
  "read_would_overmint:comb:N3/Hazard-4 fifo read_ptr (b1c0eace, wire-only)"
  "wr_hold_drain_release:comb:Hazard-1/TL-043 drain release (2413aa60, wire-only)"
  "swi_auto_anchor_force_in:port:Hazard-3/N2 AUTO_ANCHOR idle-qualified force"
  "ahb_sub_w_beat_consumed_o:port:per-beat W-consumption strobe (burst fix)"

  # --- eth-chiplet-side peer-write burst-corruption fix + EWR guard --------
  "hwdata_hold_r:flop:burst fix - frozen payload at release edge (181632f)"
  "peer_wcon_r:flop:burst fix - consume-before-release (181632f)"
  "w_beat_consumed:flop:burst fix - W-beat consumption tracking"
  "ewr_reject_dph_r:flop:EWR guard - early-write reject data phase (0ec54af)"
  "ewr_err2_r:flop:EWR guard - two-cycle ERROR response (0ec54af)"
  "ewr_seen_sticky_r:obs:EWR guard - mark_debug-only sticky observability reg"
)

# Controls: MUST be present in any real eth-chiplet gate netlist, fix or no fix.
# These are long-standing flops/hierarchy, unrelated to the fixes under test.
CONTROLS=(
  "wr_hold_r:tidelink_top.sv flop, predates all fixes under test"
  "synth_b_pending:tidelink_top.sv flop, predates all fixes under test"
  "tidelink:TideLink hierarchy must appear in the chiplet netlist at all"
)

# Negative controls: names that MUST NOT be found. If one of these hits, the
# matcher is too loose (e.g. matching inside comments or unrelated tokens) and
# every positive result is suspect.
NEG_CONTROLS=(
  "zzz_not_a_real_signal_xyzzy"
)

QUIET=0
LIST_ONLY=0
NETLIST=""

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list)    LIST_ONLY=1; shift ;;
    --quiet)   QUIET=1; shift ;;
    --expect)  [ $# -ge 2 ] || usage; EXPECTED+=("$2"); shift 2 ;;
    --control) [ $# -ge 2 ] || usage; CONTROLS+=("$2"); shift 2 ;;
    -h|--help) usage ;;
    -*)        echo "$PROG: unknown option '$1'" >&2; usage ;;
    *)         NETLIST="$1"; shift ;;
  esac
done

if [ "$LIST_ONLY" = 1 ]; then
  echo "Expected signatures:"
  for e in "${EXPECTED[@]}"; do
    printf '  %-28s %-6s %s\n' "${e%%:*}" "$(echo "$e" | cut -d: -f2)" "$(echo "$e" | cut -d: -f3-)"
  done
  echo "Controls (must be non-zero):"
  for c in "${CONTROLS[@]}"; do printf '  %-28s %s\n' "${c%%:*}" "${c#*:}"; done
  exit 0
fi

[ -n "$NETLIST" ] || usage
if [ ! -r "$NETLIST" ]; then
  echo "$PROG: FATAL: cannot read netlist '$NETLIST'" >&2
  exit 3
fi

# Resolve symlinks: several build dirs symlink their netlist to another build's
# output, and reporting the link path as if it were an independent build is how
# "10 builds all missing the fix" becomes "6 builds, 4 of them the same file".
REAL="$(readlink -f "$NETLIST")"
SIZE="$(stat -Lc %s "$NETLIST" 2>/dev/null || echo '?')"
MTIME="$(stat -Lc %y "$NETLIST" 2>/dev/null || echo '?')"

# A stub/truncated netlist is a common false-zero source; catch it explicitly.
if [ "$SIZE" != '?' ] && [ "$SIZE" -lt 100000 ]; then
  echo "$PROG: FATAL: '$NETLIST' is only $SIZE bytes - not a real gate netlist" >&2
  echo "  (a dangling symlink or an aborted run; refusing to report zeros from it)" >&2
  exit 2
fi

# count <pattern> -> occurrence count, case-insensitive substring.
# Substring matching is deliberate: it already covers the mangled forms
# (<name>_reg, <name>_reg[3], flat_hier_prefix_<name>, .<name> port refs)
# without needing a variant list per signature.
count() { grep -oiF -- "$1" "$REAL" 2>/dev/null | wc -l; }

# forms <pattern> -> the distinct mangled identifiers the name appears inside
forms() {
  grep -oiE "[A-Za-z0-9_\\\\./]*$1[A-Za-z0-9_]*(\[[0-9]+\])?" "$REAL" 2>/dev/null \
    | sort -u | head -4 | tr '\n' ' '
}

echo "=============================================================================="
echo " verify_fix_delivery — is the fix in the NETLIST, not just in git?"
echo "=============================================================================="
echo " netlist : $NETLIST"
[ "$REAL" != "$NETLIST" ] && echo " resolves: $REAL   (SYMLINK - not an independent build)"
echo " size    : $SIZE bytes"
echo " mtime   : $MTIME"
GENUS_STAMP="$(head -3 "$REAL" 2>/dev/null | grep -i 'Generated on' | sed 's/^\/\/ *//')"
[ -n "$GENUS_STAMP" ] && echo " stamp   : $GENUS_STAMP"
echo

#-----------------------------------------------------------------------------
# Step 1: controls. If these fail nothing below can be trusted.
#-----------------------------------------------------------------------------
echo "--- CONTROLS (search method must find these) --------------------------------"
CTRL_BAD=0
for c in "${CONTROLS[@]}"; do
  n="${c%%:*}"; why="${c#*:}"
  hits="$(count "$n")"
  if [ "$hits" -eq 0 ]; then
    printf '  %-28s %8s  <== CONTROL FAILED\n' "$n" "$hits"
    CTRL_BAD=1
  else
    printf '  %-28s %8s  ok    (%s)\n' "$n" "$hits" "$why"
  fi
done
for n in "${NEG_CONTROLS[@]}"; do
  hits="$(count "$n")"
  if [ "$hits" -ne 0 ]; then
    printf '  %-28s %8s  <== NEGATIVE CONTROL HIT (matcher too loose)\n' "$n" "$hits"
    CTRL_BAD=1
  else
    printf '  %-28s %8s  ok    (negative control, correctly absent)\n' "$n" "$hits"
  fi
done
echo

if [ "$CTRL_BAD" -ne 0 ]; then
  echo "##############################################################################"
  echo "# SEARCH METHOD BROKEN — CANNOT TRUST THIS RESULT"
  echo "#"
  echo "# A control signal that must exist in any real eth-chiplet gate netlist came"
  echo "# back with zero hits (or a signal that cannot exist came back non-zero)."
  echo "# That means the search itself failed — wrong file, wrong hierarchy naming,"
  echo "# truncated netlist, or a broken matcher. It does NOT mean the fixes are"
  echo "# absent. Do not report an absence from this run."
  echo "##############################################################################"
  exit 2
fi

#-----------------------------------------------------------------------------
# Step 2: the expected signatures.
#-----------------------------------------------------------------------------
echo "--- EXPECTED FIX SIGNATURES -------------------------------------------------"
printf '  %-28s %-6s %8s  %s\n' "SIGNATURE" "KIND" "HITS" "VERDICT"
MISSING=0
UNSEARCHABLE=0
FOUND=0
for e in "${EXPECTED[@]}"; do
  n="$(echo "$e" | cut -d: -f1)"
  k="$(echo "$e" | cut -d: -f2)"
  label="$(echo "$e" | cut -d: -f3-)"
  hits="$(count "$n")"
  case "$k" in
    comb)
      UNSEARCHABLE=$((UNSEARCHABLE+1))
      printf '  %-28s %-6s %8s  UNSEARCHABLE (wire: synthesis deletes the name)\n' "$n" "$k" "$hits"
      ;;
    obs)
      # observability-only regs with no functional fanout are legitimately
      # swept by synthesis; absence is expected, not a delivery failure.
      if [ "$hits" -gt 0 ]; then
        FOUND=$((FOUND+1))
        printf '  %-28s %-6s %8s  PRESENT\n' "$n" "$k" "$hits"
      else
        printf '  %-28s %-6s %8s  SWEPT (obs-only reg, no fanout - expected)\n' "$n" "$k" "$hits"
      fi
      ;;
    *)
      if [ "$hits" -gt 0 ]; then
        FOUND=$((FOUND+1))
        printf '  %-28s %-6s %8s  PRESENT\n' "$n" "$k" "$hits"
      else
        MISSING=$((MISSING+1))
        printf '  %-28s %-6s %8s  *** MISSING ***\n' "$n" "$k" "$hits"
      fi
      ;;
  esac
  if [ "$QUIET" = 0 ] && [ "$hits" -gt 0 ]; then
    f="$(forms "$n")"
    [ -n "$f" ] && printf '  %-28s        forms: %s\n' "" "$f"
  fi
done
echo

#-----------------------------------------------------------------------------
# Step 3: verdict
#-----------------------------------------------------------------------------
echo "--- VERDICT -----------------------------------------------------------------"
printf '  searchable found : %s\n' "$FOUND"
printf '  searchable MISSING: %s\n' "$MISSING"
printf '  unsearchable (comb, not scored): %s\n' "$UNSEARCHABLE"
echo
if [ "$MISSING" -gt 0 ]; then
  echo "  RESULT: FAIL — $MISSING expected fix signature(s) are NOT in this netlist."
  echo "  This netlist does not carry the fixes. Landed-in-git != delivered-in-gates."
else
  echo "  RESULT: PASS — every searchable expected signature is present."
fi
if [ "$UNSEARCHABLE" -gt 0 ] && [ "$QUIET" = 0 ]; then
  echo
  echo "  NOTE: $UNSEARCHABLE signature(s) are pure combinational logic and CANNOT be"
  echo "  confirmed or denied by name in a gate netlist. A PASS here does not cover"
  echo "  them. To prove those, run LEC (Conformal/Formality) netlist-vs-RTL, or"
  echo "  check the source pin the build actually read (git SHA of the tidelink"
  echo "  submodule at synthesis time) — which is the cheaper and usually decisive"
  echo "  check, and is exactly what the 2026-08 miss came down to."
fi
echo "=============================================================================="

[ "$MISSING" -gt 0 ] && exit 1
exit 0
