#!/usr/bin/env python3
"""cov_publish.py - put a coverage artifact into the store. DRY RUN BY DEFAULT.

    python3 scripts/coverage/cov_publish.py --artifact imp/coverage/<run_tag>
    python3 scripts/coverage/cov_publish.py --artifact ... --publish
    python3 scripts/coverage/cov_publish.py --artifact ... --promote-baseline
    python3 scripts/coverage/cov_publish.py --selftest

NOTHING IS UPLOADED WITHOUT `--publish`. The default prints the exact PUTs,
paths and properties and exits 0. A publisher whose rehearsal mode acts is not
a rehearsal mode -- an earlier retention selftest in this programme ran a real
`--destroy` sweep across a production repo and deleted a real candidate.

WHERE IT PUTS THINGS
--------------------
    verif-coverage   every gate run. Swept at 120 days, newest 10 always kept.
    verif-baseline   the reference a delta is measured against. PROTECTED --
                     no retention code path can produce it as a target.

Path shape is NOT free. `artifactory_retention.py` derives a run tag as
`path.split("/")[2]` and a delete prefix as `"/".join(path.split("/")[:2])`, so
the layout must be exactly

    <project>/<block>/<run_tag>/<kind>/<file>
    tidelink/simgate/covrun-20260826T0013Z-5994cce7/merged/cov_merged.vdb.tar.zst

A layout one level shallower makes the sweep derive the wrong tag; a layout one
level deeper makes it derive the wrong DELETE TARGET, which is a subtree
removal at the wrong node. This is checked here, at publish time, rather than
discovered by a sweep.

PROPERTIES ARE SET AT DEPLOY TIME OR NOT AT ALL
-----------------------------------------------
Measured on this instance and recorded in artifactory.py: the retro-fit
`PUT /api/storage/<repo>/<path>?properties=` endpoint is Artifactory Pro only
and returns an errors body. An artefact already in the store CANNOT acquire a
property without being re-deployed -- which is exactly why four hand-published
ASIC candidates carry no identity at all and needed a whole backfill program.
So every property this artifact will ever need goes on the deploy URL as a
matrix parameter, including `build.name`/`build.number`, without which the
promotion refuses with `Unable to find artifacts of build`.

PROMOTION -- the mechanism that is built and has never been used
----------------------------------------------------------------
`artifactory.py promote` exists, is selftested, copies rather than moves, and
`asic-release` is deliberately empty because there is no release candidate yet.
A coverage baseline is precisely the artifact that mechanism was written for:
"the one every other run is compared against" is a promotion, not a filename.
So the baseline is not a path convention and not a symlink; it is a copy into a
protected repo, made by the promote call, with the build record as the join.

REFUSALS. This program will not:
  * publish an artifact whose manifest is missing or unparseable;
  * publish when a digest in the manifest does not match the bytes on disk;
  * PROMOTE an artifact whose manifest says promotable:false -- which covers a
    dirty tree, any UNVERIFIED identity field, and any partial merge.
It WILL publish a non-promotable artifact. Evidence from an imperfect run is
still evidence, and this programme's recurring failure is instruments that
existed as a single untracked file on one host, not instruments that were
labelled too honestly.

Copyright (C) 2026, SoC Labs (www.soclabs.org)
"""

import argparse
import hashlib
import json
import os
import sys

CANDIDATE_REPO = "verif-coverage"
BASELINE_REPO = "verif-baseline"
PROJECT = "tidelink"
BLOCK = "simgate"
UNV = "UNVERIFIED:"


def is_unv(v):
    return isinstance(v, str) and v.startswith(UNV)


def find_client():
    """Locate the project's Artifactory client. It lives in the ethernet
    chiplet tree, not here, and there is deliberately no vendored copy: two
    copies of the code that talks to a store is how one of them keeps a trap
    the other fixed."""
    cands = [os.environ.get("ASIC_CI_SCRIPTS"),
             os.path.expanduser("~/SoCLabs/nanosoc-ethernet-chiplet/scripts/ci"),
             "../nanosoc-ethernet-chiplet/scripts/ci"]
    for c in cands:
        if c and os.path.exists(os.path.join(c, "artifactory.py")):
            sys.path.insert(0, os.path.abspath(c))
            try:
                import artifactory  # noqa
                return artifactory
            except ImportError:
                pass
    return None


