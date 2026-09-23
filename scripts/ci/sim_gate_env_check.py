#!/usr/bin/env python3
"""Fail-closed launch check for `make sim_gate`.

WHAT WENT WRONG (measured 2026-09-09). The Makefile's sim_gate_env_check ran
exactly two tests -- `command -v vcs` and `command -v cocotb-config`. A shell
with VCS on PATH but WITHOUT `source ./set_env.sh` passed it, and then every
suite died at parse in 3-5 s with

    Error-[SFCOR] Source file "${CMSDK_FPGA_SRAM_V}" cannot be opened

and sim_gate_run duly wrote a CLEAN-STAMPED FAIL .status for each one. The gate
produced a full, correctly-stamped, entirely meaningless red table. Three whole
classes of launch fault were invisible to it:

  * a ${VAR} token used by the flists that is unset, or set to a path that does
    not exist (the case above);
  * an UNINITIALISED SUBMODULE -- `git submodule status --recursive` prints a
    leading '-'. deps/axi-chiplet-controller holds most of the Wlink RTL, so an
    unpopulated deps/ means the flists name files that are not there;
  * a DIRTY TREE at launch, which makes every .status stamp `-dirty` and makes
    sim_gate_summary refuse to report PASS at the end of a 45-95 minute run.

HOW THE VAR LIST IS BUILT -- MECHANICALLY, NOT BY HAND. A hard-coded list rots
the moment someone adds a flist. Instead:

  1. the gate's bench directories are read out of the root Makefile, from the
     `-C cocotb/<dir>` / `cd cocotb/<dir>` occurrences inside sim_gate* recipes;
  2. each bench Makefile is scanned for the flist/.f files it names, with simple
     variable assignments resolved;
  3. references found inside the RECIPE of a target the gate does not invoke are
     EXCLUDED -- this is what keeps flists/tidelink_netlist.flist (used only by
     cocotb/tidelink's `sim_asic`/`sim_saif`, and its STDCELL_VERILOG/MEM_PATH
     tokens) out of the required set without naming it;
  4. the resulting set is closed transitively over the `-f <file>` include lines
     inside those flists;
  5. every ${VAR} / $VAR token in the closure is required.

For each required var the check does what VCS will do: substitute the
environment into each flist line that mentions it and require the resulting path
to exist. That tests the actual failure mode rather than a proxy for it.

SIBLING REPOS (CHIPLET_HOME / TIDECHART_HOME / ETH_SS_HOME) are reported but do
NOT fail the check, deliberately. They appear in the root Makefile, not in any
flist, and the Makefile already checks them PER SUITE via SIM_GATE_REQUIRE for a
documented reason: "a missing sibling must fail its own suites loudly while the
other 15 still run -- aborting the whole gate on one absent checkout would be
worse than the gap it reports." This check surfaces them early instead of
silently, and names the suites that will fail.

Exit codes:  0 = ready   1 = a named, actionable failure   2 = could not evaluate

Run:  python3 scripts/ci/sim_gate_env_check.py [--repo DIR] [--allow-dirty]
Control: scripts/ci/tests/test_sim_gate_env_check.py
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
FLIST_TOKEN_RE = re.compile(r"[\w./$(){}-]+\.(?:flist|f)\b")
MAKE_ASSIGN_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*[:?]?=\s*(.*?)\s*$")
RULE_RE = re.compile(r"^([A-Za-z0-9_./$(){}%-]+)\s*:(?!=)")

# Tokens that are shell/SystemVerilog noise rather than environment variables.
NOT_ENV_VARS = {"unit"}


class Finding:
    def __init__(self, kind, name, detail, fix):
        self.kind, self.name, self.detail, self.fix = kind, name, detail, fix

    def render(self):
        out = ["  [%s] %s" % (self.kind, self.name), "      %s" % self.detail]
        out += ["      FIX: %s" % line for line in self.fix.splitlines()]
        return "\n".join(out)


# ── step 1: the bench directories the gate actually drives ────────────────────
def gate_bench_dirs(makefile_text):
    """Bench dirs named inside sim_gate* recipes, and the explicit sub-targets."""
    benches = {}          # dir -> set of explicitly invoked targets
    in_gate = False
    for line in makefile_text.splitlines():
        m = RULE_RE.match(line)
        if m and not line.startswith("\t"):
            in_gate = m.group(1).startswith("sim_gate")
        if not in_gate or not line.startswith("\t"):
            continue
        for dm in re.finditer(r"(?:-C\s+|cd\s+)((?:cocotb|uvm)/[A-Za-z0-9_]+)", line):
            d = dm.group(1)
            benches.setdefault(d, set())
            tail = line[dm.end():]
            tm = re.match(r"\s+([a-z][a-z0-9_]*)\b", tail)
            if tm and "=" not in tm.group(1):
                benches[d].add(tm.group(1))
    return benches


# ── step 2/3: the flists each bench pulls in on its DEFAULT path ──────────────
def bench_flists(repo, bench_dir, gate_targets):
    mk = repo / bench_dir / "Makefile"
    if not mk.is_file():
        return set()
    assigns, found, cur_target = {}, set(), None
    for raw in mk.read_text(errors="replace").splitlines():
        if raw.lstrip().startswith("#"):
            continue
        if not raw.startswith("\t"):
            rm = RULE_RE.match(raw)
            cur_target = rm.group(1) if rm else None
            am = MAKE_ASSIGN_RE.match(raw)
            if am:
                assigns[am.group(1)] = am.group(2)
        # A reference inside the recipe of a target the gate never invokes is
        # not part of the gate's file set (this is what excludes sim_asic's
        # tidelink_netlist.flist without naming it).
        if raw.startswith("\t") and cur_target and cur_target not in gate_targets:
            continue
        line = raw
        for _ in range(6):                       # resolve $(VAR) a few levels
            def sub(m):
                return assigns.get(m.group(1), m.group(0))
            new = re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_]*)\)", sub, line)
            if new == line:
                break
            line = new
        for tok in FLIST_TOKEN_RE.findall(line):
            if "$(" in tok or "${" in tok:
                tok = re.sub(r"\$[({][A-Za-z_][A-Za-z0-9_]*[)}]", "", tok)
            tok = tok.lstrip("/")
            for cand in (repo / tok, repo / bench_dir / tok, repo / "flists" / Path(tok).name):
                if cand.is_file():
                    found.add(cand.resolve())
                    break
    return found


# ── step 4: close over `-f <file>` includes ──────────────────────────────────
def close_over_includes(repo, seeds, env):
    seen, queue = set(), list(seeds)
    while queue:
        f = queue.pop()
        if f in seen:
            continue
        seen.add(f)
        try:
            text = f.read_text(errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            m = re.match(r"\s*-f\s+(\S+)", line)
            if not m:
                continue
            nxt = Path(expand(m.group(1), env))
            if nxt.is_file():
                queue.append(nxt.resolve())
    return seen


def expand(text, env):
    def sub(m):
        return env.get(m.group(1) or m.group(2), m.group(0))
    return VAR_RE.sub(sub, text)


def tokens_in(path):
    try:
        text = path.read_text(errors="replace")
    except OSError:
        return {}
    out = {}
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for m in VAR_RE.finditer(line):
            name = m.group(1) or m.group(2)
            if name in NOT_ENV_VARS:
                continue
            out.setdefault(name, (path, n, line.strip()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=os.environ.get("TIDELINK_HOME") or ".")
    ap.add_argument("--allow-dirty", action="store_true",
                    help="downgrade the dirty-tree check to a warning "
                         "(for a deliberate experiment, NOT for CI)")
    ap.add_argument("--skip-tools", action="store_true",
                    help="skip the vcs/cocotb-config checks (the Makefile does "
                         "them first; used by the control harness)")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    env = dict(os.environ)
    env.setdefault("TIDELINK_HOME", str(repo))
    mkfile = repo / "Makefile"
    if not mkfile.is_file():
        print("sim_gate_env_check: COULD-NOT-EVALUATE: no Makefile at %s" % repo)
        return 2

    findings = []
    print("sim_gate_env_check: repo = %s" % repo)

    # ── tools ────────────────────────────────────────────────────────────────
    if not args.skip_tools:
        for tool in ("vcs", "cocotb-config"):
            if not which(tool, env):
                findings.append(Finding(
                    "TOOL", tool,
                    "%s is not on PATH." % tool,
                    "source ./set_env.sh"))

    # ── flist ${VAR} closure ─────────────────────────────────────────────────
    benches = gate_bench_dirs(mkfile.read_text(errors="replace"))
    seeds = set()
    for d, targets in benches.items():
        seeds |= bench_flists(repo, d, targets)
    closure = close_over_includes(repo, seeds, env)
    print("sim_gate_env_check: %d gate benches -> %d flist/.f files in the closure"
          % (len(benches), len(closure)))
    if not closure:
        print("sim_gate_env_check: COULD-NOT-EVALUATE: the flist closure is EMPTY. "
              "Either the Makefile's sim_gate recipes changed shape or this is not "
              "a tidelink checkout; refusing to report ready on a check that "
              "examined nothing.")
        return 2

    required = {}
    for f in sorted(closure):
        for name, where in tokens_in(f).items():
            required.setdefault(name, where)

    print("sim_gate_env_check: required flist vars: %s"
          % (", ".join(sorted(required)) or "(none)"))

    # ANTI-FAIL-OPEN AUDIT. The closure is derived, so a bench Makefile written
    # in a shape step 2 does not recognise would silently shrink it and a var
    # used only there would silently stop being required. Name every var that
    # exists in the flist corpus but fell OUTSIDE the closure, so a narrowed
    # closure is visible in the log rather than invisible.
    outside = {}
    for f in sorted(list((repo / "flists").glob("*.flist")) +
                    list(repo.glob("cocotb/*/*.f"))):
        if f.resolve() in closure:
            continue
        for name, where in tokens_in(f).items():
            if name not in required:
                outside.setdefault(name, where[0])
    if outside:
        print("  [NOTE] vars present in the flist corpus but OUTSIDE the gate "
              "closure, so NOT required here:")
        for name, where in sorted(outside.items()):
            rel = where.relative_to(repo) if str(where).startswith(str(repo)) else where
            print("         %-20s first seen in %s" % (name, rel))

    for name in sorted(required):
        path, lineno, line = required[name]
        rel = path.relative_to(repo) if str(path).startswith(str(repo)) else path
        if not env.get(name):
            findings.append(Finding(
                "UNSET-VAR", name,
                "${%s} is used by %s:%d but is not set in the environment.\n"
                "      That line is: %s\n"
                "      VCS does not fail on an unexpanded token -- it reports\n"
                "      Error-[SFCOR] Source file \"${%s}\" cannot be opened and the\n"
                "      suite dies at parse in a few seconds, which sim_gate records\n"
                "      as a correctly-stamped FAIL."
                % (name, rel, lineno, line, name),
                "source ./set_env.sh   (and check site.env defines %s;\n"
                "     see site.env.example)" % name))
            continue
        resolved = expand(line, env)
        for cand in candidate_paths(resolved):
            if not Path(cand).exists():
                findings.append(Finding(
                    "MISSING-PATH", name,
                    "%s=%s is set, but %s:%d resolves to a path that does not\n"
                    "      exist: %s" % (name, env[name], rel, lineno, cand),
                    "check that %s points at a populated tree" % name))
                break

    # ── submodules ───────────────────────────────────────────────────────────
    rc, out = git(repo, ["submodule", "status", "--recursive"])
    if rc != 0:
        findings.append(Finding(
            "SUBMODULE", "(status unavailable)",
            "`git submodule status --recursive` failed; the gate cannot confirm\n"
            "      deps/ is populated. Treated as a FAILURE, not as 'fine' -- a\n"
            "      check that cannot report is not a check that passed.",
            "run it by hand and fix whatever it reports"))
    else:
        for line in out.splitlines():
            if line.startswith("-"):
                name = line[1:].split()[1] if len(line.split()) > 1 else line
                findings.append(Finding(
                    "SUBMODULE", name,
                    "submodule '%s' is NOT initialised (leading '-' in\n"
                    "      `git submodule status --recursive`). The flists name files\n"
                    "      inside it, so every suite that needs them dies at parse."
                    % name,
                    "git submodule update --init --recursive\n"
                    "     (in a worktree whose origin is a local path, git refuses the\n"
                    "      file:// transport by default -- prepend\n"
                    "      `git -c protocol.file.allow=always`)"))

    # ── tree cleanliness ─────────────────────────────────────────────────────
    rc, out = git(repo, ["status", "--porcelain"])
    if rc != 0:
        findings.append(Finding(
            "DIRTY-TREE", "(status unavailable)",
            "`git status --porcelain` failed, so tree cleanliness is UNKNOWN.\n"
            "      Reported as a failure rather than assumed clean.",
            "check the repository is readable"))
    elif out.strip():
        n = len(out.strip().splitlines())
        detail = ("the working tree is DIRTY (%d path%s).\n"
                  "      Every .status this run writes will be stamped `-dirty`, and\n"
                  "      sim_gate_summary refuses to report PASS on a dirty cohort --\n"
                  "      so a 45-95 minute gate will end in\n"
                  "      \"STALE / CROSS-BRANCH -- refusing to report PASS\" no matter\n"
                  "      how many suites pass. Paths:\n%s"
                  % (n, "" if n == 1 else "s",
                     "\n".join("        " + l for l in out.strip().splitlines()[:20])))
        fix = ("commit or stash before launching the gate.\n"
               "     If a GATE TARGET wrote one of those paths, that is a\n"
               "     self-dirtying gate: fix the writer. Do not reach for\n"
               "     `git update-index --assume-unchanged` -- it hides the problem\n"
               "     in one clone and it recurs in the next worktree.")
        if args.allow_dirty:
            print("\n  [WARN] DIRTY-TREE (downgraded by --allow-dirty)")
            print("      " + detail.replace("\n      ", "\n      "))
        else:
            findings.append(Finding("DIRTY-TREE", "working tree", detail, fix))

    # ── site contract: every gated bench must PARSE under this site ─────────
    # mk/site.mk (chore/site-path-hygiene) makes each bench's SITE_VARS_REQUIRED
    # mandatory at parse time with no default. Those are Makefile-level names
    # (VIP_HOME, VCS_HOME, PHYS_IP_PATH, ...), not flist tokens, so the closure
    # above cannot see them. Measured 2026-09-22 on a green tree: the one UVM
    # suite in the gate FAILed in 0 s because VIP_HOME was unset in site.env --
    # a correctly-stamped, meaningless result. Ask make itself: a dry run of a
    # target that does not exist parses the bench Makefile (and mk/site.mk)
    # and executes nothing.
    for d in sorted(benches):
        mk = repo / d / "Makefile"
        if not mk.is_file() or "mk/site.mk" not in mk.read_text(errors="replace"):
            continue
        try:
            r = subprocess.run(["make", "-C", str(repo / d), "-n",
                                "__sim_gate_env_check_site_probe__"],
                               capture_output=True, text=True, env=env, timeout=120)
            text = r.stdout + r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            text = "unset, with no default: (probe could not run: %s)" % e
        m = re.search(r"unset, with no default: ([A-Z_0-9 ()a-z:.-]+)", text)
        if m:
            findings.append(Finding(
                "SITE-CONTRACT", d,
                "mk/site.mk refuses to run this bench: %s" % m.group(1).strip(),
                "set it in site.env (site.env.example says what each one locates)\n"
                "and `source set_env.sh`; the gate would otherwise record a 0 s FAIL\n"
                "for every suite that drives this bench."))
    # ── siblings: reported, never fatal (see the module docstring) ───────────
    for var, probe, why in (
        ("TIDECHART_HOME", "flist/tidechart.flist", "the tc_pair_* co-sim suites"),
        ("CHIPLET_HOME", "src/rtl/tidechart_shim.sv", "the tc_pair_* co-sim suites"),
        ("ETH_SS_HOME", "set_env.sh", "the eth_* suites"),
        ("PHC_HOME", "src/rtl/phc_clock_core.sv", "the ptp_servo_converge suite"),
    ):
        val = env.get(var)
        if not val or not (Path(val) / probe).exists():
            print("  [NOTE] %s does not resolve (%s) -- %s will fail their own\n"
                  "         SIM_GATE_REQUIRE check; the rest of the gate still runs."
                  % (var, val or "unset", why))

    if findings:
        print("\nsim_gate_env_check: NOT READY — %d blocking problem%s\n"
              % (len(findings), "" if len(findings) == 1 else "s"))
        for f in findings:
            print(f.render())
            print()
        print("Refusing to start a 45-95 minute gate that would record "
              "correctly-stamped, meaningless results.")
        return 1

    print("sim_gate_env_check: READY")
    return 0


def candidate_paths(resolved_line):
    """Absolute paths a VCS flist line names, after ${VAR} expansion.

    Each whitespace token is stripped of the flist option prefixes that can sit
    in front of a path (`+incdir+`, `-f`, `-v`, `-y`) so that a directory named
    by `+incdir+${TIDELINK_HOME}/src/rtl` is checked too -- an unset var there
    is just as fatal at parse time as one in a bare source line.
    """
    out = []
    for tok in resolved_line.split():
        for prefix in ("+incdir+", "-f", "-v", "-y"):
            if tok.startswith(prefix):
                tok = tok[len(prefix):]
        tok = tok.strip().rstrip(",;")
        if tok.startswith("/"):
            out.append(tok)
    return out


def which(tool, env):
    for d in env.get("PATH", "").split(os.pathsep):
        p = Path(d) / tool
        if p.is_file() and os.access(str(p), os.X_OK):
            return True
    return False


def git(repo, argv):
    try:
        r = subprocess.run(["git", "-C", str(repo)] + argv,
                           capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout
    except Exception:
        return 1, ""


if __name__ == "__main__":
    sys.exit(main())
