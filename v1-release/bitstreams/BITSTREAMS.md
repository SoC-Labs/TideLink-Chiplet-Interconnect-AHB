# FPGA bitstreams — fetch / rebuild instructions

The release-pair FPGA bitstreams are **no longer committed to git** (they total
~8 MB of binary content, and tracking them in source control bloats the repo
for clones that only need RTL/sim/docs). They live in the build outputs and
can be rebuilt deterministically from the release commit.

## What was here

| Artifact | Bytes | Repo build path | Bundle path (pre-untrack) |
|---|---|---|---|
| `tidelink.bin` | 4 045 516 | `imp/fpga/output/pynq-z2-pair-all/tidelink.bin` | `v1-release/bitstreams/tidelink.bin` |
| `tidelink.hwh` | 387 968 | `imp/fpga/output/pynq-z2-pair-all/tidelink.hwh` | `v1-release/bitstreams/tidelink.hwh` |
| `tidelink.bin.manifest.json` | 369 | (generated alongside `tidelink.bin`) | `v1-release/bitstreams/tidelink.bin.manifest.json` |
| `tidelink-flip.bin` | 4 045 516 | `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin` | `v1-release/bitstreams/tidelink-flip.bin` |
| `tidelink-flip.hwh` | 387 968 | `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.hwh` | `v1-release/bitstreams/tidelink-flip.hwh` |
| `tidelink-flip.bin.manifest.json` | 400 | (generated alongside `tidelink-flip.bin`) | `v1-release/bitstreams/tidelink-flip.bin.manifest.json` |

The SHA256 of every artifact remains in `../CHECKSUMS.sha256` as the
authoritative manifest; external copies can be verified against it.

## How to rebuild

From a clean checkout of the release commit (see `../PROVENANCE.md` for the
exact parent + submodule pins):

```bash
source set_env.sh
make -C fpga build_design TARGET=pynq-z2-pair-all
make -C fpga build_design TARGET=pynq-z2-pair-flip-all

# Convert .bit -> .bin and write manifests
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-all/tidelink.bit ./tidelink.bin
python3 fpga/scripts/bit2bin.py imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit ./tidelink-flip.bin
bash pynq_host/scripts/make_bitstream_manifest.sh ./tidelink.bin \
    --commit "$(git rev-parse HEAD)" --target pynq-z2-pair --lock-min 14
bash pynq_host/scripts/make_bitstream_manifest.sh ./tidelink-flip.bin \
    --commit "$(git rev-parse HEAD)" --target pynq-z2-pair-flip --lock-min 14

# Verify against the release manifest
sha256sum -c ../CHECKSUMS.sha256
```

Each `build_design` invocation is roughly 40-45 minutes of Vivado wall-clock on
a typical workstation. The `build_farm.sh` recipe in `../README.md` runs both
in parallel across the build farm.

## How to obtain pre-built bitstreams

The pre-built rc2 bitstreams are available either:

1. As **GitHub Release assets** attached to the `v1.0` tag (once published —
   currently planned-not-pushed; see `../README.md` for status), OR
2. From the SoC Labs internal release archive — contact the release owner
   (David Mapstone, d.a.mapstone@soton.ac.uk).

Both copies are byte-identical to the hashes in `../CHECKSUMS.sha256`.

## Why they aren't in git

- ~8 MB total, dominated by 4 MB `.bin` artifacts that re-bloat the pack
  file on every release-candidate iteration.
- Bitstreams are a *build output*, not a *source artifact* — they can be
  reproduced from the release commit + the documented build recipe.
- The same external-pointer pattern is used for the ASIC handoff binaries
  (see `../asic/BINARIES.md`).
