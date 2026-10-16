#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# scripts/ci/test_bump_check.py — self-test for bump_check.py and the pre-push
# hook. Stdlib only:  python3 scripts/ci/test_bump_check.py   (or `make bump-check-selftest`)
#
# Each test builds a throwaway git repo whose second commit moves a gitlink,
# so the script is exercised on real `git diff --raw` output, not on a mock.
# The fake release manager is an in-process HTTP server on 127.0.0.1 that
# lives only for the test that starts it.
#
# Copyright 2026, SoC Labs (www.soclabs.org)
# -----------------------------------------------------------------------------
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bump_check  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
HOOK = os.path.join(REPO, "scripts", "hooks", "pre-push")

MANIFEST = """schema: 1
component: demo
capabilities:
  - id: lint
    kind: lint
    tier: t1
    run: %s
    affected_by: [sub]
    verdict: {exit: 0, forbid: ['SKIPPED']}
    gate: block
  - id: unrelated
    kind: lint
    tier: t1
    run: "false"
    affected_by: [other]
    gate: block
compose:
  - {path: sub, run: [lint-fast], when: on_bump}
"""


def sh(cwd, *args):
    return subprocess.run(list(args), cwd=cwd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, universal_newlines=True).stdout.strip()


class Repo:
    """A repo whose HEAD~1..HEAD moves gitlink `sub` (and optionally adds a manifest)."""

    def __init__(self, run_cmd="true", manifest=True, move=True):
        self.dir = tempfile.mkdtemp(prefix="bump_check_test_")
        g = lambda *a: sh(self.dir, "git", "-c", "user.name=t", "-c", "user.email=t@t", *a)
        g("init", "-q")
        g("config", "commit.gpgsign", "false")
        a, b = "1" * 40, "2" * 40
        if manifest:
            os.makedirs(os.path.join(self.dir, ".nanosoc"))
            with open(os.path.join(self.dir, ".nanosoc", "capabilities.yaml"), "w") as f:
                f.write(MANIFEST % json.dumps(run_cmd))
            g("add", ".nanosoc/capabilities.yaml")
        with open(os.path.join(self.dir, "README"), "w") as f:
            f.write("x\n")
        g("add", "README")
        g("update-index", "--add", "--cacheinfo", "160000,%s,sub" % a)
        g("commit", "-q", "-m", "one")
        if move:
            g("update-index", "--cacheinfo", "160000,%s,sub" % b)
        else:
            with open(os.path.join(self.dir, "README"), "a") as f:
                f.write("y\n")
            g("add", "README")
        g("commit", "-q", "-m", "two")
        self.base = g("rev-parse", "HEAD~1")
        self.tip = g("rev-parse", "HEAD")

    def check(self, mode, **kw):
        out = io.StringIO()
        rc = bump_check.check([(self.base, self.tip)], mode, cwd=self.dir, out=out, **kw)
        return rc, out.getvalue()

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class FakeRM:
    """Answers GET /api/v1/bump-check with a fixed verdict and records the query."""

    def __init__(self, verdict, status=200):
        self.queries = []
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                outer.queries.append((u.path, dict(urllib.parse.parse_qsl(u.query)),
                                      self.headers.get("Authorization")))
                body = json.dumps({"verdict": verdict, "url": "/jobs/1"}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        self.srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]
        self.t = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.t.start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


