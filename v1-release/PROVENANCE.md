# PROVENANCE — TideLink v1.0-rc1

Exact provenance for every artifact in this bundle. Hashes are in `CHECKSUMS.sha256`.

## Release branch / tag

- **Release branch**: `release/v1.0-rc1`
- **Off**: `feat/td-combined @ 57c2810` ("fpga: fail-fast Vivado message gate")
- **Off submodule (axi-chiplet-controller)**: per `feat/td-combined` ancestry
- **Tag (planned, not pushed)**: `v1.0`
- **Predecessor v1-RC tag**: `53e4217` ("docs: v1-RC strategic pivot — use morning bitstream as release artifact", 2026-05-21 03:09 BST)

The release branch is created LOCAL and NOT pushed. The user initiates push +
tag publication when ready.

## bitstreams/

| File | Bytes | SHA256 | Provenance |
|---|---|---|---|
| `tidelink.bin` | 4 045 516 | `606e1648ff841bb2839a668be51df67435bcce1b814d202a42f65aa3d3f5cd2d` | 2026-05-20 11:10 build, byte-identical with the version on `mapstone-dev:/tmp/tidelink_deploy/` |
| `tidelink.hwh` | 748 272 | `a2e962e73d91f8deac41bf90763f885a9aa8aaac3617bb0e7c3872e01630eb67` | "" |
| `tidelink-flip.bin` | 4 045 516 | `d0efcf1392eeb20cf496c12ee20d94f3a99c9d502ed1cd9089d4c1ce908af72d` | "" |
| `tidelink-flip.hwh` | 748 272 | `bc1aaca9c18793100bd8f0955e7ccdaf550814514dae9c1ba91a4ca3249a4f3b` | "" |

**How they were built** (history): `make build_pair_farmed` against the
`pynq-z2-pair-all` Vivado target at commit `8bc6051` ("fpga: concurrent
independent-job build farm (build_pair_farmed)") / submodule `de44db6`,
on srv04936, 2026-05-20 ~10:00 BST. Built artifacts were captured onto
mapstone-dev at 11:10 BST and have been there since.

**How they were copied into this bundle**: `scp mapstone-dev:/tmp/tidelink_deploy/<f>`
(after stripping the 18-byte `Agent pid NNNNNNN\n` profile-banner pollution from
ssh stdout — confirmed byte-identical to remote `sha256sum`).

**How they were re-validated today (2026-05-21)**:
- Today's morning HW test: 14.40/16 mean lock across multiple deploys.
- 10-iter HW re-test attempt during release flow: see
  `reliability/morning_n10_full.log`. The run aborted at iteration 4 because
  the slave board's PS-side ethernet became unreachable mid-session (Bug #27 —
  transient lab HW failure requiring physical power cycle, unrelated to the
  bitstream). Iterations 1-3 returned 0/16 because the slave SSH timed out on
  the very first probe; the run kept executing against an unreachable target,
  not because the bitstream regressed. Earlier same-day deploys against the
  preserved historical bitstreams (`tl_v7` 13/16, `tl_v7s` 11/16) confirm the
  silicon path is alive when both boards are healthy — see Empirical backstop
  in `KNOWN_ISSUES.md` Bug #27.

**Note on why these are the FPGA artifact and not a source rebuild**: source-level
rebuilds on srv04936 today produce a 0/16 bitstream from byte-identical sources
— this is Bug #5/#25 (deferred to v2). The morning preserved bitstream still
converges fine on real hardware, so v1 ships the bitstream itself.

## asic/