def sha256_of(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for c in iter(lambda: fh.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def load_manifest(art_dir):
    p = os.path.join(art_dir, "manifest", "cov_manifest.json")
    if not os.path.exists(p):
        sys.exit("cov_publish: no manifest at %s. An artifact without an "
                 "identity is not publishable here -- that is the whole point "
                 "of the repository." % p)
    try:
        return json.load(open(p))
    except ValueError as e:
        sys.exit("cov_publish: manifest is unparseable (%s)" % e)


def check_layout(rel):
    """The retention-compatibility check, run before anything is uploaded."""
    parts = rel.split("/")
    if len(parts) != 5:
        sys.exit("cov_publish: path %r has %d segments, must have exactly 5 "
                 "(<project>/<block>/<run_tag>/<kind>/<file>). "
                 "artifactory_retention.py reads the run tag at index 2 and the "
                 "delete prefix as indices 0..1; a different depth makes a "
                 "sweep delete the wrong subtree." % (rel, len(parts)))
    return parts[2]


def verify_digests(art_dir, man):
    """Re-hash every file the manifest claims. A manifest that describes bytes
    other than the ones being uploaded is the [verdict read the wrong stream]
    failure, and it is cheap to make impossible."""
    bad = []
    files = man.get("digests", {}).get("files") or {}
    if not files:
        sys.exit("cov_publish: manifest lists no file digests -- refusing to "
                 "publish bytes nothing has measured")
    for rel, d in sorted(files.items()):
        p = os.path.join(art_dir, rel)
        if not os.path.exists(p):
            bad.append("%s: listed in the manifest, absent on disk" % rel)
            continue
        got = sha256_of(p)
        if got != d.get("sha256"):
            bad.append("%s: manifest says %s, bytes are %s"
                       % (rel, str(d.get("sha256"))[:16], got[:16]))
    on_disk = set()
    for sub in ("merged", "report", "unexercised", "manifest"):
        d = os.path.join(art_dir, sub)
        if os.path.isdir(d):
            for n in os.listdir(d):
                if os.path.isfile(os.path.join(d, n)) and n != "cov_manifest.json":
                    on_disk.add("%s/%s" % (sub, n))
    extra = on_disk - set(files)
    if extra:
        bad.append("files on disk that the manifest does not describe: %s"
                   % ", ".join(sorted(extra)))
    if bad:
        sys.exit("cov_publish: REFUSING to publish.\n  " + "\n  ".join(bad))


def properties_for(man, rel):
    """Every property this artefact will ever carry, because it can never
    acquire another without being re-deployed."""
    ident = man.get("identity", {})
    dig = man.get("digests", {})
    run_tag = man["run_tag"]
    props = {
        # the join that makes promotion possible at all
        "build.name": "tidelink-coverage",
        "build.number": run_tag,
        # identity -- UNVERIFIED values are stored AS UNVERIFIED, never dropped
        # and never defaulted. A missing property and a property reading
        # "UNVERIFIED:x" are different facts and the store must hold the second.
        "coverage.commit": ident.get("source_commit", UNV + "absent"),
        "coverage.tree_state": ident.get("tree_state", UNV + "absent"),
        "coverage.closure_id": dig.get("input_closure_id", UNV + "absent"),
        "coverage.id": dig.get("coverage_id", UNV + "absent"),
        "coverage.scope_sha256": ident.get("scope_sha256", UNV + "absent"),
        "coverage.completeness": man.get("completeness", UNV + "absent"),
        "coverage.promotable": str(man.get("verdict", {})
                                   .get("promotable", False)).lower(),
        "coverage.schema": man.get("schema", "?"),
    }
    d = (man.get("digests", {}).get("files") or {}).get(rel)
    if d:
        # The store indexes the md5 OF THE ARCHIVE. Anyone citing this artifact
        # by content cites the sha256 of the uncompressed part, so carry it as a
        # property -- the same reason `pnr.raw_md5` exists for streams.
        props["coverage.file_sha256"] = d["sha256"]
    return props


def plan(art_dir, man, repo):
    run_tag = man["run_tag"]
    items = []
    for rel in sorted((man.get("digests", {}).get("files") or {})):
        sub, name = rel.split("/", 1)
        path = "%s/%s/%s/%s/%s" % (PROJECT, BLOCK, run_tag, sub, name)
        check_layout(path)
        items.append((os.path.join(art_dir, rel), repo, path,
                      properties_for(man, rel)))
    # the manifest itself, last, so a half-published run has no identity file
    # standing over it claiming completeness
    mrel = "manifest/cov_manifest.json"
    path = "%s/%s/%s/manifest/cov_manifest.json" % (PROJECT, BLOCK, run_tag)
    check_layout(path)
    items.append((os.path.join(art_dir, mrel), repo, path,
                  properties_for(man, mrel)))
    return items


def render_plan(items, man):
    L = ["cov_publish: DRY RUN -- nothing has been uploaded.", ""]
    total = 0
    for local, repo, path, props in items:
        size = os.path.getsize(local)
        total += size
        L.append("  PUT %s/%s   (%.1f KB)" % (repo, path, size / 1024.0))
    L.append("")
    L.append("  %d file(s), %.2f MB total" % (len(items), total / 1e6))
    L.append("")
    L.append("  properties on every file (set at DEPLOY time; they cannot be "
             "added later on this instance):")
    for k, v in sorted(items[0][3].items()):
        L.append("    %-26s %s" % (k, v))
    L.append("")
    v = man.get("verdict", {})
    L.append("  promotable: %s" % v.get("promotable"))
    for r in v.get("reasons", []):
        L.append("    - %s" % r)
    for f in v.get("unverified_fields", [])[:12]:
        L.append("    - UNVERIFIED: %s" % f)
    return "\n".join(L)


def do_publish(client, items, man, base):
    if client is None:
        sys.exit("cov_publish: --publish needs the project's Artifactory "
                 "client (scripts/ci/artifactory.py from the ethernet-chiplet "
                 "tree). Set ASIC_CI_SCRIPTS to its directory. Refusing to "
                 "reimplement the store protocol here: that module carries "
                 "measured traps (the Pro-only listing endpoint, AQL include() "
                 "dedup, ?properties as a false existence test) that a second "
                 "copy would not.")
    deployed = []
    for local, repo, path, props in items:
        client.deploy(local, repo, path, props, base)   # verifies read-back
        deployed.append((repo, path))
        print("  PUT %s/%s ok" % (repo, path))

    # build record: what makes `promote` possible, and what makes two runs
    # subtract.
    mods = [{"id": "tidelink-coverage",
             "artifacts": [client.artifact_entry(local, name=os.path.basename(p))
                           for local, _r, p, _pr in items]}]
    ident = man.get("identity", {})
    vcs = None
    if not is_unv(ident.get("source_commit")):
        vcs = [{"revision": ident["source_commit"],
                "branch": ident.get("branch") or ""}]
    client.build_publish(
        "tidelink-coverage", man["run_tag"], mods,
        properties={"coverage.id": man.get("digests", {}).get("coverage_id"),
                    "coverage.closure_id": man.get("digests", {})
                    .get("input_closure_id"),
                    "coverage.completeness": man.get("completeness"),
                    "coverage.promotable": str(man.get("verdict", {})
                                               .get("promotable", False))},
        vcs=vcs, base=base)
    print("  build record tidelink-coverage/%s published" % man["run_tag"])
    return deployed


def do_promote(client, man, base, dry):
    v = man.get("verdict", {})
    if not v.get("promotable"):
        sys.exit(
            "cov_publish: REFUSING to promote %s to %s.\n"
            "  promotable=false. Reasons: %s\n"
            "  A baseline is the thing every future run is measured against. An\n"
            "  artifact that could not identify its own inputs cannot be that.\n"
            "  Publish it as a candidate (it already is), fix the identity, and\n"
            "  promote a later run."
            % (man["run_tag"], BASELINE_REPO,
               "; ".join(v.get("reasons", []) or ["(none recorded)"])))
    if client is None:
        sys.exit("cov_publish: --promote-baseline needs the Artifactory client "
                 "(see --publish)")
    client.promote("tidelink-coverage", man["run_tag"], BASELINE_REPO,
                   status="BASELINE",
                   comment="coverage baseline for %s"
                           % man.get("identity", {}).get("source_commit", "?"),
                   dry_run=dry, base=base)
    print("  promote %s -> %s %s"
          % (man["run_tag"], BASELINE_REPO, "(rehearsal)" if dry else "DONE"))


# --------------------------------------------------------------------------

def selftest():
    """Offline. Proves the refusals fire, without a store and without a
    simulator."""
    import tempfile
    ok = True

    def say(what, cond):
        nonlocal ok
        print("  %-62s %s" % (what, "ok" if cond else "FAIL"))
        ok = ok and cond

    print("cov_publish selftest (offline, no store contacted)")

    # layout guard
    for bad in ("tidelink/covrun-x/merged/f", "a/b/c/d/e/f"):
        try:
            check_layout(bad)
            say("layout %r refused" % bad, False)
        except SystemExit:
            say("layout %r refused" % bad, True)
    try:
        t = check_layout("tidelink/simgate/covrun-1/merged/f.zst")
        say("good layout accepted, tag='covrun-1'", t == "covrun-1")
    except SystemExit:
        say("good layout accepted", False)

    # digest guard
    d = tempfile.mkdtemp(prefix="covpub-")
    os.makedirs(os.path.join(d, "merged"))
    os.makedirs(os.path.join(d, "manifest"))
    with open(os.path.join(d, "merged", "x.zst"), "wb") as fh:
        fh.write(b"hello")
    man = {"run_tag": "covrun-1", "identity": {}, "completeness": "complete",
           "verdict": {"promotable": True},
           "digests": {"files": {"merged/x.zst": {"sha256": "0" * 64,
                                                  "bytes": 5}}}}
    try:
        verify_digests(d, man)
        say("a wrong sha256 in the manifest is refused", False)
    except SystemExit:
        say("a wrong sha256 in the manifest is refused", True)

    man["digests"]["files"]["merged/x.zst"]["sha256"] = \
        sha256_of(os.path.join(d, "merged", "x.zst"))
    try:
        verify_digests(d, man)
        say("matching digests accepted", True)
    except SystemExit:
        say("matching digests accepted", False)

    with open(os.path.join(d, "merged", "stowaway.bin"), "wb") as fh:
        fh.write(b"?")
    try:
        verify_digests(d, man)
        say("an undescribed file in the tree is refused", False)
    except SystemExit:
        say("an undescribed file in the tree is refused", True)
    os.unlink(os.path.join(d, "merged", "stowaway.bin"))

    # promotion guard
    man2 = dict(man)
    man2["verdict"] = {"promotable": False, "reasons": ["tree_state=dirty"]}
    try:
        do_promote(None, man2, "http://x", True)
        say("promote refuses a non-promotable manifest", False)
    except SystemExit as e:
        say("promote refuses a non-promotable manifest",
            "REFUSING to promote" in str(e))

    # properties always carry an identity, even a bad one
    p = properties_for({"run_tag": "covrun-1", "identity": {}, "digests": {}},
                       "merged/x.zst")
    say("absent identity is stored AS UNVERIFIED, not dropped",
        p["coverage.commit"].startswith(UNV)
        and p["coverage.tree_state"].startswith(UNV))
    say("build.name/build.number present (promotion join)",
        p.get("build.name") and p.get("build.number"))

    print("cov_publish selftest: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--artifact", help="imp/coverage/<run_tag>")
    ap.add_argument("--repo", default=CANDIDATE_REPO)
    ap.add_argument("--base", default=os.environ.get("ASIC_ARTIFACT_BASE"))
    ap.add_argument("--publish", action="store_true",
                    help="ACTUALLY upload. Needs ~/.netrc credentials.")
    ap.add_argument("--promote-baseline", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not a.artifact:
        ap.error("--artifact is required (or --selftest)")

    man = load_manifest(a.artifact)
    verify_digests(a.artifact, man)
    items = plan(a.artifact, man, a.repo)

    if not a.publish and not a.promote_baseline:
        print(render_plan(items, man))
        print("\n  Add --publish to upload. Nothing was contacted.")
        return 0

    client = find_client()
    base = a.base or (client.DEFAULT_BASE if client else None)
    if not base:
        sys.exit("cov_publish: no ASIC_ARTIFACT_BASE and no client default")
    if a.publish:
        do_publish(client, items, man, base)
    if a.promote_baseline:
        do_promote(client, man, base, dry=not a.publish)
    return 0


if __name__ == "__main__":
    sys.exit(main())
