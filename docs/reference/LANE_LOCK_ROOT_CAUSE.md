# TideLink FPGA Lane-Lock — Root Cause & Known-Good Builds

**Status: SOLVED (2026-05-22).** The multi-day "0/16 lane-lock regression" is
definitively root-caused, with a reproducible 16/16 build identified.

---

## TL;DR

- **Root cause:** commit **`51b5169`** ("fpga: align BD scripts + IP packaging
  with a092251 (no idelay_*/USE_*)") **stripped the `USE_CLKBUF` + `USE_IDELAY`
  RTL clock-structure fix** from the FPGA build path. Without it, Vivado places
  the GPIO-PHY recovered capture clock on a **LUT-driven net** (`Place 30-568`
  "LUT driving clock pin") → **hold-timing violation** on `pad_clk_rx` →
  calibrator never completes (`cal_done=0`) → **0/16 lane lock**.
- **The fix is in RTL, not constraints.** `USE_CLKBUF` puts the capture/word
  clocks on dedicated `BUFG` global nets; `USE_IDELAY` adds per-lane `IDELAYE2`
  (needs a 200 MHz `IDELAYCTRL` ref clock). XDC cannot constrain away a LUT the
  RTL placed on a clock pin.
- **Reproducible winning build: parent `72c280b` + submodule `17160eb`** →
  **16/16 bidirectional, cal_done=1, hold MET (WHS +0.051 ns)**, verified on the
  `bridge1` z2_02/z2_03 pair 2026-05-22.

---

## The mechanism

`USE_CLKBUF` (generate-guarded `BUFG` in `WavD2DGpioRx.v`) and `USE_IDELAY`
(per-lane `IDELAYE2` + `IDELAYCTRL` in `tidelink_idelay_rx.sv`) default **OFF**
at module level (bit-exact passthrough for sim/ASIC/UVM — no Xilinx primitive
elaborated) and are turned **ON only in the FPGA wrapper**
(`fpga/vivado_ip/tidelink_vivado_wrapper.v`: `USE_IDELAY=1'b1`, `USE_CLKBUF=1'b1`).
The 200 MHz `IDELAYCTRL` reference is wired as `clk_wiz` CLKOUT3 →
`tidelink_0/idelay_ref_clk` in both pair targets' `tidelink_design.tcl`.

When these hooks are present and enabled:
- `gpiorx_0..7/g_clkbuf.u_cap_bufg` → 8 capture BUFGs on `pad_clk_rx`
- 8× `IDELAYE2` + 2× `IDELAYCTRL` in the netlist
- `Place 30-568` count = **0**, post-route **WHS > 0** (hold met) → **16/16**

When stripped (`51b5169` onward, incl. `release/v1.0-rc1`):
- recovered clock synthesised through `WavClockMux` + `~adj_count[3]` onto
  **LUT-driven clock nets**
- **7× `Place 30-568`**, post-route **WHS −0.537 ns** (hold violated) → **0/16**,
  `cal_done=0` both dies

---

## Timeline (the regression)

| Commit | Date | USE_CLKBUF? | Lane lock |
|---|---|---|---|
| `0ea3d08` (sub `743821b`) | 2026-05-18 15:03 | **No** (pre-fix) | marginal — 0/16 to 13/16 by P&R luck |
| `7011e78` | 2026-05-19 23:12 | **introduced** (in-PHY clean-clock restructure) | — |
| **`72c280b` (sub `17160eb`)** | 2026-05-20 10:50 | **Yes, enabled** | **16/16 (reproducible)** ✅ |
| **`51b5169`** ← REGRESSOR | 2026-05-21 08:48 | **stripped** ("no idelay_*/USE_*") | breaks it |
| `02d4009` (`release/v1.0-rc1`) | 2026-05-22 | **No** (inherits strip) | **0/16** |

`72c280b` is an ancestor of `02d4009`: the release lineage **had** the working
fix and then removed it at `51b5169`.

---

## Commits / builds KNOWN TO WORK (locking)

| Build | Parent / sub | MD5 (master / slave) | Lock | Reproducible? | Notes |
|---|---|---|---|---|---|
| **`72c280b`** | `72c280b` / `17160eb` | `e2bd4d9f` / `0f752a05` | **16/16** | **YES** | USE_CLKBUF+USE_IDELAY; WHS +0.051; THE v1 target |
| tl_v7 | ≈`0ea3d08` / `743821b` | `b0633476` / `d5f42180` | 13/16 | No (pre-fix, timing-lucky) | preserved `mapstone-dev:/tmp/tl_v7_*` |
| tl_v6 | ≈`0cf9117` era | `d84521f8` / — | 13/16 | No (pre-fix) | preserved |
| tl_v7s | ≈05-18 18:08 | `8c6e16d1` / — | 11/16 | No (pre-fix) | preserved |

**Reproducible-v1 canonical hashes (72c280b build, 2026-05-22):**
- master `tidelink.bin` MD5 `e2bd4d9ff308db8c0c46c0000b143f25`
- slave `tidelink-flip.bin` MD5 `0f752a059557779a584400138cff8098`

## Commits / builds KNOWN TO FAIL (0/16, cal_done=0)

| Build | Parent / sub | Reason |
|---|---|---|
| `release/v1.0-rc1` | `02d4009` / `a55d346` | USE_CLKBUF stripped by `51b5169`; 7× Place 30-568, WHS −0.537 |
| `8bc6051` | `8bc6051` / `de44db6` | pre-USE_CLKBUF (clean-host build 0/16 too) |
| `0ea3d08` fresh | `0ea3d08` / `743821b` | pre-USE_CLKBUF; WHS −0.595 (marginal, unlucky P&R) |
| phase-v2 (`188ebdd8`) | ~05-06 | pre-IDELAY/T3/S_HOLD |
| hwval (`86aa3a95`) | ~05-20 eve | non-locking (pre/partial fix) |

---

## Hypotheses investigated and DISPROVEN (the journey)

| # | Hypothesis | Verdict | Why wrong |
|---|---|---|---|
| 15 | xhb500/generated rsync contamination | 🧊 | fresh regen still 0/16 |
| 26 | clk_wiz 50→25 MHz mutation | 🧊 | apples-to-oranges target diff; 25 MHz since inception |
| 28 | post-power-cycle ribbon HW damage | 🧊 | tl_v7 13/16 pre+post cycle — HW fine |
| 25 | farm-host-a build-env regression | 🧊 | 8bc6051 builds 0/16 on clean farm-host-b too — it's the commit, not the env |
| (mine) | marginal timing luck / fix via set_false_path | partially right (symptom) but **superseded** | the failing hold is the *functional* LUT-driven clock; XDC can't fix it — the RTL `USE_CLKBUF` fix can |

Recurring lesson: **every dead-end was commit/bitstream/provenance confusion
masking the single missing RTL fix.** Agents that trusted stored provenance
labels reached wrong conclusions; agents that empirically rebuilt + HW-tested
got it right.

---

## Prevention guards built this session

To stop the bitstream/provenance confusion class of error recurring:

1. **`tidelink_clkfreq_check`** (`feat/clkfreq-check`) — runtime link clock-freq
   cross-check (catches wrong-bitstream/mismatched-clk via dual-counter + Gray CDC)
2. **Deploy provenance guard** (`fix/deploy-provenance-guard`) — `deploy_pair.sh`
   SHA256-verifies the bitstream before flashing (aborts on mismatch)
3. **`td-artifact` content-addressed store** (`feat/td-artifact-store`) — immutable
   blobs, deploy-by-label, lock-history; makes "stale /tmp clobbered the bitstream"
   structurally impossible
4. **Vivado msg gate** (`57c2810`) — fail-fast on silent constraint-drop CRITICAL WARNINGs
5. **Verilator strict-lint gate** (`feat/verilator-lint-gate`) — synth-class bug gate

---

## v1 action

Re-base `release/v1.0-rc1` onto **`72c280b` (sub `17160eb`)** so the release source
builds its own 16/16 bitstream (closes the source↔bitstream integrity gap), rebuild
the `v1-release/` bundle with the `e2bd4d9f`/`0f752a05` bitstreams, after confirming
16/16 is stable across an N-deploy reliability run.

**Recommended fix-forward for the active branches:** revert/restore the
`USE_CLKBUF`/`USE_IDELAY` hooks that `51b5169` stripped, OR re-base onto `72c280b`,
on any branch intended for FPGA bring-up.
