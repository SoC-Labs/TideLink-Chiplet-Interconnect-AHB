#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# site_check.sh — refuse to let an absolute site path or a revision-coded
#                 vendor release name back into a tracked build file.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# WHAT IT ENFORCES
#
# site.env.example names two disclosure classes that must not appear in any
# tracked file. This is the guard for both, over the build layer:
#
#   RULE site-path     an absolute path under the `research`, `eda`, `apps`
#                      or `home` roots. It publishes one institution's
#                      filesystem layout, and it resolves on exactly one
#                      machine.
#
#   RULE vendor-drop   a revision-suffixed vendor package name (an Arm drop
#                      code such as <PKG>-BU-<NNNNN>-r<N>p<N>-<NN>rel<N>). A library
#                      FAMILY name is public; a release-coded drop name is an
#                      inventory of what this site is licensed for.
#
# Both classes previously hid behind a `?=` default that RESOLVED on the lab
# host, so the "no default site path" policy looked enforced while ~80 bench
# Makefiles quietly depended on one mount. Grep for the value, not for the
# policy: that is what this script does.
#
# SCOPE: tracked build files — Makefile, *.mk, *.sh, *.bash, *.csh, *.tcl,
# *.py, *.pl. Documentation and the YAML build/bug registries are NOT scanned:
# a registry entry recording where a bitstream physically lived is a historical
# fact about a past run, not a setting anything resolves today. See
# docs/CLEANUP_PLAN_2026-09.md for that decision.
#
# ALLOW-LIST: scripts/ci/site_allowlist.txt. Three TAB-separated fields —
# path, regex, reason — and the reason is MANDATORY: an undocumented
# exemption is refused, and so is one that no longer matches anything.
#
# USAGE
#   site_check.sh                     scan every tracked build file
#   site_check.sh FILE...             scan only these files (used by the tests)
#   site_check.sh --allowlist FILE    use a different allow-list
#   site_check.sh --list-scope        print the files that would be scanned
#
# EXIT: 0 clean, 1 violations found, 2 the checker itself could not run.
#-----------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/site_allowlist.txt"
LIST_SCOPE=0
declare -a EXPLICIT=()

while [ $# -gt 0 ]; do
    case "$1" in
        --allowlist) ALLOWLIST="${2:?--allowlist needs a path}"; shift 2 ;;
        --list-scope) LIST_SCOPE=1; shift ;;
        -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do EXPLICIT+=("$1"); shift; done ;;
        -*) echo "site_check.sh: unknown option $1" >&2; exit 2 ;;
        *)  EXPLICIT+=("$1"); shift ;;
    esac
done

