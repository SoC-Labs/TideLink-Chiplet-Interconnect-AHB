#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# TideLink Content-Addressed Bitstream Artifact Store
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# td-artifact — store, label and deploy FPGA bitstreams by content hash.
#
# WHY THIS EXISTS (Bug #32)
#   The old workflow was "scp the .bin into a shared, volatile
#   /tmp/tidelink_deploy and run deploy_pair.sh".  /tmp is shared between
#   agents and reaped on reboot, so a *population test* could (and did) leave
#   a known-bad 0/16 May-6 phase-v2 build sitting in that staging dir.  The
#   next deploy/bundle picked it up BLINDLY — the v1 release nearly shipped
#   the wrong, never-locking bitstream.  There was no record of which bytes
#   were which build, no immutability, and no "deploy by name" — only
#   "deploy whatever is in the path right now".
#
#   This tool turns that into a content-addressed store (a tiny git-blob-like
#   CAS on the filesystem): bytes live under blobs/<sha256>/ (write-once,
#   immutable), and human labels are mutable symlinks (tags/<label>) that
#   point at a blob.  You "deploy by label", the bytes are re-verified at
#   deploy time, and a known-bad build is permanently labelled so it can
#   never be silently mistaken for a good one again.
#
# DETERMINISTIC HASHING
#   For a PAIRED artifact (master tidelink.bin + slave tidelink-flip.bin) the
#   PRIMARY KEY is sha256(master_bytes).  The slave hash is tracked in the
#   manifest (sha256_slave) but does not participate in the blob address.
#   Rationale: die_a/master is the canonical, role-defining bitstream; the
#   flip is mechanically derived (mirrored RPi-GPIO pin map) from the same
#   build, so the master uniquely identifies the build.  This keeps the blob
#   address stable and human-traceable to "the build", and a re-`add` of the
#   identical master is a pure no-op + retag (idempotent).
#
# COMPOSITION WITH deploy_pair.sh (deploy-provenance-guard, Bug #32)
#   deploy_pair.sh gained --expect-sha256 / --manifest / --no-verify /
#   --check-only options.  We DO NOT reimplement flashing — `deploy` resolves
#   a label to its immutable blob dir, re-verifies the bytes, writes a sidecar
#   "<bin>.manifest.json" the guard auto-discovers, and invokes deploy_pair.sh
#   with --expect-sha256 so the guard aborts on any mismatch.  Manifest schema
#   is a SUPERSET of the guard's sidecar schema (sha256, source_commit,
#   build_host, build_date, target, expected_lock_min, label).
#-----------------------------------------------------------------------------
"""TideLink content-addressed bitstream artifact store CLI (td-artifact)."""

import argparse
import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys

# --- store layout constants -------------------------------------------------
DEFAULT_ROOT = os.environ.get(
    "TIDELINK_ARTIFACTS",
    os.path.expanduser("~/tidelink-artifacts"),
)
INDEX_NAME = "index.json"
BLOBS_DIR = "blobs"
TAGS_DIR = "tags"
MANIFEST_NAME = "manifest.json"
RESULTS_NAME = "results.jsonl"

MASTER_BIN = "tidelink.bin"
MASTER_HWH = "tidelink.hwh"
SLAVE_BIN = "tidelink-flip.bin"
SLAVE_HWH = "tidelink-flip.hwh"

# Default deploy_pair.sh location (relative to this file: pynq_host/scripts/).
_SELF_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DEPLOY_PAIR = os.path.join(_SELF_DIR, "scripts", "deploy_pair.sh")

# bridge1 board map (boards reached via mapstone-dev ProxyJump routing).
BRIDGES = {
    "bridge1": {
        "master": {"ip": "192.168.4.101", "role": "die_a", "label": "z2_02"},
        "slave":  {"ip": "192.168.6.101", "role": "die_b", "label": "z2_03"},
    },
}

SSH_HOP = os.environ.get("TIDELINK_DEPLOY_HOST", "mapstone-dev")
BOARD_PASS = os.environ.get("TIDELINK_BOARD_PASS", "xilinx")


# --- small helpers ----------------------------------------------------------
def _now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _today():
    return datetime.date.today().isoformat()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def die(msg, code=2):
    sys.stderr.write("td-artifact: ERROR: %s\n" % msg)
    sys.exit(code)


