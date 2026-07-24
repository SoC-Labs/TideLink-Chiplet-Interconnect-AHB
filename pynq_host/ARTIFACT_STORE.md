# TideLink Bitstream Artifact Store (`td-artifact`)

A content-addressed store + CLI for TideLink FPGA bitstreams. It replaces the
error-prone "scp the `.bin` into a shared, volatile `/tmp/tidelink_deploy/` and
run `deploy_pair.sh`" workflow that caused **Bug #32**: a known-bad 0/16 May-6
phase-v2 build was left in the shared staging dir by a population test and got
captured into the v1 release bundle. With this store you **deploy by label, not
by path**, the bytes are content-addressed and immutable, and a known-bad build
is permanently labelled so it can never be silently mistaken for a good one.

> Hard evidence of the mixup: the v1 release `tidelink.bin` SHA256
> (`606e1648…cd2d`, MD5 `188ebdd8`) is **byte-identical** to the phase-v2
> known-bad master now labelled `phase-v2-KNOWN-BAD`. The morning 14.40/16 build
> is a *different* blob (`40f6477c…`), now labelled `morning-v1`.

## Store layout

Root: `~/tidelink-artifacts/` by default (override with `--root` or
`$TIDELINK_ARTIFACTS`). Lives on the deploy-origin host (**mapstone-dev**), also
usable on farm-host-b.

```
tidelink-artifacts/
  index.json                      # registry: {label: {sha256, commit, build_host, build_date, target, blob_dir}}
  blobs/<sha256>/                 # IMMUTABLE — write-once, never overwritten
    tidelink.bin                  # master (die_a / non-flip)
    tidelink.hwh
    tidelink-flip.bin             # slave (die_b / flip) — optional, paired
    tidelink-flip.hwh
    manifest.json                 # full provenance (superset of deploy-guard sidecar)
    results.jsonl                 # append-only lock-test history
  tags/<label> -> ../blobs/<sha256>   # mutable symlink; human labels -> immutable blobs
```

### Deterministic hashing (the key choice)

For a **paired** artifact the blob's **primary key = `sha256(master_bytes)`**
(`tidelink.bin`). The slave (`tidelink-flip.bin`) hash is tracked in the
manifest as `sha256_slave` but does **not** participate in the address.

Rationale: die_a/master is the canonical, role-defining bitstream; the flip is
mechanically derived (mirrored RPi-GPIO pin map) from the *same* build, so the
master uniquely identifies the build. This keeps the blob address stable and
human-traceable to "the build", and makes re-`add` of identical master bytes a
pure no-op + retag (idempotent).

### `manifest.json` schema

```json
{
  "sha256": "<master sha>",          "sha256_master": "<master sha>",
  "sha256_slave": "<slave sha|null>",
  "commit": "8bc6051",               "source_commit": "8bc6051",
  "build_host": "farm-host-a",          "build_date": "2026-05-20",
  "target": "pynq-z2-pair",          "label": "morning-v1",
  "expected_lock_min": 14,           "created_at": "2026-05-22T…Z",
  "files": ["tidelink.bin", "tidelink.hwh", "tidelink-flip.bin", "tidelink-flip.hwh"]
}
```

`source_commit` / `expected_lock_min` / `label` / `target` / `build_host` /
`build_date` / `sha256` are a **superset of the deploy-provenance-guard's
sidecar schema** (`<bin>.manifest.json`), so the two compose without conflict.

## CLI commands

Run `pynq_host/td_artifact.py …` or the wrapper `pynq_host/scripts/td-artifact …`.

| Command | Purpose |
|---|---|
| `add --master <bin> [--slave <flip>] [--master-hwh <h>] [--slave-hwh <h>] --label <L> [--commit <sha>] [--build-host <h>] [--build-date <d>] [--target <t>] [--expected-lock-min <n>] [--note <s>]` | content-address + label a bitstream; write-once blob, idempotent re-add, refuses to clobber |
| `list` | table: label, sha(12), commit, target, #results, best lock, mean lock |
| `show <label\|sha>` | full manifest + `results.jsonl` history |
| `deploy <label\|sha> --pair <bridge> [--dry-run] [--deploy-pair <path>]` | resolve → re-verify sha256 → provenance banner → invoke `deploy_pair.sh` with `--expect-sha256` |
| `record <label\|sha> --lock-best <n> --lock-mean <f> --iters <n> [--cal-done 0\|1] [--pair <b>] [--note <s>]` | append a lock result to the blob's `results.jsonl` |
| `verify [<label\|sha>] --pair <bridge> [--dry-run]` | read back board `/lib/firmware/tidelink.bin` MD5 (ssh via mapstone-dev) vs expected blob |
| `gc [--force]` | remove untagged (orphan) blobs; **dry-run by default** |
| `untag <label>` | remove a label (blob retained; `gc` to reap) |