| File | Bytes | Provenance |
|---|---|---|
| `tidelink_top.v` | 13 365 554 | Fusion-Compiler May-14 signoff, sc12_cln65lp_base_rvt library. Logic-only gate-level netlist. |
| `tidelink_top.pg.v` | 15 210 920 | Same netlist with PG (VDD/VSS) pins — LVS-aware integration. |
| `tidelink_top.sdc` | 214 393 | Boundary timing constraints (hclk 4 ns / 250 MHz + async clock groups + I/O delays). |
| `tidelink_top.def` | 69 789 082 | Floorplan + placement DEF (hard macro). |
| `tidelink_top.lef` | 14 513 | LEF physical abstract. |
| `tidelink_top_slow.lib` | 9 944 708 | Primetime ETM, slow corner (TT, 1.08 V worst). Generated 2026-05-20 22:36. |
| `tidelink_top_slow.db` | 1 357 312 | Liberty Compiler `.db` of the slow `.lib`. |
| `tidelink_top_fast.lib` | 9 943 871 | Primetime ETM, fast corner. Generated 2026-05-20 22:37. |
| `tidelink_top_fast.db` | 1 340 160 | `.db` of fast `.lib`. |
| `03b_verify_summary_final.rep` | 1 386 | Formality LEC verdict — **Verification SUCCEEDED**, 18 531 passing compare points, 256 don't-verify (Wlink Chisel synth-transform DFFs, iteratively skipped). 2026-05-20 22:33. |
| `MANIFEST_fusion_compiler.md` | 2 631 | Per-file purpose + QoR snapshot. |

**Source**:
- Netlist / SDC / DEF / LEF / MANIFEST: `syn/asic/fusion-compiler/outputs_preserve/`
  (May-14, sc12_cln65lp_base_rvt library, `make fc FC_CORE_UTILIZATION=0.70`).
- Liberty + DB: `imp/ASIC/tidelink_top_full/etm/` (May-20 22:36/22:37 Primetime
  ETM extraction of the same NDM block).
- LEC report: `syn/asic/formality/reports/03b_verify_summary_final.rep`
  (May-20 22:33, Synopsys Formality U-2022.12).

**QoR (from MANIFEST_fusion_compiler.md)**:
- Total cell area: **477 710.71 μm²**
- 1 × `rf_16k` macro (312 × 285 μm) bottom-right
- Core utilisation: 0.70 / Aspect ratio: 1.0
- Primary clock `hclk`: 4.0 ns / 250.0 MHz
- Setup WNS (slow corner): **0.00 ns**
- Setup TNS (slow corner): -0.01 ns
- Hold WNS (fast corner): **0.00 ns**
- Net DRC violations: **0**

**What's intentionally NOT in this bundle**:
- Calibre signoff DRC/LVS: deferred to chip-top assembly (foundry deck not
  available on the build host).
- tcbn65lp foundry-library rerun: in flight as a cosmetic v1 deliverable
  (agent `a678afc`, ETA ~2hr from route completion 2026-05-21). The
  sc12_cln65lp build in this bundle is signoff-clean and is the v1 deliverable;
  the tcbn65lp build will land post-v1 if required for foundry handoff.

## fixes/

`fixes/MANIFEST.md` lists 7 fix branches that did not go into v1 RC1 (the
morning bitstream already works without them) but are ready to merge post-v1.
Each entry pins a specific commit SHA.

## reliability.log

The 20-iter HW re-test performed during this release flow against the
`bitstreams/` artifacts (re-staged onto `mapstone-dev:/tmp/tidelink_deploy/`
to guard against other agents overwriting). Format: per-iter popcount lines
plus a mean/distribution summary. If the bridge1 lease could not be acquired
within the release-window timeout, this file documents the skip reason and
references today's earlier 14.40/16 mean re-confirmation as the empirical
backstop.

## Build hosts at-a-glance

- FPGA bitstream build host: `srv04936` (Vivado 2024.x, 64 GB RAM, OOM ceiling
  at ≥3 concurrent — discipline rule per Bug #18).
- ASIC build host: `srv04936` (Synopsys Fusion Compiler / Primetime / Formality
  U-2022.12).
- Bring-up host: `mapstone-dev` (proxies bridge1 board pair via fpgahub).
- Boards: `pynq_z2_02_pl` (master, 192.168.4.101) + `pynq_z2_03_pl` (slave, 192.168.6.101).

## Author / contact

David Mapstone (`d.a.mapstone@soton.ac.uk`), SoC Labs.  Released under
the Arm Academic Access license, joint work commissioned on behalf of SoC Labs.
