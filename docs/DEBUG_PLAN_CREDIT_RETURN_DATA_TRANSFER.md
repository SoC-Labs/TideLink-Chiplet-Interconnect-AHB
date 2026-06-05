# Debug Plan — Credit-Return / Sustained Data-Transfer Failure on Silicon

Status: ACTIVE — final hurdle for TideLink chiplet link
Author: agent grounding pass 2026-06-05
Working dir: `/home/dam1n19/SoCLabs/tidelink`
Branch: `fix/build9-unified`

> HARD RULE: never modify anything under `/research/AAA/ip_library/**` or
> `/research/AAA/phys_ip_library/**` (vendor IP, read-only). Use
> `src/rtl/local_overrides/` for any IP-adjacent change.

---

## 0. One-paragraph orientation

The link comes up bilaterally on silicon (cal_done=1, cr=1, crack=1, 8/8 lane
lock, committed fixes `45a13fe`/`f99ec48`/`ccfd255`). Initial data crosses BOTH
directions. **The remaining hurdle: sustained traffic decays** — after the
first 1–2 packets/doorbells, delivery stops and the FCSM credit ring drains and
never refills:

```
master: FCSM=5 (LINK_DATA)  CURRENT_CREDITS=0xdea (3562, draining from 4096)  RESP_ACC=0  PAIR_CREDIT=0
slave:  FCSM=4 (LINK_IDLE)  CURRENT_CREDITS=0x0   (fully drained)             RESP_ACC=0  PAIR_CREDIT=0
```

cocotb does NOT reproduce this: `test_10_sustained_doorbell_replenish`
(`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:1158`) rings 48
doorbells each way and PASSES. The central task of this plan is to **close that
sim/HW gap** and root-cause the credit-return decay.

---

## 1. Precise problem statement + resolved credit-accounting model

There are **TWO distinct credit ledgers**. They must not be conflated; ~12h of
prior debug was lost to conflating them (see address-map memory).

### 1A. Functional link-layer credit ring (the FCSM "fe/ne" ring)

This is the credit that gates whether the **sender FCSM may launch the next FC
data packet** onto the link. All references in
`src/rtl/local_overrides/WlinkGenericFCSM_6.v`:

* **Consume (sender side):** when the app presents a data word and the ring is
  not full, the FCSM advances `ne_rx_ptr` and enters LINK_DATA (state 5):
  * `WlinkGenericFCSM_6.v:539` `_T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full`
  * `:546` `_GEN_59 = (… & ~fe_rx_is_full) ? ne_rx_ptr_next : ne_rx_ptr`
  * `:547` `_GEN_60 = (… & ~fe_rx_is_full) ? 3'h5 : state`  (→ LINK_DATA)
  * `:441` `ne_rx_ptr_next = (ne_rx_ptr == fe_rx_credit_max_txsync) ? 0 : ne_rx_ptr+1`
  * `:464` `fe_rx_is_full` = ring full when `ne_rx_ptr_next` wraps onto `fe_rx_ptr`.
  So **a packet may only launch while `~fe_rx_is_full`**. Ring depth modulus =
  `fe_rx_credit_max_txsync` = `0x1f` (31), loaded from the CR/CRACK `0x1f1f`
  word during bringup (`:514`), tx-synchronized by the `ccfd255` 2-flop fix
  (`:391` `fe_rx_credit_max_txsync_meta` / `:392` `_txsync`).

* **Return (receiver side):** the receiver, on decoding a valid expected data
  packet, must emit an **ACK packet** back across the return link. The ACK
  carries `last_good_pkt_from_rx` which, when received by the original sender,
  advances `fe_rx_ptr`, **freeing a ring slot**:
  * RX decode writes the exp-pkt tag into `ack_nack_fifo`
    (wr clock = **io_rx_clk**, `:856`; `:858` winc on
    `pkt_is_ack | pkt_is_nack | exp_pkt_seen | exp_pkt_not_seen | crc_err`).
  * tx domain dequeues (`:862` `rinc = ack_nack_fifo_valid & state!=0`;
    rd clock = **io_tx_clk**, `:860`).
  * `:418` `isExpPacket` (tag 0) → `:548` sets `send_ack_req`
    (also on `l2a_fifo_raddr_txclk_update`).
  * When `send_ack_req & count==0` the FCSM goes to **state 6 (send ACK)**:
    `:553` `_GEN_67 = (send_ack_req & _T_54) ? 3'h6 : …`, emitting
    `last_good_pkt_from_rx` (`:471`, `:525` `_GEN_61`).
  * On the ORIGINAL sender, that returning ACK is decoded, written to ITS
    `ack_nack_fifo`, dequeued, and `:1205` `isAckPacket | isNackPacket` →
    `:1206` `fe_rx_ptr <= ack_nack_fifo_io_rdata[15:8]` — **this is the credit
    return**. Until `fe_rx_ptr` advances, `fe_rx_is_full` eventually latches and
    the sender FCSM cannot launch further packets.

  **Crucially: this functional ring return does NOT require the receiver to
  drain its RX FIFO.** The ACK is emitted by the link-layer FCSM purely on RX
  decode of the data packet. A doorbell (sideband, no RX-FIFO payload) gets the
  same ACK treatment.

