#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# test_site_check.sh — unit tests for scripts/ci/site_check.sh
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# WHY THIS EXISTS
#
# A guard that cannot go red is worse than no guard: it reports "clean"
# forever and everyone believes it. The first draft of site_check.sh read
#
#     TL39=${TD_TL39:-/home/xilinx/tl39.py}
#
# as CLEAN, because its leading-context class excluded `-`. It passed the
# whole repository on that draft. Case 2 below is that exact line, and it is
# the reason this file exists: every rule is proved to FIRE on a seeded
# violation before the all-clear on the real tree is believed.
#
#   ./scripts/ci/tests/test_site_check.sh
#
# Exit 0 if every case behaves, 1 otherwise.
#-----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../site_check.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# expect <wanted-rc> <name> -- <args...>
expect() {
    local want="$1" name="$2"; shift 3
    local out rc
    out="$("$CHECK" "$@" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then ok "$name (rc=$rc)"
    else
        bad "$name — wanted rc=$want, got rc=$rc"
        printf '%s\n' "$out" | sed 's/^/          | /'
    fi
}

cd "$TMP" || exit 2
EMPTY_AL="$TMP/empty_allowlist.txt"; : > "$EMPTY_AL"

echo "site_check.sh unit tests"
echo ""
echo "-- every rule must FIRE on a seeded violation --"

# 1. a tool install path
printf 'VERDI_HOME ?= /eda/synopsys/2022-23/RHELx86/VERDI_2022.06-SP2\n' > case1_Makefile
expect 1 "site-path: an EDA install path is caught" -- --allowlist "$EMPTY_AL" case1_Makefile

# 2. THE REGRESSION: a site path behind the shell default idiom `${VAR:-...}`.
printf 'TL39=${TD_TL39:-/home/dam1n19/SoCLabs/tidelink/tl39.py}\n' > case2.sh
expect 1 "site-path: \${VAR:-/home/...} is caught (the draft-1 miss)" -- --allowlist "$EMPTY_AL" case2.sh

# 3. a vendor IP mount
printf 'export PHYS_IP_PATH ?= /research/AAA/phys_ip_library/arm/tsmc/cln65lp\n' > case3_Makefile
expect 1 "site-path: a /research/ vendor IP mount is caught" -- --allowlist "$EMPTY_AL" case3_Makefile

# 4. a revision-coded vendor drop name, with NO absolute path anywhere on the
#    line — the class the path rule alone cannot see.
printf 'export CMSDK_DIR ?= $(ARM_IP_LIBRARY_PATH)/Corstone-101/BP210-BU-00000-r1p1-00rel0\n' > case4_Makefile
expect 1 "vendor-drop: a release-coded Arm drop name is caught" -- --allowlist "$EMPTY_AL" case4_Makefile

# 5. a Vivado install path
printf 'XILINX_VIVADO ?= /apps/Xilinx/Vivado/2024.1\n' > case5_Makefile
expect 1 "site-path: an /apps/ install path is caught" -- --allowlist "$EMPTY_AL" case5_Makefile

echo ""
echo "-- clean input must stay GREEN (no false red) --"

# 6. the fixed forms of all of the above
cat > case6_Makefile <<'EOF'
SITE_VARS_REQUIRED += CMSDK_DIR
include $(TIDELINK_HOME)/mk/site.mk
gui:
	@$(SITE_REQUIRE) VERDI_HOME "the Verdi install root"
EOF
expect 0 "clean: the post-fix Makefile form passes" -- --allowlist "$EMPTY_AL" case6_Makefile

# 7. a relative path that merely CONTAINS one of the root words
printf 'SRC = $(TIDELINK_HOME)/src/home/thing.sv\nD = deps/apps/x\n' > case7_Makefile
expect 0 "clean: a relative path containing 'home'/'apps' is not a hit" -- --allowlist "$EMPTY_AL" case7_Makefile

echo ""
echo "-- the allow-list must work, and must be honest --"

# 8. an exemption with a reason suppresses its own violation
printf 'PYNQ_DEST ?= /home/xilinx/tidelink_overlay\n' > case8_Makefile
printf 'case8_Makefile\t/home/xilinx/tidelink_overlay\tBoard-side deploy directory.\n' > al8.txt
expect 0 "allow-list: a documented exemption suppresses its violation" -- --allowlist al8.txt case8_Makefile

# 9. ... but only for the file it names
printf 'PYNQ_DEST ?= /home/xilinx/tidelink_overlay\n' > case9_Makefile
expect 1 "allow-list: an exemption does NOT leak to another file" -- --allowlist al8.txt case9_Makefile

# 10. an exemption with no reason is refused outright (rc=2, checker error)
printf 'case10_Makefile\t/home/xilinx\n' > al10.txt
printf 'X = /home/xilinx/y\n' > case10_Makefile
expect 2 "allow-list: an entry with no stated reason is refused" -- --allowlist al10.txt case10_Makefile

echo ""
echo "-- the checker must fail LOUDLY rather than pass vacuously --"

# 11. an unreadable allow-list path is not silently "no exemptions"... it is:
#     a missing file legitimately means no exemptions, so this must PASS on
#     clean input. Asserted so the behaviour is a decision, not an accident.
expect 0 "scope: a missing allow-list means no exemptions, not an error" -- --allowlist "$TMP/nope.txt" case6_Makefile

# 12. An empty scope must NOT report success. site_check.sh always scans the
#     repository it LIVES in (REPO_ROOT is derived from $BASH_SOURCE), so the
#     way to reach the empty-scope branch is to run a copy of it from a tree
#     that is not a git checkout — which is also the real-world shape of the
#     failure: the scanner shipped somewhere `git ls-files` returns nothing,
#     reporting "clean" over zero files forever.
mkdir -p "$TMP/fakerepo/scripts/ci"
cp "$CHECK" "$TMP/fakerepo/scripts/ci/site_check.sh"
out="$("$TMP/fakerepo/scripts/ci/site_check.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    ok "scope: a non-checkout (empty scope) exits 2, never a vacuous PASS"
else
    bad "scope: a non-checkout did NOT exit 2 — got rc=$rc"
    printf '%s\n' "$out" | sed 's/^/          | /'
fi

echo ""
echo "-- and the real tree must be green --"
expect 0 "repository: the tracked build layer is clean" --

echo ""
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
