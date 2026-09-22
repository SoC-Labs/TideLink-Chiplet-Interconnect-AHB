#!/usr/bin/env bash
# =============================================================================
# check-secrets.sh — publication guard for CREDENTIALS
# =============================================================================
#
# THIS REPOSITORY IS PUBLIC. `make vendor-check` already guards vendor and
# foundry collateral, but it is a vendor-collateral scanner: it looks for
# revision-coded release names, absolute site mounts and PDK values. It does NOT
# look for credentials, and on 2026-08-24 that gap was live — the board ssh
# password appeared as a hardcoded shell default in 13 scripts and a python
# default in one more, alongside the boards' reachable addresses and usernames,
# for a total of 24 occurrences across 20 files. Every one of them was published.
#
# So this is the second half of the same guard, kept deliberately separate and
# in-repo: the vendor scanner is maintained in the nanoSoC-ASIC-Toolkit and
# operates on a different question.
#
# WHAT IT SCANS: tracked files, plus untracked-but-not-ignored files — the
# second corpus being the one that matters, since it is what the next
# `git add -A` would publish.
#
# EVERY RULE IS ARMED FIRST. Before scanning the tree the script plants an
# invented specimen of each rule and requires it to fire. A guard that cannot be
# shown to detect anything is not a guard, and a scanner that silently stops
# matching is worse than none. Arming failures are fatal.
#
# NO EDA TOOL, NO LICENCE, NO NETWORK. Seconds on this tree.
#
#   scripts/ci/check-secrets.sh            scan (default)
#   scripts/ci/check-secrets.sh --arm-only just prove the rules fire
# =============================================================================
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || { echo "not a git repo" >&2; exit 2; }

ARM_ONLY=0
[ "${1:-}" = "--arm-only" ] && ARM_ONLY=1

# --- rules ------------------------------------------------------------------
# id | description | ERE. Each rule ships a specimen below with the SAME id.
RULES=(
"shell_default_pw|a shell parameter default supplying a literal password/secret|(PASS|PASSWD|PASSWORD|SECRET|TOKEN|APIKEY|API_KEY)[A-Z_]*:-[A-Za-z0-9_.@!%+-]*[A-Za-z][A-Za-z0-9_.@!%+-]*\}"
"py_default_pw|a python env-lookup defaulting to a literal password/secret|environ\\.get\\([\"'][A-Za-z_]*(PASS|PASSWD|PASSWORD|SECRET|TOKEN|API_?KEY)[A-Za-z_]*[\"'][[:space:]]*,[[:space:]]*[\"'][^\"']{4,}[\"']"
"assign_pw|a password/secret/token assigned a literal|(^|[^A-Za-z_])(password|passwd|secret|api_key|apikey|auth_token|access_token)[[:space:]]*[=:][[:space:]]*[\"'][^\"'{}$][^\"']{3,}[\"']"
"private_key|an embedded private key block|BEGIN[[:space:]](RSA|DSA|EC|OPENSSH|PGP)[[:space:]]PRIVATE[[:space:]]KEY"
"url_cred|credentials embedded in a URL|[a-zA-Z][a-zA-Z0-9+.-]*://[^/[:space:]:$]+:[^/[:space:]@$\{]+@"
)

# --- allowlist ---------------------------------------------------------------
# Each entry is "<path-glob>|<rule-id>|<reason>". Keep it short and keep the
# reason honest — an allowlist entry is a claim somebody will trust.
ALLOW=(
"scripts/ci/check-secrets.sh|*|THIS FILE IS THE DETECTOR. It carries the rule table and the invented specimens, so it matches itself by construction."
"pynq_host/scripts/eye_toolkit/*|assign_pw|python keyword arguments and dataclass fields named password/token, assigned from variables, not literals — the rule's literal-only guard already excludes these, listed so a future loosening of the rule is a decision"
"pynq_host/throughput_gui/static/vendor/*|*|vendored third-party browser libraries, minified. Not our source and not our credentials; a minified bundle matches almost any content rule by accident."
)