### 1B. SW/sideband observability ledger (PAIR_CREDIT / CURRENT_CREDITS)

This is a SEPARATE accounting that mirrors RX-FIFO occupancy and **does** require
a SW drain. See address-map memory: `PAIR_CREDIT_CTR` (APB 0x28) is a
SW/sideband OBSERVABILITY counter, NOT the functional credit.

* **CURRENT_CREDITS (APB 0x08)** = `current_credit_count` = RX-FIFO free space:
  * generated in `src/rtl/fifo/tidelink_fifo_ctrl.sv:265`
    `assign current_credit_count = credit_count_r;`
  * `:257` resets to `MAX_CREDITS` (4096), `:244` decrements by `packet_delta`
    on `write_complete` (RX FIFO filled by an inbound data packet),
    `:251` increments on `read_complete` (SW/AHB **drains** the RX FIFO).
  * `:107` `read_complete = ahb_valid_transfer && (haddr==read_target_addr_r) && ~hwrite`
    — i.e. a real AHB read of the RX FIFO. **No drain → no `read_complete` →
    CURRENT_CREDITS only decrements.**

* **PAIR_CREDIT (APB 0x28)** = peer's `pair_credit_counter`
  (`src/rtl/fifo/tidelink_apb_regs.sv:320`), incremented across the link by the
  peer's RETURNER channel-0 on `release_credits_trigger`
  (`tidelink_apb_regs.sv:393`), which fires on `read_complete_d1`
  (`:394`, threshold-gated by `release_threshold`, default 20 at `:200`).
  `release_credits_trigger` → returner channel-0 writes a delta to the peer's
  released-credits accumulator (`tidelink_fifo.sv:314`,
  `PAIR_RELEASED_CREDITS_ADDR` = pair_base+0x020).

### 1C. Doorbell vs AHB-data — do they share the ring?

* A **doorbell** is a returner channel-2/SW sideband write that the
  `tidelink_fc_adapter` converts into an FC sideband data packet
  (`src/rtl/tidelink_fc_adapter.sv:8,263`). It crosses the link AS an FC data
  packet → consumes one slot of the **functional ring 1A** (advances
  `ne_rx_ptr`) and is ACK'd back the same way. It does **NOT** land in the RX
  FIFO, so it never produces `write_complete`/`read_complete` and never moves
  ledger **1B**.
* An **AHB DATA packet** (DEADBEEF/CAFEBABE) lands in the RX FIFO
  (`write_complete`, `tidelink_fifo_ctrl.sv:98/104`), decrements
  CURRENT_CREDITS, and ALSO consumes a functional-ring slot to cross the link.
  Its functional-ring credit returns via ACK (1A); its 1B ledger only returns
  when SW drains.

### 1D. Therefore — the HW symptom decoded

The HW shows the **functional ring 1A** draining and never refilling:
master in LINK_DATA (state 5), slave in LINK_IDLE (state 4), both
PAIR_CREDIT=0, RESP_ACC=0. The master keeps consuming `ne_rx_ptr` slots
(CURRENT_CREDITS 0x08 separately drains because nothing is drained, but that's
1B and is partly expected) but **`fe_rx_ptr` never advances → no ACK is coming
back from the slave**. The slave is stuck in LINK_IDLE (state 4) and **never
reaches state 6 to emit the ACK** — OR it emits ACKs that are corrupted on the
return link so the master's `ack_nack_fifo` never produces `isAckPacket`.

