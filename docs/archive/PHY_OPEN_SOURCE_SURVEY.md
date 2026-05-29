# PHY_OPEN_SOURCE_SURVEY — survey of open-source PHY alternatives for TideLink

**Date:** 2026-05-27
**Author:** Survey agent (read-only research; no RTL touched)
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-phy-archdoc`
**Scope:** Look for an open-source, source-synchronous, ~16-pin/direction GPIO-style chiplet PHY with per-lane bit-slip + phase calibration we could borrow heavily from, instead of continuing to fix the Wavious-derived stack whose calibrator picks eye-EDGE not eye-CENTRE (`docs/CALIBRATOR_BUG_HANDOFF_2026_05_26.md`, `docs/agent_b_phy_interface_audit.md`, `docs/agent_o_structural_fix_proposal.md`).

---

## 1. Executive summary

There **is** a credible near-drop-in alternative: **pulp-platform/serial_link** (ETH Zurich PULP). It is a silicon-validated (Occamy, GF 12 nm FinFET, July 2022), all-digital source-synchronous DDR die-to-die link with **8 lanes per direction**, AXI4 protocol layer, an explicit channel-allocator fault-tolerance layer, active in May 2026 (v2.0.0 release April 2026), permissive Solderpad SHL-0.51 license. Its calibration scope is narrower than what we currently have — it identifies **bad channels** by pattern compare and reroutes around them, but does **not** sweep per-lane sampling phase — so it does not by itself solve our eye-centring problem; it solves a different (and arguably more important) reliability problem and would push our centring work into IDELAY-tap sweep code we keep.

A clear second is **UC Berkeley ucb-bar/ucie + uciedigital** (BSD-3-Clause, Scala/Chisel). It has the right *shape* of training/sweep code (MBTrainer, MBInitFSM, per-lane PatternGenerator with per-lane errorCount) but is **explicitly incomplete** — `MBInitFSM.scala`'s training-pattern + sampling-phase selection states are marked TODO. Not silicon-validated. Useful as a **design reference** for the architecture of a layered training FSM but not as a drop-in.

**Headline recommendation:** Replace the Wavious *link-layer / channel-recovery* with PULP serial_link; keep our IDELAY+slip+phase calibrator but rewrite it per Agent O's structural-fix proposal using the eye-width centre algorithm pattern documented below in §7. None of the surveyed projects has a ready-to-use eye-CENTRE calibrator — every silicon-validated source-sync chiplet PHY we found delegates phase alignment either to a hard IDDR macro (BSG, PULP) or to physical board termination + 90-degree natural offset (BSG ODDR PHY). Our 100 MHz target on PYNQ-Z2 (xc7z020) needs explicit IDELAY taps, which puts us off-piste of every survey candidate.

---

## 2. Survey methodology

Investigated 14 candidate projects via WebSearch + WebFetch over ~50 min, with results triangulated against repo READMEs, raw source files, and (for Occamy) the recent ETH paper *Toward Open-Source Chiplets for HPC and AI: Occamy and Beyond* (arXiv:2511.15564). Filters applied: (i) source-synchronous parallel PHY (not SerDes/Aurora/PCIe), (ii) lane count ~8 (or parametric), (iii) speed range overlapping 25–250 MHz forwarded clock, (iv) permissive license (Apache/BSD/MIT/SHL — copyleft and proprietary excluded), (v) **synthesisable RTL or Chisel-emitted Verilog** (not VHDL, not behavioural-only). For each candidate, the calibration mechanism was specifically probed: is there a per-lane phase sweep? Is "best phase" picked by widest eye or first-passing? For PULP I fetched the channel-allocator and `slink_phys_layer.sv` source to confirm; for BSG I fetched `bsg_link_source_sync_downstream.sv`, `bsg_link_oddr_phy.sv`, `bsg_link_ddr_downstream.sv`, `bsg_link_osdr_phy_phase_align.sv`; for UCIe I fetched `MBTrainer.scala`, `MBInitFSM.scala`, `PatternGenerator.scala`. The current Wavious stack and the LMCo AXI4/AIB bridge were also revisited.

---

## 3. Candidates table

| Project | URL | License | Lanes | Speed | Cal approach | Verif | Active | Match (1-5) |
|---|---|---|---|---|---|---|---|---|
| **pulp-platform/serial_link** | https://github.com/pulp-platform/serial_link | SHL-0.51 (permissive) | Param, default 8 DDR | 250 MHz io clk (Occamy nominal 125) | Channel-allocator: SW pattern compare, mask + reroute. NO per-lane phase sweep. | Silicon: Occamy GF 12 nm FF, July 2022 (dual-chiplet, 64 Gbit/s duplex). | Yes — v2.0.0 7 Apr 2026 | 4 |
| **ucb-bar/ucie + uciedigital** | https://github.com/ucb-bar/ucie  https://github.com/ucb-bar/uciedigital | BSD-3-Clause | Param (UCIe-ish module widths) | UCIe 1.1 target | MBTrainer/MBInitFSM scaffolding; PatternGenerator has per-lane errorCount. **Phase-pick logic flagged TODO** in MBInitFSM.scala. | Sim only; "rewriting portions" of impl. May 2026 commits. | Yes — Jan 2026 | 2 |
| **bespoke-silicon-group/basejump_stl (bsg_link)** | https://github.com/bespoke-silicon-group/basejump_stl/tree/master/bsg_link | BSD-3-Clause | Param | 1.2 Gbps/pin LVCMOS (≥600 MHz io clk implied) | **Delegated**: ODDR PHY uses 90° natural offset (negedge clk drives forwarded clock, posedge data → centre-aligned). IDDR PHY "assumes incoming clock is center-aligned." NO sweep. Phase-align module is a 180° XOR clock inverter, not calibration. | Silicon: 4 BSG chips taped out TSMC 180/16 nm. | Active library; bsg_link files dated Paul Gao 2014/2019 | 3 |
| **chipsalliance/aib-phy-hardware (v2.0/rev1.1)** | https://github.com/chipsalliance/aib-phy-hardware | Apache-2.0 | 24 channels MAIB-style; AIB lanes typ. 80/ch | AIB 1.0: 2 Gbps/lane; AIB 2.0: 6× | RTL is "extracted from an actual AIB 2.0 design" — includes BCA macro w/ DLL/redundancy but **no source-level per-lane sweep visible from dir listing**. AIB assumes mature analog calibration in hard IP. | Production AIB taped out by Intel (proprietary refs); the open RTL is for sign-off/DV. | Last commit Sep 2022 — effectively frozen | 1 |
| **waviousllc/wav-wlink-hw** (the CURRENT stack) | https://github.com/waviousllc/wav-wlink-hw | Apache-2.0 | 8 GPIO | parametric | The buggy one we're trying to escape (Chisel-emitted Verilog). 1-lane reference test only. | Sim only. | **Last commit Oct 2021 — abandoned** | n/a (current) |
| **waviousllc/wav-d2d-hw** | https://github.com/waviousllc/wav-d2d-hw | Apache-2.0 | 8 lane Wlink + D2D | n/a | Same calibrator family as wlink. | Sim only. | Last commit Oct 2021 — abandoned | 1 |
| **SLink-Protocol/S-Link** | https://github.com/SLink-Protocol/S-Link | MIT | up to 8 (spec: 128+) | n/a in README | Link-layer protocol; "freedom for application and physical layers" — i.e. NO PHY calibration included. | FPGA tested 4TX/4RX on Zedboard. | Last release Jul 2021; now maintained by Wavious | 1 |
| **PrincetonUniversity/openpiton (chip bridge)** | https://github.com/PrincetonUniversity/openpiton | BSD-3-Clause-ish | 32-bit unidir × 2 | "9 Gbps over FPGA serial" — NOT source-sync GPIO | Inter-chip credit-based flow control; **no per-lane PHY calibration**. | FPGA serial link only. | Active | 1 |
| **chili-chips-ba/openeye-CamSI** | https://github.com/chili-chips-ba/openeye-CamSI | BSD-3-Clause | 2-or-4 LVDS DDR + clock | CSI rates | IDELAY-based eye-centring for MIPI CSI-2. Clock_Lock_FSM. **Closest match to "eye-centre via IDELAY tap sweep" but is a 4-lane MIPI receiver, not 8-lane bidirectional chiplet.** | FPGA only (Artix-7). | Active (chili-chips lab) | 2 |
| **someone755/ddr3-controller** | https://github.com/someone755/ddr3-controller | n/a (no LICENSE shown) | DDR3 byte-lane | DDR3 freq | IDELAYE2 sweep "to center the DQS edges into the center of the DQ data eye." Whole-bus sweep, not per-bit. README notes "improvement can be made." | FPGA only (xc7-series). | Stale | 2 |
| **AngeloJacobo/UberDDR3** | https://github.com/AngeloJacobo/UberDDR3 | **GPL-3.0** | DDR3 byte-lane | DDR3 freq | Has MPR-based read cal + write leveling + bit-slip training in `rtl/ddr3_controller.v`. Active dev. | FPGA validated on Arty-S7, Nexys Video, QMTech Wukong. | Very active | 1 (GPL excludes) |
| **lmco/axi4_aib_bridge** | https://github.com/lmco/axi4_aib_bridge | Apache-2.0 | depends on AIB | n/a | Bridge only — uses external `tlrb_aib_phy` for PHY. | DV report in repo. | **Archived Dec 2024** | 1 |
| **google/open-chiplet** | https://github.com/google/open-chiplet | Apache-2.0 | n/a | n/a | Spec only — no RTL. | n/a | **Archived Nov 2022** | 0 |
| **chipsalliance/aib-protocols** | https://github.com/chipsalliance/aib-protocols | Apache-2.0 | varies | varies | Protocol RTL (PHY-side) on top of AIB hard macro. | DV included. | Some 2023 activity | 1 |

---

## 4. Top 3 candidates in detail

### 4.1 pulp-platform/serial_link — strongest match, primary recommendation for L2/L3

**Pros:**
- **Silicon-validated** in real die-to-die mode: Occamy (RISC-V manycore chiplet) taped out at GF 12 nm FinFET, July 2022. Paper (arXiv:2511.15564) reports 96% link utilisation on 16 KiB transfers, 1.6 pJ/bit, 19.5 GB/s wide-segment bandwidth across 38 PHYs. Each PHY: **all-digital, source-synchronous duplex, 8 DDR lanes per direction** — *this is exactly the topology TideLink targets*.
- License **SHL-0.51 (Solderpad)** — permissive, Apache-style, lab-compatible.
- AXI4 protocol layer included (we don't need it — we have FC adapter — but it's clean to bypass).
- Active in May 2026: v2.0.0 release 7 Apr 2026; commits march through Mar-Apr 2026 cleaning up Make→Justfile, REUSE license headers.
- Has a **channel allocator** — explicit fault-tolerance layer that detects bad lanes via SW pattern compare and reroutes packets across the working set. Solves a class of bug we currently don't even detect: a single dead/glitchy lane silently corrupts our link until full re-cal. Source: `src/channel_allocator/slink_ch_alloc.sv`, `src/channel_allocator/serial_link_channel_allocator.sv` (sub-module names confirmed).
- The "Raw Mode" gives SW full per-channel visibility (good for our bringup-debug workflow).
- Param `SLINK_NUM_LANES` defaults 8, matches our pin budget exactly.
- Used in **multiple PULP tapeouts** beyond Occamy (Snitch-based systems).

**Cons:**
- **No per-lane sampling-phase sweep.** The physical layer (`src/slink_phys_layer.sv`, SHL-0.51, Tim Fischer ETH) literally has zero phase / bit-slip / IDELAY calibration logic — it relies on a forwarded clock + IDDR centre-alignment assumption. This is fine on ASIC (Occamy ran at 125 MHz io clk, max 250) where you control routing skew, but on FPGA where the forwarded clock arrives at a different pin/MMCM than the data, you need IDELAYs and a sweep — which is exactly what TideLink needs and what serial_link does *not* provide.
- The channel allocator's "calibration" is a per-channel **functional pattern check** (8-element shift pattern; bidirectional channel-mask exchange — see `tb_ch_calib_slink.sv`, copyright ETH 2022/SHL-0.51), **not** a per-lane sampling-phase sweep. It would not have caught the calibrator-eye-edge bug we're chasing.
- Implementation language is SystemVerilog; we already use SV — no port cost.
- Channel count parameter has implications for the AXI protocol layer we'd skip.

**Integration cost estimate:** ~2-3 weeks. Replace `axi_chiplet_controller` link-and-data-link layers with serial_link's. Reuse our FC-adapter as the user-side mapper; bypass serial_link's `slink_prot_layer.sv` (AXI4). Keep our own per-lane PHY calibrator (rewritten per Agent O) underneath serial_link's `slink_phys_layer.sv` interface. Channel-allocator gives us free fault-tolerance — adopt as-is.

**Calibrator design notes:**
- serial_link's channel allocator does NOT provide eye-centre selection. It does provide **bad-channel detection** (mask + redistribute) which is complementary to and orthogonal to eye-centre selection. We should keep our own per-lane (slip, phase) sweep + eye-centre algorithm UNDERNEATH whatever link layer we adopt.

### 4.2 ucb-bar/ucie + uciedigital — architectural reference, not drop-in

**Pros:**
- Layered Chisel implementation matches the TideLink stack shape: `logphy/` has `LinkTrainingFSM.scala`, `MBInitFSM.scala` (main-band init), `MBTrainer.scala`, `PatternGenerator.scala`, `PatternReader.scala`, `PatternWriter.scala`, `RdiBringup.scala` — the right *vocabulary* for what a calibrator should look like.
- **PatternGenerator has per-lane error counters** (`errorCount = RegInit(VecInit(Seq.fill(afeParams.mbLanes)(0.U(maxPatternCount.W))))`) — exactly the per-lane bookkeeping our calibrator needs.
- BSD-3-Clause.
- Active (last commit Jan 2026 on ucie, Jan 2026 on uciedigital).
- UC Berkeley BAR has serious silicon credibility (RocketChip, Chipyard).

**Cons:**
- **Explicitly incomplete.** `MBInitFSM.scala` clearly says training pattern + sampling phase selection are TODO. Clock-repair / validation states are commented out. No silicon tape-out yet.
- Per-lane phase sweep + eye-centre logic is **not implemented** — the trainer is a pattern-exchange FSM, not a sampling-phase calibrator.
- Chisel-emitted Verilog; we tolerate this (Wavious is also Chisel) but it adds build-chain complexity.
- UCIe is a much bigger spec than we need (sideband, MBAFE, D2D adapter, 32-lane modules) — it would force us into significant integration overhead for very little PHY benefit.

**Integration cost estimate:** Not viable as drop-in. Useful as a **design-pattern reference** for a layered training FSM with per-lane error counters. Estimated borrow value: 1-2 days of reading.

**Calibrator design notes:**
- Borrow the *structure*: separate PatternWriter/PatternReader/MBTrainer roles; per-lane errorCount vector; SUCCESS/ERR + timeout reporting. Our calibrator currently mixes pattern-gen, score-keeping, and FSM in one ~700-line file; the UCIe split-of-concerns is cleaner.

### 4.3 BaseJump STL bsg_link — silicon-credible but delegates phase alignment

**Pros:**
- BSD-3-Clause; Bespoke Silicon Group (UCSD/Manycore).
- Four chips taped out (TSMC 180/16 nm) using this link family. Tested at 1.2 Gbps/pin LVCMOS.
- Clean modular files: `bsg_link_source_sync_{upstream,downstream}.sv`, `bsg_link_ddr_{upstream,downstream}.sv`, `bsg_link_oddr_phy.sv`, `bsg_link_iddr_phy.sv`. Token-credit flow control built in.
- ODDR PHY uses the elegant trick: forwarded clock is generated on `negedge` of input clock, data is generated on `posedge` → natural 90° centre-aligned output (we should **borrow this**, see §7).

**Cons:**
- The receiver "assumes incoming clock is center-aligned to data bits" — i.e. it **delegates** per-lane phase calibration to either physical board termination or to an upstream PHY layer (IDDR with hard analog calibration). BSG's silicon path uses hard IO macros that handle this; on FPGA you'd need IDELAY + sweep, which BSG doesn't provide.
- `bsg_link_osdr_phy_phase_align.sv` is a 180°-shift clock-inverter (XOR of two flops), NOT a calibration module — the file name is misleading.
- No per-lane bit-slip or sampling-phase sweep at all in `bsg_link/`. The phase-alignment problem we have simply *doesn't exist* in BSG's design because they pin termination + 90°-natural-offset their way around it.
- Not active development (most files dated Paul Gao 2019).

**Integration cost estimate:** Adopting BSG wholesale = adopting a different assumption set (board-level skew control) we don't have on PYNQ-Z2. ~3 weeks to integrate AND we still don't get our centring fix because BSG doesn't have one. Net: low value as drop-in; high value as a **specific design pattern source** (90°-natural-offset TX clock generation).

**Calibrator design notes:**
- Their `bsg_link_oddr_phy.sv` TX-clock-generation pattern (negedge clock for forwarded clock, posedge for data) is worth **borrowing on the ASIC side** — it eliminates the need for explicit TX-side phase calibration when you control routing skew. For FPGA we still need IDELAY taps on the RX.

---

## 5. Verdict

**Recommendation: Hybrid — keep our own calibrator (rewritten per Agent O), borrow the link layer from PULP serial_link, borrow design patterns from openeye-CamSI and UCIe.**

Specifically:
1. **REPLACE the Wavious link layer / channel-recovery (`axi_chiplet_controller` minus FC adapter) with PULP serial_link v2.0.0.** Gets us silicon-validated, actively-maintained, SHL-0.51 code with a real channel-allocator fault-tolerance layer that fixes a class of bug we don't even detect yet.
2. **KEEP our own per-lane PHY calibrator (`tidelink_phy_align_calibrator.sv`) but rewrite it per Agent O's structural-fix proposal** with `MIN_LOCK_DWELLS` widest-contiguous-run eye-centre selection. None of the surveyed projects has a usable centring algorithm — the only IDELAY-sweep ones (openeye-CamSI, ddr3-controller, UberDDR3) are either bus-wide (not per-lane), DDR3-specific, or GPL.
3. **DO NOT** adopt UCIe (too heavy, incomplete), AIB (frozen since 2022, hard-IP-assuming), BSG bsg_link (no FPGA calibration), or anything else from the table at match ≤ 2.

**Confidence:** Moderate-to-high on (1) and (2); high on the "nothing usable found" verdict for the centring algorithm specifically — every silicon-validated source-sync chiplet PHY delegates phase calibration to mixed-signal IP or board control.

---

## 6. Integration plan — PULP serial_link adoption

Phased plan, low-risk reversible:

**Phase A (1 week) — Sandbox spike.**
Clone serial_link v2.0.0 to a worktree. Stand up `tb_ch_calib_slink` in our cocotb harness. Confirm AXI-Stream payload path matches our FC-adapter axis bus. Measure simulation cycles to bringup vs. our 50-min FPGA loop.

**Phase B (1 week) — Adapter layer.**
Write a thin wrapper that maps our FC-adapter axis to serial_link's AXI-Stream user port (bypass `slink_prot_layer.sv`). Keep `axi_chiplet_controller` standalone-buildable as a fallback flist.

**Phase C (3-5 days) — PHY pluggability.**
serial_link's `slink_phys_layer.sv` is bit-exact source-sync DDR with no calibration. Swap in our `tidelink_phy_align_calibrator.sv` + `tidelink_idelay_rx.sv` between serial_link's logical Phy and the pads. This is the design-intent integration point — both projects converge on the same interface shape (lane data + forwarded clock).

**Phase D (1 week) — Calibrator rewrite per Agent O.**
Independent of the link-layer swap. Implement `MIN_LOCK_DWELLS` widest-eye-centre selection, `S_FINALIZE` state, demoted `S_PROBE`, APB-runtime `SWI_CAL_MIN_DWELLS`. Validate against `cocotb/tidelink_phy_align_calibrator/test_eye_offcenter.py`.

**Phase E (1 week) — Integration sim + HW bringup.**
Run `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py` end-to-end with new link layer + new calibrator. Build & deploy on `pynq-z2-pair-flip-ila`.

Reversibility: every phase keeps the Wavious flist as a fallback target. If serial_link doesn't integrate cleanly we stop after Phase D and keep the calibrator rewrite — which is the most-load-bearing piece anyway.

---

## 7. Borrowable design patterns (5)

Even with no drop-in, these specific patterns from the survey should land in the rewrite:

### Pattern 1 — MIN_LOCK_DWELLS widest-contiguous-run eye-centre (Agent O, no surveyed project)

No surveyed project implements this directly, but it's the right algorithm. Pseudocode (already in `agent_o_structural_fix_proposal.md` §3): scan slip-inner sweep order; track current-run-length and best-run-length per lane; at sweep exhaustion latch `(slip, phase) = run_start + floor((best_run-1)/2)`. Requires one new FSM state (`S_FINALIZE`), ~75 lines RTL. **This is the most important borrowable pattern; it just happens to come from our own Agent O, not the survey.**

### Pattern 2 — Per-channel functional pattern verification with bidirectional mask exchange (PULP serial_link)

From `tb_ch_calib_slink.sv` (SHL-0.51, ETH/Bologna 2022): send 8-element shifting bit pattern through all lanes simultaneously in Raw Mode; per-lane RX compares against expected; mark non-matching as `bad_channel_mask`; **exchange the local-RX-bad-mask with the peer over the link itself**, both sides reconfigure `channel_allocator` to skip bad lanes. This is orthogonal to and complementary to phase calibration: phase cal picks the best sampling point on a working lane; channel masking handles a permanently dead/stuck lane. We have neither right now. Adopt as a follow-up after the centring fix.

### Pattern 3 — Layered training FSM with per-lane error counter (UCIe `MBTrainer.scala` + `PatternGenerator.scala`)

Split the calibrator into three roles: `PatternWriter` (drive training symbols out), `PatternReader` (capture + per-lane errorCount vector), `MBTrainer` (FSM that walks through phases, requests, response handshakes). Our current `tidelink_phy_align_calibrator.sv` mixes all three at ~700 lines; the UCIe pattern is much cleaner. Snippet from `PatternGenerator.scala`:
```scala
errorCount = RegInit(VecInit(Seq.fill(afeParams.mbLanes)(0.U(maxPatternCount.W))))
```
Per-lane vector indexed by lane id; written by the reader, read by the FSM at dwell-expire to decide pass/fail per lane. Use this idiom.

### Pattern 4 — IDELAY tap sweep + eye-centre on Artix-7 (openeye-CamSI)

The `chili-chips-ba/openeye-CamSI` project (BSD-3-Clause) demonstrates exactly the FPGA primitive chain we need: **IBUFDS → IDELAYE2 → ISERDES** with PLL-driven IDELAY reference clock. Their `Clock_Lock_FSM` is a per-lane lock-detector; eye-centring is done by IDELAY tap walk. We are already using IDELAYE2 + ISERDES (see `tidelink_idelay_rx.sv`); their organisation of the lock FSM and the IDELAY tap update path is cleaner than our current `WavD2DGpioRx.v` overrides. **Specifically borrow:** the staging of `IDELAY tap update → wait for lock-FSM to re-converge → score → advance` as a known-good sequence (vs. our current asynchronous calibrator → IDELAY → score path which has the CDC hazard documented in `agent_b_phy_interface_audit.md` §4 Suspect C).

### Pattern 5 — Source-sync TX clock at natural 90° offset (BaseJump bsg_link_oddr_phy.sv)

From Paul Gao 2019:
```systemverilog
always_ff @(negedge clk_i) begin
  if (reset_i_r) clk_r <= 1'b0;
  else clk_r <= ~clk_r;
  clk_r_o <= clk_r;