# ── CONTENT exceptions, NOT path exceptions ─────────────────────────────────
# "<rule-id>|<ERE matched against the FINDING LINE>|<reason>". A path allowlist
# would blanket-waive a whole directory; pynq_host/scripts/ is precisely where
# the 2026-08-24 KR260 leak lived, so waiving it wholesale would disarm the guard
# over the one tree that has already failed. These except one exact string and
# nothing else: any OTHER credential default, in these same files, still fires.
EXCEPT=(
"shell_default_pw|TIDELINK_BOARD_PASS:-xilinx\\}|factory-default board password — see the note below"
"py_default_pw|[\"']TIDELINK_BOARD_PASS[\"'][[:space:]]*,[[:space:]]*[\"']xilinx[\"']|factory-default board password — see the note below"
)

excepted() { # $1=ruleid $2=finding line text
    local e r re
    for e in "${EXCEPT[@]}"; do
        r="${e%%|*}"; re="${e#*|}"; re="${re%%|*}"
        [ "$r" = "$1" ] || continue
        printf '%s\n' "$2" | grep -qE "$re" && return 0
    done
    return 1
}

# ── ON `TIDELINK_BOARD_PASS:-xilinx` (13 shell + 2 python sites) ─────────────
# ACCEPTED, DELIBERATELY, and the reason matters because the identical shape was
# a genuine leak elsewhere in this same tree.
#
# `xilinx` is the FACTORY DEFAULT account password shipped on every PYNQ/Xilinx
# board image. It is printed in Xilinx's own documentation and in this repo's
# docs_site/boards.md. Publishing it discloses nothing that is not already
# universal knowledge, and the boards it applies to are the Z2 bench units on an
# RFC1918 lab network.
#
# THE CONTRAST IS THE POINT. The KR260 password removed on 2026-08-24 was a
# SITE-CHOSEN secret for named, reachable hosts. A factory default and a chosen
# secret have the same syntax and are not the same finding, and a scanner that
# cannot tell them apart teaches people to ignore it.
#
# WHAT WOULD CHANGE THIS: if the boards are ever moved off the factory password,
# these defaults become stale AND wrong, and both allowlist lines above must go.
# The rule stays armed either way, so removing the line is all it takes.

allowed() { # $1=path $2=ruleid
    local e g r
    for e in "${ALLOW[@]}"; do
        g="${e%%|*}"; r="${e#*|}"; r="${r%%|*}"
        # shellcheck disable=SC2053
        if [[ "$1" == $g ]] && { [ "$r" = "*" ] || [ "$r" = "$2" ]; }; then return 0; fi
    done
    return 1
}

# --- arming ------------------------------------------------------------------
# Invented specimens. None of these is, or ever was, a real credential.
declare -A SPECIMEN=(
  [shell_default_pw]='PW="${BOARD_PASSWORD:-hunter2placeholder}"'
  [py_default_pw]='PW = os.environ.get("BOARD_PASSWORD", "hunter2placeholder")'
  [assign_pw]='password = "hunter2placeholder"'
  [private_key]='-----BEGIN RSA PRIVATE KEY-----'
  [url_cred]='https://someuser:hunter2placeholder@example.invalid/repo.git'
)

# Lookalikes that MUST NOT fire. Every one of these was a real false positive
# this scanner produced on its first run over this tree; they are kept as
# specimens so a future loosening of a rule is caught here and not by a reviewer
# learning to ignore the output.
declare -A ANTISPECIMEN=(
  [shell_default_pw]='YIELD_PASS="${YIELD_PASS:-1.00}"   # a pass/fail threshold, not a password'
  [py_default_pw]='n = os.environ.get("RETRY_PASSES", "3")'
  [assign_pw]='def fake_write(ip, addr, val, password=None):'
  [private_key]='# regenerate the host key with ssh-keygen before first boot'
  [url_cred]='WIKI_PUSH_URL="https://gitlab-ci-token:${CI_JOB_TOKEN}@${CI_SERVER_HOST}/x.wiki.git"'
)

