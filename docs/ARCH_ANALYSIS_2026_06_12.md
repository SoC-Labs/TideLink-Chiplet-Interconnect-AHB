# TideLink Quantitative Architecture Analysis — 2026-06-12

**Scope:** bandwidth/latency budget, RX-FIFO sizing vs bandwidth-delay product,
backpressure-chain audit, the AXI-Lite control-port question, and ranked
bottleneck reductions. Branch `feat/phy-v2-integration`. All file references are
repo-relative; all numbers are derived from RTL/build collateral cited inline,
or are clearly-labelled estimates.

---

## 0. Executive summary

1. **The link is the bottleneck at every link rate.** Effective mailbox payload
   bandwidth is **2.08 / 8.3 / 33.3 MB/s** at 6.25 / 25 / 100 MHz pad rates
   (33% on-wire protocol efficiency: a 32-bit payload costs 12 bytes on the
   wire). The AHB/PS side sustains ~10–13 MB/s on the FPGA rig and
   ≳125 MB/s on the ASIC target — always above the link except for
   Python-driven SW on the 25 MHz rig.
2. **The 16 KB FIFO is ~100× larger than the flow-control BDP.** The pure-HW
   credit-return bandwidth-delay product is ≈ **150 bytes (~40 words) at every
   link rate** (BDP is rate-invariant because RTT scales inversely with rate).
   The FIFO's real job is absorbing *receiver SW drain latency*: 16 KB buys
   7.9 ms / 2.0 ms / 0.49 ms of drain tolerance at the three rates. For the
   nanosoc Cortex-M0 bare-metal target, **8 KB (rf_08k) is recommended**:
   it halves the TSMC65 macro area (0.0889 → 0.0480 mm², −0.041 mm²) while
   keeping 0.25 ms drain tolerance at the 100 MHz ASIC rate. One parameter
   (`RAM_ADDR_W` 14→13) plus the ASIC flist swap realizes it; the credit grant
   is self-describing (doorbell response carries the actual total), so no
   protocol or manifest change is needed.
3. **The 1-entry fc_adapter skid is a rate adapter, not the weak buffer.**
   Burst absorption M→S is 2 (adapter) + 16 (a2l FIFO) = **18 words at AHB
   speed** before throttling to link rate — adequate given the link is ~5–100×
   slower than the AHB side. The genuinely fragile element is the **returner's
   one-pending-register-per-channel design**: under sideband backpressure,
   credit-release *deltas can be silently overwritten* (permanent credit leak
   until a doorbell resync) and doorbell rings coalesce. Verified against
   `tidelink_returner.sv` + `tidelink_apb_regs.sv` below (§3.3).
4. **AXI-Lite port: NO new RTL port; YES to a BD-only isolation move if
   needed.** The entire hot SW-poll set (doorbell 0x2014, RESP_ACC 0x2024,
   PAIR_CREDIT 0x2028/2C, SWI_LANE_STATUS 0x2108) is *already* on the APB
   config port, not the blocking AHB data path. What hurts on the bench is
   that APB and AHB share the single PS GP0 ordering domain, so a wedged
   `ahb_tx` write stalls APB polls behind it. `M_AXI_GP1` is unused — moving
   the existing `axi_apb` bridge to GP1 isolates the control surface with
   **zero RTL change**. The TX_STALL_TIMEOUT ERROR mechanism (≤1.3 ms @50 MHz)
   already converts the deadly wedge into a bounded stall, which demotes this
   from "must-fix" to "nice-to-have".
5. **Top-ranked improvements by value/effort:** (1) replay-idempotency fix
   (3–5× observed duplicate amplification on marginal PHY — it is a
   *throughput* bug, not just correctness); (2) returner delta-accumulate fix
   (tiny RTL, kills the credit-leak class); (3) multi-word FC packets
   (33% → ~63% wire efficiency, high effort); (4) FIFO right-sizing (ASIC
   area); (5) GP1 APB isolation (BD-only). Skid deepening and
   MAX_SIDEBAND_BURST tuning are low value.

### Headline numbers