end
```
TX data is generated on `posedge clk_i`; forwarded clock toggles on `negedge clk_i`. Natural 90° centre-alignment for free. On ASIC where you control routing skew this eliminates **the TX-side phase calibration problem entirely** — only RX side needs IDELAY for board/package skew compensation. Worth considering for the v2 ASIC TX path (we currently calibrate TX phase via the same calibrator that should only need to calibrate RX). On FPGA we keep IDELAY because pad-to-IDDR skew is uncontrolled.

---

## 8. Disqualified candidates (so you don't ask)

For completeness, the following were investigated and disqualified:

- **AIB v2.0/rev1.1** (chipsalliance) — Apache-2.0 but frozen since Sep 2022. Designed around hard analog macro (BCA); the open RTL is sign-off/DV scaffolding, not a synthesisable PHY calibrator. Pin pitch + analog assumptions wildly mismatched to our PYNQ-Z2 GPIO.
- **OpenHBI** — spec only, no open RTL, targets interposer HBM-style channels, not our problem.
- **lmco/axi4_aib_bridge** — Apache-2.0 but **archived Dec 2024**; only the bridge layer, the underlying `tlrb_aib_phy` is a separate submodule that's even more constrained.
- **google/open-chiplet** — Apache-2.0 but **archived Nov 2022**; specification only.
- **OpenPiton chip bridge** — Source-sync but FPGA-serial-link only (9 Gbps), no per-lane PHY calibration; ProcessingCommunication abstracted at a credit/NoC level that doesn't help our problem.
- **BlackParrot chiplet I/O** — Searched; no usable open-source D2D PHY found (paper-level references only; not on GitHub at a useful granularity).
- **SiFive Freedom / U-series** — No open-source chip-to-chip PHY found.
- **lowRISC OpenTitan** — Single-die security chip; no off-chip PHY of our shape.
- **NVIDIA NVDLA** — No D2D PHY.
- **AngeloJacobo/UberDDR3** — **GPL-3.0**, disqualified by license per the brief ("copyleft probably NOT compatible"). Otherwise the most actively-maintained eye-centring read calibrator on FPGA we found.
- **someone755/ddr3-controller** — No LICENSE file visible; small project; bus-wide (not per-bit/lane) sweep. README acknowledges centring "improvement can be made."
- **S-Link** (SLink-Protocol/S-Link) — MIT; predecessor of Wavious wlink, **now maintained by waviousllc** — i.e. it IS our current stack's ancestor. No newer/better calibrator there.
- **wav-d2d-hw** — Same family as the current stack; abandoned Oct 2021. Not newer than what we have.
- **Wavious LPDDR PHY** (wav-lpddr-hw) — DDR memory PHY, not chiplet-to-chiplet; different topology.
- **chili-chips-ba/openPCIE / openCologne-PCIE** — SerDes-only PCIe; doesn't apply to our source-sync GPIO.
- **OpenSERDES (SparcLab)** — full SerDes for SkyWater 130 nm; overkill, wrong topology.
- **Chipyard UCIe integration** — searched; not surfaced as a discrete useful artefact beyond ucie/uciedigital above.

---

## 9. References (verifiable URLs)

- pulp-platform/serial_link: https://github.com/pulp-platform/serial_link  (v2.0.0 release 2026-04-07; SHL-0.51)
- serial_link channel calibrator TB: https://github.com/pulp-platform/serial_link/blob/main/test/tb_ch_calib_slink.sv  (header confirms SHL-0.51, ETH/Bologna 2022)
- serial_link phys layer: https://github.com/pulp-platform/serial_link/blob/main/src/slink_phys_layer.sv
- serial_link channel allocator: https://github.com/pulp-platform/serial_link/blob/main/src/channel_allocator/slink_ch_alloc.sv
- Occamy paper (Snitch/PULP): https://arxiv.org/html/2511.15564 ("Toward Open-Source Chiplets for HPC and AI: Occamy and Beyond")
- Occamy chip page: http://asic.ethz.ch/2022/Occamy.html ; https://pulp-platform.org/occamy/
- ucb-bar/ucie: https://github.com/ucb-bar/ucie  (latest commit Jan 2026; BSD-3-Clause; Scala/Chisel)
- ucb-bar/uciedigital MBTrainer: https://github.com/ucb-bar/uciedigital/blob/main/src/main/scala/logphy/MBTrainer.scala
- ucb-bar/uciedigital MBInitFSM: https://github.com/ucb-bar/uciedigital/blob/main/src/main/scala/logphy/MBInitFSM.scala  (training-pattern + sampling-phase TODOs visible)
- ucb-bar/uciedigital PatternGenerator: https://github.com/ucb-bar/uciedigital/blob/main/src/main/scala/logphy/PatternGenerator.scala
- bespoke-silicon-group/basejump_stl bsg_link: https://github.com/bespoke-silicon-group/basejump_stl/tree/master/bsg_link
- bsg_link_oddr_phy.sv: https://github.com/bespoke-silicon-group/basejump_stl/blob/master/bsg_link/bsg_link_oddr_phy.sv (Paul Gao 03/2019)
- bsg_link_source_sync_downstream.sv: https://github.com/bespoke-silicon-group/basejump_stl/blob/master/bsg_link/bsg_link_source_sync_downstream.sv
- chipsalliance/aib-phy-hardware: https://github.com/chipsalliance/aib-phy-hardware  (last commit Sep 2022)
- chili-chips-ba/openeye-CamSI: https://github.com/chili-chips-ba/openeye-CamSI  (BSD-3-Clause; Artix-7 IDELAY eye-centre)
- someone755/ddr3-controller: https://github.com/someone755/ddr3-controller
- AngeloJacobo/UberDDR3: https://github.com/AngeloJacobo/UberDDR3  (GPL-3.0)
- waviousllc (current stack origin): https://github.com/waviousllc  (last activity 2022)
- lmco/axi4_aib_bridge: https://github.com/lmco/axi4_aib_bridge  (archived 2024-12-13)
- google/open-chiplet: https://github.com/google/open-chiplet  (archived 2022-11-08)
- SLink-Protocol/S-Link: https://github.com/SLink-Protocol/S-Link  (MIT; predecessor of waviousllc)
- PrincetonUniversity/openpiton: https://github.com/PrincetonUniversity/openpiton

---

## 10. Bottom line

The open-source-PHY landscape in May 2026 has **one credible, actively-maintained, silicon-validated source-sync chiplet PHY**: PULP serial_link. It does not by itself solve our specific calibrator-eye-edge bug because none of the surveyed projects has a per-lane sampling-phase calibrator with eye-centre selection — every silicon-validated one delegates that to mixed-signal IP, board control, or hard IDDR macros. We are off-piste on FPGA where IDELAY-tap sweeps are mandatory; that's our problem to own.

Recommended action: borrow the link-layer (serial_link), borrow design patterns (UCIe layered FSM, BSG natural 90° TX, openeye-CamSI IDELAY chain), and write our own MIN_LOCK_DWELLS eye-centre calibrator as Agent O proposed. Estimated effort: 4-5 weeks vs. ~indefinite continued fixing of the current Wavious calibrator.