def info(msg):
    sys.stdout.write(msg + "\n")


# --- store object -----------------------------------------------------------
class Store:
    def __init__(self, root):
        self.root = os.path.abspath(os.path.expanduser(root))
        self.blobs = os.path.join(self.root, BLOBS_DIR)
        self.tags = os.path.join(self.root, TAGS_DIR)
        self.index_path = os.path.join(self.root, INDEX_NAME)

    # -- filesystem init --
    def ensure(self):
        os.makedirs(self.blobs, exist_ok=True)
        os.makedirs(self.tags, exist_ok=True)
        if not os.path.exists(self.index_path):
            self._write_index({})

    # -- index r/w --
    def read_index(self):
        if not os.path.exists(self.index_path):
            return {}
        with open(self.index_path) as f:
            return json.load(f)

    def _write_index(self, idx):
        tmp = self.index_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(idx, f, indent=2, sort_keys=True)
            f.write("\n")
        os.replace(tmp, self.index_path)

    # -- blob paths --
    def blob_dir(self, sha):
        return os.path.join(self.blobs, sha)

    def manifest_path(self, sha):
        return os.path.join(self.blob_dir(sha), MANIFEST_NAME)

    def results_path(self, sha):
        return os.path.join(self.blob_dir(sha), RESULTS_NAME)

    def read_manifest(self, sha):
        p = self.manifest_path(sha)
        if not os.path.exists(p):
            return {}
        with open(p) as f:
            return json.load(f)

    def read_results(self, sha):
        p = self.results_path(sha)
        out = []
        if os.path.exists(p):
            with open(p) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        out.append(json.loads(line))
        return out

    # -- tag resolution --
    def tag_link(self, label):
        return os.path.join(self.tags, label)

    def resolve(self, ref):
        """Resolve a label or (full/prefix) sha to a sha256 string."""
        # Exact blob dir?
        if os.path.isdir(self.blob_dir(ref)):
            return ref
        # Tag?
        link = self.tag_link(ref)
        if os.path.islink(link) or os.path.exists(link):
            target = os.path.realpath(link)
            sha = os.path.basename(target)
            if os.path.isdir(self.blob_dir(sha)):
                return sha
        # sha prefix?
        if os.path.isdir(self.blobs):
            matches = [d for d in os.listdir(self.blobs)
                       if d.startswith(ref) and os.path.isdir(self.blob_dir(d))]
            if len(matches) == 1:
                return matches[0]
            if len(matches) > 1:
                die("ambiguous sha prefix '%s' (%d matches)" % (ref, len(matches)))
        return None

    def tags_for(self, sha):
        out = []
        if not os.path.isdir(self.tags):
            return out
        for name in sorted(os.listdir(self.tags)):
            link = self.tag_link(name)
            if os.path.islink(link) and os.path.basename(os.path.realpath(link)) == sha:
                out.append(name)
        return out


