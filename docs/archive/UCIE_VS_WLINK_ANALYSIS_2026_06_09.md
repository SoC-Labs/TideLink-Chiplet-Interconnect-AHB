# Replacing Wlink with UCIe in TideLink — A Decision-Grade Technical Report

**Prepared for:** David Mapstone, SoC Labs, University of Southampton
**Subject:** Feasibility, overhead, and migration analysis for replacing the Wavious Wlink D2D controller with UCIe (or a UCIe-inspired stack) in the TideLink AHB chiplet-interconnect subsystem
**Date:** 2026-06-09
**Target system:** AHB chiplet interconnect, Cortex-M-class, Wlink over single-ended GPIO PHY, PYNQ-Z2 FPGA (~25–100 MHz), TSMC65 ASIC target
**Provenance:** Synthesized from an 8-agent codebase+research workflow, then adversarially fact-checked and completeness-reviewed. Corrections folded in 2026-06-09 (notably UCIe 3.0 / 64 GT/s, and S-Link maturity).

---

## Source-reliability disclaimer (read first)

The UCIe specification is members-only. Every numeric/protocol UCIe claim below (4 GT/s floor, 800 MHz sideband, FDI/RDI signal names, raw-mode CRC drop, LTSSM sub-states) is derived from the HotChips 2023 UCIe tutorial, EDPS 2023 keynote, the UCIe Consortium blog/flipbook, vendor VIP docs (Synopsys/Cadence/Alphawave) and design-reuse articles — **not from the spec verbatim**. They are corroborated across multiple sources and treated as indicative. Codebase claims carry `file:line` citations and are first-hand.

---

## Executive Summary

TideLink today is a working, silicon-and-sim-validated open D2D link: an AHB subsystem that wraps the Wavious **Wlink** packet controller over a custom **single-ended GPIO PHY**, brought up to bilateral 8/8 lane lock on FPGA after months of calibrator/deskew/FCSM/byte-align debugging. The question is whether to replace Wlink with **UCIe**.

**Bottom line: Do not replace Wlink with compliant UCIe for V1/V2.** UCIe's entire value proposition — multi-vendor, multi-node chiplet interoperability — is structurally unavailable to a single-vendor, same-node (TSMC65), two-die academic link, and its electrical layer cannot be met by a ~100 MHz single-ended GPIO PHY by orders of magnitude. You are, in effect, already running a "UCIe-inspired, non-compliant" link: Wlink is a layered, packetized, raw-mode-equivalent D2D controller with CRC/ECC/retry/power-states and a pluggable PHY.

The decisive technical facts:

- **Electrical impossibility on GPIO.** UCIe's *minimum* lane rate is **4 GT/s**; there is no sub-GT/s profile. Your PHY runs SDR at ~25 Mb/s/lane (FPGA) / ~100 Mb/s/lane (ASIC target). Canonical gap framing against the **4 GT/s floor**: **~4× short** at best-case FPGA SelectIO DDR (~1 Gb/s/lane, implementation-dependent), **~40× short** at the ASIC SDR target, **~160× short** at the FPGA SDR rate. Against the **64 GT/s ceiling (UCIe 3.0, Aug 2025)** the gap is up to **~640×–2560×**. UCIe additionally mandates a continuously-running **800 MHz sideband**, a forwarded clock with analog centering (DLL/PI), Valid/Track lanes, low-swing signaling, and **45/110 µm in-package micro-bumps** that a PCB-routed FPGA board cannot present.
- **The digital stack ports; the electrical AFE does not.** UCIe's Protocol Layer, D2D Adapter, and Logical PHY are ordinary synchronous RTL that runs on FPGA fabric. Only the electrical AFE is the wall. The honest framing for any UCIe work here is **"UCIe-inspired digital stack on a non-compliant GPIO electrical layer"** — which is electrically much closer to **BoW/AIB** than to UCIe.
- **The cost is large and the marginal functional gain is small (not zero).** A *compliant minimal* UCIe stack still requires the full LTSSM (SBINIT→MBINIT→MBTRAIN→LINKINIT→ACTIVE), the mandatory always-on sideband + protocol, parameter negotiation, the D2D adapter, and FDI/RDI conformance — a multi-engineer, multi-quarter RTL+verification project that re-implements capability Wlink already delivers, over the same GPIO PHY. The genuine (if minor) UCIe gains for *this* link are: standardized spare-lane repair (TideLink has masking only), a real retraining LTSSM (vs the frozen-once calibrator that is the root cause of several bring-up bugs), and a characterized BER/FEC (vs TideLink's uncharacterized BER).
- **TideLink's coupling to Wlink is narrow and the app layer is portable.** The entire functional mailbox data plane is one 48-bit credited valid/data/ready (+ valid/data/accept) handshake (`tidelink_fc_adapter.sv:135-141`). The fc_adapter, FIFO, returner, apb_regs, addr_translator and PTP modules are transport-agnostic and survive a controller swap unchanged. The Wlink coupling is concentrated in `tidelink_top.sv` and is mostly observability/control reach-in — **which is itself a hidden cost (see §7.5).**

**Recommendation: Option B for the engineering line** (keep Wlink's link layer; refactor TideLink's seam to a clean FDI/RDI-style boundary and document it in UCIe terms), **with Option C** (a Zero-ASIC-style scoped UCIe-streaming-raw demonstrator over a low-rate PHY) **as a deliberately-labelled "UCIe-inspired / non-compliant" research/teaching track** if and only if there is appetite and bandwidth. Reserve full compliant UCIe (Option D) for a hypothetical advanced-node, advanced-package V3 that has a genuine second-vendor chiplet to talk to. Do not let any UCIe work touch the hard-won V1/V2 bring-up.

---

## 1. Mapping the current TideLink/Wlink stack onto the UCIe layered model

UCIe defines three layers (Protocol / D2D Adapter / Physical = Logical PHY + Electrical AFE) joined by two standardized seams (**FDI** between Protocol↔Adapter, **RDI** between Adapter↔Logical PHY). Wlink is also a three-layer stack but with different, non-standard seams.

### 1.1 Side-by-side layer table

| UCIe layer / seam | UCIe role | TideLink/Wlink equivalent | Citation | Match quality |
|---|---|---|---|---|
| **Protocol Layer** | Presents/consumes flit payloads; PCIe/CXL/Streaming/Raw | **TideLink app layer**: AHB↔48-bit FC word; XHB500 AHB↔AXI bridges; PTP/TideChart sources | `tidelink_fc_adapter.sv:243-244`; `tidelink_top.sv:1539-1709` | Conceptual match; payload packing is custom |
| **FDI (Protocol↔Adapter)** | Flit-aware: `lp_data/lp_valid/lp_irdy` + `pl_trdy`; carries Adapter-LSM/vLSM state handshake | **FCSM app interface** `a2l/l2a` valid-ready + Diplomacy node bundles | `FC.scala:92-104`; `Nodes.scala:58-65,182-189`; `tidelink_top.sv:1969-1970` | **Where TideLink's app layer attaches.** Shape matches; no state-handshake fields |
| **D2D Adapter** | ARB/MUX, CRC, link-level retry, Link State Mgmt, parameter negotiation | **Wlink FC layer**: per-channel `WlinkGenericFCSM` (credit FC + CRC-16 + Go-Back-N replay) + TX/RX routers | `FC.scala:49-678`; `LinkLayer.scala:36-135,319-350` | **Strong functional match** — Wlink FC layer *is* a D2D-adapter-class reliability layer |
| **RDI (Adapter↔Logical PHY)** | Raw flit bytes + PHY state machine (RESET→ACTIVE) + clock-gating handshakes; `lp_state_req`/`pl_state_sts` | **Wlink link2phy seam** `WlinkPHYTx/RxBundle`: parallel word + `tx_en/tx_ready` + forwarded clock | `PHY.scala:59-74,84-121` | **The link2phy seam.** Much thinner than RDI — no sideband FSM, no per-lane valid framing, no formal state negotiation |
| **Logical PHY** | Byte↔lane map, Valid lane, scrambling, training-pattern gen, lane reversal/repair, training FSM, sideband msg TX/RX | **Wlink link layer (framing/ECC/striping)** + **TideLink calibrator + lane deskew** | `LinkLayer.scala:390-790,793-946`; `tidelink_phy_align_calibrator.sv:410-492`; `WavD2DGpio.v:346-370` | Partial: byte-striping + Hamming ECC + bring-up FSM + deskew exist; no Valid lane, no scrambling, no spec sideband |
| **Electrical / AFE** | Forwarded clock + 4–64 GT/s slices + 800 MHz sideband; DLL/PI; CTLE/DFE; micro-bumps | **WavD2DGpio**: 8× single-ended LVCMOS33 lanes + 1 fwd clock, 16:1 SDR serializer, no eq, no DLL | `WavD2DGpio.v:51-68`; `WavD2DGpioTx.v:308-323`; `WavD2DGpioRx.v:280-282` | **No match** — the hard wall (§3, §4) |

### 1.2 Where TideLink's app layer and the link2phy seam attach

1. **TideLink's app layer → UCIe FDI.** The fc_adapter's view of the controller is *"lossless, in-order, credited 48-bit beats with valid/data/ready (TX) + valid/data/accept (RX)"* (`tidelink_fc_adapter.sv:135-141`). This maps cleanly onto a **UCIe Streaming FDI** port with a thin shim that (a) carries ≥48 bits/beat (UCIe flits are 64B/256B-class, so one TideLink word is tiny — you would pad or aggregate; **aggregation has a PTP hazard, see §7.1**), (b) preserves in-order lossless delivery (the RX decoder is *stateless* and assumes every accepted word arrives intact and in order — `TIDELINK_SPECIFICATION.md:283`), and (c) provides backpressure equivalent to `a2l_ready`/`l2a_accept`, which FDI supplies natively.

2. **Wlink link2phy seam → UCIe RDI.** The `WlinkPHYTx/RxBundle` (`PHY.scala:59-74`) is the contract a PHY must implement: a clock-forwarded, source-synchronous *parallel-word* seam (`tx_en/tx_ready` + 128-bit word + forwarded clock) — far simpler than UCIe RDI, which adds a stateful sideband FSM, per-lane valid framing, and a negotiated RESET→ACTIVE state machine. **The single biggest architectural gap vs UCIe is that Wlink has no LTSSM, no sideband protocol, and no RDI/FDI state machine** — link bring-up (CR/CRACK credit handshake) happens in the *FC layer* (`FC.scala:444-499`), and bit/word alignment in the GPIO PHY is a free-running byte counter with no SOP delimiter (precisely why TideLink had to bolt on `tidelink_phy_align_calibrator` + `tidelink_lane_deskew`).

### 1.3 UCIe-comparison crib

| Concept | UCIe | Wlink/TideLink | Citation |
|---|---|---|---|
| LogPHY↔Adapter seam | RDI (stateful, flit + sideband FSM) | parallel word + `tx_en/tx_ready` + fwd clock, no FSM | `PHY.scala:59-74` |
| Adapter↔Protocol seam | FDI (flit-aware, state handshake) | `a2l/l2a` valid-ready + Diplomacy bundles | `FC.scala:92-104` |
| Link bring-up | LTSSM (PHY/sideband) | FC-layer credit handshake CR/CRACK; PHY has none | `FC.scala:444-499` |
| Flit | UCIe flit (64B/256B) | MIPI long/short packet `{data_id,WC,ECC,payload,CRC}` | `LinkLayer.scala` |
| Retry | Adapter CRC+retry | Per-FCSM CRC-16 + Go-Back-N replay | `FC.scala`; `WlinkGenericFCReplayV2` |
| Lane repair | spare-lane remap + reversal | `active_lanes` mask remap; fault flag; **no spare, no auto-repair** | `LinkLayer.scala:541-552`; `WavD2DGpio.v:272-311` |
| Power states | L1/L2 + ALMP/sideband | P-state (`WlinkTxPstateCtrl`) | `LinkLayer.scala:146-266` |
| Sideband | mandatory always-on 800 MHz, redundant | none — I²C/APB management | `PHY_ARCHITECTURE_REFERENCE.md:468-487` |

**Reading:** Wlink's FC layer is a genuine D2D-adapter analog (credit FC + CRC + retry + ARB/MUX). The gaps are all in *seam formalization* (no FDI/RDI state machines), *Logical-PHY completeness* (no Valid lane, no scrambling), and — decisively — *electrical/sideband*.

---

## 2. Q1 — Could we replace Wlink with UCIe?

**Technically yes; strategically and economically, not for V1/V2.** Three independent reasons:

**(a) The interop value is structurally unavailable.** UCIe's dominant benefit is composing chiplets from *different vendors* on *different nodes*. TideLink is single-vendor, same-node (TSMC65), two-die — both dies are your own RTL. Every UCIe benefit that requires a counterparty (3rd-party chiplet interop, heterogeneous-node mixing, native PCIe/CXL transport, commercial PHY IP reuse, compliance branding) evaluates to "not realizable" for this link. The project's own documentation already concluded UCIe and CHI are *"probably more complicated than needed"* (https://soclabs.org/project/axi-chiplet-controller).

**(b) The electrical layer is impossible on GPIO** (see §3, §4).

**(c) You would re-pay an integration cost you've already paid.** Wlink is sim- and silicon-debugged to bilateral 8/8 lane lock. Replacing it restarts that clock with a *larger* stack.

**What replacement would actually entail in the codebase:** a UCIe swap leaves the **entire application layer below `tidelink_top` intact** — `tidelink_fc_adapter.sv`, `tidelink_fifo*.sv`, `tidelink_returner.sv`, `tidelink_apb_regs.sv`, `tidelink_addr_translator.sv`, `tidelink_ptp*` are all transport-agnostic. The swap replaces the single `axi_chiplet_controller` instance (`tidelink_top.sv:1811-2097`) and the Wlink-specific glue: the packed `tidelink_in/out`/`ptp_in/out` buses, the `apb_sel_wlink` 0x0000-0x1FFF decode (`tidelink_top.sv:640-672`), the 0x208 pwdata hardening (`tidelink_top.sv:1764-1804`), and the deep observability reach-in (role/autoneg/eye/lane/Bug-A ports, `tidelink_top.sv:1844-2097`; credit-path regs reading `WlinkGenericFCSM_6.state`, `REGISTER_MAP.md:172-218`). **A UCIe swap is overwhelmingly a `tidelink_top` rewrite, not an app-layer rewrite.** The single load-bearing contract to preserve is the fc_adapter's: lossless, in-order, credited ≥48-bit beats with valid/data/ready + valid/data/accept — **plus the PTP timestamp determinism the servo depends on (§7.1).**

---

## 3. Q2 — What open-source UCIe implementations are there?

**Honest headline: there is no production-grade, FPGA-proven, Verilog-native open UCIe RTL.** The closest open UCIe RTL is sim-only Chisel; the most *build-ready* open D2D PHYs are the UCIe *alternatives* BoW and AIB.

| Name | URL | License | What it implements | Maturity | Lang | Caveat |
|---|---|---|---|---|---|---|
| **ucb-bar/uciedigital** | github.com/ucb-bar/uciedigital | BSD-3 | Full UCIe **digital** stack: Protocol (FDI), D2D Adapter (FDI↔RDI, credit FC, Hamming SECDED retry), Logical PHY + RDI, training FSM, **sideband** (128-bit msgs), mainband | **RTL + sim only. No FPGA, no silicon.** Mid-rewrite; AFE is a digital **stub** | Chisel/Scala | Closest open UCIe RTL; UCIe **1.1**. **Modeling reference, not a drop-in.** Chisel-regen is flagged DESTRUCTIVE in this project (see §7.7) |
| **Zero ASIC UCIe prototype** | zeroasic.com/blog/ucie-open-source-design | unstated | UCIe **1.1 raw**, 16-bit, ≤8 GT/s, tightly-coupled: adapter + logPHY + electrical PHY in **GF12LP** + sideband + link-init | **Simulated only** (Verilator + Xyce) | Verilog | **The UCIe RTL is NOT a browsable open repo** — only the blog + umi/switchboard infra are public. Best *scoping template*, but do not anchor a plan on unavailable code |
| **chipsalliance/aib-phy-hardware** | github.com/chipsalliance/aib-phy-hardware | Apache-2.0 | **AIB D2D PHY** (electrical + logical + cell models); **FPGA impls (Stratix 10 + Agilex)** | **Silicon-proven + FPGA-proven** | Verilog/SV | **UCIe alternative. Most build-ready open D2D PHY for FPGA.** Single-ended, source-synchronous — natural comparison to your GPIO PHY |
| **opencomputeproject/ODSA-BoW** | github.com/opencomputeproject/ODSA-BoW | OCP | BoW **specification only** | Spec-only v1.0 (2022) | docs | UCIe alternative; deployed 5–65 nm in industry; **no open RTL**. Most FPGA-reachable rate tier (~2 Gbps/wire) |
| **zeroasiccorp/umi (+LUMI)** | github.com/zeroasiccorp/umi | Apache-2.0 | UMI transaction spec + LUMI link layer; documented mappings over UCIe RDI, BoW, AIB | Active spec + examples; no full standalone LUMI module | Verilog/SV/Py | A transport that rides on a D2D PHY — not a UCIe controller |
| **google/open-chiplet** | github.com/google/open-chiplet | Apache-2.0 | Spec only | **Archived 2022, read-only** | docs | Dormant |
| **waviousllc/wav-wlink-hw** | github.com/waviousllc/wav-wlink-hw | Apache-2.0 | **Your current base.** Packetized layered link controller + pluggable logical PHY. **NOT UCIe** | RTL + sim; FPGA+ASIC-proven *in this project* | Chisel→Verilog | Closest *open, buildable, hardware-proven* analog to a UCIe adapter+logPHY. Wavious now unsupported (abandonment risk) |
| **waviousllc/wav-slink-hw** | github.com/waviousllc/wav-slink-hw | MIT* | Link-layer controller, 128b/130b, multi-lane, P-states, ECC/CRC; **no PHY** | RTL + sim + **FPGA (Xilinx XC7Z020)**; *silicon-proven unverified* | Verilog | Lighter alt to Wlink. *Corrected:* public evidence shows FPGA proof only; treat "silicon-proven" as unverified |
| **ETH Occamy** | arxiv.org/abs/2511.15564 | permissive (PULP) | Open 2.5D RISC-V chiplet w/ fully-digital tech-independent DDR D2D link (passive 65 nm interposer) | **Silicon-proven** (12 nm chiplets) | SystemVerilog | **Not UCIe**, but best academic *open + silicon-proven* chiplet-link exemplar |
| Synopsys / Cadence / Alphawave / Blue Cheetah | (vendor) | **closed** | Full UCIe PHY+controller+VIP | Commercial, advanced-node | — | Hardened for advanced nodes/packages, not 65 nm GPIO |

**Refuted / clarified:** "OpenUCIe" does not exist as a named open RTL project. "UCIe-Lite" open project — refuted/unverified. Chipyard/Constellation is an on-die NoC, **not** UCIe (uciedigital is a separate ucb-bar repo). QuickLogic+YorChip UCIe FPGA chiplets / YorChip "OpenPHY" are announcements/commercial, not open RTL.

**Practical takeaway:** for UCIe-*compliance* study → **uciedigital** (model only). For *working FPGA hardware* → **AIB** (build-ready, FPGA-proven) or stay on **Wlink**. For *scoping a minimal demonstrator* → the **Zero ASIC recipe** (but write your own RTL — theirs isn't published).

---

## 4. Q3 — Can we develop a UCIe GPIO PHY?

**Candid answer: No — not an electrically UCIe-*compliant* GPIO PHY. Yes — a UCIe-*inspired* digital stack on a non-compliant GPIO electrical layer.** This distinction is the crux of the whole report.

### 4.1 The electrical layer cannot be GPIO/FPGA-based and remain compliant

Four hard walls:

1. **Data-rate floor.** UCIe's *minimum* lane rate is **4 GT/s**; **no sub-GT/s "low-rate UCIe" profile exists** (the only "low" tier is the 4 GT/s bring-up rate). Your PHY is SDR at ~100 Mb/s/lane (ASIC) / ~25 Mb/s/lane (FPGA) (`WavD2DGpioTx.v:122,257-323`). Even pushed to FPGA SelectIO source-synchronous DDR with IDELAY/ISERDES (~1 Gb/s/lane, implementation-dependent), you are still ~4× short of the floor.
2. **Wrong PHY class.** UCIe is single-ended, **forwarded-clock, parallel** with a Valid lane, a Track lane, and an 800 MHz sideband. FPGA GTH/GTY transceivers reach the bit rate (16–32 Gb/s) but are **CDR-based differential SerDes** — you'd be *tunneling* UCIe, not complying.
3. **Mandatory always-on 800 MHz sideband.** A continuous 800 MHz forwarded clock + data on spare GPIO is itself near the FPGA SelectIO ceiling. TideLink has no sideband — it uses slow, single, non-redundant I²C/APB (`PHY_ARCHITECTURE_REFERENCE.md:468-487`). This is *also* a reset/clock-architecture problem, not just a rate problem (§7.2).
4. **Packaging.** UCIe assumes 45/110 µm in-package micro-bumps. An FPGA board exposes PCB-routed BGA/headers at 0.5–2.54 mm pitch (your PYNQ ribbon/Dupont). The eye/jitter/BER (target 1e-15) compliance environment cannot be met. ESD requirements also differ: advanced-package UCIe assumes minimal in-package ESD; any PCB-routed analog needs full ESD cells (pad/area cost).

Additionally the GPIO PHY lacks: Valid/Track sidebands; continuous per-lane phase tracking (phase/slip latched once at `S_DONE` and frozen — `PHY_ARCHITECTURE_REFERENCE.md:957-1044`); spare-lane repair (masking only, `WavD2DGpio.v:272-311`); FEC and a characterized BER; and a UCIe-conformant multi-stage training protocol (the calibrator is a single bring-up sweep, not SBINIT/MBINIT/MBTRAIN staging).

### 4.2 The digital logical-PHY + adapter IS portable to FPGA

UCIe's **Protocol Layer, D2D Adapter, and Logical PHY are plain synchronous RTL and do run on FPGA fabric** (confirmed by Berkeley EECS-2022-145 FPGA-emulation work and the QuickLogic/YorChip program). And crucially, **TideLink's GPIO PHY already contains the logical scaffolding UCIe needs**: a multi-lane forwarded-clock bundle, a training FSM (`tidelink_phy_align_calibrator.sv:410-492` — S_IDLE→ARM→PROBE→SWEEP→FINALIZE→HOLD→VALIDATE→DONE), per-lane phase/slip/IDELAY knobs, cross-lane deskew (`WavD2DGpio.v:346-370`), lane mask/fault, and wiring/lane-reversal detection (OK/SWAPPED/DEAD, `TRAINING_MODULE_SPEC.md:230-261`). What is missing is *fundamentally electrical/physical, not logical.*

### 4.3 The realistic framing

> **"UCIe-inspired digital stack on a non-compliant GPIO electrical layer."**

Electrically, model the GPIO PHY on the **BoW/AIB single-ended forwarded-clock family** — your design is already a slow BoW/AIB cousin (BoW's lowest grade ~2 Gbps/wire; AIB Gen1 ~2 Gbps/wire, single-ended, clock-forwarded). Reserve "UCIe" language strictly for the *digital flow* (layered PHY/adapter/protocol, training+sideband concepts, flit/credit/retry).

---

## 5. Q4 — What are the hardware overheads?

### 5.1 Published UCIe electrical figures (for context — what you are *not* buying)

| Metric | UCIe-S (Standard, organic 2D) | UCIe-A (Advanced, 2.5D/3D) | Source |
|---|---|---|---|
| Bump pitch | 100–130 µm (≈110) | 45 µm (25 µm option; 3D → 10–25 µm) | Wikipedia/UCIe; Alphawave |
| Lanes/module | 16 | 64 | EDPS 2023 |
| Lane rate | 4–32 GT/s (UCIe 1.0/2.0); **48/64 GT/s (UCIe 3.0, Aug 2025)** | same | UCIe Consortium |
| Energy/bit | ~0.5–1 pJ/bit | ~0.25–0.5 pJ/bit | arXiv 2406.00182; Synopsys |
| Shoreline BW density | 28→224 GB/s/mm (indicative) | up to ~1.3 Tbps/mm | EDPS 2023 |
| Areal BW density | — | up to ~1.35 TB/s/mm² @45 µm | Wikipedia/UCIe |
| Latency | < 2 ns (Tx+Rx, FDI-to-bump-and-back) | similar | EDPS 2023 |
| BER | 1e-15 (raw, mainband) | same | uciexpress.org |

### 5.2 TideLink current footprint (FPGA, whole-design)

The only quantitative numbers are whole-`tidelink_top` on xc7z020 at 25 MHz (`RTL_OPTIMISATION_ANALYSIS.md:38-46`):

| Resource | Count | Note |
|---|---|---|
| Logic LUTs | 25,087 | **whole design** incl. AXI SmartConnect + Wlink IP + FIFOs (NOT PHY-only) |
| Flip-flops | 25,713 | — |
| BRAM tiles | 16 | map to ASIC SRAM macros |
| DSP48E1 | 1 | — |

PHY-relevant per-block estimates: calibrator eye-centre ≈ **+72 flops** for 8 lanes (`tidelink_phy_align_calibrator.sv:189-206`); cross-lane deskew ≈ **1.1 Kbit + small control** (`PHY_LANE_DESKEW_DESIGN_2026_06_03.md:140-147`); autoneg FSM ≈ **150–200 LUTs** (`AUTONEG_PROTOCOL.md:412`). No standalone gate-count/µm² for the GPIO PHY is published; **the 25,087-LUT figure must not be read as PHY overhead.**

### 5.3 Per-lane gap table (current GPIO PHY vs UCIe)

| Axis | TideLink GPIO PHY | UCIe (min) | UCIe (max) | Gap vs floor |
|---|---|---|---|---|
| Lane rate | 0.025 Gb/s (FPGA SDR) / 0.1 (ASIC) / ~1 (FPGA DDR best-case) | **4 GT/s** | 64 GT/s (3.0) | **~4× (best-case DDR) → ~40× (ASIC) → ~160× (FPGA SDR)** |
| Signaling | single-ended LVCMOS33, full-swing | single-ended low-swing + fwd clk | same | non-compliant |
| Clock | fwd clock, **no DLL/PI** | fwd clk + DLL/PI + Track deskew | same | missing analog centering |
| Sideband | none / I²C-APB | **always-on 800 MHz** | same | missing |
| Energy/bit | *rough estimate* ~tens of pJ (full-swing CMOS @ PCB load — **no power analysis exists in repo**) | ~0.5 pJ | ~0.25 pJ | ~order(s) of magnitude worse |
| Channel/pitch | PCB ribbon, mm-pitch | 110 µm micro-bump | 45 µm | not same regime |

### 5.4 Effort estimate — minimal UCIe stack vs status quo (RTL + verification)

| Stack | New RTL surface | Verification surface | Effort |
|---|---|---|---|
| **Status quo (Wlink)** | none (done) | done (sim + silicon to 8/8) | **0 — already paid** |
| **Option B (UCIe-inspired adapter behind Wlink)** | thin FDI/RDI-style shim + naming/docs around `tidelink_top` seam; reuse Wlink FC/CRC/retry | re-run existing cocotb suite against the refactored seam | **Low–Medium** — weeks-to-a-month; *risk: formalizing the seam relocates/removes bring-up observability (§7.5)* |
| **Option C (compliant-ish streaming+raw, low-rate PHY)** | full LTSSM (~14 MBTRAIN sub-states) + **mandatory sideband channel & protocol** + parameter negotiation + D2D adapter shell + FDI/RDI conformance; new low-rate forwarded-clock PHY | UVM/VIP-class: training/reversal/retry, sideband+mainband, RDI/FDI transitions, compliance register block | **High** — multi-engineer, multi-quarter |
| **Option D (full UCIe)** | all of C + flit modes + CRC/retry buffers + ARB/MUX + advanced-node AFE | full UCIe VIP + compliance program | **Very high** — out of academic scope |

**The marginal functional gain of C/D over the status quo for *this* link is small; the marginal cost is a large RTL+verification project that duplicates Wlink capability over the same GPIO PHY.**

---

## 6. Q5 — Standard-compliant but minimal implementation?

### 6.1 The smallest *legal* UCIe profile

The minimal sensible compliant profile is **Streaming protocol + Raw format + tightly-coupled + reduced lanes + no-retry** — the UCIe 1.0 "streaming over raw" path (and the Zero ASIC recipe). Mandatory vs droppable:

| Element | Status in minimal profile | Basis |
|---|---|---|
| **Sideband** | **MANDATORY, always-on, never optional** | 2 lanes/dir (data + 800 MHz fwd clk), aux-power, up before mainband trains |
| **Link training (4-stage init)** | **MANDATORY** | Reset → SBINIT → MBINIT/repair → protocol-param exchange |
| **Parameter negotiation** | **MANDATORY** | capabilities advertised/agreed over sideband |
| **FDI/RDI conformance** | **MANDATORY for compliance** | compliance spans protocol + PHY + adapter including RDI and FDI |
| **Interface flow control (ready/valid)** | **MANDATORY** (present even in raw) | FDI/RDI handshake is structural |
| **CRC** | **DROPPABLE in raw format** | in raw, protocol layer owns CRC/retry/FEC; adapter inserts/checks nothing |
| **Retry** | **DROPPABLE / advertisable** | legal via raw; for non-raw configs with raw BER > **1e-27**, Retry MUST be supported |
| **Reduced lanes** | **YES** — Standard module = 16 lanes; width degradation + 1/2/4 modules | — |
| **Flit modes (68B/256B)** | **N/A in raw** — raw bypasses adapter flit machinery | — |

**Direct answers:**
- **Can CRC/retry be dropped?** Yes — in **raw format** the adapter does no CRC/retry/header; the protocol layer brings its own (exactly what Wlink's FC layer already does).
- **Is sideband mandatory?** **Yes, unconditionally.** This is the single hardest mandatory element to satisfy on GPIO (continuous 800 MHz) and the reason a *compliant* minimal UCIe is still expensive.
- **Reduced lanes?** Yes — Standard-package profile is 16 lanes with legal width degradation.

### 6.2 Truly-compliant minimal build vs UCIe-inspired non-compliant build

| | **Compliant minimal (streaming+raw)** | **UCIe-inspired non-compliant (reuse Wlink link layer)** |
|---|---|---|
| Sideband | mandatory always-on 800 MHz channel + protocol | reuse I²C/APB management (no spec sideband) |
| LTSSM | mandatory full SBINIT/MBINIT/MBTRAIN/LINKINIT/ACTIVE | reuse calibrator FSM + FC credit handshake |
| Adapter | minimal D2D adapter shell (LSM + param negotiation) | reuse Wlink FCSM (credit FC + CRC + Go-Back-N) |
| Seams | FDI + RDI conformant | FDI/RDI-*style* boundary, documented but not conformant |
| PHY | new low-rate forwarded-clock PHY (still ≥4 GT/s for any electrical claim) | keep existing GPIO PHY |
| Interop / branding | yes (if certified) | no |
| Effort | **High** (multi-quarter) | **Low** (weeks) |
| Functional value to *your* link | ~same as status quo | ~same as status quo |

**Key insight:** because (a) AXI/custom payload packing is *already* vendor-proprietary and non-interoperable across vendors even under compliant UCIe (Synopsys: *"no different vendors implementing AXI over UCIe can interoperate"*), and (b) raw/streaming lets you bring your own reliability, **two dies you design can agree on any private flit packing and skip the compliance program entirely.** There is no certification gatekeeper for a closed two-die link.

---

## 7. Q6 — Other considerations (incl. system-architecture gaps the first pass missed)

### 7.1 PTP / time-plane impact — *first-order, and TideLink's differentiator*

TideLink owns a **dedicated PTP FC node (0xa2)**, exchanges SYNC/DELAY_REQ short packets (0x50/0x51), carries servo (t1,t4) as PKT_SIDEBAND, and relies on `phc_hw_capture` for atomic timestamping (`TIDELINK_SPECIFICATION.md:195,217,1192-1196`). A controller swap to UCIe perturbs PTP accuracy in three ways:

- **Residence-time determinism.** Wlink's FC node has a known, low-jitter forward latency. UCIe's D2D adapter + LTSSM + ARB/MUX + flit aggregation + (optional) retry insert *variable* latency. PTP offset/delay math assumes symmetric, bounded path delay; the timestamp point must sit at a fixed offset from the FDI/RDI boundary.
- **Flit-aggregation hazard.** A 48-bit TideLink word is tiny vs a 64B/256B UCIe flit. Padding a single word per flit wastes bandwidth; *aggregating* batches PTP short-packets and destroys single-phase sync timing. This is an architectural conflict, not a footnote.
- **CDC into the PHC domain.** `tidelink_phc_cdc.sv` already crosses hclk↔phc_clk (~6 paths). A UCIe stack adds mainband + sideband clock domains; timestamp capture must be re-architected to cross them deterministically.

**Implication:** any UCIe migration must define a fixed, low-jitter timestamp reference and forbid PTP-packet aggregation — or accept degraded sync. This alone is a strong reason to keep the lean Wlink FC path for the time plane.

### 7.2 Reset / clock-domain architecture

The app layer is single-clock `hclk` with synchronous `hresetn` (`tidelink_fc_adapter.sv:42-45`). UCIe introduces (a) a mainband link clock, (b) a **mandatory always-on 800 MHz sideband clock on aux power** that must be up *before* mainband and *before* core reset deasserts, and (c) LTSSM state that must survive core reset. A UCIe migration is therefore a multi-clock/multi-reset redesign with new CDC FIFOs at FDI/RDI and an aux-power/always-on reset-ordering requirement the current single-reset design does not have.

### 7.3 Latency budget

The spec budget is ~10 ns one-way, 20–100 AHB stall cycles for the blocking bridge path, ~100–200 cycle ISR (`TIDELINK_SPECIFICATION.md:919,1156-1158`). UCIe adds adapter/LTSSM/flit pipeline depth; the end-to-end mailbox latency delta (AHB write → remote FIFO) Wlink-vs-UCIe is **unquantified here** — do not assume UCIe is latency-neutral.

### 7.4 XHB500 AXI-bridge → UCIe mapping

The transparent-bridge path (AHB→XHB500→AXI→Wlink-AXI→XHB500→AHB) uses 5× AXI FC nodes (AW/W/B/AR/R, 0x80–0x84) + APB initiator 0x90 (`TIDELINK_SPECIFICATION.md:58,225`). UCIe natively defines **PCIe and CXL** mappings, **not AXI** — AXI rides only as **Streaming/raw**, and Synopsys' own caveat is that AXI-over-UCIe is non-interoperable across vendors. So the 5 AXI nodes gain *nothing* from UCIe; PCIe/CXL mapping is overkill for a Cortex-M. The bridge would become UCIe-Streaming, losing any UCIe-native flow control (you'd keep AXI's).

### 7.5 DFT / observability loss behind an opaque UCIe seam — *the strongest counter to Option B*

The entire bring-up methodology depends on **deep `tidelink_top` reach-in** — role/autoneg/eye/lane/Bug-A ports, ILA taps, `SWI_LANE_STATUS` @0x108, reading `WlinkGenericFCSM_6.state`. A *clean* FDI/RDI boundary, by design, **hides PHY internals** — which would destroy the observability the project relies on to debug calibrator/deskew/FCSM issues. Any seam refactor (even Option B) must explicitly preserve or re-expose these debug taps, or it makes the link *harder* to bring up. UCIe's answer is the Test/Compliance register block (loopback, per-lane margining, eye monitoring) — adopting that as the DFT vector is non-trivial new work.

### 7.6 Security / manageability — UCIe 2.0 / 3.0

UCIe **2.0 (Aug 2024)** adds manageability (System/UCIe Manageability), a DFx architecture, and 3D packaging support; **3.0 (Aug 2025)** adds 48/64 GT/s and extended sideband reach (~100 mm). For an academic *teaching* artifact this is the "industry-relevant" content students want — but none of it is needed or feasible for a closed two-die link. Omission is deliberate.

### 7.7 FPGA emulation strategy + toolchain blocker

A UCIe digital stack on FPGA would **serial-tunnel mainband+sideband over the existing GPIO/GTH link and emulate LTSSM/sideband in fabric** (electrical layer non-compliant, digital layer exercised). Concrete blocker: **uciedigital is Chisel**, and Chisel-regen is flagged DESTRUCTIVE in this project's chiplet-controller audit — integrating it means treating it as a *reference model*, not importing its generator.

### 7.8 Other

- **Packaging.** No UCIe silicon exists on 65 nm; production UCIe lives on N3E/CoWoS. Your TSMC65 GPIO PHY is a different physical regime.
- **Compliance / certification.** As of 2024–2025 the official UCIe interop/compliance program is still aspirational; there is nothing for an academic single-vendor link to certify against today.
- **Verification.** Every EDA vendor sells dedicated UCIe VIP; adopting UCIe discards the working cocotb leverage (`cocotb/tidelink_top_pair`, PTP UVM). Policy: integrated paired-die cocotb must pass before any HW deploy.
- **IP licensing.** Wlink/S-Link are Apache/MIT and already integrated (Wavious unsupported = abandonment risk); AIB is Apache-2.0, royalty-free, FPGA-proven; commercial UCIe IP is closed/advanced-node; uciedigital is BSD-3 but Chisel/sim-only.
- **Educational value.** The one genuine UCIe upside: students learn an industry-relevant standard rather than an abandoned vendor IP; "we did UCIe" carries pedagogical/paper value.
- **Resource contention.** A UCIe track competes for the *same* scarce calibrator/deskew expertise currently consumed by the active deskew regression line (415d040, 1bff199) and the open PHC Phase-1 work.

---

## 8. Phased migration / decision path

| Option | Description | Effort | Interop/branding | Risk to V1/V2 | Functional gain |
|---|---|---|---|---|---|
| **A — Stay on Wlink** | Keep current stack; continue stabilization | none | none | none | baseline |
| **B — UCIe-inspired digital adapter behind Wlink link layer** | Refactor `tidelink_top` seam to a clean FDI/RDI-style boundary; document in UCIe terms; reuse Wlink FC/CRC/retry; keep GPIO PHY; **preserve debug taps (§7.5)** | Low–Medium (weeks–month) | none (honest "UCIe-inspired") | low (seam-only) | ~0 functional, **high clarity/teaching value** |
| **C — Minimal compliant-ish UCIe streaming+raw + low-rate PHY** | Zero-ASIC recipe: raw + tightly-coupled + reduced lanes + sideband + LTSSM; new low-rate forwarded-clock PHY; label non-compliant electrically | High (multi-quarter) | partial (logical only; PHY non-conformant) | medium (separate track) | small for this link; option value + research artifact |
| **D — Full UCIe** | Compliant PHY + adapter + flit modes; advanced node/package | Very high | full (if certified) | high | only meaningful with a 2nd-vendor chiplet |

### Recommended phased path

- **Phase 0 (now): Option A — protect the bring-up.** Finish stabilizing the link (deskew/calibrator regression line still active). Do not perturb it.
- **Phase 1 (low cost, high clarity): Option B — refactor and re-document the seam.** Formalize the link2phy seam (`PHY.scala:59-74`) and the fc_adapter seam (`tidelink_fc_adapter.sv:135-141`) as an explicit FDI-style / RDI-style boundary, documented with the §1 mapping table — **but design the boundary to keep the bring-up debug taps exposed (§7.5).** Costs weeks-to-a-month, makes a future swap bounded, gives students the UCIe mental model on a working link. Keep Wlink and the GPIO PHY. Label everything "UCIe-inspired, non-compliant."
- **Phase 2 (optional, isolated): Option C — scoped UCIe demonstrator.** If a spare engineer exists, build a streaming + raw + tightly-coupled + reduced-lane demonstrator, studying **uciedigital** (sim, as a reference model — do not regen) for FDI/RDI/sideband/LTSSM semantics and **AIB** (FPGA-proven) for the electrical analog, serial-tunneled over the existing link. Explicitly label UCIe-inspired / non-compliant. Must never gate V1/V2.
- **Phase 3 (only if justified): Option D — full compliant UCIe.** Reserve for a hypothetical advanced-node, advanced-package V3 with a genuine second-vendor chiplet.

### What would flip the recommendation (trip-wires)

A→B/C or B→C/D becomes justified if **any** of: (1) a confirmed second-vendor / external chiplet partner appears (interop value becomes real); (2) V3 moves to an advanced node + advanced package (electrical compliance becomes attainable); (3) a funded multi-quarter verification engineer is allocated (cost ceases to be prohibitive); (4) the project's goal pivots from "working low-cost link" to "industry-standard teaching artifact" as the *primary* deliverable.

### Recommendation for an academic Cortex-M chiplet on TSMC65

**Adopt A→B as the engineering line; treat C as an optional, isolated teaching/research track; defer D indefinitely.** B gives you the UCIe vocabulary and a clean migration surface almost for free, while preserving the silicon-validated Wlink link layer and the hard-won GPIO bring-up. Full UCIe is the wrong fit for V1/V2: its core value is structurally unavailable to a single-vendor same-node link, and its electrical layer is unattainable on GPIO by orders of magnitude.

---

## Appendix — Confidence flags

- **High confidence:** UCIe 4 GT/s floor with no sub-GT/s tier; sideband mandatory/always-on 800 MHz; 16-lane Standard / 64-lane Advanced modules; 110/45 µm bump pitches; raw mode drops adapter CRC/retry (protocol layer owns them); streaming maps AXI/CXS/CHI; uciedigital is BSD-3 Chisel sim-only (UCIe 1.1, stub AFE); AIB is Apache-2.0 + FPGA- and silicon-proven; energy/bit ~0.5/0.25 pJ; areal density ~1.35 TB/s/mm²; UCIe 3.0 (Aug 2025) = 48/64 GT/s; TideLink app layer transport-agnostic (`tidelink_fc_adapter.sv:135-141`); Wlink coupling concentrated in `tidelink_top`.
- **Corrections applied vs first draft:** added UCIe 3.0 / 64 GT/s (draft stopped at 2.0/32 GT/s); downgraded wav-slink-hw to FPGA-proven (silicon unverified); reconciled the per-lane gap to one canonical framing (4× DDR / 40× ASIC / up to 2560× vs 64 GT/s); softened "zero functional gain" to "small"; added §7.1 PTP, §7.2 reset/clock, §7.5 DFT/observability, §7.4 XHB500/AXI, §7.7 FPGA-emulation/Chisel blocker, trip-wires.
- **Soft / unverified:** Zero ASIC UCIe RTL is *not* a browsable open repo (blog + umi/switchboard only) — do not anchor Option C on it; the "~4× with FPGA SelectIO DDR" multiplier rests on an implementation-dependent ~1 Gb/s/lane assumption; the TideLink energy/bit figure is a rough estimate (no power analysis in repo); named LTSSM sub-state counts and 28→224 GB/s/mm shoreline endpoints are tutorial/VIP-derived, not spec-verbatim.