| Quantity | 6.25 MHz (now) | 25 MHz (target) | 100 MHz (ASIC) |
|---|---|---|---|
| Raw wire BW (8 lanes × rate) | 50 Mb/s | 200 Mb/s | 800 Mb/s |
| Link-word (128b) clock = pad/16 | 390.6 kHz | 1.5625 MHz | 6.25 MHz |
| FC packet ceiling (12 B/pkt, dense) | 521 k pkt/s | 2.08 M pkt/s | 8.33 M pkt/s |
| **Effective payload BW (dense packing)** | **2.08 MB/s** | **8.33 MB/s** | **33.3 MB/s** |
| Effective payload BW (1 pkt/beat floor) | 1.56 MB/s | 6.25 MB/s | 25 MB/s |
| One-way word latency (est., §1.4) | ~25–40 µs | ~6–10 µs | ~1.6–2.4 µs |
| HW credit-return RTT (est.) | ~60–80 µs | ~15–20 µs | ~4–5 µs |
| **BDP (HW credit loop)** | **~150 B** | **~150 B** | **~150 B** |
| 16 KB FIFO drain-latency tolerance | 7.9 ms | 2.0 ms | 0.49 ms |
| AHB-side ceiling (HW path, est.) | ~10–13 MB/s (50 MHz hclk) | same | ≳125 MB/s (250 MHz hclk) |
| **Bottleneck** | **link** | **link** (or Python SW) | **link** |

---

## 1. Bandwidth / latency budget

### 1.1 Raw link bandwidth

The GPIO PHY is 8 data lanes, source-synchronous, 1 bit/lane/pad-clock; the
link layer assembles 16 bits per lane per link-clock (`link_clk = pad/16`,
ARCHITECTURE.md §6), i.e. a **128-bit link word per link-clock**:

- raw = 8 lanes × pad rate = **50 / 200 / 800 Mb/s** at 6.25 / 25 / 100 MHz.

FPGA clocking reality check (`fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`):
`clk_out1` drives `hclk` *and* `user_ref_clk` (= pad clock) — currently
**6.25 MHz for both** (v36 link-rate drop). The "hclk 50 MHz / link 25 MHz"
configuration is the pre-v36 rig and the analysis baseline below; the ASIC
target is hclk 250 MHz (`syn/asic/common.mk` `CLK_PERIOD=4.0`) with a
~100 MHz GPIO link.

### 1.2 Protocol efficiency stack (per 32-bit mailbox payload word)

| Layer | Bits | Overhead source |
|---|---|---|
| Payload | 32 | — |
| FC flit (`tidelink_fc_adapter.sv`) | 48 | 2b pkt_type + 14b addr_offset → **66.7%** |
| Wlink long packet | 96 (12 B) | 1 B data_id + 2 B word_count + 7 B data (48b flit padded to 56b) + 2 B CRC16 → **33.3%** |
| Link-beat quantization (floor) | 128 | if 1 packet per 128-bit beat → **25%** |

Evidence: the FC node sends each 48-bit app word as one long packet with
`word_count = 16'h7` (7 bytes) — `local_overrides/Wlink.v` /
`WlinkGenericFCSM_6.v:631` (`_GEN_57 = a2l_fc_replay_link_valid &
~fe_rx_is_full ? 16'h7 : word_count`); header/CRC framing per
`WlinkTxLinkLayer` byte-packing (`deps/.../WlinkTxLinkLayer.v`, `LinkLayer.scala
:499-521` byte-index packing). The TX link layer byte-packs consecutive
packets into the 128-bit bus, so sustained efficiency sits between the 25%
beat-aligned floor and the 33.3% dense-packing bound. **This doc uses 33.3%
(12 B/word) as the headline; quote 25% as the conservative floor.**

On top of this, the SW mailbox convention costs 2 header words per packet
(`archive/TIDELINK_SPECIFICATION.md` §packet): an N-word packet is
N/(N+2) efficient — 67% at N=4, 99.8% at N=1024. Worst-case small packets
(N=4) land at **0.667 × 0.333 ≈ 22%** end-to-end wire efficiency.

### 1.3 AHB-side bandwidth

