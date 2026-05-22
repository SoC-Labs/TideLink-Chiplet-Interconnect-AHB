# TideLink v1.0-rc1 — Release Bundle

**Tag**: `v1.0-rc1` (planned) · **Release branch**: `release/v1.0-rc1` · **Off**: `feat/td-combined @ 57c2810`
**Date**: 2026-05-21
**Owner**: David Mapstone (SoC Labs)

## What this is

The first release-candidate bundle for the TideLink chiplet subsystem. It packages
the **confirmed-locking** FPGA bitstream `tl_v7` (**13/16 best** lane lock,
HW-validated pre- and post-power-cycle on 2026-05-22, `cal_done=1`) and the
**signoff-clean** ASIC handoff (Setup WNS = 0 ns, Hold = 0 ns, 0 net DRCs,
Formality LEC SUCCEEDED) as a self-contained deliverable.

> **Provenance correction (2026-05-22, Bug #34):** earlier drafts of this bundle
> claimed a **14.40/16** FPGA artifact attributed to a "morning" build. That
> attribution was FALSE — the blob it pointed to (md5 `86aa3a95`, .bit build-date
> 2026-05-20 23:41 *evening*) actually measures **0/16 on healthy hardware** and
> has been relabelled `hwval-eve-NONLOCKING` in the artifact store. The true
> 14.40/16 build is currently **unidentified** (open provenance investigation,
> Bug #35). The shipped FPGA artifact is now `tl_v7` at an honest **13/16 best**.

See `PROVENANCE.md` for exactly how every artifact was produced and `KNOWN_ISSUES.md`
for what's deferred to v2.

## Where this exists

This release exists in two byte-identical forms:

1. **In-repo, on the `release/v1.0-rc1` branch**: docs + small artifacts + bitstreams.
   The large ASIC binaries (~116 MB, with a 66.6 MB DEF) are referenced by path
   in `asic/BINARIES.md` to avoid blowing past GitHub's per-file limits.
2. **On-disk full bundle** at `/home/dam1n19/SoCLabs/td-bisect/v1-release/`: same
   tree plus the large ASIC binaries. Use this form if you want a single
   `sha256sum -c CHECKSUMS.sha256` self-check covering everything.

`CHECKSUMS.sha256` in this directory covers both forms — the large-binary
lines reference the on-disk bundle paths explicitly.

## Tree

```
v1-release/
├── README.md              ← this file
├── DEMO.md                ← how to flash + bring up a board pair
├── KNOWN_ISSUES.md        ← v1 limitations and v2-deferred bugs (#3, #5/#25, #10, #16, #22, #24)
├── PROVENANCE.md          ← exact commits, build hosts, dates for every artifact
├── CHECKSUMS.sha256       ← SHA256 of every binary/netlist in this tree
├── reliability.log        ← 20-iter HW re-test log (historical)
├── bitstreams/            ← tl_v7 FPGA artifacts (the v1 FPGA deliverable, 13/16 confirmed)
│   ├── tidelink.bin                  (4 045 516 bytes, md5 b0633476 / sha256 3cedd3ba)
│   ├── tidelink.hwh                  (   749 353 bytes, tl_v7 BD memory map)
│   ├── tidelink-flip.bin             (4 045 516 bytes, opposite pin assignment for slave)
│   ├── tidelink-flip.hwh             (   749 353 bytes)
│   ├── tidelink.bin.manifest.json    (deploy-guard provenance sidecar, label tl_v7)
│   └── tidelink-flip.bin.manifest.json
├── asic/                  ← ASIC chip-top handoff (May-14 fusion-compiler signoff)
│   ├── tidelink_top.v / .pg.v          ← gate-level netlists (logic-only and PG)
│   ├── tidelink_top.sdc                ← boundary timing constraints
│   ├── tidelink_top.def / .lef         ← physical abstract + floorplan/placement
│   ├── tidelink_top_{slow,fast}.lib    ← Liberty ETMs (extracted timing models)
│   ├── tidelink_top_{slow,fast}.db     ← compiled Synopsys DB equivalents
│   ├── 03b_verify_summary_final.rep    ← Formality LEC verdict: SUCCEEDED
│   └── MANIFEST_fusion_compiler.md     ← per-file purpose + QoR summary
└── fixes/
    └── MANIFEST.md        ← catalogue of 7 fix branches ready to merge post-v1
```

## TL;DR

- **FPGA artifact** = `tl_v7` bitstream (master md5 `b0633476` / sha256 `3cedd3ba`),
  byte-identical copy in `bitstreams/`, also stored in the content-addressed
  artifact store (`mapstone-dev:~/tidelink-artifacts/`, tag `tl_v7`). HW-validated
  **13/16 best, cal_done=1**, confirmed both pre- and post-power-cycle on
  2026-05-22. This is the highest *confirmed-locking* build available; source
  rebuild on srv04936 still regresses to 0/16 (Bug #25, deferred to v2).
- **ASIC artifact** = May-14 fusion-compiler `outputs_preserve/` (sc12_cln65lp_base_rvt
  library, 250 MHz hclk, signoff-clean). The ASIC track is **independent** of the
  FPGA env regression — it ships clean.
- **Source state** at release: `feat/td-combined @ 57c2810` (msg-gate). Source
  rebuild does **not** currently reproduce the FPGA bitstream — this is the open
  issue tracked as Bug #5/#25, deferred. The bitstream itself is the deliverable.
- **7 fix branches** are catalogued in `fixes/MANIFEST.md` ready to merge post-v1.
  They fix CI, deploy-script robustness, lint gate, a 33→32 bit truncation, XDC
  syntax issues, and add the cocotb adversarial silicon-replication suite. None
  of them was strictly required for v1 RC1 (the morning bitstream already works).

## Quick links

- Bring-up & flash procedure → `DEMO.md`
- Provenance / how it was built → `PROVENANCE.md`
- Deferred items (Bug list) → `KNOWN_ISSUES.md`
- Post-v1 merge plan → `fixes/MANIFEST.md`
- Full bug history → `docs/BUG_TRACKER.md` (in the tidelink repo)
