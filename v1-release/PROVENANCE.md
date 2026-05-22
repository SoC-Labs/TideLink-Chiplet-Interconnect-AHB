# PROVENANCE — TideLink v1.0-rc2

Exact provenance for every artifact in this bundle. Hashes are in `CHECKSUMS.sha256`.

## Release branch / tag

- **Release branch**: `release/v1.0-rc2`
- **Off**: parent `72c280b` + submodule `axi-chiplet-controller @ 17160eb`
  (the **reproducible 16/16** source — see `docs/LANE_LOCK_ROOT_CAUSE.md`)
- **Tag (planned, not pushed)**: `v1.0`
- **Supersedes**: `release/v1.0-rc1` (parent `02d4009` / sub `a55d346`), which
  shipped the `tl_v7` bitstream at an honest 13/16 because the lineage had the
  `USE_CLKBUF` clock-structure fix **stripped at `51b5169`** and no
  source-consistent 16/16 build existed yet.

The release branch is created LOCAL and NOT pushed. The user initiates push +
tag publication when ready.

## Why rc2 supersedes rc1 (the headline)

rc1 shipped a *preserved* bitstream (`tl_v7`, 13/16) whose source did **not**
rebuild it (the rc1 source rebuilt to 0/16 — the "Bug #25 rebuild regression").
rc2 fixes that at the root: it is branched directly from `72c280b`/`17160eb`,
the commit that carries the `USE_CLKBUF` + `USE_IDELAY` RTL clock-structure fix.
**The rc2 source rebuilds its own shipped bitstream**, and that bitstream locks
**16/16**. Source ↔ bitstream integrity is restored; the "rebuild regression"
(rc1 Bugs #5/#25) was never an environment fault — it was the missing RTL fix
(`51b5169` strip), now present. See `docs/LANE_LOCK_ROOT_CAUSE.md` for the full
root-cause writeup.

## bitstreams/  (artifact = `72c280b` source build, 16/16)

Built on the farm host **srv04936** (Vivado 2024.1), dispatched from srv03335,
2026-05-22 12:18. Targets `pynq-z2-pair-all` (master) + `pynq-z2-pair-flip-all`
(slave). `USE_CLKBUF=1` + `USE_IDELAY=1` in the FPGA wrapper; 200 MHz IDELAYCTRL
reference wired as `clk_wiz` CLKOUT3 in both targets' block design.

| File | Bytes | SHA256 | MD5 | Provenance |
|---|---|---|---|---|
| `tidelink.bin` | 4 045 516 | `dd54203bc8715f23797b0eb24b9dd0f1c86c7382467f4b77f0b9b46950d4f347` | `e2bd4d9ff308db8c0c46c0000b143f25` | `pynq-z2-pair-all` (die_a/master), 72c280b/17160eb |
| `tidelink.hwh` | 387 968 | `757413258ff30921970cf34d998b96333caca6f73896d430ed5a4192e5c165cd` | `a67c7cdf0785604b55bc9d038b6eff69` | BD memory map for the master build |
| `tidelink-flip.bin` | 4 045 516 | `b50553bfc26087d88c27cb81074c6c29cae43d454be1c801d2e9f406919b0a60` | `0f752a059557779a584400138cff8098` | `pynq-z2-pair-flip-all` (die_b/slave, mirrored RPi-GPIO pin map) |
| `tidelink-flip.hwh` | 387 968 | `4df9033f04ff2389e7c0ca52658808efc45ba5cdf488b964eff6974e8adada79` | `6f992eecc83109fae3b3f76868611aae` | BD memory map for the slave build |
| `tidelink.bin.manifest.json` | — | (see CHECKSUMS) | — | deploy-guard provenance sidecar, `expected_lock_min=16`, label `rc2-72c280b-16of16` |
| `tidelink-flip.bin.manifest.json` | — | (see CHECKSUMS) | — | "" |

**Netlist evidence the clock-structure fix reached silicon** (routed reports of
this build): per-lane capture clocks sourced from **BUFG** (not LUT), **8×
`IDELAYE2` + `IDELAYCTRL`**, **`Place 30-568` count = 0**, post-route **WHS
+0.051 ns** (hold met). Contrast the rc1 lineage: 7× `Place 30-568`, WHS
−0.537 ns (hold violated) → 0/16. See `docs/LANE_LOCK_ROOT_CAUSE.md §"The
mechanism"`.

**HW validation**: this exact bitstream pair locks **16/16 bidirectional,
cal_done=1, fault=0x00** on the `bridge1` z2_02/z2_03 pair (verified 2026-05-22).
The N-deploy reliability distribution is in `reliability.log`.

**Staging integrity**: the `.bin`/`.hwh` in this bundle are byte-identical to the
build outputs (`md5 e2bd4d9f` / `0f752a05`), verified at copy time and again after
staging to the bench host. The deploy path SHA-verifies the bitstream before
flashing (deploy-provenance guard), so the "stale /tmp clobbered the bitstream"
class of error (rc1 Bug #32/#34) cannot recur silently.

## asic/

Unchanged from rc1 — the ASIC handoff is independent of the FPGA clock fix and
was already signoff-clean. Fusion-Compiler May-14 signoff, sc12_cln65lp_base_rvt
library. Large binaries (`.v`/`.pg.v`/`.def`/`.lef`/`.lib`/`.db`) are NOT in git
(see `asic/BINARIES.md`); they live in the on-disk bundle. Small text files
(`MANIFEST_fusion_compiler.md`, `03b_verify_summary_final.rep`, `BINARIES.md`)
are tracked here.

**QoR** (from `MANIFEST_fusion_compiler.md`): total cell area 477 710.71 μm²,
1× `rf_16k` macro, util 0.70, `hclk` 4.0 ns / 250 MHz, Setup WNS 0.00 ns, Hold
WNS 0.00 ns, 0 net DRC violations. Formality LEC: **Verification SUCCEEDED**,
18 531 passing compare points, 256 don't-verify (Wlink Chisel synth-transform
DFFs, iteratively skipped).

## fixes/

`fixes/MANIFEST.md` lists the fix branches catalogued post-v1. NOTE: several of
these were authored on the rc1 lineage *after* `72c280b` and are not yet on the
rc2 source — re-basing them onto rc2 (with the `USE_CLKBUF` fix intact) is the
RTL-freeze work tracked in `docs/RTL_FREEZE_CHECKLIST.md`.

## reliability.log

N-deploy HW reliability distribution for the shipped `72c280b` bitstream pair,
captured 2026-05-22 on the `bridge1` pair via `bringup_reliability.sh` (safe-ops
only, no AHB_TX). This is the authoritative lock-rate record for the rc2 artifact.

## Build hosts at-a-glance

- FPGA bitstream build host: `srv04936` (Vivado 2024.1; OOM ceiling at ≥3
  concurrent — discipline rule).
- ASIC build host: `srv04936` (Synopsys Fusion Compiler / Primetime / Formality
  U-2022.12).
- Bring-up host: `mapstone-dev` (proxies the `bridge1` board pair via fpgahub).
- Boards: `pynq_z2_02_pl` (master, 192.168.4.101) + `pynq_z2_03_pl` (slave, 192.168.6.101).

## Author / contact

David Mapstone (`d.a.mapstone@soton.ac.uk`), SoC Labs. Released under the Arm
Academic Access license, joint work commissioned on behalf of SoC Labs.
