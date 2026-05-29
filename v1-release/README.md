# TideLink v1.0-rc2 — Release Bundle

**Tag**: `v1.0` (planned) · **Release branch**: `release/v1.0-rc2` · **Off**: `72c280b` (sub `17160eb`)
**Date**: 2026-05-22
**Owner**: David Mapstone (SoC Labs)

## What this is

The release-candidate bundle for the TideLink chiplet subsystem. It packages the
**source-consistent, 16/16-locking** FPGA bitstream pair built from `72c280b` and
the **signoff-clean** ASIC handoff (Setup WNS = 0 ns, Hold = 0 ns, 0 net DRCs,
Formality LEC SUCCEEDED) as a self-contained deliverable.

> **Why rc2 supersedes rc1.** rc1 shipped a *preserved* bitstream (`tl_v7`,
> honest 13/16) whose source did not rebuild it — the rc1 lineage had the
> `USE_CLKBUF`/`USE_IDELAY` clock-structure fix **stripped at commit `51b5169`**,
> so source rebuilds regressed to 0/16 (the "rebuild regression", rc1 Bugs
> #5/#25). rc2 is branched directly from `72c280b`/`17160eb`, which carries that
> fix. **The rc2 source rebuilds its own shipped bitstream, and it locks 16/16.**
> The rebuild regression was never an environment fault — it was the missing RTL
> fix, now restored. Full root cause: `docs/LANE_LOCK_ROOT_CAUSE.md`.

See `PROVENANCE.md` for exactly how every artifact was produced and `KNOWN_ISSUES.md`
for what's deferred to v2.

## Where this exists

This release exists in two byte-identical forms:

1. **In-repo, on the `release/v1.0-rc2` branch**: docs + small artifacts. The
   ~8 MB FPGA bitstream pair is referenced by path in `bitstreams/BITSTREAMS.md`
   (with rebuild + fetch instructions); the large ASIC binaries (~116 MB, with
   a 66.6 MB DEF) are referenced by path in `asic/BINARIES.md`. Both kinds of
   binaries are kept out of git so the source repo stays clone-friendly.
2. **On-disk full bundle**: same tree plus the FPGA bitstreams and the large
   ASIC binaries. Use this form if you want a single `sha256sum -c CHECKSUMS.sha256`
   self-check covering everything.

`CHECKSUMS.sha256` in this directory covers both forms — the large-binary lines
reference the on-disk bundle paths explicitly.

## Tree

```
v1-release/
├── README.md              ← this file
├── DEMO.md                ← how to flash + bring up a board pair
├── KNOWN_ISSUES.md        ← v1 limitations and v2-deferred bugs
├── PROVENANCE.md          ← exact commits, build hosts, dates for every artifact
├── CHECKSUMS.sha256       ← SHA256 of every binary/netlist in this tree
├── reliability.log        ← N-deploy HW reliability distribution (16/16 build)
├── bitstreams/            ← 72c280b FPGA artifacts (the v1 FPGA deliverable, 16/16)
│   └── BITSTREAMS.md                 ← fetch / rebuild instructions; binaries are NOT in git
│       (tidelink{,-flip}.bin, .hwh, .bin.manifest.json — SHA256s in ../CHECKSUMS.sha256)
├── asic/                  ← ASIC chip-top handoff (May-14 fusion-compiler signoff)
│   ├── tidelink_top.v / .pg.v          ← gate-level netlists (logic-only and PG)
│   ├── tidelink_top.sdc                ← boundary timing constraints
│   ├── tidelink_top.def / .lef         ← physical abstract + floorplan/placement
│   ├── tidelink_top_{slow,fast}.lib    ← Liberty ETMs (extracted timing models)
│   ├── tidelink_top_{slow,fast}.db     ← compiled Synopsys DB equivalents
│   ├── 03b_verify_summary_final.rep    ← Formality LEC verdict: SUCCEEDED
│   └── MANIFEST_fusion_compiler.md     ← per-file purpose + QoR summary
└── fixes/
    └── MANIFEST.md        ← catalogue of fix branches for post-v1 / RTL-freeze work
```

## TL;DR

- **FPGA artifact** = the `72c280b` (sub `17160eb`) source build. Master
  `tidelink.bin` md5 `e2bd4d9f` / sha256 `dd54203b`; slave `tidelink-flip.bin`
  md5 `0f752a05` / sha256 `b50553bf`. **HW-validated 16/16 bidirectional,
  cal_done=1, fault=0x00** on the `bridge1` pair (2026-05-22). Routed netlist:
  8× BUFG capture clocks + 8× IDELAYE2, `Place 30-568` = 0, WHS +0.051 ns.
- **Source rebuilds the bitstream**: unlike rc1, the rc2 branch source builds its
  own shipped 16/16 bitstream (source ↔ bitstream integrity restored).
- **ASIC artifact** = May-14 fusion-compiler `outputs_preserve/` (sc12_cln65lp_base_rvt,
  250 MHz hclk, signoff-clean). Independent of the FPGA fix; ships clean.
- **Source state** at release: `72c280b` + submodule `17160eb`.
- **Post-v1 / RTL-freeze work**: the RTL bug-fixes authored on the rc1 lineage
  after `72c280b` still need re-basing onto rc2 (with `USE_CLKBUF` intact) and
  HW re-validation — see `docs/RTL_FREEZE_CHECKLIST.md`.

## Quick links

- Bring-up & flash procedure → `DEMO.md`
- Provenance / how it was built → `PROVENANCE.md`
- Deferred items (Bug list) → `KNOWN_ISSUES.md`
- Lane-lock root cause → `docs/LANE_LOCK_ROOT_CAUSE.md` (in the tidelink repo)
- RTL-freeze checklist → `docs/RTL_FREEZE_CHECKLIST.md`
- Post-v1 merge plan → `fixes/MANIFEST.md`