That second clause is exactly the **deskew-bubble failure mode** already
root-caused in memory `project_tidelink_deskew_bubble_bug_2026_06_04`: under
real per-lane skew the framer mis-frames sustained traffic ("first packet OK,
then dies; FCSM bounces 4/5/7; PAIR_CREDIT=0; sustained doorbells don't cross").
**The credit-return ACK packets ARE sustained return-link traffic and are the
prime victim of that mis-framing.** This plan treats the deskew-bubble class as
the #1 structural hypothesis while still proving the cheap alternatives first.

---

## 2. Ranked hypothesis list

Ranked by (likelihood given evidence) × (cheapness to test). Each: mechanism /
why HW-only / cheapest experiment.

### H1 — ACK/credit-return packet mis-framed on the return link (deskew-bubble class) ★ TOP
* **Mechanism:** Slave decodes master's first data packet, emits an ACK (FCSM
  state 6). But the return link's RX framer on the master mis-frames sustained
  words because the cross-lane deskew FIFO injects bubble words when `all_ready`
  glitches low (`tidelink_lane_deskew.sv:22-28`; framer `WlinkRxLinkLayer` has
  no flow control). The first packet frames cleanly (FIFOs prime at bootstrap),
  later packets/ACKs desync EOP→SOP. Master's `ack_nack_fifo` never sees a clean
  `isAckPacket` → `fe_rx_ptr` (`:1206`) never advances → ring fills → master
  wedges in LINK_DATA. Simultaneously the master's data packets to the slave
  mis-frame, so the slave's exp_pkt decode fails and it never reaches state 6 →
  slave stuck LINK_IDLE (state 4). **Bilateral, symmetric — matches HW exactly.**
* **Why HW-only:** zero-skew sim has no per-lane skew → deskew FIFO stays primed,
  `all_ready` never glitches, no bubbles, framing never desyncs. The current
  prime-and-continuous fix (`0fc5be0`/`f9bd57a`) is sim-validated but its HW
  validation is BLOCKED/UNCONFIRMED (master-RX phase-centering + a CR-bootstrap
  regression were observed; sustained-data re-run never completed cleanly).
* **Cheapest experiment:** add per-lane skew to the cocotb top_pair bench and
  re-run a sustained AHB-data test (see §3, S3-A). If it decays in sim → H1
  confirmed and now sim-reproducible.

### H2 — Test-methodology / no-AHB-data artifact (the sim gap is partly a test gap)
* **Mechanism:** `test_10` rings **doorbells only** — sideband packets that
  never fill the RX FIFO. It exercises functional ring 1A's ACK return but NOT
  the AHB-data write_complete path, NOT the RX-FIFO fill/drain, NOT
  CURRENT_CREDITS/PAIR_CREDIT. The HW test driver (`/tmp/td_*` helpers) may be
  sending AHB DATA packets and never draining the slave RX FIFO → CURRENT_CREDITS
  (1B) monotonically drains by construction (expected), which can be MISREAD as
  the bug. Part of the reported `CURRENT_CREDITS=0x0` may be a no-drain artifact,
  not a return-path RTL failure.
* **Why HW-only:** the sim test simply never drives this path; HW driver does.
* **Cheapest experiment:** clarify the HW driver: does `td_unidir_sustained.sh`
  send AHB data or doorbells, and does anything drain the slave RX FIFO? If
  data-without-drain, add a SW drain loop and recheck whether the FUNCTIONAL
  ring (SWI_LANE_STATUS FCSM + fe_rx_credit fields) still wedges. Separates 1B
  artifact from 1A bug. Zero build cost.

### H3 — `ack_nack_fifo` CDC under sustained load (rx→tx pointer crossing)
* **Mechanism:** `ack_nack_fifo` is written io_rx_clk (`:856`) and read io_tx_clk
  (`:860`). It is a `WavFIFO_1` (Gray-coded pointer CDC; `WavFIFO.v` uses
  `sync_wptr_demet`/`sync_rptr_demet` 2-flop demet of Gray pointers — verified
  multi-bit-safe). If the two link clocks are skewed/jittery on silicon the
  CDC could drop/duplicate an entry under sustained back-to-back ACK/exp writes,
  losing the ACK that returns credit. The `rinc` gate `& state!=0` (`:862`) means
  entries only dequeue when the FCSM is out of reset — a stuck state could also
  stall the dequeue.
* **Why HW-only:** sim link clocks are clean and phase-aligned; FIFO never
  approaches full/empty race. HW has real CDC + jitter.
* **Cheapest experiment:** in sim, run sustained traffic with the two io clocks
  given a small frequency offset + phase jitter (top_pair_drift-style) and watch
  `ack_nack_fifo_io_wfull` / `io_rempty` / rd-wr ptr gap. If entries are lost →
  H3. (Reuses the existing drift harness.)

### H4 — Returner / `release_credits_trigger` logic (1B path) stalls
* **Mechanism:** the returner is a shared AHB master with 3 channels
  (`tidelink_fifo.sv:306`). Channel-0 (release credits) fires on
  `release_credits_trigger_d`. If `master_error`/`returner_busy`/`ctrl_flush`
  wedges the returner (`tidelink_fifo.sv:337-339`), credit-release sideband
  writes never cross → PAIR_CREDIT stays 0. The `release_threshold` default of 20
  (`tidelink_apb_regs.sv:200`) means <20 drained credits never trigger a release
  at all — another 1B-only artifact.
* **Why HW-only:** depends on returner AHB completing on the real fabric; a
  contended/erroring AHB or a never-reached threshold won't show in a clean sim.
