#!/usr/bin/env bash
#
# setup_flist_merge_driver.sh — register the TideLink flist semantic merge driver
# in THIS clone's git config. Idempotent: safe to re-run any number of times.
#
# Why this script exists
# ----------------------
# `.gitattributes` (committed) says WHICH files use the driver. `merge.<name>.driver`
# (per-clone local config, never committed) says WHAT the driver is. Ship only the
# first half and the automation is documented but never invoked — the exact failure
# mode this repo has been bitten by before. This script is the second half.
#
# FAIL-SAFE, BY DESIGN: if `.gitattributes` is committed and the driver is NOT
# registered, Git falls back to the built-in text merge and the file simply
# CONFLICTS. A missing registration costs extra human work; it can never cause a bad
# auto-resolution. That is also why this script REFUSES to register a driver whose
# implementation is absent — a registered-but-missing driver adds a failing exec to
# every flist merge, which is noise without benefit.
#
# Scope note: `git config --local` writes the shared repo config
# ($GIT_COMMON_DIR/config), so ONE run covers every linked worktree of this repo.
#
# Usage:
#   bash scripts/setup_flist_merge_driver.sh              # register (idempotent)
#   bash scripts/setup_flist_merge_driver.sh --verify     # report only, change nothing
#   bash scripts/setup_flist_merge_driver.sh --unregister # remove the registration
#   bash scripts/setup_flist_merge_driver.sh --force      # register even if the
#                                                         # implementation is absent
#
# Env overrides:
#   FLIST_MERGE_DRIVER      path to the driver, repo-relative
#                           (default: scripts/flist_merge_driver.sh)
#   FLIST_MERGE_DRIVER_CMD  the whole command line, placeholders included
#                           (overrides FLIST_MERGE_DRIVER entirely)
#
# Exit codes: 0 ok / 1 refused or --verify failed / 2 cannot run (not a git
# worktree, git too old, bad usage).
#
# See docs/STAGE4_RESOLUTION_2026_08_10.md §6.

set -euo pipefail

MERGE_NAME="flist"
DRIVER_PATH="${FLIST_MERGE_DRIVER:-scripts/flist_merge_driver.sh}"
DRIVER_DESC="TideLink flist semantic merge"

# %O base, %A ours (ALSO the output file), %B theirs, %L conflict-marker size,
# %P the real pathname in the worktree. Git runs the driver with cwd = top of the
# working tree, so a repo-relative command is correct, including in linked worktrees.
# Do NOT use %S/%X/%Y — those need git >= 2.44 and this site runs 2.43.x.
DRIVER_CMD="${FLIST_MERGE_DRIVER_CMD:-${DRIVER_PATH} %O %A %B %L %P}"

MODE="register"
for arg in "$@"; do
  case "$arg" in
    --verify)     MODE="verify" ;;
    --unregister) MODE="unregister" ;;
    --force)      MODE="force" ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "setup_flist_merge_driver.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

die()  { echo "setup_flist_merge_driver.sh: $*" >&2; exit 2; }
warn() { echo "  ! $*" >&2; }
note() { echo "  - $*"; }

command -v git >/dev/null 2>&1 || die "git not found in PATH"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git worktree"
cd "$ROOT"

# %L / %P have been supported since git 2.5; refuse on anything older rather than
# registering a driver that would be handed empty placeholders.
GIT_VER="$(git --version | awk '{print $3}')"
GIT_MAJ="${GIT_VER%%.*}"
GIT_REST="${GIT_VER#*.}"
GIT_MIN="${GIT_REST%%.*}"
if [ "${GIT_MAJ:-0}" -lt 2 ] || { [ "${GIT_MAJ}" -eq 2 ] && [ "${GIT_MIN:-0}" -lt 5 ]; }; then
  die "git ${GIT_VER} is too old for the %L/%P driver placeholders (need >= 2.5)"
fi

echo "flist merge driver setup"
echo "  repo:   ${ROOT}"
echo "  git:    ${GIT_VER}"
echo "  driver: ${DRIVER_CMD}"

cur_driver="$(git config --local --get "merge.${MERGE_NAME}.driver" || true)"

# Does the implementation exist and look runnable?
driver_present=0
if [ -n "${FLIST_MERGE_DRIVER_CMD:-}" ]; then
  # Caller supplied a full command line; we can only check the first token.
  first_tok="${DRIVER_CMD%% *}"
  { [ -f "$first_tok" ] || command -v "$first_tok" >/dev/null 2>&1; } && driver_present=1