## Immutability guarantees

- `blobs/<sha>/` is **write-once**. `add` of identical content re-tags only and
  never rewrites bytes (verified: blob sha + mtime unchanged across a re-add).
- Adding *different* content under a *second* label creates that content's own
  distinct blob and **cannot touch any other blob**.
- A label (tag) is mutable and can be repointed; the blob content it pointed at
  is unaffected.
- `add` refuses to overwrite — a sha-collision with mismatched bytes aborts
  loudly (blob-corruption guard).

## Integration with `deploy_pair.sh` (deploy-provenance-guard)

`td-artifact deploy` does **not** reimplement flashing. It:

1. Resolves the label/sha to its immutable `blobs/<sha>/` dir.
2. **Re-verifies** the blob's master sha256 (integrity gate).
3. Prints a provenance banner (label, both shas, commit, build host/date,
   target, expected lock).
4. Writes guard-compatible sidecar manifests (`tidelink.bin.manifest.json`,
   `tidelink-flip.bin.manifest.json`) next to the bytes so `deploy_pair.sh`
   auto-discovers them.
5. Invokes `deploy_pair.sh <ip> <label> <role> <blob_dir> --expect-sha256 <sha>`
   for master (die_a) then slave (die_b). The guard aborts on any mismatch.

The `blob_dir` is passed as `deploy_pair.sh`'s `ARTEFACTS_DIR` positional, so
the canonical `tidelink.bin` / `tidelink-flip.bin` names line up with its
existing role→bitstream selection.

Boards are reached via the **mapstone-dev** ProxyJump routing. `bridge1` =
`pynq_z2_02` master (die_a, 192.168.4.101) + `pynq_z2_03` slave (die_b,
192.168.6.101).

## Operator workflow

**After a build — register it:**
```bash
td-artifact add \
  --master imp/fpga/output/pynq-z2-pair-all/tidelink.bin \
  --slave  imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin \
  --master-hwh …/tidelink.hwh --slave-hwh …/tidelink.hwh \
  --label nightly-$(date +%m%d) --commit "$(git rev-parse --short HEAD)" \
  --build-host "$(hostname)" --target pynq-z2-pair --expected-lock-min 12
```

**Deploy by label (never by path):**
```bash
td-artifact deploy morning-v1 --pair bridge1            # dry-run first if unsure
td-artifact deploy morning-v1 --pair bridge1 --dry-run  # print plan, no flash
```

**Confirm what is actually on the boards:**
```bash
td-artifact verify morning-v1 --pair bridge1            # board MD5 vs blob
```

**Record a lock test:**
```bash
td-artifact record morning-v1 --lock-best 14 --lock-mean 14.40 \
  --iters 10 --cal-done 1 --note "n10 re-test"
```

**See the catalogue / clean up:**
```bash
td-artifact list
td-artifact show phase-v2-KNOWN-BAD
td-artifact gc            # dry-run; --force to delete orphans
```

## Seeded artifacts (on `mapstone-dev:~/tidelink-artifacts/`)

| Label | sha(12) | best/mean lock | Note |
|---|---|---|---|
| `morning-v1` | `40f6477ca4f7` | 14 / 14.40 | best-known morning build (commit 8bc6051) |
| `phase-v2-KNOWN-BAD` | `606e1648ff84` | 0 / 0.00 | pre-IDELAY 0/16 — **DO NOT SHIP** (= v1 release bin) |
| `tl_v7` | `3cedd3ba42cc` | 13 / 7.60 | rescue artifact (2026-05-18) |
| `tl_v7s` | `e92d65968536` | 11 / 6.10 | rescue artifact (2026-05-18) |
```
```
A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license. David Mapstone (d.a.mapstone@soton.ac.uk). Copyright (C) 2026, SoC Labs
(www.soclabs.org).