FPGA path per 32-bit single-beat write: PS GP0 (AXI3, ~8-deep posted-write
acceptance) → SmartConnect → `axi_ahblite_bridge` (one blocking AHB txn at a
time) → `fc_adapter` TX aperture (addr + data phase, 2 hclk when the skid is
empty). Estimated **~15–20 hclk per write ≈ 300–400 ns @ 50 MHz → ~10–13 MB/s
hardware ceiling** (estimate — no measured counter in the repo; the perf
profiling block, Regions 5–7, can measure this directly). Driver software
dominates in practice: Python/PYNQ MMIO ≈ 1–3 µs/write (~1–4 MB/s); a C
`/dev/mem` loop ≈ 150–300 ns/write (~13–26 MB/s, saturating the fabric path).

ASIC target: Cortex-M0 at 250 MHz issuing native AHB single-beat stores,
~5–8 CPU cycles per store-loop iteration → **≳125–200 MB/s**.

### 1.4 Where the bottleneck is

| Link rate | Link payload | AHB side | Bottleneck |
|---|---|---|---|
| 6.25 MHz | 2.08 MB/s | 10–13 MB/s (HW) / ~1–4 MB/s (Python) | **link** (Python SW comes close) |
| 25 MHz | 8.33 MB/s | 10–13 MB/s (HW) / ~1–4 MB/s (Python) | **link** with C driver; **SW** with Python |
| 100 MHz ASIC | 33.3 MB/s | ≳125 MB/s | **link**, ~4× margin |

The architecture honours its own design intent (ARCHITECTURE.md §1: bulk data
must not stall the host bus): the host side always has headroom over the
link. Conversely, **any wire-efficiency gain converts 1:1 into system
throughput** — see §5.3.

### 1.5 Latency budget (one-way, M→S mailbox word — estimates)

Dominated by link-clock-domain steps (each link beat = 2.56 µs / 0.64 µs /
0.16 µs at the three rates): a2l CDC sync (~2–3 link clk) + FCSM packetize
(~2–4) + serialize (1) + RX LL/deskew (~3–5) + l2a CDC (~2) ≈ **10–15 link
beats**, plus ~10 hclk of fabric on each end:

- 6.25 MHz: **~25–40 µs**; 25 MHz: **~6–10 µs**; 100 MHz ASIC: **~1.6–2.4 µs**.

The transparent `ahb_sub` bridge path freezes HREADY for a full round trip
(2× the above + AXI/XHB500 conversions) — at 6.25 MHz that is a ≥60 µs CPU
stall per remote read, confirming the doc's "control-plane only" guidance.

---

## 2. Is the 16 KB FIFO too big?

### 2.1 Credit machinery recap (ground truth)

- `RAM_ADDR_W = 14` → 16 KB SRAM; `MAX_CREDITS = 1<<(14-2) = 4096` word
  credits, 1 credit = one 32-bit word (`tidelink_fifo_ctrl.sv:74,257`).
- Peer learns its budget via the doorbell-response grant (TOTAL free credits,
  `credit_count_data`) — observed on silicon as the 0x1000 = 4096 residue
  (`archive/AUTOCAL_CLOSURE_2026_06_10.md` §1).
- Release path: every packet read completion accumulates `length+2` into
  `release_acc`; at `release_threshold` (default **20 words**,
  `tidelink_apb_regs.sv:206`) the returner sends one SIDEBAND delta flit; the
  peer's `RELEASED_CREDITS_ACC` write auto-increments `PAIR_CREDIT_COUNTER`
  (`tidelink_apb_regs.sv:328`). Sender SW checks/consumes via 0x2028/0x202C.
- The Wlink FC node adds its own packet-level credit loop: CR/CRACK exchange
  `word_count = 0x1f1f` → **31 packets** outstanding each direction
  (`WlinkGenericFCSM_6.v:1079,1167`).

### 2.2 Bandwidth-delay product

Credit-return round trip = (data one-way) + (receiver-side release latency) +
(sideband flit return) + (counter apply). Two regimes:

**(a) Hypothetical pure-HW loop** (auto-release at wire rate, no SW):
RTT ≈ 2 × one-way ≈ 50–80 µs / 12–20 µs / 3–5 µs. BDP = payload BW × RTT:

