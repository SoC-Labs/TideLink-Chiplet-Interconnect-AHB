#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# Selftest for td_artifact.py — covers add / immutability / retag / list /
# show / record / gc / deploy(dry-run). Runs against a throwaway temp store;
# touches no real artifacts, no HW. Run: python3 test_td_artifact.py
#-----------------------------------------------------------------------------
import io
import json
import os
import shutil
import sys
import tempfile
from contextlib import redirect_stdout

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import td_artifact as ta  # noqa: E402


def _run(root, argv):
    """Invoke the CLI; capture stdout; return (text, exit_code_or_None)."""
    buf = io.StringIO()
    code = None
    try:
        with redirect_stdout(buf):
            ta.main(["--root", root] + argv)
    except SystemExit as e:
        code = e.code
    return buf.getvalue(), code


def _mkbin(path, content):
    with open(path, "wb") as f:
        f.write(content)


PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS  %s" % name)
    else:
        FAIL += 1
        print("  FAIL  %s" % name)


def main():
    work = tempfile.mkdtemp(prefix="td_artifact_test_")
    src = os.path.join(work, "src")
    root = os.path.join(work, "store")
    os.makedirs(src)
    try:
        # --- fixtures: two distinct "builds" -------------------------------
        good_m = os.path.join(src, "good.bin")
        good_s = os.path.join(src, "good-flip.bin")
        good_h = os.path.join(src, "good.hwh")
        bad_m = os.path.join(src, "bad.bin")
        _mkbin(good_m, b"GOOD-MASTER-BYTES" * 100)
        _mkbin(good_s, b"GOOD-SLAVE-BYTES" * 100)
        _mkbin(good_h, b"<hwh/>")
        _mkbin(bad_m, b"BAD-PHASE-V2-BYTES" * 100)
        good_sha = ta.sha256_file(good_m)
        bad_sha = ta.sha256_file(bad_m)

        # --- add (paired) --------------------------------------------------
        out, _ = _run(root, ["add", "--master", good_m, "--slave", good_s,
                             "--master-hwh", good_h, "--label", "good-v1",
                             "--commit", "abc1234", "--build-host", "h1",
                             "--target", "pynq-z2-pair",
                             "--expected-lock-min", "14",
                             "--note", "seed 14/16"])
        st = ta.Store(root)
        check("add creates blob dir", os.path.isdir(st.blob_dir(good_sha)))
        check("add copies master.bin", os.path.exists(
            os.path.join(st.blob_dir(good_sha), ta.MASTER_BIN)))
        check("add copies slave.bin", os.path.exists(
            os.path.join(st.blob_dir(good_sha), ta.SLAVE_BIN)))
        check("add creates tag symlink", os.path.islink(st.tag_link("good-v1")))
        man = st.read_manifest(good_sha)
        check("manifest sha256==sha(master)", man["sha256"] == good_sha)
        check("manifest tracks slave sha", man["sha256_slave"] == ta.sha256_file(good_s))
        check("manifest guard-field source_commit", man["source_commit"] == "abc1234")
        check("seed note went to results.jsonl", len(st.read_results(good_sha)) == 1)

        # --- idempotency: re-add identical content is a no-op + retag ------
        blob = st.blob_dir(good_sha)
        before = sorted(os.listdir(blob))
        mtime_before = os.path.getmtime(os.path.join(blob, ta.MASTER_BIN))
        out, _ = _run(root, ["add", "--master", good_m, "--slave", good_s,
                             "--label", "good-v1-alias"])
        after = sorted(os.listdir(blob))
        mtime_after = os.path.getmtime(os.path.join(blob, ta.MASTER_BIN))
        check("re-add is idempotent (no new files)", before == after)
        check("re-add does NOT rewrite bytes (mtime stable)",
              mtime_before == mtime_after)
        check("re-add adds second tag to same blob", os.path.islink(
            st.tag_link("good-v1-alias")))
        check("both tags resolve to same sha",
              st.resolve("good-v1") == st.resolve("good-v1-alias") == good_sha)

        # --- IMMUTABILITY: adding DIFFERENT content under another label ----
        #     must NOT touch the good blob.
        good_master_sha_before = ta.sha256_file(os.path.join(blob, ta.MASTER_BIN))
        out, _ = _run(root, ["add", "--master", bad_m, "--label",
                             "phase-v2-KNOWN-BAD", "--expected-lock-min", "0",
                             "--note", "0/16 DO NOT SHIP"])
        good_master_sha_after = ta.sha256_file(os.path.join(blob, ta.MASTER_BIN))
        check("bad add creates its own distinct blob",
              os.path.isdir(st.blob_dir(bad_sha)) and bad_sha != good_sha)
        check("IMMUTABILITY: good blob master bytes UNCHANGED",
              good_master_sha_before == good_master_sha_after == good_sha)
        check("good-v1 tag still points at good blob",
              st.resolve("good-v1") == good_sha)

        # --- retag: repoint an existing label to a different blob ----------
        _run(root, ["add", "--master", bad_m, "--label", "good-v1-alias"])
        check("retag repoints label to new blob",
              st.resolve("good-v1-alias") == bad_sha)
        check("retag did not damage original good blob",
              ta.sha256_file(os.path.join(blob, ta.MASTER_BIN)) == good_sha)
        # restore alias to good for the rest of the test
        _run(root, ["add", "--master", good_m, "--slave", good_s,
                    "--label", "good-v1-alias"])

        # --- record --------------------------------------------------------
        _run(root, ["record", "good-v1", "--lock-best", "14",
                    "--lock-mean", "14.40", "--iters", "10", "--cal-done", "1",
                    "--note", "n10"])
        _run(root, ["record", "good-v1", "--lock-best", "13",
                    "--lock-mean", "7.60", "--iters", "10"])
        res = st.read_results(good_sha)
        check("record appends (seed + 2 = 3)", len(res) == 3)
        check("record stores lock_best", any(r.get("lock_best") == 14 for r in res))

        # --- list ----------------------------------------------------------
        out, _ = _run(root, ["list"])
        check("list shows good-v1", "good-v1" in out)
        check("list shows phase-v2-KNOWN-BAD", "phase-v2-KNOWN-BAD" in out)
        check("list shows best lock 14", "14" in out)

        # --- show ----------------------------------------------------------
        out, _ = _run(root, ["show", "good-v1"])
        check("show prints sha", good_sha[:12] in out)
        check("show prints results history", "n10" in out)
        out, _ = _run(root, ["show", good_sha[:10]])
        check("show resolves by sha prefix", good_sha[:12] in out)

        # --- deploy dry-run + sidecar manifest -----------------------------
        out, code = _run(root, ["deploy", "good-v1", "--pair", "bridge1",
                                "--dry-run"])
        check("deploy dry-run prints provenance banner",
              "provenance banner" in out)
        check("deploy dry-run mentions --expect-sha256", "--expect-sha256" in out)
        check("deploy dry-run does not flash", "no flashing" in out)
        sidecar = os.path.join(blob, ta.MASTER_BIN + ".manifest.json")
        check("deploy writes guard-compatible sidecar", os.path.exists(sidecar))
        if os.path.exists(sidecar):
            sc = json.load(open(sidecar))
            check("sidecar sha256 matches blob", sc["sha256"] == good_sha)
            check("sidecar has guard field source_commit",
                  "source_commit" in sc)

        # --- verify dry-run ------------------------------------------------
        out, _ = _run(root, ["verify", "good-v1", "--pair", "bridge1",
                            "--dry-run"])
        check("verify dry-run mentions md5", "md5" in out.lower())

        # --- gc ------------------------------------------------------------
        # Create an orphan: add a blob then move its only tag away.
        orphan_src = os.path.join(src, "orphan.bin")
        _mkbin(orphan_src, b"ORPHAN" * 50)
        orphan_sha = ta.sha256_file(orphan_src)
        _run(root, ["add", "--master", orphan_src, "--label", "tmp-orphan"])
        _run(root, ["add", "--master", good_m, "--label", "tmp-orphan"])  # repoint away
        out, _ = _run(root, ["gc"])
        check("gc dry-run (default) lists orphan", orphan_sha[:12] in out)
        check("gc dry-run does NOT delete", os.path.isdir(st.blob_dir(orphan_sha)))
        out, _ = _run(root, ["gc", "--force"])
        check("gc --force deletes orphan", not os.path.isdir(st.blob_dir(orphan_sha)))
        check("gc --force keeps tagged good blob", os.path.isdir(st.blob_dir(good_sha)))

        # --- untag + index reconcile ---------------------------------------
        _run(root, ["add", "--master", good_m, "--label", "tmp-untag"])
        out, _ = _run(root, ["untag", "tmp-untag"])
        check("untag removes the tag", not os.path.islink(st.tag_link("tmp-untag")))
        check("untag drops index entry", "tmp-untag" not in st.read_index())
        # manual tag removal -> list self-heals the stale index entry
        _run(root, ["add", "--master", good_m, "--label", "tmp-manual"])
        os.remove(st.tag_link("tmp-manual"))
        check("stale index entry present before reconcile",
              "tmp-manual" in st.read_index())
        _run(root, ["list"])
        check("list reconciles stale index entry",
              "tmp-manual" not in st.read_index())

        # --- index integrity ----------------------------------------------
        idx = st.read_index()
        check("index.json is valid + has good-v1", "good-v1" in idx)
        check("index entry has blob_dir", "blob_dir" in idx["good-v1"])

    finally:
        shutil.rmtree(work, ignore_errors=True)

    print("\n%d passed, %d failed" % (PASS, FAIL))
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
