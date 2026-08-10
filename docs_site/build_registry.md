# Build Registry

`docs/BUILD_REGISTRY.yaml` records **which bitstream ran on which board**, built
from which commit, with which parameters, and what was actually proven. It is the
companion to `docs/BUG_REGISTRY.yaml`: that file tracks defects, this one tracks
the bytes they were seen in.

Render it with the same generator as the bug registry:

```bash
python3 scripts/gen_bug_registry_html.py     # -> docs/bug_registry.html + docs/build_registry.html
python3 scripts/gen_bug_registry_html.py --check    # CI staleness check, both pages
```

The build registry is optional to the generator — if the YAML is absent the bug
page is written exactly as before.

## Why it exists

**The failure it prevents: shipping a build that differs from the validated one
by a parameter nobody can see.** Two concrete cases, both from this repo:

:::{danger}
**Case 1 — the same target name, two different netlists.**
`fpga/targets/kr260-pair-onchip/tidelink_design.tcl` sets
`CONFIG.DEBUG_UNLOCK_DEFAULT {1'b0}` at commit `9cca6fe` (the
hardware-validated build) and `{1'b1}` at `9eaafb7` (this branch's HEAD).

```bash
git diff 9eaafb7 9cca6fe -- fpga/targets/kr260-pair-onchip/tidelink_design.tcl
# 4 changed lines, all parameter values, on both dies
```

At `1'b1`, `tidelink_top.sv:2511` drives
`.apb_debug_unlock_i (DEBUG_UNLOCK_DEFAULT ? 1'b1 : apb_debug_unlock_i)` — the
top-level pin is **discarded** and the BD's debug-unlock GPIO strap becomes
decorative. That strap is what enables external-APB *writes* to Wlink on a slave
die (`axi_chiplet_controller.sv:3708`), and driving it wrong has already stuck
both dies at `fcsm=2` on this rig. Rebuilding "kr260-pair-onchip" from this
branch therefore produces a **different netlist** from the validated one — and
the two builds' manifests differ only in the commit field.
:::

:::{danger}
**Case 2 — the 2026-08-09 all-zeros hunt.** The cross-lane deskew anchor
defaults to `1'b0` and, on the byte-exact reference vehicle, is forced to `1'b1`
by the **eth-chiplet SoC RTL** in the sibling `nanosoc-ethernet-chiplet` repo
(recorded in `docs/BUILD_REGISTRY.yaml:1280` as
`nanosoc_eth_chiplet.sv:760`). Every standalone `kr260-pair` / `pynq-z2`
bitstream therefore shipped the anchor **off** while the reference vehicle
shipped it **on**. Nothing revealed this: not the manifest, not the build log,
and not `fpga/scripts/check_wrapper_params.sh`, which validates the wrapper
*default* rather than the value the target tcl bakes into the netlist (it prints
`OK USE_IDELAY = 1'b1` on KR260 builds that set `CONFIG.USE_IDELAY {0}`).
:::

:::{warning}
**Name check.** The registry entries for that hunt call the knob
`AUTO_ANCHOR_EN`, because that is the identifier used in the sibling
eth-chiplet RTL. **No such parameter exists in this repository** — a grep of
`.v/.sv/.tcl/.sh/.py` returns zero hits, and the only occurrences anywhere in
the tree are the `docs/BUILD_REGISTRY.yaml` prose above. The TideLink name for
the same knob is **`EPOCH_ANCHOR_EN`**; see
{doc}`parameters` [§6.1](parameters.md#61-epoch_anchor_en-and-the-auto_anchor_en-naming-correction).
A script or ticket carrying `AUTO_ANCHOR_EN` against *this* tree will silently
do nothing.
:::

## What already works, and what it misses

TideLink emits a build manifest from **inside** the build
(`tl_write_manifest`, `fpga/scripts/build_provenance.tcl:253`, called from
`fpga/build_design.tcl:676` right after the `.bit` is written), so it cannot be
forgotten. That is the good half.

| Recorded by `tidelink-build-manifest/1` | Not recorded — this registry's job |
|---|---|
| `sha256` of the `.bit` | any IP parameter (`CONFIG.*` on the BD cells) |
| `source_commit`, `git_dirty` | the dirty diff itself (only the six characters `-dirty` survive) |
| `phy_marker` (V1/V2), `flist` | build-time env: `TL_TRAIN_ENTRY_FALLBACK`, `TL_EPOCH_ANCHOR_EN`, `TIDELINK_FPGA_PTP`, `TD_AUTO_LANE_MASK_E4`, `FPGA_ALLOW_CRITICAL_WARNINGS` |
| two submodule pins (`tidelink-phy`, `tidelink-gpio-phy`) | `deps/axi-chiplet-controller` (a declared submodule) and `deps/xhb500` (not a submodule — versioned by nothing) |
| `usr_access`, `target`, `build_host`, `build_date`, `label` | Vivado version, timing closure, boards, any test result |

`phy_marker` is the one field that already works as intended: it is what caught
the 2026-08-09 `kr260-pair-nptp` rebuild silently falling back to the **V1** PHY
flist while the reference vehicle is V2.

### Manifest traps

:::{warning}
**`usr_access` is not a discriminator.** `build_provenance.tcl:275` strips
`-dirty` before deriving the value, so a dirty manifest still carries a
plausible-looking hex string that was **never stamped** into the bitstream
(`build_design.tcl:637-643` only exports `TIDELINK_GIT_USR_ACCESS` on a clean
tree, printing *"USR_ACCESS: tree dirty/unknown — NOT stamping a commit SHA"*).
Only `git_dirty: false` proves the stamp is real.
:::

| Trap | Where |
|---|---|
| The deploy sidecar **drops the dirty flag**: `tidelink_manifest.json` says `9eaafb7152f…-dirty`, the sibling `tidelink.bin.manifest.json` that travels to the board says `9eaafb7` | `imp/fpga/output/pynq-z2-pair-all/` |
| `.bit` and `.bin` in one directory can be from **different builds** (mtimes 2026-07-24 and 2026-07-29), and the `.bin` — what actually gets flashed — has no manifest | `imp/fpga/output/kr260-pair-onchip/` |
| The output directory label is **typed, not derived**: `…prefixG-855096a/` contains a manifest whose `source_commit` is `34b006cb…` | eth-chiplet tree |
| Two labels, two recorded commits, **one blob**: `tl-trainfb-8lane` (`76202ed-dirty`) and `tl-nopark-8lane` (`a5df514`) both record `.bin` sha256 `777bf435…` | `~/tidelink_artefacts/` |

## Schema

One YAML file, one entry per built bitstream. Only the shape is shown; read
`docs/BUILD_REGISTRY.yaml` for the populated version, whose per-line comments
carry the reason each `unknown` is unknown.

```yaml
- id: BLD-2026-08-08-kr260-onchip     # BLD-<date>-<vehicle>
  date: 2026-08-08
  status: hw_validated                # built | deployed | hw_validated | superseded | known_bad
  provenance: full                    # full | partial | sha_unrecoverable
  source:
    git_sha: 9cca6fe276330743f3e8a7d26760305dcb6e8cde   # full 40, never abbreviated
    git_dirty: false
    branch: integ/tidelink-consolidated-2026-08-07
    tag: null
    worktree: /home/dam1n19/SoCLabs/tidelink-consolidated
    reachable_here: true              # git cat-file -t <sha> succeeds in this repo
    fetchable: true                   # an ancestor of a pushed remote branch
  submodule_pins:                     # enumerate; deps/xhb500 is not a submodule
    deps/tidelink-phy: 5c76e764…
    deps/tidelink-gpio-phy: 6ee8418b…
    deps/axi-chiplet-controller: unknown  # not recorded at build time
  build:
    fpga_target: kr260-pair-onchip    # or asic_flow: for a DC/FC run
    flist: tidelink_fpga_v2.flist
    phy: V2
    tool_version: unknown             # not recorded at build time
    build_host: srv03335
    build_date: 2026-08-08T11:15:47Z
  key_parameters:                     # the values baked into THIS netlist
    recorded: none                    # manifest schema/1 carries no parameter map
    inferred_from: "fpga/targets/…/tidelink_design.tcl @9cca6fe (an inference)"
    values: {NEGO_CFG_RESET: "7'b1100001", DEBUG_UNLOCK_DEFAULT: "1'b0", …}
  build_env: {TIDELINK_PHY_V2: "1", TL_EPOCH_ANCHOR_EN: unset, …}
  bitstream:
    bit_sha256: fa9d0fe2…
    bin_sha256: unknown
    usr_access: "0xcb6e8cde"
    usr_access_stamped: true          # false whenever git_dirty is true
    retained: true
    path: …/imp/fpga/output/kr260-pair-onchip/tidelink.bit
  boards: [kr260-01]
  rig: onchip-single-board
  validation:
    proven:   ["4/4 fresh PORs, SOAK 500/500 byte-exact each"]
    claimed:  ["1000/1000 byte-exact on the first POR"]
    evidence_class: retained_artifact # retained_artifact | commit_message | tag_body | memory_note | none
    evidence: ["…/onchip_landrate.log"]
    caveats:  ["the log stamps tip=9cca6fe but records no bitstream hash"]
  known_bad: ["does not exercise the two-board ribbon eye (TL-001, TL-009)"]
  supersedes: BLD-2026-07-24-kr260-onchip
  signoff: {approved: false, approved_by: null, approved_date: null}
```

### The two rules that make it worth keeping

1. **`unknown` is written, never guessed.** A field that was not recorded at
   build time is `unknown  # not recorded at build time`. An honest gap is what
   makes the next gap visible; a back-filled guess is indistinguishable from a
   record.
2. **`hw_validated` requires a retained artefact.** A result that survives only
   in a commit message, a tag body or a handover document is recorded under
   `validation.claimed` with the matching `evidence_class` — not promoted. On the
   seeded history that rule leaves exactly **one** `hw_validated` entry out of
   26.

## Adding an entry

Run at deploy time, not later:

```bash
# 1. the manifest the build already wrote
cat imp/fpga/output/<TARGET>/tidelink_manifest.json

# 2. confirm the bytes you are about to flash are the bytes it describes
sha256sum imp/fpga/output/<TARGET>/tidelink.bit
sha256sum imp/fpga/output/<TARGET>/tidelink.bin      # the .bin is what gets flashed

# 3. capture what the manifest does NOT carry, while you still know it
grep -n 'CONFIG\.' fpga/targets/<TARGET>/tidelink_design.tcl
env | grep -E '^(TIDELINK|TL|TD|FPGA)_'
git status --porcelain                                # if non-empty, save `git diff HEAD`

# 4. is the commit reachable and pushed?
git cat-file -t <sha> && git ls-remote origin | grep <branch>
```

Then append the entry with `status: deployed`. Promote to `hw_validated` only
when a named artefact exists, and re-render:

```bash
python3 scripts/gen_bug_registry_html.py
```

:::{note}
A pre-existing, unused content-addressed store already implements most of this:
`pynq_host/td_artifact.py` (+ `pynq_host/ARTIFACT_STORE.md`) provides
`add / list / show / deploy / record / verify / gc` over write-once
`blobs/<sha256>/` with an `index.json` and an append-only `results.jsonl`, and
refuses to flash bytes whose hash does not match. Its default root is
`$TIDELINK_ARTIFACTS` or `~/tidelink-artifacts` — which **does not exist** on
this host; the store actually in use since June is `~/tidelink_artefacts`
(underscore, no index, no results). Point the tool at the store that is used
rather than designing a third mechanism.
:::

## Finding the last known-good build

```bash
# the registry answers it directly
grep -n 'last_known_good\|status: hw_validated' docs/BUILD_REGISTRY.yaml
```

To re-derive it from scratch, a build must satisfy all four of:

| Test | Command |
|---|---|
| clean tree | `"git_dirty": false` in the manifest |
| bytes still exist and match | `sha256sum <bit>` equals the manifest `sha256` |
| commit resolvable here | `git cat-file -t <sha>` → `commit` |
| a hardware result with a retained artefact | a log/JSON on disk naming the build |

**Do not** use `usr_access` as one of the tests (see the trap above), and do not
use tags as a build index: all 137 tags predate 2026-07-30, `v2026.07.16-chiplet-verified`
points at a commit dated 2026-07-09 whose own tag body says *"NOT
hardware-validated as part of this snapshot"*, and `v33-ms-data-crossed`
explicitly points at *"the first commit whose tree matches what was on the
boards"* — a reconstruction, not the build.

## Current registry — the builds that matter

Full table in `docs/BUILD_REGISTRY.yaml` (26 entries, 2026-06-10 → 2026-08-09).

### Last known-good

| Field | Value |
|---|---|
| id | `BLD-2026-08-08-kr260-onchip` |
| target | `kr260-pair-onchip` (one XCK26, two TideLink instances in fabric, no ribbon) |
| commit | `9cca6fe276330743f3e8a7d26760305dcb6e8cde`, **clean tree** |
| branch | `integ/tidelink-consolidated-2026-08-07` (pushed; `9cca6fe` is a verified ancestor of the remote head) |
| flist / PHY | `tidelink_fpga_v2.flist` / V2 |
| bitstream | sha256 `fa9d0fe282f7e0e679fa85ce3dc3d34cbcda2b839245479470b829e553ec74e3` (recomputed 2026-08-10, exact match) |
| USR_ACCESS | `0xcb6e8cde` — genuinely stamped (clean tree); low 32 bits of the commit |
| board | kr260-01 |
| proven | 4/4 fresh PORs: autonomy PASS, `SOAK sent=500 drained=500 good=500 bad=0 stalls=0` each |
| evidence | `tidelink-consolidated/onchip_landrate.log` (header stamps `tip=9cca6fe`) |
| tag | **none** — this build is untagged |

Caveats carried in the entry: the "1000/1000 byte-exact first POR" half of the
claim exists only in commit `e66b539`'s message and appears in no document; the
landrate log records no bitstream hash, so the log↔bytes binding is by timestamp
and commit rather than identity; and the onchip vehicle cannot exercise TL-001 or
TL-009 at all.

### Recent history

| id | Date | Target | Status | Provenance | Note |
|---|---|---|---|---|---|
| `BLD-2026-08-09-eth-chiplet-a2lonly` | 08-09 | kr260-eth-chiplet | deployed | partial | clean tree, real stamp, but `5d58c2a3` is **not fetchable from this repo**; its "128/128" is disputed by the live line's own commit log |
| `BLD-2026-08-09-kr260-pair-autoanchor` | 08-09 | kr260-pair-nptp | **known_bad** | partial | still all-zeros; built **V1** by apparent accident; the `AUTO_ANCHOR_EN` fix under test is uncommitted worktree state |
| `BLD-2026-08-08-kr260-onchip` | 08-08 | kr260-pair-onchip | **hw_validated** | full | ← last known-good |
| `BLD-2026-08-02-eth-chiplet-bare` | 08-02 | kr260-eth-chiplet | deployed | sha_unrecoverable | four bare `.bit` files, no manifest, no directory — the TL-007 B-wedge hardware proof was taken on these |
| `BLD-2026-07-30-eth-chiplet-i1` | 07-30 | kr260-eth-chiplet | deployed | partial | I1 resolved on silicon (6/6 byte-exact D2D); commit unreachable here |
| `BLD-2026-07-30-z2-epochfix` | 07-30 | pynq-z2-pair-all | deployed | partial | the epoch fix engaged on silicon; its two decisive parameters are env-gated and appear in no manifest |
| `BLD-2026-07-23-kr260-onchip-soak` | 07-23 | kr260-pair-onchip | superseded | **sha_unrecoverable** | the project's largest soak — 30,500 byte-exact packets — and its SHA cannot be recovered |
| `BLD-2026-07-17-golden-z2` | 07-17 | pynq-z2 pair | deployed | **sha_unrecoverable** | recovered from the boards' `/lib/firmware`; usable as an A/B control, never as a version datapoint |

### What the seeded history shows

| Metric | Value |
|---|---|
| Entries | 26 |
| `hw_validated` (retained artefact) | **1** |
| Source commit unrecoverable | 5 |
| Built from a dirty tree, diff never captured | 7 (a further 12 never recorded whether the tree was dirty at all) |
| Bitstreams still on disk | 18 |
| Builds carrying **any** concrete IP-parameter value | 9 — every one reconstructed by hand from a build note or a target tcl, none from a build-time record |
| Builds whose hardware result rests on a retained artefact | 1 (9 rest on a memory note, 8 on a tag body, 1 on a commit message, 7 have no result) |

Fields that had to be marked `unknown` for essentially every historic entry:
**tool version** (nothing captures Vivado's version anywhere in the flow),
**`deps/axi-chiplet-controller` and `deps/xhb500` versions**, **build-time
environment**, **`.bin` hashes**, and **`key_parameters`** except where a
`build_note` or a target tcl could be read after the fact.

## Improving the mechanism

Ordered by cost-to-benefit; each closes a gap this registry currently fills by
hand.

1. Extend `tl_write_manifest` (bump to `tidelink-build-manifest/2`) to dump every
   `CONFIG.*` actually set on the `tidelink_0`/`_1` BD cells via
   `report_property`, **enumerated from the design** rather than hand-listed.
2. Snapshot an allow-listed `TIDELINK_*`/`TL_*`/`TD_*`/`FPGA_*` env set,
   recording `unset` explicitly — an absent key is indistinguishable from a
   forgotten one.
3. Add `tool: {vivado: [version -short], host, os}`. One line of Tcl.
4. Emit submodule pins by iterating `git submodule status` instead of naming two,
   and record `deps/xhb500` by directory tree hash.
5. On a dirty build, keep refusing to stamp USR_ACCESS, but write
   `dirty_diff_sha256` plus the modified-path list and archive the patch beside
   the bitstream — a dirty build then becomes reproducible as *sha + patch*.
6. Derive the output directory name from the manifest
   (`<target>.<label>-<commit[:7]><dirty?'+'>`) so a label/sha mismatch is
   structurally impossible.

See {doc}`known_issues` for the defect side of the same audit, and
{doc}`boards` / {doc}`bringup` for what happens to a bitstream after it is built.