else
  [ -f "$DRIVER_PATH" ] && driver_present=1
fi

# Does .gitattributes actually route flists at this driver?
attr_ok=0
if [ -f .gitattributes ] && \
   [ "$(git check-attr merge -- flists/tidelink_fpga_v2.flist 2>/dev/null | sed 's/.*: //')" = "${MERGE_NAME}" ]; then
  attr_ok=1
fi

case "$MODE" in
  verify)
    rc=0
    if [ "$attr_ok" -eq 1 ]; then
      note ".gitattributes maps *.flist -> merge=${MERGE_NAME}   [OK]"
    else
      warn ".gitattributes does NOT map *.flist -> merge=${MERGE_NAME}"
      warn "  apply .gitattributes.flist-driver-snippet, then re-run"
      rc=1
    fi
    if [ "$driver_present" -eq 1 ]; then
      note "driver implementation present: ${DRIVER_PATH}   [OK]"
    else
      warn "driver implementation MISSING: ${ROOT}/${DRIVER_PATH}"
      rc=1
    fi
    if [ "$cur_driver" = "$DRIVER_CMD" ]; then
      note "merge.${MERGE_NAME}.driver registered   [OK]"
    elif [ -n "$cur_driver" ]; then
      warn "merge.${MERGE_NAME}.driver registered but DIFFERENT:"
      warn "    have: ${cur_driver}"
      warn "    want: ${DRIVER_CMD}"
      rc=1
    else
      warn "merge.${MERGE_NAME}.driver NOT registered in this clone"
      warn "  fix: bash scripts/setup_flist_merge_driver.sh"
      rc=1
    fi
    [ "$rc" -eq 0 ] && echo "  => wired end to end" \
                    || echo "  => NOT fully wired (see above). Merges of *.flist / *.f"
    [ "$rc" -eq 0 ] || echo "     fall back to the built-in text merge, which conflicts."
    exit "$rc"
    ;;

  unregister)
    git config --local --unset-all "merge.${MERGE_NAME}.driver"    2>/dev/null || true
    git config --local --unset-all "merge.${MERGE_NAME}.name"      2>/dev/null || true
    git config --local --unset-all "merge.${MERGE_NAME}.recursive" 2>/dev/null || true
    note "unregistered. *.flist / *.f now fall back to the built-in text merge,"
    note "which conflicts on any real difference — fail-safe, just noisier."
    exit 0
    ;;
esac

# ---- register / force -------------------------------------------------------
if [ "$driver_present" -eq 0 ]; then
  if [ "$MODE" != "force" ]; then
    warn "driver implementation not found: ${ROOT}/${DRIVER_PATH}"
    warn "REFUSING to register a driver that does not exist."
    warn "An unregistered driver is fail-safe (merges simply conflict);"
    warn "a registered-but-missing one adds a failing exec to every flist merge."
    warn "Land the driver first, or point at it:"
    warn "    FLIST_MERGE_DRIVER=scripts/my_driver.sh bash \$0"
    warn "Re-run with --force only if you know what you are doing."
    exit 1
  fi
  warn "--force: registering although ${DRIVER_PATH} is absent"
fi

changed=0
set_cfg() { # key value
  local have
  have="$(git config --local --get "$1" || true)"
  if [ "$have" = "$2" ]; then
    note "$1 already correct"
  else
    git config --local "$1" "$2"
    if [ -n "$have" ]; then note "$1 UPDATED"; else note "$1 SET"; fi
    changed=1
  fi
}

set_cfg "merge.${MERGE_NAME}.name"   "$DRIVER_DESC"
set_cfg "merge.${MERGE_NAME}.driver" "$DRIVER_CMD"
# `recursive text` makes git use the built-in merge for the VIRTUAL common ancestors
# of a criss-cross merge, so the driver only ever sees real file versions.
set_cfg "merge.${MERGE_NAME}.recursive" "text"

if [ "$changed" -eq 0 ]; then
  echo "  => already registered, nothing to do"
else
  echo "  => registered"
fi

if [ "$attr_ok" -eq 0 ]; then
  echo
  warn "NEXT STEP: .gitattributes does not yet route *.flist to this driver."
  warn "The registration above is inert until you apply the snippet:"
  warn "    sed -n '/^# TideLink flist semantic merge/,\$p' \\"
  warn "        .gitattributes.flist-driver-snippet >> .gitattributes"
  warn "    git check-attr merge -- flists/tidelink_fpga_v2.flist   # => merge: flist"
fi

exit 0
