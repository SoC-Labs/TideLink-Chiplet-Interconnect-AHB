# ASIC binaries — fetch instructions

The large ASIC handoff binaries are **not committed to git** (they total
~116 MB, with a single 66.6 MB DEF that would blow past GitHub's 100 MB
per-file limit). They live in their canonical source paths in this repo's
build outputs and are mirrored byte-identically in the on-disk release bundle.

## Where they live

| Artifact | Bytes | Repo source path | Bundle path |
|---|---|---|---|
| `tidelink_top.v` | 13 365 554 | `syn/asic/fusion-compiler/outputs_preserve/tidelink_top.v` | `td-bisect/v1-release/asic/tidelink_top.v` |
| `tidelink_top.pg.v` | 15 210 920 | `syn/asic/fusion-compiler/outputs_preserve/tidelink_top.pg.v` | `td-bisect/v1-release/asic/tidelink_top.pg.v` |
| `tidelink_top.sdc` | 214 393 | `syn/asic/fusion-compiler/outputs_preserve/tidelink_top.sdc` | `td-bisect/v1-release/asic/tidelink_top.sdc` |
| `tidelink_top.def` | 69 789 082 | `syn/asic/fusion-compiler/outputs_preserve/tidelink_top.def` | `td-bisect/v1-release/asic/tidelink_top.def` |
| `tidelink_top.lef` | 14 513 | `syn/asic/fusion-compiler/outputs_preserve/tidelink_top.lef` | `td-bisect/v1-release/asic/tidelink_top.lef` |
| `tidelink_top_slow.lib` | 9 944 708 | `imp/ASIC/tidelink_top_full/etm/tidelink_top_slow.lib` | `td-bisect/v1-release/asic/tidelink_top_slow.lib` |
| `tidelink_top_slow.db` | 1 357 312 | `imp/ASIC/tidelink_top_full/etm/tidelink_top_slow_lib.db` | `td-bisect/v1-release/asic/tidelink_top_slow.db` |
| `tidelink_top_fast.lib` | 9 943 871 | `imp/ASIC/tidelink_top_full/etm/tidelink_top_fast.lib` | `td-bisect/v1-release/asic/tidelink_top_fast.lib` |
| `tidelink_top_fast.db` | 1 340 160 | `imp/ASIC/tidelink_top_full/etm/tidelink_top_fast_lib.db` | `td-bisect/v1-release/asic/tidelink_top_fast.db` |

## Verifying the binaries

The SHA256 of every binary is in `../CHECKSUMS.sha256` (paths are relative to
the bundle root: `td-bisect/v1-release/`). On a checkout of the tidelink repo
at the release commit:

```bash
# Verify in-repo source paths against the bundle CHECKSUMS
cd /path/to/v1-release-bundle
sha256sum -c CHECKSUMS.sha256
```

Both copies (in-repo build output and the on-disk bundle) are byte-identical
and were verified via `sha256sum` at release time.

## Why they aren't in git

- `tidelink_top.def` is 66.6 MB, very close to GitHub's 100 MB per-file ceiling.
- `tidelink_top.v` (12.7 MB) + `tidelink_top.pg.v` (14.5 MB) would inflate the
  pack repeatedly on any future v1.x release.
- The repo does not currently use git-lfs; introducing it would change the
  clone story for everybody downstream.
- The artifacts already live in the repo's `syn/asic/fusion-compiler/outputs_preserve/`
  and `imp/ASIC/tidelink_top_full/etm/` directories — committing them at
  `v1-release/asic/` would be a 116 MB duplicate.

If the chip-top integrator needs the binaries packaged together, the
canonical on-disk bundle at `/home/dam1n19/SoCLabs/td-bisect/v1-release/asic/`
serves that role (or zip the two repo source paths together).

## Integration recipe (for chip-top PnR)

See `MANIFEST_fusion_compiler.md` in this directory and the §"Integration notes"
section therein. Quick form:

```tcl
read_lef    syn/asic/fusion-compiler/outputs_preserve/tidelink_top.lef
read_def    syn/asic/fusion-compiler/outputs_preserve/tidelink_top.def
read_verilog syn/asic/fusion-compiler/outputs_preserve/tidelink_top.pg.v
read_sdc    syn/asic/fusion-compiler/outputs_preserve/tidelink_top.sdc
# Or, NDM-based:
open_block  syn/asic/fusion-compiler/work_preserve/tidelink_top_full.dlib/tidelink_top/signoff.design
```