| Rate | Payload BW | RTT (HW) | BDP |
|---|---|---|---|
| 6.25 MHz | 2.08 MB/s | ~70 µs | **~146 B (37 words)** |
| 25 MHz | 8.33 MB/s | ~18 µs | **~150 B (38 words)** |
| 100 MHz | 33.3 MB/s | ~4.5 µs | **~150 B (38 words)** |

BDP is **rate-invariant ≈ 150 B** because RTT is dominated by a fixed count
of link beats whose period scales inversely with bandwidth. Adding the
20-word release-threshold batching and the 31-packet Wlink node window, pure
flow-control correctness needs only **~64–128 words (256–512 B)**.

**(b) Real SW-mediated drain** (credits only return once the receiving CPU
*reads* the packet — `read_complete` fires on AHB reads,
`tidelink_fifo_ctrl.sv:107`): the FIFO must absorb BW × SW-drain-latency.
What 16 KB (4096 words) buys:

| Rate | Time to fill 16 KB at full payload rate |
|---|---|
| 6.25 MHz | 7.9 ms |
| 25 MHz | 2.0 ms |
| 100 MHz ASIC | **0.49 ms** |

So 16 KB is ~100× the flow-control BDP, but only ~0.5 ms of drain tolerance
at the ASIC rate — *not* absurdly oversized if the receiver is a loaded
Linux-class host. For the stated reference integration (nanosoc Cortex-M0,
bare-metal IRQ drain, ~10–50 µs response) it is oversized by ~10×.

### 2.3 ASIC cost (TSMC65, `syn/asic/common.mk` MEM_BASE)

`/research/precompiled_mems/TSMC65` stocks rf_01k / rf_08k / rf_16k / rf_32k
(32-bit words; rf_16k = 4096×32, rf_08k = 2048×32 (`A[10:0]`), rf_01k =
256×32 (`A[7:0]`)). LEF footprints:

| Macro | Size (µm) | Area | Δ vs rf_16k |
|---|---|---|---|
| rf_16k (current) | 311.8 × 285.25 | **0.0889 mm²** | — |
| rf_08k | 311.8 × 154.09 | 0.0480 mm² | **−0.0409 mm² (−46%)** |
| rf_01k | 177.4 × 58.99 | 0.0105 mm² | −0.0784 mm² (−88%) |

Beyond area: lower leakage/access energy, and a shorter macro eases the FC
floorplan that fought aspect-2.0 closure (the 2026-06-02 GDSII saga). On
FPGA the cost is 4 vs 8 BRAM36 — negligible either way.

### 2.4 Recommendation

**Adopt 8 KB (rf_08k, `RAM_ADDR_W = 13`) for the ASIC v1 config; keep 16 KB
on the FPGA bring-up rig if convenient (sizes need not match — see below).**

The math: required size ≈ BW×L_drain + max_packet + threshold + node window.
At 33.3 MB/s with a 100 µs worst-case bare-metal drain: 3.3 KB + headroom →
8 KB gives 2.4× margin (0.25 ms tolerance) and still admits 2046-word
(8 KB-2) packets. 1 KB (rf_01k) covers only 30 µs — too tight for anything
but hard-real-time drains. 16 KB is the right choice only if a Linux-class
peer with ≥1 ms drain jitter is a real deployment.

What realizes it:

1. `RAM_ADDR_W` 14→13 at the `tidelink_top`/`tidelink_fifo` instantiation —
   `MAX_CREDITS` (2048), `MAX_PACKET_LEN` (2046), aperture decode, and
   `credit_count_data` all derive from it automatically.
2. ASIC flist/`common.mk`: swap `rf_16k` macro vars for `rf_08k`
   (`RF_16K_DB_*` → rf_08k .db/.lef/.gds2; `tidelink_sram` ASIC impl wraps
   the macro).
3. **No protocol change**: the credit grant is self-describing (doorbell
   response = actual `current_credit_count`), so an 8 KB die interoperates
   with a 16 KB die automatically. The FC `addr_offset` stays 14 bits with
   the top bit unused.