* **Cheapest experiment:** APB-read returner health (master_error, busy) if
  surfaced; in sim, force ≥`release_threshold` drained credits and confirm
  PAIR_CREDIT increments. Mostly relevant to 1B, low priority vs H1.

### H5 — Reset-domain / SW-bringup leaves the return path disabled
* **Mechanism:** the ACK path depends on `en_ff2_tx_demet_io_out` (app_enable
  synchronized to tx, `:880`) and `en_ff2_rx`. If `io_app_enable` deasserts mid-
  run (or the slave's training mode re-asserts, re-zeroing `fe_rx_ptr` at `:1204`
  `~en_ff2_tx_demet_io_out` and `ne_rx_ptr` at `:891`), the ring resets and
  credit math collapses. The `sw_coord_FIX` bringup or a watchdog re-pulse could
  toggle enable.
* **Why HW-only:** sim bringup holds enable stable; HW bringup scripts and
  watchdog (L11) can re-pulse.
* **Cheapest experiment:** read SWI_LANE_STATUS repeatedly during the HW decay —
  if FCSM bounces 4↔5↔7 (not stuck), enable is glitching (this is also the
  deskew-bubble fingerprint). In sim, toggle `io_app_enable` mid-run and observe
  ring re-zero.

### H6 — `fe_rx_credit_max` modulus collapse regression (Bug-C, already fixed)
* **Mechanism:** the pre-`ccfd255` enable-dip re-zeroed `fe_rx_credit_max`→0,
  collapsing the ring modulus so `ne_rx_ptr_next` always wraps → `fe_rx_is_full`
  immediately. `ccfd255` removed the re-zero and added the tx-sync.
* **Why HW-only / status:** already fixed and gated by the enable-dip test
  (`test_tidelink_pair_doorbell.py:~1300`). Listed for completeness — confirm it
  has NOT regressed by reading `fe_rx_credit_max_txsync==0x1f` on HW (surface via
  APB obs, §4). LOW priority unless §4 shows modulus != 0x1f.

**Ranking:** H1 (deskew-bubble ACK corruption) ≫ H2 (test gap) > H3 (ack_nack
CDC) > H5 (enable glitch) > H4 (returner/1B) > H6 (already fixed).

---

## 3. Sim-reproduction strategy (HIGHEST PRIORITY)

The whole plan hinges on making the sim DECAY like HW. `test_10` doesn't,
because (a) it sends doorbells not AHB data, and (b) zero-skew → deskew never
bubbles. Three concrete, ordered sim builds:

### S3-A (do first) — sustained AHB-DATA fill/drain under per-lane skew
The single most likely reproduction. New test
`cocotb/tidelink_top_pair/test_11_sustained_data_skew_decay.py`:
1. Bring up the pair (`run_bringup_full`).
2. Apply **per-lane skew** to the slave (and master) RX lanes. The skew knob is
   the same mechanism as `cocotb/tidelink_top_pair_drift` (slave on independent
   clock + phase offset) and the committed bubble test (627ae7a /
   `test_..._deskew_bubble`). Re-use the deskew bench: drive lanes
   frequency-LOCKED but **phase-offset by 1..7 word-periods** (the real HW
   scenario per the deskew memory), NOT frequency-mismatch (that over-stresses).
3. Drive **N≥64 back-to-back AHB DATA packets** M→S (compliant AHB writer from
   `test_data_path_compliant` / `test_08_ahb_packet_master_to_slave:1007`), each
   a 2-word header + payload, landing in the slave RX FIFO.
4. **Drain** the slave RX FIFO via AHB reads every few packets (drives
   `read_complete` → 1B release + frees nothing on the functional ring, which is
   ACK-driven).
5. Assert: every packet's payload arrives in order; master `fe_rx_is_full`
   never latches permanently; master `fe_rx_ptr` keeps advancing;
   slave FCSM reaches state 6 (emits ACK) at least once per packet.
6. **Expected (if H1 right):** with phase-offset skew the run DECAYS — first
   packet lands, then framer desyncs, slave stops ACKing, master `fe_rx_is_full`
   latches, delivery stalls. That is the red regression that reproduces HW.

If S3-A decays → **H1 confirmed, sim-reproducible**, go to §6 fix path (a/b from
the deskew memory). The prime-and-continuous fix (`0fc5be0`) should turn it
green; if it does NOT, the prime fix is insufficient for the ACK-return facet
and needs extension (gate framer on real `out_valid`, option (b)).