# ── Scope ───────────────────────────────────────────────────────────────────
declare -a FILES=()
if [ ${#EXPLICIT[@]} -gt 0 ]; then
    FILES=("${EXPLICIT[@]}")
else
    cd "$REPO_ROOT" || exit 2
    while IFS= read -r f; do FILES+=("$f"); done < <(
        git ls-files -z 2>/dev/null | tr '\0' '\n' |
        grep -E '(^|/)(Makefile|GNUmakefile)$|\.(mk|make|sh|bash|csh|tcl|py|pl)$'
    )
    # A scope that silently came back empty would report "clean" forever.
    if [ ${#FILES[@]} -eq 0 ]; then
        echo "ERROR: site-check found no files to scan — is this a git checkout?" >&2
        exit 2
    fi
fi

if [ "$LIST_SCOPE" -eq 1 ]; then printf '%s\n' "${FILES[@]}"; exit 0; fi

# ── Rules ───────────────────────────────────────────────────────────────────
# The leading context excludes only alphanumerics and `_`, so that a path
# reached through a relative segment (`src/home/…`) is not a hit while the
# shell default idiom `${VAR:-<absolute path>}` IS one — `-` and `.` must
# stay INSIDE the allowed context. Getting this wrong is how the first
# draft of this checker read a board path behind `:-` as clean.
RE_SITE_PATH='(^|[^A-Za-z0-9_])/(research|eda|apps|home)/'
# An Arm-style drop code: <PKG>-r<N>p<N>-<NN>rel<N>, or the BU part number form.
RE_VENDOR_DROP='[A-Z]{2,}[0-9]{2,}[A-Za-z0-9-]*-r[0-9]+p[0-9]+-[0-9]+rel[0-9]+'

# ── Allow-list ──────────────────────────────────────────────────────────────
declare -a AL_PATH=() AL_RE=() AL_WHY=()
declare -a AL_HITS=()
if [ -f "$ALLOWLIST" ]; then
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno+1))
        case "$line" in ''|'#'*) continue ;; esac
        IFS=$'\t' read -r p r why <<< "$line"
        if [ -z "${p:-}" ] || [ -z "${r:-}" ] || [ -z "${why:-}" ]; then
            echo "ERROR: $ALLOWLIST:$lineno — needs three TAB-separated fields:" >&2
            echo "       <path>  <regex>  <reason>. An exemption with no stated" >&2
            echo "       reason is refused; write down why this one is legitimate." >&2
            exit 2
        fi
        AL_PATH+=("$p"); AL_RE+=("$r"); AL_WHY+=("$why"); AL_HITS+=(0)
    done < "$ALLOWLIST"
fi

allowed() {   # allowed <file> <line-text>  -> 0 if an entry covers it
    local f="$1" txt="$2" i
    for i in "${!AL_PATH[@]}"; do
        [ "${AL_PATH[$i]}" = "$f" ] || continue
        if printf '%s' "$txt" | grep -Eq -- "${AL_RE[$i]}"; then
            AL_HITS[$i]=$(( ${AL_HITS[$i]} + 1 )); return 0
        fi
    done
    return 1
}

# ── Scan ────────────────────────────────────────────────────────────────────
violations=0
for f in "${FILES[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
        n="${hit%%:*}"; txt="${hit#*:}"
        rule=site-path
        printf '%s' "$txt" | grep -Eq -- "$RE_SITE_PATH" || rule=vendor-drop
        allowed "$f" "$txt" && continue
        if [ "$violations" -eq 0 ]; then
            echo "site-check: FAIL — tracked build files carry site-specific values."
            echo ""
        fi
        violations=$((violations+1))
        printf '  %s:%s  [%s]\n' "$f" "$n" "$rule"
        printf '      %s\n' "$(printf '%s' "$txt" | sed 's/^[[:space:]]*//' | cut -c1-120)"
    done < <(grep -nE -- "$RE_SITE_PATH|$RE_VENDOR_DROP" "$f" 2>/dev/null)
done

# ── Stale allow-list entries ────────────────────────────────────────────────
# An exemption that no longer matches anything is an exemption nobody is
# reviewing. Only meaningful over the FULL scope: a targeted scan legitimately
# touches none of them.
stale=0
if [ ${#EXPLICIT[@]} -eq 0 ]; then
    for i in "${!AL_PATH[@]}"; do
        if [ "${AL_HITS[$i]}" -eq 0 ]; then
            [ "$stale" -eq 0 ] && { echo ""; echo "site-check: STALE allow-list entries (matched nothing):"; }
            stale=$((stale+1))
            printf '  %s:%d  %s\t%s\n' "$ALLOWLIST" $((i+1)) "${AL_PATH[$i]}" "${AL_RE[$i]}"
        fi
    done
fi

if [ "$violations" -gt 0 ] || [ "$stale" -gt 0 ]; then
    echo ""
    echo "  $violations violation(s), $stale stale allow-list entry/entries."
    echo ""
    echo "  A site path or a vendor drop code in a tracked file resolves on one"
    echo "  machine and publishes this site's layout or licence inventory. Move"
    echo "  the value to site.env (see site.env.example), read it from the"
    echo "  environment, and let it FAIL NAMED when unset — mk/site.mk"
    echo "  (SITE_VARS_REQUIRED / \$(SITE_REQUIRE)) does that for Makefiles,"
    echo "  \${VAR:?message} for shell."
    echo ""
    echo "  If a hit is legitimate — a path on a TARGET BOARD, say — add it to"
    echo "  $ALLOWLIST with a reason."
    exit 1
fi

echo "site-check: PASS — ${#FILES[@]} tracked build files, no site paths, no vendor drop codes."
exit 0
