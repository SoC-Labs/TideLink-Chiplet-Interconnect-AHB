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

## bitstreams/  (artifact = `tl_v7`, corrected 2026-05-22 — Bug #31/#33/#34)

| File | Bytes | SHA256 | MD5 | Provenance |
|---|---|---|---|---|
| `tidelink.bin` | 4 045 516 | `3cedd3ba42ccb5e65f6419dcb414255c401e128ec5764743d2e8289a5377e033` | `b0633476131e4e2f1ce1585f200b0300` | `tl_v7` master, from `mapstone-dev:/tmp/tl_v7_tidelink.bin` + artifact-store tag `tl_v7` |
| `tidelink.hwh` | 749 353 | `9860f4f39ee76ed2dbcd8c603556029531e21d8f34e61b84e5bf38e74b98c13a` | `98f2a48d3dfd07bbd311d3e8a08ca39e` | `tl_v7` blob BD memory map |
| `tidelink-flip.bin` | 4 045 516 | `60b84430a5da24dd208cfacd01fa29e1d6161e5743f294f98298afb01870e0e7` | `d5f4218031817e530f1c6849f3bf4815` | `tl_v7` slave (mirrored RPi-GPIO pin map, same build) |
| `tidelink-flip.hwh` | 749 353 | `0b6b17d041ddbce266399843fff08fd1f9463cde8060325fd3a0abc27bd115c7` | `33cd0261ac5744c9177bfd0196f09550` | "" |
| `tidelink.bin.manifest.json` | — | (see CHECKSUMS) | — | deploy-guard provenance sidecar, label `tl_v7`, `expected_lock_min=12` |
| `tidelink-flip.bin.manifest.json` | — | (see CHECKSUMS) | — | "" |

**IMPORTANT — provenance correction (Bug #34).** An earlier draft of this bundle
shipped the `phase-v2` bitstream (master md5 `188ebdd8` / sha256 `606e1648`) and
described it as a "morning 14.40/16" artifact. BOTH of those were wrong:
`phase-v2` is a **known-bad 0/16** build, and the separate `morning-v1`
artifact-store tag (blob md5 `86aa3a95` / sha256 `40f6477c`) that carried the
"14.40/16" label is *also* non-locking (**0/16 on healthy HW 2026-05-22**, .bit
build-date 2026-05-20 23:41 *evening*, not the 11:10 morning build). That tag has
been relabelled `hwval-eve-NONLOCKING`. The true 14.40/16 build is **unidentified**
(Bug #35). This bundle now ships the **`tl_v7`** bitstream, which is the highest
*confirmed-locking* artifact we actually possess.

**How `tl_v7` was validated (2026-05-22)**:
- 13/16 best, mean ~8/16, `cal_done=1` — measured **before** a power cycle (14:53)
  AND re-confirmed **after** the power cycle. This pre+post-cycle agreement is also
  what proves Bug #28 (suspected ribbon-cable damage) was a FALSE ALARM: the
  hardware is fine.
- `tl_v7s` (sha256 `e92d6596`) is a sibling at 11/16 best — also confirmed locking.
- Lock history is recorded in the artifact store: `td-artifact show tl_v7`.

**How they were copied into this bundle (2026-05-22)**: `ssh mapstone-dev 'cat <f>'`
streamed to local files (scp is broken on mapstone-dev). The 18-byte
`Agent pid NNNNNNN\n` ssh-agent profile-banner prefix was stripped from each
stream and every file was re-verified against the canonical `tl_v7` blob
sha256/md5 — all four match byte-for-byte. The `.hwh` files were taken directly
from the `tl_v7` blob (`mapstone-dev:~/tidelink-artifacts/blobs/3cedd3ba.../`)
so the BD memory map matches the shipped `.bin`.

**Note on why this is the FPGA artifact and not a source rebuild**: source-level
rebuilds on srv04936 still produce a 0/16 bitstream from byte-identical sources —
this is Bug #25 (deferred to v2). `tl_v7` converges on real hardware, so v1 ships
the preserved bitstream itself. Honest lock rate: **13/16 best**, not 16/16.

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

Historical HW re-test log captured during the 2026-05-21 release flow. NOTE: any
"14.40/16" figure recorded in this log refers to the build now known to be
mislabelled (Bug #34) and should NOT be read as the `tl_v7` lock rate. The
authoritative, current lock history for the shipped artifact lives in the
artifact store (`td-artifact show tl_v7`): **13/16 best, cal_done=1, confirmed
pre+post power-cycle 2026-05-22**.

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