echo "== arming — every rule must fire on an invented specimen, and stay quiet on its lookalike =="
arm_fail=0
for rule in "${RULES[@]}"; do
    id="${rule%%|*}"; rest="${rule#*|}"; desc="${rest%%|*}"; re="${rest#*|}"
    if ! printf '%s\n' "${SPECIMEN[$id]}" | grep -qE "$re"; then
        printf '  FAIL %-18s DOES NOT FIRE on its own specimen — rule is dead\n' "$id"
        arm_fail=$((arm_fail+1))
    elif printf '%s\n' "${ANTISPECIMEN[$id]}" | grep -qE "$re"; then
        printf '  FAIL %-18s FIRES on its lookalike — rule is too broad\n' "$id"
        arm_fail=$((arm_fail+1))
    else
        printf '  ok   %-18s %s\n' "$id" "$desc"
    fi
done
if [ "$arm_fail" -ne 0 ]; then
    echo ""
    echo "ARMING FAILED for $arm_fail rule(s). Refusing to report a pass that was not measured."
    exit 2
fi
[ "$ARM_ONLY" -eq 1 ] && { echo ""; echo "arm-only: $((${#RULES[@]})) rule(s) armed."; exit 0; }

# --- corpus ------------------------------------------------------------------
corpus="$(mktemp)"; trap 'rm -f "$corpus"' EXIT
{ git ls-files; git ls-files --others --exclude-standard; } | LC_ALL=C sort -u > "$corpus"
n_files="$(wc -l < "$corpus" | tr -d ' ')"
echo ""
echo "== corpus =="
echo "  $n_files file(s): tracked + untracked-not-ignored (what the next \`git add -A\` publishes)"

# --- scan --------------------------------------------------------------------
echo ""
echo "== scan =="
total=0
for rule in "${RULES[@]}"; do
    id="${rule%%|*}"; rest="${rule#*|}"; desc="${rest%%|*}"; re="${rest#*|}"
    hits=0; out=""
    # ONE grep over the whole corpus per rule: -I skips binaries, -n gives the
    # line, and xargs handles the argument limit. A per-file loop over ~1800
    # files x 5 rules took minutes; this takes seconds, and a guard people wait
    # for is a guard people switch off.
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        f="${m%%:*}"; rest="${m#*:}"; ln="${rest%%:*}"; txt="${rest#*:}"
        allowed "$f" "$id" && continue
        excepted "$id" "$txt" && continue
        out+="        ${f}:${ln}  ${desc}"$'\n'
        hits=$((hits+1))
    done < <(xargs -a "$corpus" -d '\n' -r grep -InE "$re" -- 2>/dev/null)
    if [ "$hits" -eq 0 ]; then
        printf '  ok   %-18s no finding\n' "$id"
    else
        printf 'FAIL   %-18s %d finding(s)\n' "$id" "$hits"
        printf '%s' "$out"
        total=$((total+hits))
    fi
done

echo ""
if [ "$total" -eq 0 ]; then
    echo "check-secrets: PASS — ${#RULES[@]} rule(s) armed, $n_files file(s), 0 finding(s)."
    exit 0
fi
cat <<EOF
check-secrets: FAIL — $total finding(s).

WHAT TO DO
  A real credential:  do NOT just delete the literal. It is in the published
                      history and must be treated as COMPROMISED: rotate it
                      first, then remove it. Replace the literal with a required
                      environment variable so the script fails loudly rather than
                      silently using a published secret:
                          PW="\${KR260_PASSWORD:?KR260_PASSWORD is not set}"
                      pynq_host/scripts/coverage/cov_common.py password() is the
                      in-repo model for the python form.
  A false positive:   add it to ALLOW above WITH A REASON. An allowlist entry is
                      a claim a reviewer will trust; make it one you would defend.
EOF
exit 1