4. Manifest/lock: `CTRL.LOCK` (write-once, Shortcoming #25) semantics are
   untouched; only bring-up scripts that hard-code 0x1000 expectations need
   a constant update.
5. Re-run the FC floorplan — the rf_08k's halved height is an opportunity to
   revisit the aspect-2.0 constraint set.

---

## 3. Backpressure chain audit

### 3.1 M→S data path: every blocking point

```
PS CPU → GP0 → SmartConnect → axi_ahblite_bridge → ahb_tx (fc_adapter)
  → skid → tl_fc_a2l FIFO → FCSM/node credits → wire → peer l2a FIFO
  → RX FSM → RX FIFO SRAM → peer SW drain
```

| # | Stage | Capacity | Drain rate | Blocking behaviour |
|---|---|---|---|---|
| 1 | PS GP0 write acceptance | ~8 posted writes | fabric | CPU stalls when full; **no PS-side timeout** (Zynq-7000) |
| 2 | SmartConnect + AXI-Lite bridge | 1 txn | — | in-order, single outstanding |
| 3 | `axi_ahblite_bridge` | 1 AHB txn | — | blocks on HREADY |
| 4 | fc_adapter TX (addr latch + **1-entry skid**) | **2 words** | 1 word/hclk when link ready | HREADYOUT low when skid full; **TX_STALL_TIMEOUT = 2^16 hclk → AHB ERROR** (`tidelink_fc_adapter.sv:44,227-292`): 1.3 ms @50 MHz, 262 µs @250 MHz, 10.5 ms @6.25 MHz hclk |
| 5 | `tl_fc_a2l` WavFIFO | **16 × 48 b** | 1 pkt / FCSM issue (~link rate) | async hclk→link_tx CDC |
| 6 | Wlink node credit window | **31 packets** (CR 0x1f1f) | peer ACK return | the Bug-A jam point: un-ACKed replay ⇒ permanent stall (residual #6) |
| 7 | Wire | 1 pkt / 12 B | 521 k–8.33 M pkt/s | — |
| 8 | Peer `tl_fc_l2a` WavFIFO | 16 × 48 b | RX FSM | async link_rx→hclk |
| 9 | fc_adapter RX FSM | 1 word | **3 hclk/word** (direct write) | 16.7 M words/s @50 MHz ≫ link rate — never the bottleneck |
| 10 | RX FIFO SRAM | **4096 words** | SW reads | overrun = silent word drop + sticky flag (`tidelink_fifo_ctrl.sv:298-310`) |
| 11 | SW drain + credit release | threshold 20 words | CPU read loop | the dominant latency term (§2.2) |

**Burst absorption:** a CPU burst lands 2 words instantly (stage 4) and 16
more at AHB speed (stage 5) = **18 words (~72 B) before the writer throttles
to link rate** (~1.9 µs/word @6.25 MHz pad, 120 ns/word @100 MHz). Beyond
that, each write stalls HREADY for up to one FC-packet time. The 1-entry
skid is therefore *suspect #1 by position but not by impact*: deepening it
shifts the knee from 18 to 21 words — the a2l FIFO behind it is the real
elastic store and the link is 5–100× slower than the producer regardless.
The skid's true function (decoupling Wlink's ready from the AHB HREADY
critical timing path) is sound.

**Failure conversion:** when stage 6 jams (the silicon-pinned Bug-A anatomy:
lost NACK/ACK on the marginal S→M direction ⇒ node sequence desync ⇒
`fcsm=5, a2l_lnk=1, fe_full=0` forever — AUTOCAL residual #6), the skid
fills, HREADY drops, and *before* the 2026-06-11 fix the PS AXI deadlocked
(bench: SSH death, JTAG reset). TX_STALL_TIMEOUT now bounds this to an AHB
ERROR + `tx_dropped_cnt` increment. Note the storm test (hwtest 5b) stalled
at word 4, not 18 — consistent with the FCSM already holding earlier words
un-ACKed (node window consumed), not with the fabric-side queue math.

### 3.2 Peer-aperture path (`ahb_sub`, residual #5)

The transparent bridge (XHB500 → AXI FC nodes 0x80–0x84) shares the link.
A peer-aperture write while `fe_full=1` still wedges with *no* TX-side
timeout on that path — the XHB500 conversion has no equivalent of
TX_STALL_TIMEOUT. Until the FC-side rework lands, 0x40000000 writes remain
the one user-reachable unbounded stall (mitigate in SW: check
`SWI_LANE_STATUS[31]` fe_full before peer-aperture access).

### 3.3 Doorbell / sideband path — can rings be lost? (verified)

The returner (`tidelink_returner.sv`) is a single-beat AHB master with **one
pending bit and zero data storage per channel**; write data is sampled from
live inputs only at the IDLE→ADDR transition (`:133-149`). Its AHB master is
intercepted by the fc_adapter; `rtn_hready = skid_can_accept`
(`tidelink_fc_adapter.sv:334`) — **with no stall timeout on this path**, a
jammed link parks the returner in DATA_PHASE indefinitely. Three concrete
loss/coalesce mechanisms:

1. **Credit-delta overwrite (real leak).** `credit_delta_data` is overwritten
   on *every* `release_credits_trigger` and `release_acc` resets each time
   (`tidelink_apb_regs.sv:402-418`). If trigger T2 fires while `pending_0` is
   still set from T1 (returner busy on another channel or stalled by the
   skid), the returner eventually sends only T2's delta — **T1's credits are
   never released**. The peer's `PAIR_CREDIT_COUNTER` permanently
   undercounts (conservative direction: throughput loss, not corruption).
   Exposure window: normally tiny (returner takes 3 hclk vs ≥20 SW reads
   between triggers) but **unbounded under sideband backpressure** — exactly
   the Bug-A regime. Healing: a doorbell response carries the TOTAL, so one
   SW doorbell ring resynchronizes; nothing heals it autonomously.
2. **Same-cycle set/clear race.** In the pending-register block
   (`tidelink_returner.sv:112-130`) the service-clear assignment executes
   after the edge-set in the same `always_ff`; an interrupt rising in the
   exact cycle its channel is being dispatched is **dropped** (last
   assignment wins). One-cycle window; reachable for ch0 (HW-timed trigger),
   effectively unreachable for SW-paced ch1 rings.
3. **Doorbell coalescing (benign-ish).** N rings while `pending_1=1` produce
   one response. The response is a TOTAL (idempotent), so credit state stays
   correct, but ring-counting SW protocols see fewer responses than rings —
   the 2026-06-10 "8 rapid rings" test was partly this, amplified by replay
   duplication (residual #7) in the other direction.

Sideband bandwidth sanity: at threshold=20, one 12 B release flit per
20 data words (240 B wire) = **5% sideband overhead**, and MAX_SIDEBAND_BURST=4
arbitration cannot starve the TX aperture for more than 4 flit-times.

---

## 4. The AHB→AXI-Lite question

**Question:** add a small AXI-Lite slave on `tidelink_top` so the PS reaches
the low-latency control surface without entering the blocking AHB data path.

### 4.1 (a) Which registers would benefit

The hot SW-poll set, with current PS addresses (APB base 0x4403_0000 +
TideLink region 0x2000, REGISTER_MAP.md):

| Register | PS addr | Role |
|---|---|---|
| DOORBELL ring | 0x4403_2014 | credit resync request |
| RELEASED_CREDITS_ACC / RESP_ACC | 0x4403_2020 / 24 | R-clear credit/doorbell receive |
| PAIR_CREDIT_COUNTER / CONSUME | 0x4403_2028 / 2C | per-send credit check/consume |
| SWI_LANE_STATUS (+CREDIT_PATH_STATUS[31:17]) | 0x4403_2108 | link-health poll incl. fe_full/a2l_lnk wedge signature |

**Key finding: all of these are already on the APB config port** behind
`axi_apb` — none traverses the `ahb_tx`/`ahb_sub` data path. There is no
register-access *path-sharing* problem in the RTL. The problem observed on
silicon is one level up: APB and AHB bridges all hang off the **single PS
GP0 ordering domain** (BD: one `S00_AXI` SmartConnect, 9 MI ports), so a
write stalled in `axi_ahb_tx` blocks every subsequent GP0 transaction —
including APB status reads — for the duration of the stall.

### 4.2 (b) What it costs

- **PS side: zero new bridge IP needed.** The BD enables only
  `PCW_USE_M_AXI_GP0` (`tidelink_design.tcl:173`); **`M_AXI_GP1` is free**.
  Enabling GP1 + one more `axi_apb_bridge` (or AXI-Lite direct) is a
  BD/PS-config change only.
- **RTL option (true AXI-Lite slave on tidelink_top):** an AXI-Lite slave FSM
  (~200–400 LUT / ≪0.01 mm² @65 nm) + arbitration into the existing config
  mux. The APB mux is already 2:1 (FC-RX-cfg priority over CPU,
  ARCHITECTURE.md §3); a third master needs a 3:1 upgrade and a re-check of
  the FC-priority invariant. No async bridge is required on FPGA (single
  hclk domain) — only on an ASIC where the control fabric clock differs.
- Verification: new port = new cocotb env + the APB-collision corner cases.

### 4.3 (c) What it does NOT fix

- **The data-path wedge itself** — fc_adapter/Wlink-side, and already
  mitigated by TX_STALL_TIMEOUT (bounded ERROR, PS survives). An AXI-Lite
  port changes *observability during* a stall, not the stall.
- The `ahb_sub` peer-aperture unbounded stall (§3.2) — that path needs its
  own timeout regardless.
- Link bandwidth, replay duplication, credit-leak races — orthogonal.
- Receiver drain: bulk RX reads stay on `ahb_fifo` by design.

### 4.4 (d) Migration sketch & recommendation

**Recommendation: NO to a new RTL AXI-Lite slave port for v1/v2; YES (cheap,
optional) to the BD-only GP1 isolation if bench debuggability during
data-path stalls is wanted.**

- *Phase 0 (BD-only, zero RTL, ~1 day):* enable `M_AXI_GP1`; move the
  existing `axi_apb` bridge (and optionally `axi_gpio_*`) to a second
  SmartConnect on GP1. Control surface then survives any GP0 data-path
  stall. Keep all data ports (`ahb_sub/tx/fifo`) on GP0.
- *Phase 1 (only if ASIC integration demands it):* fold the decision into
  the nanosoc integration — there the host is a Cortex-M0 on native AHB and
  the PS/AXI framing of the question disappears; a Cortex-M system would
  instead want the APB on a low-priority expansion port, which the unified
  APB already is.

Rationale: the latency win is ~2× on the fabric hop (~20 hclk → ~10) while
SW driver overhead (≥150 ns–µs) dominates end-to-end poll latency; the
robustness win is real but TX_STALL_TIMEOUT already caps the outage at
1.3 ms per aborted beat; and every hot register is already off the data
path. The remaining exposure (peer-aperture stalls) is better fixed at its
source than insured against with a new port.

---

## 5. Other bottleneck reductions, ranked by value/effort

| # | Item | Expected gain | Effort | Risk |
|---|---|---|---|---|
| 1 | **Replay idempotency (residual #7)** | up to 3–5× effective throughput on marginal links; correctness | M–H (Wlink RX seq/dedup) | M (Chisel-domain change) |
| 2 | **Returner delta-accumulate fix (§3.3.1)** | kills autonomous credit-leak class | **S** (~10 lines) | L |
| 3 | **Multi-word FC packets** | wire efficiency 33%→63% (≈ +90% payload BW) | H | M |
| 4 | **FIFO right-size to 8 KB (§2)** | −0.041 mm² ASIC, floorplan relief | S–M | L |
| 5 | **GP1 APB isolation (§4)** | debug/poll surface survives stalls | S (BD only) | L |
| 6 | HW auto credit-release / threshold tuning | latency, small | S | L–M |
| 7 | Skid deepen 1→4 | burst knee 18→21 words (~nil) | S | L |
| 8 | MAX_SIDEBAND_BURST tuning | nil today | S | L |
| 9 | Write-combining in TX aperture | nil without #3 | M | M |

Detail:

1. **Replay non-idempotency** (`archive/AUTOCAL_CLOSURE_2026_06_10.md`
   residual #7): each link-layer replay is re-applied by the RX consumer —
   silicon showed 3–5 copies per doorbell (RESP_ACC 0x3000–0x5000 for one
   ring). Frame it as a *throughput* bug: every duplicate burns a full 12 B
   packet slot and corrupts W-add accumulators, and with FIFO_DATA it
   duplicates RX words (data corruption). Fix at Wlink RX (sequence-number
   dedup) or make all FC consumers idempotent (harder: FIFO writes are
   positional, so the addr_offset actually makes FIFO_DATA *naturally*
   idempotent — the same word rewrites the same address; the vulnerable
   consumers are the W-add accumulators and `write_complete` edge logic).
   The targeted small fix: dedup only SIDEBAND, exploit positional
   idempotency for FIFO_DATA, and make `write_complete` level- rather than
   event-derived.
2. **Returner delta-accumulate**: change `credit_delta_data` update to
   *add* while `pending_0` is outstanding (or defer the `release_acc` clear
   until the returner captures). Removes mechanism §3.3.1 entirely; also
   close the same-cycle set/clear race by prioritizing set over clear.
3. **Multi-word FC packets**: the FCSM hardcodes 7-byte packets; Wlink
   `word_count` is 16-bit. Batching N 48-bit flits per long packet gives
   4N/(6N+5) bytes efficiency: N=4 → 55%, N=16 → 63% (vs 33%). Requires
   FCSM/Chisel regen (`FC_DATA_W` contract, ARCHITECTURE.md §7 warns) + a
   TX-side packing buffer + RX unpack — the right vehicle is the planned
   V2 link-management refactor, not a point patch. A further protocol step
   (suppress per-word addr for sequential streams) reaches 4N/(4N+5) → 93%
   at N=16, but that is a format redesign.
6. **Credit-release tuning**: threshold 20 is well-chosen (5% sideband
   overhead, 0.5% of the credit pool). A HW auto-release *below* SW
   (releasing on `read_complete` directly with threshold=0) already exists
   as a degenerate config; the real win would be HW-autonomous *drain*
   (DMA), out of scope here. Not a bottleneck at current rates.
7. **Skid deepening**: only worth bundling with other fc_adapter edits; the
   quantitative effect (§3.1) is a 3-word shift of the burst knee.
9. **Write-combining**: cannot help while the FC word carries exactly one
   32-bit payload — it is subsumed by #3.

**Already good (no action):** the RX direct-write path (3 hclk/word ≈
16.7 M words/s @50 MHz, 25–2000× the link packet rate) — the 2026-era
"2x throughput" bypass did its job; the release-threshold pipeline
(2-cycle latency, invisible behind the 3-cycle returner); sideband
arbitration fairness.

---

## Appendix: assumptions & sources

- Wire efficiency bounds (25%/33.3%) — `WlinkGenericFCSM_6.v:631`
  (word_count=7), `WlinkTxLinkLayer.v` byte-packing; dense-packing assumed
  for headline, beat-aligned floor quoted. Short-packet (CR/ACK) overhead
  and LL idle patterns not modelled (second-order at sustained load).
- One-way latency beat counts (10–15) are architectural estimates from the
  CDC/FSM structure, not ILA-measured; error bars ±50% do not change any
  conclusion (BDP stays ≪ FIFO size; ahb_sub stall stays unacceptable).
- AHB-side per-write cost (15–20 hclk) is an estimate; the perf-profiling
  registers (Regions 5–7) can replace it with a measurement.
- SW drain latencies: bare-metal M0 IRQ 10–100 µs, Linux/Python 1–10 ms —
  planning numbers, not measurements.
- Macro areas from LEF `SIZE` lines under `/research/precompiled_mems/TSMC65/`
  (rf_16k/rf_08k/rf_01k); read-only collateral, no IP-library files modified.
- Measured failure modes from `docs/archive/AUTOCAL_CLOSURE_2026_06_10.md`
  (residuals #5/#6/#7) and `docs/V37_FINAL_DIAGNOSIS_2026_06_12.md`.
- Clock rates: BD tcl (`pair-all`, v36 = 6.25 MHz hclk+link; pre-v36 rig =
  50 MHz hclk / 25 MHz link); ASIC `common.mk` CLK_PERIOD 4.0 ns (250 MHz
  hclk) with ~100 MHz GPIO link target.