# --- command: add -----------------------------------------------------------
def cmd_add(store, args):
    store.ensure()
    if not os.path.exists(args.master):
        die("master bin not found: %s" % args.master)
    sha = sha256_file(args.master)
    sha_slave = sha256_file(args.slave) if args.slave else None
    blob = store.blob_dir(sha)

    # Map of canonical-name -> source path (only for files actually given).
    files = {MASTER_BIN: args.master}
    if args.master_hwh:
        files[MASTER_HWH] = args.master_hwh
    if args.slave:
        files[SLAVE_BIN] = args.slave
    if args.slave_hwh:
        files[SLAVE_HWH] = args.slave_hwh

    existed = os.path.isdir(blob)
    if existed:
        # IMMUTABILITY: the blob is content-addressed by sha(master); the
        # master bytes are guaranteed identical. Verify any present files
        # match (defence against a corrupted store), but NEVER overwrite.
        cur_master = os.path.join(blob, MASTER_BIN)
        if os.path.exists(cur_master):
            cur = sha256_file(cur_master)
            if cur != sha:
                die("BLOB CORRUPTION: %s holds master sha %s, expected %s "
                    "(refusing to touch)" % (blob, cur, sha))
        info("blob %s already exists — idempotent, NOT rewriting bytes" % sha[:12])
    else:
        # Write-once: stage into a temp dir then atomically rename in.
        tmp = blob + ".incoming"
        if os.path.isdir(tmp):
            shutil.rmtree(tmp)
        os.makedirs(tmp)
        for canon, src in files.items():
            shutil.copy2(src, os.path.join(tmp, canon))
        manifest = {
            "sha256": sha,                 # primary key = sha256(master)
            "sha256_master": sha,
            "sha256_slave": sha_slave,
            # guard-compatible alias for the slave key
            "source_commit": args.commit or "",
            "commit": args.commit or "",
            "build_host": args.build_host or "",
            "build_date": args.build_date or _today(),
            "target": args.target or "pynq-z2-pair",
            "label": args.label,
            "expected_lock_min": args.expected_lock_min,
            "created_at": _now(),
            "files": sorted(files.keys()),
        }
        with open(os.path.join(tmp, MANIFEST_NAME), "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.write("\n")
        # empty append-only results log
        open(os.path.join(tmp, RESULTS_NAME), "w").close()
        os.rename(tmp, blob)
        info("created immutable blob %s (%d files)" % (sha[:12], len(files)))

    # (Re)point the tag — tags are mutable, blobs are not.
    _retag(store, args.label, sha)

    # Update the registry index.
    idx = store.read_index()
    man = store.read_manifest(sha)
    idx[args.label] = {
        "sha256": sha,
        "commit": man.get("commit", ""),
        "build_host": man.get("build_host", ""),
        "build_date": man.get("build_date", ""),
        "target": man.get("target", ""),
        "blob_dir": os.path.relpath(blob, store.root),
    }
    store._write_index(idx)
    info("label '%s' -> %s" % (args.label, sha[:12]))
    if args.note:
        _record(store, sha, lock_best=None, lock_mean=None, iters=None,
                 cal_done=None, note=args.note, pair="(add)")


def _retag(store, label, sha):
    link = store.tag_link(label)
    # remove any existing tag (file or symlink) then recreate
    if os.path.islink(link) or os.path.exists(link):
        os.remove(link)
    rel = os.path.join("..", BLOBS_DIR, sha)
    os.symlink(rel, link)


def _reconcile_index(store):
    """Tags are the source of truth: drop index entries whose tag is gone.

    Manual `rm tags/<label>` (or an external edit) can leave the registry
    out of sync; reading the index self-heals so `list` never shows a label
    that no longer resolves. Returns the reconciled (and persisted) index.
    """
    idx = store.read_index()
    if not os.path.isdir(store.tags):
        return idx
    stale = [label for label in list(idx)
             if not os.path.islink(store.tag_link(label))]
    if stale:
        for label in stale:
            del idx[label]
        store._write_index(idx)
    return idx


# --- command: list ----------------------------------------------------------
def cmd_list(store, args):
    idx = _reconcile_index(store)
    if not idx:
        info("(store empty — %s)" % store.root)
        return
    hdr = "%-22s %-14s %-10s %-16s %-8s %-9s %-9s" % (
        "LABEL", "SHA", "COMMIT", "TARGET", "#RESULTS", "BEST", "MEAN")
    info(hdr)
    info("-" * len(hdr))
    for label in sorted(idx):
        ent = idx[label]
        sha = ent["sha256"]
        results = store.read_results(sha)
        best = max((r.get("lock_best") for r in results
                    if r.get("lock_best") is not None), default=None)
        means = [r.get("lock_mean") for r in results if r.get("lock_mean") is not None]
        mean = (sum(means) / len(means)) if means else None
        info("%-22s %-14s %-10s %-16s %-8d %-9s %-9s" % (
            label, sha[:12], (ent.get("commit") or "-")[:10],
            (ent.get("target") or "-")[:16], len(results),
            ("%d" % best) if best is not None else "-",
            ("%.2f" % mean) if mean is not None else "-"))


# --- command: show ----------------------------------------------------------
def cmd_show(store, args):
    sha = store.resolve(args.ref)
    if not sha:
        die("no such label or sha: %s" % args.ref)
    man = store.read_manifest(sha)
    info("=== manifest (blob %s) ===" % sha[:12])
    info(json.dumps(man, indent=2, sort_keys=True))
    info("tags -> %s" % (", ".join(store.tags_for(sha)) or "(none)"))
    info("blob_dir: %s" % store.blob_dir(sha))
    results = store.read_results(sha)
    info("=== results.jsonl (%d entries) ===" % len(results))
    for r in results:
        info("  %-20s pair=%-8s best=%-3s mean=%-6s iters=%-4s cal=%-2s %s" % (
            r.get("timestamp", "?"), str(r.get("pair", "?")),
            str(r.get("lock_best", "-")), str(r.get("lock_mean", "-")),
            str(r.get("iters", "-")), str(r.get("cal_done", "-")),
            r.get("note", "")))


# --- command: record --------------------------------------------------------
def cmd_record(store, args):
    sha = store.resolve(args.ref)
    if not sha:
        die("no such label or sha: %s" % args.ref)
    _record(store, sha, lock_best=args.lock_best, lock_mean=args.lock_mean,
            iters=args.iters, cal_done=args.cal_done, note=args.note,
            pair=args.pair)
    info("recorded result for %s" % sha[:12])


def _record(store, sha, lock_best, lock_mean, iters, cal_done, note, pair):
    rec = {
        "timestamp": _now(),
        "pair": pair,
        "lock_best": lock_best,
        "lock_mean": lock_mean,
        "iters": iters,
        "cal_done": cal_done,
        "note": note or "",
    }
    with open(store.results_path(sha), "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")


# --- command: deploy --------------------------------------------------------
def cmd_deploy(store, args):
    sha = store.resolve(args.ref)
    if not sha:
        die("no such label or sha: %s" % args.ref)
    blob = store.blob_dir(sha)
    man = store.read_manifest(sha)

    # RE-VERIFY blob bytes before doing anything (provenance integrity).
    master = os.path.join(blob, MASTER_BIN)
    if not os.path.exists(master):
        die("blob %s missing %s" % (sha[:12], MASTER_BIN))
    actual = sha256_file(master)
    if actual != sha:
        die("INTEGRITY FAIL: blob %s master sha is %s, expected %s"
            % (sha[:12], actual, sha))

    bridge = BRIDGES.get(args.pair)
    if not bridge:
        die("unknown bridge '%s' (known: %s)" % (args.pair, ", ".join(BRIDGES)))

    # Provenance banner.
    info("=" * 64)
    info(" td-artifact DEPLOY — provenance banner")
    info("   pair          : %s" % args.pair)
    info("   label(s)      : %s" % (", ".join(store.tags_for(sha)) or "-"))
    info("   sha256(master): %s" % sha)
    info("   sha256(slave) : %s" % (man.get("sha256_slave") or "-"))
    info("   commit        : %s" % (man.get("commit") or "-"))
    info("   build_host    : %s" % (man.get("build_host") or "-"))
    info("   build_date    : %s" % (man.get("build_date") or "-"))
    info("   target        : %s" % (man.get("target") or "-"))
    info("   expected_lock : >= %s / 16" % (man.get("expected_lock_min")))
    info("   blob_dir      : %s" % blob)
    info("=" * 64)

    # Compose with the deploy-provenance-guard: drop a guard-compatible
    # sidecar manifest next to the master bin so deploy_pair.sh auto-discovers
    # it, AND pass --expect-sha256 explicitly (belt and braces).
    _write_sidecar_manifest(store, blob, MASTER_BIN, sha, man)
    if man.get("sha256_slave"):
        _write_sidecar_manifest(store, blob, SLAVE_BIN,
                                man["sha256_slave"], man, master_sha=sha)

    deploy_pair = args.deploy_pair or DEFAULT_DEPLOY_PAIR
    if not os.path.exists(deploy_pair):
        die("deploy_pair.sh not found at %s (set --deploy-pair)" % deploy_pair)

    plans = []
    for which in ("master", "slave"):
        b = bridge[which]
        expect = sha if which == "master" else man.get("sha256_slave")
        cmd = ["bash", deploy_pair, b["ip"], b["label"], b["role"], blob]
        if expect:
            cmd += ["--expect-sha256", expect]
        plans.append((which, b, cmd))

    if args.dry_run:
        info("[DRY-RUN] would invoke deploy_pair.sh as follows:")
        for which, b, cmd in plans:
            info("  %-6s %s (%s): %s" % (which, b["label"], b["role"],
                                          " ".join(cmd)))
        info("[DRY-RUN] no flashing performed.")
        return

    rc_all = 0
    for which, b, cmd in plans:
        info(">>> deploying %s -> %s (%s)" % (which, b["label"], b["role"]))
        rc = subprocess.call(cmd)
        if rc != 0:
            sys.stderr.write("td-artifact: deploy %s rc=%d\n" % (which, rc))
            rc_all = rc
    sys.exit(rc_all)


def _write_sidecar_manifest(store, blob, binname, sha, man, master_sha=None):
    """Write a deploy-provenance-guard-compatible <bin>.manifest.json sidecar."""
    sidecar = {
        "sha256": sha,
        "source_commit": man.get("commit", ""),
        "build_host": man.get("build_host", ""),
        "build_date": man.get("build_date", ""),
        "target": man.get("target", ""),
        "expected_lock_min": man.get("expected_lock_min"),
        "label": man.get("label", ""),
    }
    if master_sha:
        sidecar["sha256_master"] = master_sha
    path = os.path.join(blob, binname + ".manifest.json")
    with open(path, "w") as f:
        json.dump(sidecar, f, indent=2, sort_keys=True)
        f.write("\n")


# --- command: verify --------------------------------------------------------
def cmd_verify(store, args):
    sha = store.resolve(args.ref) if args.ref else None
    bridge = BRIDGES.get(args.pair)
    if not bridge:
        die("unknown bridge '%s'" % args.pair)
    if not sha:
        # default: use whichever blob the bridge's expected label points to,
        # but with no ref we require an explicit one.
        die("verify needs a <label|sha> ref to compare against")
    man = store.read_manifest(sha)
    expect_master = sha
    expect_slave = man.get("sha256_slave")

    info("=== td-artifact verify — pair %s vs blob %s ===" % (args.pair, sha[:12]))
    overall_ok = True
    for which in ("master", "slave"):
        b = bridge[which]
        # blob bytes -> compute MD5 too (board read-back uses md5sum)
        canon = MASTER_BIN if which == "master" else SLAVE_BIN
        local = os.path.join(store.blob_dir(sha), canon)
        if not os.path.exists(local):
            info("  %-6s %s: blob has no %s — skip" % (which, b["label"], canon))
            continue
        local_md5 = _md5_file(local)
        if args.dry_run:
            info("  [DRY-RUN] %-6s %s @ %s: would ssh via %s and md5sum "
                 "/lib/firmware/tidelink.bin; expect %s"
                 % (which, b["label"], b["ip"], SSH_HOP, local_md5))
            continue
        board_md5 = _board_md5(b["ip"])
        match = (board_md5 == local_md5)
        overall_ok = overall_ok and match
        info("  %-6s %s @ %s: board=%s expect=%s -> %s"
             % (which, b["label"], b["ip"], board_md5 or "?", local_md5,
                "MATCH" if match else "MISMATCH"))
    info("VERDICT: %s" % ("ALL MATCH" if overall_ok else "MISMATCH DETECTED"))
    if not args.dry_run:
        sys.exit(0 if overall_ok else 1)


def _md5_file(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _board_md5(board_ip):
    """Read back MD5 of /lib/firmware/tidelink.bin via ssh through the hop."""
    remote = ("sshpass -p %s ssh -o StrictHostKeyChecking=no "
              "-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "
              "xilinx@%s md5sum /lib/firmware/tidelink.bin"
              % (BOARD_PASS, board_ip))
    cmd = ["ssh", SSH_HOP, remote]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode()
        return out.split()[0] if out.strip() else None
    except subprocess.CalledProcessError:
        return None


# --- command: gc ------------------------------------------------------------
def cmd_gc(store, args):
    if not os.path.isdir(store.blobs):
        info("(no blobs dir)")
        return
    # Collect all sha referenced by a tag.
    live = set()
    for name in os.listdir(store.tags) if os.path.isdir(store.tags) else []:
        link = store.tag_link(name)
        if os.path.islink(link):
            live.add(os.path.basename(os.path.realpath(link)))
    orphans = []
    for d in sorted(os.listdir(store.blobs)):
        full = store.blob_dir(d)
        if not os.path.isdir(full) or d.endswith(".incoming"):
            continue
        if d not in live:
            orphans.append(d)
    if not orphans:
        info("gc: no orphan blobs.")
        return
    for d in orphans:
        if args.force:
            shutil.rmtree(store.blob_dir(d))
            info("gc: REMOVED orphan blob %s" % d[:12])
        else:
            info("gc: [dry-run] would remove orphan blob %s" % d[:12])
    if not args.force:
        info("gc: dry-run (default). Re-run with --force to delete %d blob(s)."
             % len(orphans))


# --- argument parsing -------------------------------------------------------
def build_parser():
    p = argparse.ArgumentParser(
        prog="td-artifact",
        description="TideLink content-addressed bitstream artifact store.")
    p.add_argument("--root", default=DEFAULT_ROOT,
                   help="store root (default %s or $TIDELINK_ARTIFACTS)" % DEFAULT_ROOT)
    # required=True via attribute for Python 3.6 compat (board hosts run 3.6).
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    a = sub.add_parser("add", help="add (content-address) + label a bitstream")
    a.add_argument("--master", required=True, help="master tidelink.bin")
    a.add_argument("--slave", help="slave tidelink-flip.bin (optional, paired)")
    a.add_argument("--master-hwh", help="master tidelink.hwh")
    a.add_argument("--slave-hwh", help="slave tidelink-flip.hwh")
    a.add_argument("--label", required=True, help="human label (tag)")
    a.add_argument("--commit", help="source commit sha")
    a.add_argument("--build-host", help="build host")
    a.add_argument("--build-date", help="build date (YYYY-MM-DD)")
    a.add_argument("--target", help="target (default pynq-z2-pair)")
    a.add_argument("--expected-lock-min", type=int, default=0,
                   help="minimum acceptable lanes locked /16")
    a.add_argument("--note", help="optional seed note (-> results.jsonl)")
    a.set_defaults(func=cmd_add)

    li = sub.add_parser("list", help="list all labelled artifacts")
    li.set_defaults(func=cmd_list)

    sh = sub.add_parser("show", help="show manifest + results for a label/sha")
    sh.add_argument("ref")
    sh.set_defaults(func=cmd_show)

    dp = sub.add_parser("deploy", help="deploy a label/sha to a bridge")
    dp.add_argument("ref")
    dp.add_argument("--pair", required=True, help="bridge (e.g. bridge1)")
    dp.add_argument("--deploy-pair", help="path to deploy_pair.sh")
    dp.add_argument("--dry-run", action="store_true",
                    help="print the deploy plan, do not flash")
    dp.set_defaults(func=cmd_deploy)

    rc = sub.add_parser("record", help="append a lock result to a blob")
    rc.add_argument("ref")
    rc.add_argument("--lock-best", type=int, required=True)
    rc.add_argument("--lock-mean", type=float, required=True)
    rc.add_argument("--iters", type=int, required=True)
    rc.add_argument("--cal-done", type=int, choices=(0, 1))
    rc.add_argument("--pair", default="bridge1")
    rc.add_argument("--note")
    rc.set_defaults(func=cmd_record)

    vf = sub.add_parser("verify", help="read-back board MD5 vs expected blob")
    vf.add_argument("ref", nargs="?", help="label/sha to compare against")
    vf.add_argument("--pair", required=True)
    vf.add_argument("--dry-run", action="store_true")
    vf.set_defaults(func=cmd_verify)

    gc = sub.add_parser("gc", help="remove untagged (orphan) blobs")
    gc.add_argument("--force", action="store_true",
                    help="actually delete (default is dry-run)")
    gc.set_defaults(func=cmd_gc)

    ut = sub.add_parser("untag", help="remove a label (blob is kept; gc to reap)")
    ut.add_argument("label")
    ut.set_defaults(func=cmd_untag)

    return p


# --- command: untag ---------------------------------------------------------
def cmd_untag(store, args):
    link = store.tag_link(args.label)
    if not (os.path.islink(link) or os.path.exists(link)):
        die("no such label: %s" % args.label)
    os.remove(link)
    idx = store.read_index()
    if args.label in idx:
        del idx[args.label]
        store._write_index(idx)
    info("removed label '%s' (blob retained; run gc to reap if now orphaned)"
         % args.label)


def main(argv=None):
    args = build_parser().parse_args(argv)
    store = Store(args.root)
    args.func(store, args)


if __name__ == "__main__":
    main()
