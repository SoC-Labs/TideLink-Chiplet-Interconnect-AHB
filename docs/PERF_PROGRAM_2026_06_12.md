# TideLink Performance Program — Consolidated Report & Implementation Plan
**2026-06-12.** Synthesis of three parallel analyses (full detail in the
companion docs):
- [ARCH_ANALYSIS_2026_06_12.md](ARCH_ANALYSIS_2026_06_12.md) — bandwidth budget, FIFO sizing, backpressure audit, AXI-Lite evaluation
- [HW_CHARACTERIZATION_PLAN_2026_06_12.md](HW_CHARACTERIZATION_PLAN_2026_06_12.md) — the test catalog + SRAM-sweep mechanics
- [THROUGHPUT_GUI_PLAN_2026_06_12.md](THROUGHPUT_GUI_PLAN_2026_06_12.md) — the web GUI for running/visualizing it all

## Executive answers to the questions asked

**Q: Is the 16 KB FIFO too big?**
Analytically: yes, ~100× the flow-control bandwidth-delay product (~150 B,
rate-invariant). Its real function is absorbing software drain latency
(~0.5 ms at ASIC rate). **Recommendation: 8 KB (`rf_08k`, `RAM_ADDR_W` 14→13,
−0.041 mm² ASIC area, zero protocol change — the credit grant is
self-describing).** The SRAM-sweep experiment (single BD knob, credits
auto-derive) settles it empirically before committing the ASIC macro change.

**Q: AHB backpressure — should we add AXI-Lite buses for doorbells?**
**Better news: no new RTL is needed.** The hot poll/control registers
(doorbell 0x2014, RESP_ACC 0x2024, PAIR_CREDIT 0x2028, SWI_LANE_STATUS
0x2108) are already on the APB path, not the blocking AHB data path. The
bench-observed pain (PS stalls during data backpressure) is **GP0
ordering-domain sharing** — control and data ride the same PS master port.
**Fix: move the `axi_apb` (control) path to the free `M_AXI_GP1` port — a
block-design-only change, zero RTL.** Combined with the already-landed
`TX_STALL_TIMEOUT` (data-path stall now bounds at ≤1.3 ms with an AHB ERROR
instead of a wedge), the control plane becomes fully decoupled from data
backpressure. AXI-Lite remains an option for ASIC integration later, but it
buys nothing the GP1 split doesn't.

**Q: Other bottleneck reductions?** Ranked (detail in ARCH_ANALYSIS §5):
1. **Wire efficiency 33% → 63%: multi-word FC packets.** A 32-bit payload
   costs 12 B on-wire today (48 b flit + Wlink id/wc/CRC overhead,
   `word_count=7` hardcoded). The single biggest throughput lever; right
   vehicle = the V2/shared-component refactor.
2. **Replay idempotency (residual #7)** — the observed 3–5× duplicate
   amplification is a throughput bug, not just correctness. FIFO_DATA is
   naturally positional-idempotent; only SIDEBAND needs dedup.
3. **Returner credit-delta overwrite race — NEW BUG FOUND by this analysis:**
   under sideband backpressure a pending credit-delta can be overwritten →
   **permanent credit leak** (plus a same-cycle ring-coalesce race; ring
   totals self-heal, credits do not). ~10-line fix in
   `tidelink_returner.sv`. This may also be a contributor to the historical
   credit-starvation signatures.
4. FIFO right-size to 8 KB (area/power, after the sweep confirms).
5. GP1 control/data port split (the AXI-Lite answer above).
6. Not worth it: deepening the 1-entry fc_adapter skid (it's a rate adapter,
   not the constriction — burst knee is 18 words set by the a2l FIFO), and
   MAX_SIDEBAND_BURST tuning.

**Context that frames everything: the LINK is the system bottleneck at every
rate** (payload-effective 2.08 / 8.3 / 33.3 MB/s at 6.25/25/100 MHz vs AHB
~10–13 MB/s FPGA, ≳125 MB/s ASIC). Host-side bus changes don't add
throughput; wire-efficiency and protocol fixes do.

## The characterization campaign (what we run on hardware)

8 tests (T1–T8, full sequences in HW_CHARACTERIZATION_PLAN): M→S / S→M /
bidirectional throughput vs burst size, doorbell RTT, credit-return latency,
wedge-boundary, bring-up time distribution, soak/error-rate.
- **Runnable TODAY on V1/v33**: T1, T4, T5, T7, T8 (T2/T3 after an S→M
  smoke; T6 needs a "v1-char" rebuild to include TX_STALL_TIMEOUT).
- **SRAM sweep**: 16K/8K/4K/2K/1K/512B = one `CONFIG.RAM_ADDR_W` value per
  build (~22 min each), credits auto-derive, idle `CREDIT_COUNT` sanity per
  point, manifests labelled per size.
- **Graphs**: throughput-vs-FIFO-size knee families by burst size, latency
  CDFs, credit-starvation duty cycle → ends in the evidence-based ASIC FIFO
  recommendation.

## The GUI (how we run and see it)

Extends the existing in-repo toolkit family (eye_toolkit :8088 /
stress_toolkit :8089) as `pynq_host/throughput_gui/` on mapstone-dev :8090.
Stdlib-only measurement daemons ON the PYNQs (SSH-per-access would measure
sshpass, not the link: 100–300 ms/op), FastAPI+SSE+Plotly server, SQLite +
NDJSON run store with **fail-closed bitstream-manifest provenance per run**
(SRAM-sweep graphs are only trustworthy if every point records its sha).
Safety interlocks ported from hwtest/fpgahub: criterion-B gate, lease check,
single-experiment mutex, jam-signature auto-abort, unjam/converge recovery
button. Browser via `ssh -L 8090:localhost:8090 david@mapstone-dev`.

## Implementation plan (sequenced)

**Phase A — quick wins, this week (independent of the PHY epoch-deskew fix):**
1. Returner credit-leak fix (~10 lines + unit test) — sim-gate, lands on
   `feat/phy-v2-integration`. *(agent-autonomous)*
2. GP1 control/data split in both pair-target BDs — build + bench A/B of
   control-plane latency under data load (becomes test T6b). *(agent + 1
   build cycle)*
3. "v1-char" build (v33 lineage + TX_STALL_TIMEOUT + perf counters checked)
   → run T1/T4/T5/T7/T8 on the rig now; first real numbers. *(agent + rig
   time)*

**Phase B — GUI P0/P1 (parallel with A):** walking skeleton (one canned M→S
run + live chart, 1.5–2 d) → sweeps/run-store/compare (2.5–3 d).
*(agent-autonomous; user: confirm port 8090 + venv/systemd on mapstone-dev)*

**Phase C — SRAM sweep campaign (~2 days):** 6 builds × T1/T3/T5 via the
GUI, produce the knee graphs, write the ASIC FIFO-size decision memo
(expected outcome per analysis: 8 KB confirmed, possibly 4 KB).

**Phase D — V2-vehicle items (with/after the PHY epoch-deskew fix):**
multi-word FC packets (33→63% wire efficiency) and SIDEBAND replay dedup —
both belong in the shared-component line; coordinate with the PHY-repo
owner. Re-run the full characterization on V2 for the before/after story.

**Dependencies/notes:** Phases A–C run entirely on V1/v33 and do not wait
for the V2 epoch-deskew fix; the campaign infrastructure then serves V2
validation the day it links. Builds stay manual/CLI; the GUI consumes
labelled bitstreams.