class BumpCheck(unittest.TestCase):
    def setUp(self):
        self.env = dict(os.environ)
        for k in ("NANOSOC_RM_URL", "NANOSOC_RM_TOKEN"):
            os.environ.pop(k, None)
        self.repos = []

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)
        for r in self.repos:
            r.close()

    def repo(self, **kw):
        r = Repo(**kw)
        self.repos.append(r)
        return r

    def test_no_gitlink_move_passes_block(self):
        rc, out = self.repo(move=False).check("block")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out, "")

    def test_move_found_with_paths_and_shas(self):
        r = self.repo()
        self.assertEqual(bump_check.changed_gitlinks(r.base, r.tip, cwd=r.dir),
                         [("sub", "1" * 40, "2" * 40)])

    def test_unverified_move_blocks_in_block_mode(self):
        rc, out = self.repo().check("block")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL", out)
        self.assertIn("nanosoc-rm test-bump <configuration> sub --to " + "2" * 40, out)

    def test_unverified_move_only_warns_in_warn_mode(self):
        rc, out = self.repo().check("warn")
        self.assertEqual(rc, 0, out)
        self.assertIn("WARNING", out)

    def test_lists_affected_capability_and_compose(self):
        rc, out = self.repo().check("warn")
        self.assertIn("affects lint", out)
        self.assertIn("composes sub:lint-fast", out)
        self.assertNotIn("unrelated", out)

    def test_rm_pass_unblocks_and_query_names_the_move(self):
        r = self.repo()
        rm = FakeRM("PASS")
        try:
            os.environ["NANOSOC_RM_URL"] = rm.url
            os.environ["NANOSOC_RM_TOKEN"] = "tok"
            rc, out = r.check("block")
        finally:
            rm.close()
        self.assertEqual(rc, 0, out)
        path, q, auth = rm.queries[0]
        self.assertEqual(path, "/api/v1/bump-check")
        self.assertEqual((q["component"], q["path"], q["from"], q["to"]),
                         ("demo", "sub", "1" * 40, "2" * 40))
        self.assertEqual(auth, "Bearer tok")

    def test_rm_fail_blocks(self):
        r = self.repo()
        rm = FakeRM("FAIL")
        try:
            os.environ["NANOSOC_RM_URL"] = rm.url
            rc, out = r.check("block")
        finally:
            rm.close()
        self.assertEqual(rc, 1, out)
        self.assertIn("release manager: FAIL", out)

    def test_rm_http_error_is_no_verdict(self):
        r = self.repo()
        rm = FakeRM("PASS", status=404)
        try:
            os.environ["NANOSOC_RM_URL"] = rm.url
            rc, out = r.check("block")
        finally:
            rm.close()
        self.assertEqual(rc, 1, out)
        self.assertIn("HTTP 404", out)

    def test_run_local_pass(self):
        rc, out = self.repo(run_cmd="echo LINT OK").check("block", run_local=True)
        self.assertEqual(rc, 0, out)
        self.assertIn("run-local lint", out)

    def test_run_local_forbidden_output_fails_despite_exit_0(self):
        rc, out = self.repo(run_cmd="echo 'PASS 3 WRAPPER: SKIPPED'").check("block", run_local=True)
        self.assertEqual(rc, 1, out)
        self.assertIn("forbidden", out)

    def test_run_local_nonzero_exit_fails(self):
        rc, out = self.repo(run_cmd="exit 3").check("block", run_local=True)
        self.assertEqual(rc, 1, out)

    def test_wave_g_spelling_tiers_and_argv_command(self):
        r = self.repo()
        alt = ("schema: 1\ncomponent: demo\ntiers:\n  - id: unit\n    kind: unit\n"
               "    tier: t1\n    command: [sh, -c, 'echo SKIPPED']\n    affected_by: [sub]\n"
               "    verdict: {forbid: ['SKIPPED']}\n")
        g = lambda *a: sh(r.dir, "git", "-c", "user.name=t", "-c", "user.email=t@t", *a)
        with open(os.path.join(r.dir, ".nanosoc", "capabilities.yaml"), "w") as f:
            f.write(alt)
        g("add", ".nanosoc/capabilities.yaml")
        g("commit", "-q", "-m", "alt")
        r.tip = g("rev-parse", "HEAD")
        rc, out = r.check("block", run_local=True)
        self.assertEqual(rc, 1, out)
        self.assertIn("run-local unit", out)
        self.assertIn("forbidden", out)

    def test_run_local_never_runs_a_regenerating_capability(self):
        r = self.repo()
        mark = os.path.join(r.dir, "ran")
        cap = ("schema: 1\ncomponent: demo\ncapabilities:\n  - id: elab\n    kind: elab\n"
               "    tier: t2\n    run: touch %s\n    regenerates: true\n    affected_by: [sub]\n" % mark)
        g = lambda *a: sh(r.dir, "git", "-c", "user.name=t", "-c", "user.email=t@t", *a)
        with open(os.path.join(r.dir, ".nanosoc", "capabilities.yaml"), "w") as f:
            f.write(cap)
        g("add", ".nanosoc/capabilities.yaml")
        g("commit", "-q", "-m", "regen")
        r.tip = g("rev-parse", "HEAD")
        os.environ.pop("NANOSOC_GEN_OK", None)
        rc, out = r.check("block", run_local=True)
        self.assertEqual(rc, 1, out)
        self.assertIn("NOT RUN", out)
        self.assertFalse(os.path.exists(mark), "a regenerating capability ran")

    def test_require_list_counts_matches(self):
        r = self.repo(run_cmd="echo PASS")
        cap = {"id": "x", "run": "echo PASS", "verdict": {"require": [{"pattern": "PASS", "min": 2}]}}
        ok, detail = bump_check.run_capability(cap, r.dir)
        self.assertFalse(ok, detail)
        cap["run"] = "echo PASS; echo PASS"
        ok, detail = bump_check.run_capability(cap, r.dir)
        self.assertTrue(ok, detail)

    def test_no_manifest_still_blocks(self):
        rc, out = self.repo(manifest=False).check("block", run_local=True)
        self.assertEqual(rc, 1, out)
        self.assertIn("no .nanosoc/capabilities.yaml", out)

    def test_pre_push_new_branch_uses_root_when_no_remote(self):
        r = self.repo()
        line = "refs/heads/x %s refs/heads/x %s\n" % (r.tip, bump_check.ZERO)
        rng = bump_check.pre_push_ranges(io.StringIO(line), "origin", cwd=r.dir)
        self.assertEqual(len(rng), 1)
        self.assertEqual(rng[0][1], r.tip)

    def test_hook_warns_but_never_blocks(self):
        r = self.repo()
        hookdir = os.path.join(r.dir, "scripts", "hooks")
        cidir = os.path.join(r.dir, "scripts", "ci")
        os.makedirs(hookdir)
        os.makedirs(cidir)
        shutil.copy(HOOK, hookdir)
        shutil.copy(os.path.join(HERE, "bump_check.py"), cidir)
        line = "refs/heads/m %s refs/heads/m %s\n" % (r.tip, r.base)
        p = subprocess.run([os.path.join(hookdir, "pre-push"), "origin"], cwd=r.dir,
                           input=line, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           universal_newlines=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("WARNING", p.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