### S3-B — ack_nack_fifo CDC stress (clock offset, no skew)
If S3-A does NOT decay (skew alone insufficient), isolate the CDC: run sustained
AHB data with the two io clocks at a small frequency offset + phase jitter
(reuse `tidelink_top_pair_drift`'s independent-clock harness). Probe
`ack_nack_fifo` wfull/rempty and the wr/rd pointer gap. If an ACK entry is lost
→ H3. This is a targeted unit-level observation, ~7 min.

### S3-C — minimal ack_nack_fifo unit testbench (if S3-A and S3-B both clean)
If the full sim cannot be made to decay in zero/clean-clock, build a standalone
cocotb unit env around `WavFIFO_1` (the ack_nack_fifo type) driven by the exact
io_rx_clk write cadence + io_tx_clk read cadence observed on HW (from ILA, §4),
with deliberate metastability injection. This is the fallback if the bug is a
pure CDC corner the full sim's clean clocks can't excite — prove or refute the
crossing in isolation.

### Why full zero-skew reproduction is impossible
The functional ring 1A is structurally correct in zero-skew (test_10 proves ACK
return works). The HW failure is a **physical-layer framing/CDC** corruption of
the return-link traffic, which is INVISIBLE without modeling skew or clock
offset. So S3-A (skew) is the only path to a faithful full-system repro; S3-B/C
are the targeted fallbacks. **Do not** expect the bug to appear in clean-clock
zero-skew — that's the whole reason `test_10` is green.

### Sim env reminders
```
export CMSDK_FPGA_SRAM_V=/home/dam1n19/SoCLabs/tidelink/imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v
cd cocotb/tidelink_top_pair && make MODULE=test_11_sustained_data_skew_decay   # ~15 min full run
```

---

## 4. HW instrumentation plan

### 4A. CHEAP — APB observability additions (no ILA, no 40-min build needed if reusing an obs build)
The FCSM already exposes obs ports (`WlinkGenericFCSM_6.v:214-245`,
`io_obs_*`). SWI_LANE_STATUS (APB 0x44032108) already surfaces FCSM[19:17],
LLRX[22:21], cr/crack[23/24], llrx_valid[29] (deskew memory). **Add to the obs
mux (cheap, single-build):**
* `fe_rx_ptr[7:0]` and `ne_rx_ptr[7:0]` — watch the ring pointers directly.
* `fe_rx_credit_max_txsync[7:0]` — confirm modulus stays 0x1f (rules H6 in/out).
* `fe_rx_is_full` (`io_obs_fe_rx_is_full` already exists, `:241`) — the wedge bit.
* `send_ack_req`, `state` (FCSM) — does the receiver ever reach state 6?
* `ack_nack_fifo_io_wfull` / `io_rempty` — CDC health (H3).
* `isAckPacket` sticky — did the sender EVER decode a returning ACK?
* returner `master_error` / `busy` — H4 (1B).

Surface these in the obs register block fed to APB 0x108/spare offsets. With
these, a single sustained run + a handful of APB reads distinguishes:
* `fe_rx_ptr` frozen while `ne_rx_ptr` advances → ACK never returns (H1/H3).
* slave `state` never == 6 → receiver never emits ACK (H1 mis-frame / H5 enable).
* `fe_rx_credit_max_txsync != 0x1f` → H6 regression.
* `ack_nack_fifo` wfull asserted → H3 CDC backpressure.

### 4B. ILA signal list (FPGA_INSERT_DEBUG_CORE=1) — the credit-return microscope
Trigger condition: **`master fe_rx_is_full` rising edge** (the wedge moment), or
`ne_rx_ptr` change with `fe_rx_ptr` unchanged for >K cycles.

Probe set (both dies, or at minimum the master RX + slave TX of one direction):
1. FCSM `state[2:0]` (both dies)
2. `ne_rx_ptr[7:0]`, `fe_rx_ptr[7:0]`, `fe_rx_credit_max_txsync[7:0]`,
   `fe_rx_is_full`
3. `a2l_fc_replay_link_valid`, `_T_59 (link_valid & ~fe_rx_is_full)`,
   `auto_tx_out_advance`, `sop`
4. `send_ack_req`, `send_nack_req`, `last_good_pkt_from_rx[7:0]`
5. `ack_nack_fifo_io_winc`, `io_rinc`, `io_wfull`, `io_rempty`,
   `ack_nack_fifo_io_rdata[18:16]` (the pkt-type tag), `isAckPacket`,
   `isExpPacket`, `isNotExpPacket`
6. RX framer health (return link): `WlinkRxLinkLayer` byte_count / endOfPacket /
   SOP-hunt state, plus deskew `all_ready` / `primed` / `out_data` MSBs
   (`tidelink_lane_deskew.sv`) — this directly tests H1 (bubble→EOP misfire).
7. `release_credits_trigger`, returner `busy`/`master_error` (1B, H4).

Capture pipeline (memory `reference_phc_ila_capture`):
`pynq_host/scripts/phc_ila_capture.{sh,tcl}`, `.ltx` staging on mapstone-dev.
Build with `FPGA_INSERT_DEBUG_CORE=1` via `farm_build` (NOTE the
`mark_debug`/dbg_hub blocker, memory `reference_fpga_markdebug_dbghub_blocker` —
do not let a probed net constant-fold).

### 4C. Build/deploy/capture recipe (from memory; bench-flake-tolerant)
* Build: `farm_build` with `--expect-sha256 <sha>` AFTER positionals.
* Deploy: `PHASE_OVERRIDE=0x00100000 deploy_pair.sh 192.168.4.101 z2_02 die_a /tmp/tidelink_deploy`
  (master phase 8 — eye CENTER, NOT phase 0 edge) +
  `PHASE_OVERRIDE=0x00060000 … 192.168.6.101 z2_03 die_b` (slave phase 3).
  bit2bin + cat-pipe staging (NOT scp; mapstone-dev user `david`).
* Bringup: `sw_coord_FIX`. Decode: `/tmp/td_decode.sh`. Sustained:
  `/tmp/td_unidir_sustained.sh` / `/tmp/td_doorbell_test.sh` /
  `/tmp/td_credit_diag.sh`.
* z2_02 drops intermittently ("No route to host") — re-ping/re-flash to clear a
  transient PS-AXI bus error before declaring a failure (deskew memory).

---

## 5. Sequenced decision-tree procedure

Front-load cheap sim/APB before any 40-min ILA build.

```
STEP 0 (zero cost): Clarify the HW driver (H2).
  Read /tmp/td_unidir_sustained.sh + td_doorbell_test.sh.
  Q: doorbells or AHB data? Does anything DRAIN the slave RX FIFO?
  → If data-without-drain: part of CURRENT_CREDITS=0 is a 1B artifact, not the
    bug. Re-baseline on the FUNCTIONAL ring (SWI_LANE_STATUS FCSM + §4A obs),
    not CURRENT_CREDITS. Proceed regardless.

STEP 1 (sim, ~15 min): S3-A — sustained AHB-data + per-lane phase-offset skew.
  → DECAYS (slave stops ACKing / master fe_rx_is_full latches):
       H1 CONFIRMED + sim-reproducible. GOTO STEP 4 (fix).
  → Does NOT decay: GOTO STEP 2.

STEP 2 (sim, ~7 min): S3-B — sustained AHB-data + io-clock freq offset/jitter
  (drift harness), probe ack_nack_fifo wfull/rempty/ptr-gap.
  → Lost ACK entry / fifo backpressure: H3 CONFIRMED. GOTO STEP 4 (H3 fix).
  → Clean: GOTO STEP 3.

STEP 3 (sim, ~7 min): S3-C — ack_nack_fifo unit TB with HW-derived cadence +
  metastability injection.
  → Corrupts: H3 (CDC corner) CONFIRMED.
  → Clean: the bug is NOT in the modeled crossings → pivot to HW-only
    instrumentation. GOTO STEP 5 (skip cheap-sim, the sim can't see it).

STEP 4 (sim gate the fix): apply candidate fix (§6), re-run the RED test from
  STEP 1/2/3 → must go GREEN, AND re-run test_04/05/08/10 (no zero-skew
  regression — the deskew memory documents that clock-gate + T3A BOTH regressed
  zero-skew; only prime-and-continuous passed). Only then build HW.

STEP 5 (HW, cheap obs first): deploy a build with §4A APB-obs additions
  (one build). Run sustained traffic, read obs:
  - fe_rx_ptr frozen while ne_rx_ptr advances + slave state never 6
        → ACK not returning (H1) — confirm with STEP 6 ILA on framer.
  - fe_rx_credit_max_txsync != 0x1f → H6 regression (revisit ccfd255).
  - ack_nack_fifo wfull asserted → H3.
  - FCSM bounces 4/5/7 (not stuck) → enable glitch (H5) / deskew bubble (H1).

STEP 6 (HW, expensive — only if obs ambiguous): ILA build
  (FPGA_INSERT_DEBUG_CORE=1, §4B), trigger on master fe_rx_is_full rising.
  Watch one credit get consumed (ne_rx_ptr++) and FAIL to return (fe_rx_ptr
  static) — correlate with deskew all_ready/bubble + framer EOP on the return
  link. This pins H1 vs H3 vs H5 definitively.

STEP 7: apply confirmed fix (§6), re-sim-gate (STEP 4), rebuild, redeploy,
  re-run EXIT CRITERIA (§7).
```

---

## 6. Candidate fixes per confirmed hypothesis

| Hyp | Fix | File:line | Sim-gate (red→green) |
|-----|-----|-----------|----------------------|
| H1 (deskew bubble corrupts ACKs) | Already-committed prime-and-continuous (`0fc5be0`/`f9bd57a`) — VERIFY it covers the sparse ACK-return cadence, not just dense data. If sparse ACK traffic under-primes, extend: lower `PRIME_THRESH`, OR add a real `out_valid` framer flow-control (option (b) of the memory) so a deskew stall never injects a bubble. **Do NOT clock-gate the shared RX clock and do NOT enable T3A — both regressed zero-skew (deskew memory).** | `deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv` read controller (~130/141/147); framer flow-control would touch the override `WlinkRxLinkLayer` (local_overrides, NOT ip_library) | S3-A red→green; test_04/05/08/10 stay green |
| H2 (test/no-drain artifact) | Not an RTL bug — fix the HW test driver to DRAIN the slave RX FIFO and to send AHB data; re-baseline metrics on functional ring | `/tmp/td_unidir_sustained.sh` (test infra) | N/A — methodology |
| H3 (ack_nack_fifo CDC) | If a real corner: deepen the fifo / add Gray-safe re-sync margin, or ensure `rinc` gate doesn't stall mid-stream. The fifo is `WavFIFO_1` (vendor-adjacent — copy to local_overrides if edit needed, NEVER edit ip_library) | `src/rtl/local_overrides/` copy of WavFIFO if required; `WlinkGenericFCSM_6.v:862` rinc gate | S3-B/S3-C red→green |
| H5 (enable glitch re-zeros ring) | Stabilize `io_app_enable` / training-mode so it doesn't re-pulse mid-run; ensure `~en_ff2_tx_demet` ring re-zero (`:1204`) only fires at true reset | `WlinkGenericFCSM_6.v:1203-1204`, `:891`; bringup script | inject enable toggle in sim, confirm fix holds ring |
| H4 (returner/1B stall) | Ensure returner AHB completes; check `release_threshold` (default 20, `tidelink_apb_regs.sv:200`) is appropriate; surface master_error | `tidelink_fifo.sv:306-340`, `tidelink_apb_regs.sv:200` | force ≥threshold drain in sim, PAIR_CREDIT increments |
| H6 (modulus collapse) | Already fixed (`ccfd255`); only if obs shows txsync!=0x1f, revisit the 2-flop sync / enable-dip removal | `WlinkGenericFCSM_6.v:391-392,514` | enable-dip test (~:1300) stays green |

**Sim-gate discipline (POLICY, memory `feedback_sim_gate_before_hw_deploy`):**
integrated paired-die cocotb MUST pass before any farm build kicks. The fix's
RED reproduction test (S3-A/B/C) must go GREEN **and** test_04/05/08/10 must not
regress, before HW.

---

## 7. Exit criteria — "reliable data transfer"

All four must hold; measured both in sim (post-fix) and on HW.

1. **Sustained doorbells:** N ≥ 100 doorbells M→S AND 100 S→M, **zero misses**
   (every ring increments the receiver's read-to-clear DOORBELL_RESP_ACC).
   * Sim: extend `test_10` BATCHES so total ≥ 100 each way (currently 48); assert
     all batches deliver. Run WITH per-lane skew (S3-A harness), not just zero-skew.
   * HW: `/tmp/td_doorbell_test.sh` loop ≥100 each way; count delivered via
     DOORBELL_RESP_ACC (read-to-clear, one increment per delivered).

2. **AHB DATA round-trip, payload-verified, repeated:** write DEADBEEF/CAFEBABE
   (and a varying pattern) as AHB data packets M→S and S→M, drain the RX FIFO,
   verify payload bit-exact, repeat K ≥ 50 times each direction with **zero
   payload mismatches and zero drops**.
   * Sim: S3-A test — compliant AHB writer + RX-FIFO drain + payload compare,
     K≥50 under phase-offset skew.
   * HW: AHB write to TX aperture (0x40000000 peer aperture), AHB read of slave
     RX FIFO (0x44010000 LOCAL RX FIFO — address-map memory), compare.

3. **Functional credit ring stable:** master `fe_rx_ptr` keeps pace with
   `ne_rx_ptr` (ring never permanently full), `fe_rx_is_full` never latches
   high for >K cycles, `fe_rx_credit_max_txsync == 0x1f` throughout, FCSM holds
   **state 5 (LINK_DATA)** under load (does NOT fall back to 4/IDLE).
   * Sim: assert in S3-A (probe fcsm signals).
   * HW: §4A APB obs reads during/after the run; SWI_LANE_STATUS FCSM == 5.

4. **CURRENT_CREDITS (1B) not monotonically draining when SW drains:** with a
   SW drain loop active, CURRENT_CREDITS (0x08) recovers after each drain (the
   `read_complete` increment, `tidelink_fifo_ctrl.sv:251`), and PAIR_CREDIT
   (0x28) increments once accumulated release ≥ `release_threshold`.
   * Sim: drive fill+drain, assert CURRENT_CREDITS oscillates (not monotone).
   * HW: `/tmp/td_credit_diag.sh` with a drain loop; CURRENT_CREDITS stable.

Acceptance = all four GREEN in sim (with skew) AND on bridge1, across a
re-deploy (not a one-shot lucky lock).

---

## 8. Risks / contingencies

* **Bench flakiness (z2_02 "No route to host"):** re-ping/re-flash to clear the
  transient PS-AXI bus error before declaring failure. Verify fpgahub lease is
  GRANTED not queued (memory `feedback_lease_grant_before_deploy`); `pkill -9`
  the whole deploy tree (parent kill orphans children). Master must be deployed
  at PHASE_OVERRIDE=0x00100000 (phase 8, eye center) or lock oscillates.
* **Deferred deskew interaction = likely the SAME bug:** §1D + H1 + memory
  `project_tidelink_deskew_bubble_bug_2026_06_04` strongly suggest the credit-
  return failure IS the deskew-bubble class manifesting on the ACK/return-link
  traffic. If STEP 1 (S3-A) confirms, the fix is the prime-and-continuous deskew
  (already committed `0fc5be0`) — but its HW validation was blocked by master-RX
  phase-centering + a CR-bootstrap regression. **Contingency:** if prime-fix is
  insufficient for the sparse ACK cadence, extend with framer flow-control
  (option (b)), NEVER clock-gate the shared RX clock and NEVER enable T3A (both
  regressed zero-skew — documented).
* **CDC corner the sim can't excite (H3):** if S3-A/B/C all stay clean, the bug
  is a pure silicon CDC/metastability corner — pivot to HW-only ILA (STEP 6) and
  fix by deepening/re-syncing the ack_nack_fifo crossing (local_overrides copy,
  never ip_library).
* **Two ledgers confound the metric:** keep 1A (functional ring, ACK-driven,
  SWI_LANE_STATUS FCSM + fe/ne ptr) and 1B (CURRENT_CREDITS/PAIR_CREDIT,
  drain-driven) STRICTLY separate when reading HW state, or a 1B no-drain
  artifact will be misread as a 1A return-path bug (this has already cost ~12h
  in prior sessions — address-map memory).
* **ip_library hard rule:** `WavFIFO`, `WlinkRxLinkLayer`, `WlinkGenericFCSM`
  base sources may live under vendor trees — any RTL fix goes into
  `src/rtl/local_overrides/` with the flist re-pointed; NEVER edit
  `/research/AAA/{ip_library,phys_ip_library}/**`.

---

## Appendix — key file:line index

| Signal / logic | File:line |
|---|---|
| Functional ring consume (ne_rx_ptr++, →LINK_DATA) | `WlinkGenericFCSM_6.v:539,546,547` |
| Ring modulus / full | `WlinkGenericFCSM_6.v:441,464` |
| credit_max tx-sync (ccfd255) | `WlinkGenericFCSM_6.v:391,392,514` |
| ack_nack_fifo wr/rd clocks | `WlinkGenericFCSM_6.v:856(io_rx_clk),860(io_tx_clk)` |
| ack_nack_fifo winc/rinc | `WlinkGenericFCSM_6.v:858,862` |
| isExpPacket→send_ack_req | `WlinkGenericFCSM_6.v:418,548` |
| FCSM →state 6 (emit ACK) | `WlinkGenericFCSM_6.v:553` |
| ACK carries last_good_pkt | `WlinkGenericFCSM_6.v:471,525` |
| Credit RETURN (fe_rx_ptr<=ACK) | `WlinkGenericFCSM_6.v:1205,1206` |
| Ring re-zero on enable drop | `WlinkGenericFCSM_6.v:1203,1204` (fe), `:891` (ne) |
| CURRENT_CREDITS (1B) | `tidelink_fifo_ctrl.sv:265`; dec `:244`, inc `:251` |
| read_complete (drain) | `tidelink_fifo_ctrl.sv:107` |
| release_credits_trigger | `tidelink_apb_regs.sv:393,394`; threshold `:200` |
| Returner channels | `tidelink_fifo.sv:306-340` |
| PAIR_CREDIT counter | `tidelink_apb_regs.sv:320` |
| Doorbell→FC sideband | `tidelink_fc_adapter.sv:8,263` |
| Deskew bubble read ctrl | `deps/tidelink-gpio-phy/rtl/tidelink_lane_deskew.sv:~99` |
| FCSM obs ports | `WlinkGenericFCSM_6.v:214-245,241(fe_rx_is_full)` |
| test_10 (passes, doorbell-only) | `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:1158` |
