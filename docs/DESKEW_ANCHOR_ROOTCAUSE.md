# TideLink cross-lane word-deskew anchor — root-cause of the intermittent data-delivery lottery

Read-only RTL trace. Target: `/home/dam1n19/SoCLabs/tidelink`, V2 FPGA build
(`flists/tidelink_fpga_v2.flist`). Prepared for the 2026-07-22 KR260 hardware session.

**Symptom (measured on real KR260, 2026-07-22):** both dies at `cal=1 fcsm=4 cr=1`,
EPOCH-anchored; a byte-exact packet crosses (many distinct tags, both directions), but
the *next* packets in the same bring-up read back all-zero. `fcsm`/`cr`/`crack`/`EPOCH`/
`llrx_valid` read **identical** whether a packet delivers or not — only a tagged data
canary tells the truth. (Source: `memory/project_kr260_first_data_crossing_2026_07_22.md`,
"CORRECTION" §.)

Every mechanism claim below is tagged **[VERIFIED-RTL]** (traced to file:line in the
files the V2 flist compiles) or **[INFERRED]** (consistent with the RTL + measurements but
not provable from RTL text alone).

---

## 0. Which corrector is actually built (correcting a stale note)

The V2 flist compiles the two local overrides, **not** the `deps/` copies:
- `flists/tidelink_fpga_v2.flist:152` → `src/rtl/local_overrides/tidelink_lane_deskew_v2.sv`
- `flists/tidelink_fpga_v2.flist:165` → `src/rtl/local_overrides/WavD2DGpio_v2.v`

`WavD2DGpio_v2.v` instantiates the deskew at **`:818-883`**:
```
.LANES(8), .WIDTH(16), .DEPTH_LOG(5), .SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN),   // :837
...
.EPOCH_ANCHOR_EN(EPOCH_ANCHOR_EN)                                            // :882
```
with the module parameter `EPOCH_ANCHOR_EN = 1'b0` (`WavD2DGpio_v2.v:145`), and **no
upstream override sets it to 1** on the V2 flist (the only `TL_EPOCH_ANCHOR_EN` define
path is in the *deps* file `deps/.../WavD2DGpio.v:788`, which is not compiled here).

**[VERIFIED-RTL] Therefore the shipping V2 build runs `SYNC_REANCHOR_EN=1`,
`EPOCH_ANCHOR_EN=0`.** The active corrector is the **SYNC-beacon re-anchor**
(`g_reanchor`, `tidelink_lane_deskew_v2.sv:1341-1553`); the EPOCH path (`g_epoch`,
`:1136-1339`) is generate-pruned. The `reanchored` latch (`:1343`, set at `:1495`) is the
"corrector-engaged" signal; it is surfaced as `epoch_anchored_o` (`:1552`).

> ⚠️ **Stale comment trap:** the `WavD2DGpio_v2.v` header at **`:51-53`** still says
> "`tidelink_lane_deskew (LANES=8, WIDTH=16, DEPTH_LOG=4, SYNC_REANCHOR_EN=0)`". That
> describes the *original/deps* wiring and is **wrong for this file** — the real instance
> at `:837` uses `DEPTH_LOG=5` and `SYNC_REANCHOR_EN=1`. Do not trust `:51-53`.
>
> ⚠️ An older memory note (`project_v2_no_armed_word_corrector_2026_07_17.md`) claims
> "`EPOCH_ANCHOR_EN` hard-coded `1'b0` at `:827`, no corrector armed." The line moved and
> the param is now genuinely forwarded (`:837`/`:882`, plumbing fixed 2026-07-17). The
> corrector that *is* built is SYNC_REANCHOR; it simply **cannot arm without the beacon**
> (§2), which is the same practical failure.

`DEPTH_LOG=5` ⇒ `DEPTH=32`, pointer width `PW=6`, `EPOCH_OFF_MAX = DEPTH-PRIME_THRESH-3
= 24` (`tidelink_lane_deskew_v2.sv:411-419`).

---

## 1. How the cross-lane word deskew anchors (SYNC_REANCHOR path) [VERIFIED-RTL]

Each of the 8 lanes deserialises 16 bits onto its **own** `io_link_clk_N` word clock. The
eight word clocks are frequency-locked (all ÷16 from the same recovered `pad_clk_rx`) but
**phase-skewed by up to ~7 word-periods** (`tidelink_lane_deskew_v2.sv:28-32`, `:114-120`).
Without correction the Wlink RX samples all lanes on lane-0's clock and assembles a
128-bit word from **different time-points** per lane — a sheared word.

**Write side, per lane (lane_clk domain) — `g_lane_write` / `g_sync_capture`:**

1. Writes free-run: every `lane_clk[gi]` edge stores `lane_data` into `mem_l` and
   increments the binary write pointer `wr_ptr_l` (`:537-546`). Writes are **never gated
   by training_mode** — training words flow through the FIFO too (`:38`, `:494`).

2. Each lane watches its incoming word for its own SYNC slice
   `TIDELINK_SYNC_WORD[16*gi +: 16]` (`:586`). A **tolerant** match:
   `sync_dist_w = popcount(word ^ sync_slice)`; `sync_hit = (sync_dist_w <=
   SYNC_REANCHOR_TOL) && (|word)` (`:598-607`). `SYNC_REANCHOR_TOL` default **4**
   (`:233`); the `&& (|word)` term is the F3c local-override IDLE-zero rejection (`:601-607`).

3. A **self-gating periodic-confirm arm** (`:609-800`) gates the commit: a hit only
   commits after `SYNC_CONFIRM` (default **2**, `:272`) consecutive matches that recur at
   a **consistent periodic write-index** — exactly `SYNC_PERIOD` (default 32, `:313`)
   `lane_clk` edges apart, at the same residue `wr_ptr_l mod SYNC_PERIOD`, within a
   circular `±SYNC_IDX_TOL` (default 2, `:307`) jitter window. `periodic` at `:707`; the
   commit at `:748-767`:
   ```
   sync_idx_l  <= wr_ptr_l;   // the CONFIRMING SYNC's (recent) write index   :766
   sync_seen_l <= 1'b1;                                                       :767
   ```
   The commit deliberately latches the **confirming** index (near the live write pointer),
   not the stale first-seed index, so `sync_idx - rd_ptr` stays a small forward distance
   (`:749-765`). The anti-poison property: a *continuous* within-tol stream resets
   `sync_gap` every beat so it never reaches `GAP_LO` ⇒ `periodic` never fires
   (`:619-635`, `:690-694`).

**CDC:** each lane's `sync_idx_l` + `sync_seen_l` cross to `out_clk` through a 2-flop
binary sync (`g_sync_sync`, `:985-1002`) → `sync_idx_sync1`, `sync_seen_sync1`.

**Read side (out_clk domain) — `g_reanchor` `:1341-1553`:**

4. `all_sync_seen = &(sync_seen_sync1 | ~lane_mask)` (`:1350`) — every **active** lane must
   have committed a SYNC index (masked lanes excluded).

5. Per-lane forward distance `sync_dist[di] = sync_idx_sync1[di] - rd_ptr`; the cross-lane
   `max_dist` (latest-arriving SYNC) folds in **only unmasked lanes** (`:1373-1390`).

6. **The anchor latch** (`:1479-1507`), gated `advance && !reanchored && !rearm_wait`:
   when `all_sync_seen && sr_rd_safe` (`sr_rd_safe = rd_ptr >= sr_span`, `:1409`),
   ```
   lane_off[lo] <= lane_mask[lo] ? (max_dist - sync_dist[lo]) : '0;   :1490-1493
   reanchored   <= 1'b1;                                              :1495
   ```
   Then each lane reads `rd_ptr_l[gi] = reanchored ? (rd_ptr - lane_off[gi]) : rd_ptr`
   (`:1514`). The earliest lane gets the largest backward offset; when `rd_ptr` sweeps up
   to `max_dist`, all 8 SYNC slices land on the **same** out_clk beat ⇒ `out_data ==
   TIDELINK_SYNC_WORD`.

**Anchor event = "a SYNC word arrived, confirmed periodic, on all active lanes."** Before
that, `reanchored=0` and `rd_ptr_l == rd_ptr` — the plain prime-and-continuous common
pointer, with **zero** cross-lane word-skew correction (`g_no_reanchor` fallback at
`:1554-1568` is bit-identical to this pre-anchor state).

**Masked lanes never bit-align [VERIFIED-RTL]:** `lane_off = lane_mask ? … : '0`
(`:1490-1493`; EPOCH twin at `:1301-1303`). A masked lane's offset is parked at 0, so it
reads the raw common pointer. With the negotiated `LANE_MASK_RESET=0xE4` (memory:
`lanes_not_dead…`), lanes 0/1/3/4 get offset 0 regardless of their true skew — this is the
"masked lanes never bit-align" note in memory, verified here.

---

## 2. Why it is a ONE-SHOT lottery at the training→data handoff

**[VERIFIED-RTL] `reanchored` is one-shot sticky.** The only writers of the latch
(`:1456-1508`) are: POR reset (`:1457`), the `clr_pulse_o` re-arm (`:1461`), and the
single `!reanchored` engage branch (`:1479`). **There is no data-mode re-measure.** Once
`reanchored=1`, the branch at `:1479` is never re-entered; `lane_off[]` is frozen for the
rest of data mode.

**[GROUNDING, per task + recipe] The beacon is off in data mode.** The recipe leaves
`R8=0x1C` (SYNC) during bring-up, then sets `R8=0x10` (DATA) before data crosses
(`project_kr260_first_data_crossing_2026_07_22.md`, aperture facts §). `R8_DATA` strips
`SYNC_EN`, so **no new SYNC arrives in data mode** ⇒ `sync_hit` never fires ⇒ no lane can
re-commit ⇒ the corrector cannot re-anchor. The **last SYNC before the R8→DATA edge is the
anchor**, and it is the *only* one this data-mode session gets.

That handoff is non-deterministic per lane, so the frozen anchor lands in one of three
states — a per-bring-up lottery:

- **State A — never engaged.** If the finite SYNC window (before `R8→DATA`) is too short
  for every active lane to complete the `SYNC_CONFIRM=2` periodic run, or a marginal eye
  keeps some lane's `sync_dist_w > TOL`, then `all_sync_seen` never asserts and
  `reanchored` stays 0. The read side falls back to the **common pointer with zero skew
  correction** (`:1514` false-arm, `:1554-1568`). Any real per-lane word-epoch skew shears
  the 128-bit word for the *entire* data session. (This is the practical "no armed
  corrector" state the older memory described.)

- **State B — engaged on wrong/inconsistent indices.** The tolerant capture (`TOL=4`,
  `:606`) can latch a **wrong-slot** SYNC on a marginal eye — the `WavD2DGpio_v2.v:7-29`
  header documents exactly this ("a lane whose sticky `sync_idx` latched ONE SLOT OFF … a
  tol-5 Hamming wrong-slot confirm on a marginal eye — the die_b byte-lane[23:16] silicon
  corruption, 0x24→0x5c"). Cross-lane consistency also requires every lane to seed on the
  **same** beacon instance and confirm the same number of periods (`:749-765`); phase
  wander beyond `±SYNC_IDX_TOL=2` on one lane makes its committed `sync_idx` off by a word
  ⇒ its `lane_off` is off ⇒ the assembled word is sheared. `reanchored=1` reports
  "engaged" while the alignment is wrong.

- **State C — engaged correctly.** All active lanes committed the same instance at
  consistent indices; `lane_off[]` equalises the true skew; `out_data` is coherent and
  packets decode.

**The historical "sampled at a different phase per lane" story** (memory `reference_
tidelink_address_map.md`, commit 1a08308) was about the *original* training-edge-anchored
deskew and was fixed by content-anchoring. Its residual survives in the SYNC path as the
per-lane commit-index non-determinism above: each lane runs its own `lane_clk`, detects
the beacon at its own phase, and commits `wr_ptr_l` at its own confirming edge (`:766`).
The read side equalises those *only if* every lane's commit is on the same instance with
skew ≤ the correctable span. Whether it lands right is set by the marginal eye + how many
beacon periods elapsed before `R8→DATA` — **not controllable from firmware today.**

### Why a packet can deliver and the *next* not, within one bring-up

The frozen-anchor model alone predicts "all deliver" (State C) or "none deliver"
(A/B) for a whole data session. The observed *within-bring-up* first-delivers-then-zeros
needs one more step, and it is **[INFERRED]** (not provable from RTL text):

- The offsets `lane_off[]` are a **static snapshot** taken at anchor time, but the physical
  per-lane recovered word-clock phases **keep wandering** during data mode — that wander is
  the very reason `SYNC_IDX_TOL=2` exists (`:273-291`). With no beacon to re-measure
  (`reanchored` frozen), a **marginally-correct** anchor (State C at the edge of B) drifts:
  an early packet lands while lanes are still inside the aligned window and decodes; a later
  packet lands after a lane has walked ±1 word-epoch and shears → framer reads all-zero.
  This is a State-C/State-B boundary with **unbounded drift because nothing re-anchors in
  data mode.** The fix ranking (§5) targets exactly this: restore a data-mode re-measure.

An alternative/compounding **[INFERRED]** contributor is the Wlink RX framer's own per-packet
re-hunt losing byte/packet lock between packets when the beacon (its re-hunt aid) is absent;
that is downstream of the deskew and out of scope for this file, but points to the same
root — no in-data-mode re-sync.

---

## 3. What `EPOCH_ANCHOR_EN=1` would do

Setting `EPOCH_ANCHOR_EN=1` (at Wlink/WlinkGPIOPHY or a tb defparam) flips the instance to
`SYNC_REANCHOR_EN=!EPOCH_ANCHOR_EN=0` (`WavD2DGpio_v2.v:837`) and enables `g_epoch`
(`tidelink_lane_deskew_v2.sv:1136-1339`). They are **mutually exclusive** — the deskew
`$fatal`s if both are set (`:426-427`).

**[VERIFIED-RTL] EPOCH anchors on the training-EXIT edge, beacon-free.** The write-side
matcher (`g_epoch_capture`, `:857-939`) Hamming-scores each word against the lane's
constant training word `PATTERN_W[gi]` (`:858-863`); after a streak ≥ `EPOCH_STREAK_MIN`
(default 8, `:326`) it latches the **first data word's** write index on the pattern→data
transition (`ep_cand_idx <= wr_ptr_l`, `:928`; commit `ep_anchor_idx <= ep_cand_idx`,
`:918`), confirmed over `EPOCH_EXIT_CONFIRM` (default 2, `:356`) non-matches with a soft
abort. The read side (`:1234-1327`) computes per-lane offsets from anchor-index
**differences**, gated by all-fresh + `EPOCH_SETTLE` (32, `:330`) stable beats + span ≤
`EPOCH_OFF_MAX` (24). **This needs the training pattern→data edge, which is present at
every training exit — no SYNC beacon required.** So `EPOCH_ANCHOR_EN=1` *does* give a
re-anchor that does not depend on the (data-mode-absent) beacon.

**But EPOCH is also one-shot-per-training-window, not periodic-in-data-mode.**
`epoch_anchored` is sticky (`:1305`); it re-loads offsets **only** on a *new* coherent,
all-fresh, span-OK anchor set, i.e. a **new training window** advancing the freshness
counters (`:1140-1145`, `:151-168`). Between training windows (i.e. all through data mode)
it is just as frozen as the SYNC path. It buys a **deterministic re-anchor at each
training exit** (beacon-independent), not continuous data-mode tracking.

**[VERIFIED-RTL] The "unstable-span history" risk.** On a marginal eye a die measures
**noise** and produces a growing, over-budget cross-lane span. `ep_span > EPOCH_OFF_MAX`
(=24) triggers the SPAN-REJECT self-heal (`:1292-1318`): offsets revert to 0 and
`epoch_anchored` drops to 0 (plain prime-and-continuous). The in-code comments record the
silicon symptom directly: `:347-354` "die_a `anc=0` on silicon, die_b a noisier eye
anchored with a garbage growing span", and `:1307-1317`. So on the marginal KR260 eye,
EPOCH risks either **failing to anchor (die_a class)** or **anchoring on a garbage span
that then self-heals to zero-correction (die_b class)** — trading the SYNC path's
wrong-slot failure for a span-instability failure. Memory (`project_v2_no_armed_word_
corrector`) flags EPOCH's "unstable-span history" and that it **needs a HW A/B** before
trust.

---

## 4. Deskew observability registers (what a HW session can read)

Read these on a **delivered** packet vs a **dropped** packet in the same bring-up; the
deskew state should differ if the deskew is the cause.

| SoC addr | Name | Source (file:line) | Trust | Meaning |
|---|---|---|---|---|
| **0x4403_2140** | `SWI_EPOCH_STATUS` | `epoch_anchored_o`/`epoch_span_o` → Wlink → top (`tidelink_top.sv:1113,1170`); deskew `:1552-1553` | **TRUSTWORTHY** | In the SYNC build: **bit[0] = `reanchored`** (corrector engaged), **bits[6:1] = `sr_span`** at engage. bit0=1 is the only positive "aligned" evidence. |
| **0x4403_212C–0x2138** | RX raw post-deskew word `dbg_obs_raw_word_1[127:0]` | `axi_chiplet_controller.sv:2321-2324` | **GROUND TRUTH** | The assembled 128-bit `out_data`, 4×32b. With the SYNC beacon flooding (SYNC mode, mask 0xFF) a correct anchor reads `f1e2d3c4_b5a69788_796a5b4c_3d2e1f00` = `TIDELINK_SYNC_WORD` on all 8 lanes. Any lane not matching its slice = that lane sheared. Memory §3: **use this as ground truth.** |
| **0x4403_215C** | `SYNC_SEEN_VEC` (RO) | `axi_chiplet_controller.sv:2413-2424` | **PARTIAL** | bits[7:0] per-lane `sync_seen_sync1`; marker 0x5F at [31:24]. Decode with 0x2140 bit0: `0x00`=no lane armed; **set & 0x2140.bit0=0** = armed but indices inconsistent (State B); **set & 0x2140.bit0=1** = armed + coherent (State C). ⚠️ **structurally blind to lane 0** on a quiet link (F3c IDLE-zero gate, `:1-22`) and reads 0 unless `SYNC_REANCHOR_EN`. |
| 0x4403_21AC / 0x21B0 | `SYNC_DIST_OBS` / `SYNC_DIST_SEL` | `axi_chiplet_controller.sv:2550-2551` | **CAUTION** | Per-lane live Hamming distance to SYNC slice (the winscan eye metric). ⚠️ `0x21B0` (the lane-select write) is **WRITE-PROTECTED on the certified build** (memory `lanes_not_dead…` §3) — the manual winscan is a no-op there. |
| 0x4403_2144 | `livematch` | `axi_chiplet_controller.sv:1013,1156` | **DO NOT TRUST** | `sync_lane_live_q <= q \| match` **saturates and never clears**; lane-0 slice popcount 5 == tol 5 ⇒ an **all-zero lane false-positives** at tol≥5. Memory: "livematch is PRIMARY" is **UNSAFE**. |
| (winscan FSM only) | `obs_anchor_verified_w` | `WavD2DGpio_v2.v:7-29,1116-1265`; `axi_chiplet_controller.sv:979,4356` | **STRONG when readable** | Sticky latch that sets only when, **with `reanchored` engaged**, a post-deskew word matches `TIDELINK_SYNC_WORD` **exactly on every active lane simultaneously** — the framer's zero-tolerance criterion. Cannot fire on a mis-anchored (one-slot-off) link (`:11-19`). It gates the winscan `WS_FINALIZE` release (`ws_verify_q`); confirm whether it is exposed at an APB slot (WINSCAN_OBS 0x21B8) on the deployed image before relying on a direct read. |

**Recommended HW read pair:** `0x2140.bit0` (reanchored) **and** the raw slice
`0x212C–0x2138`. If a delivered packet and a dropped packet show **identical** `reanchored`
and identical raw slices, the deskew anchor is *not* changing between packets and the
within-bring-up intermittency is drift/framer (§2 INFERRED), not a re-latch. If the raw
slice differs (one lane's slice sheared on the dropped read), the deskew alignment is
marginal/drifting — the primary hypothesis.

---

## 5. Ranked fix candidates

Ranked by how directly each gives **reliable data-mode delivery**.

### (a) Beacon-free periodic re-anchor in the deskew — **HIGHEST LEVERAGE, most work**
**[INFERRED, RTL-suggested]** The true root is that **nothing re-anchors in data mode**
(§2). Add a data-mode re-measure that does **not** need the idle-gated SYNC beacon:
either keep a low-rate SYNC in data mode (drop the `io_link_tx_tx_idle` gate — the
`io_swi_sync_force_always_in` knob already exists, `WavD2DGpio_v2.v:230-242`) *and* make
`reanchored` re-evaluate instead of latch-once (relax the `!reanchored` guard at `:1479` to
a periodic re-arm), **or** drive the existing `sync_obs_clr_pulse` re-arm (`:1461`,
`:913`/`:1024`) periodically in data mode so each fresh beacon re-measures.
- **Changes:** deskew read-side latch semantics (`:1479-1508`) from one-shot to periodic;
  TX beacon kept alive at low rate in data mode.
- **Breaks / risk:** a live re-shift on an aligned data link momentarily un-aligns it — the
  RTL comment at `:1426-1430` explicitly warns the clear "can momentarily un-shift an
  already-aligned link" and is only safe in the idle gap. A periodic re-anchor must fire in
  an inter-packet idle window, or it will *cause* the drop it is meant to prevent. Needs
  the same "anchor in the idle gap" discipline the EPOCH path relies on.
- **Sim coverage:** partial — `cocotb/tidelink_top_pair_wordskew`, `phy_rx_deskew`,
  `tidelink_phy_align_calibrator` exercise skew/anchor, but no test drives a *data-mode
  re-anchor*. New coverage required.
- **HW risk:** medium-high (touches the live datapath). But it is the only option that
  addresses the *within-bring-up drift* directly.

### (b) `EPOCH_ANCHOR_EN=1` — **directly available, beacon-independent, but eye-risky**
**[VERIFIED-RTL available]** Flip `EPOCH_ANCHOR_EN=1` (Wlink/WlinkGPIOPHY param or tb
defparam). Gives a **deterministic re-anchor at every training exit** without the beacon
(§3) — strictly better than the SYNC path for the *bring-up* handoff, because it does not
depend on a beacon that the recipe turns off.
- **Changes:** one parameter; `SYNC_REANCHOR_EN` auto-complements to 0 (`:837`).
- **Breaks:** it **disables the SYNC re-anchor + `sync_dist` winscan/autoneg autonomy
  stack** that `v2_winscan_fsm`/`v2_autonomous_sync_detect` depend on (`WavD2DGpio_v2.v:138-144`).
  The on-chip autonomy path would lose its corrector. And the **unstable-span risk** (§3,
  `:1307-1317`, `:347-354`): on the marginal KR260 eye EPOCH may fail-to-anchor or
  span-reject to zero-correction — trading one lottery for another.
- **Still one-shot per training window** — does **not** fix within-data-mode drift (§2) on
  its own; a data-mode disturbance still needs a fresh training window.
- **Sim coverage:** `EPOCH_PROFILE=silicon` path exists but is historically **RED/ungated**
  (memory); elaboration-only ASIC checks cannot see it. Needs a real HW A/B.
- **HW risk:** medium — needs a rebuild + a bench A/B; memory explicitly says "EPOCH anchor
  has unstable-span history, needs HW A/B" before trust.

### (c) Deterministic training→data handoff — **narrow, addresses State A/B, not drift**
**[INFERRED]** Make the last-SYNC anchor deterministic: hold `R8=SYNC` (beacon on) until
firmware has **confirmed** the anchor landed correctly — poll `0x2140.bit0==1` **and**
`obs_anchor_verified` (or the raw slice `0x212C–0x2138` == `TIDELINK_SYNC_WORD` on all
active lanes) **before** switching `R8→DATA`. Only enter data mode from a *verified* anchor.
- **Changes:** recipe/firmware only (no RTL) — a gated `R8→DATA` transition. `obs_anchor_
  verified` (`WavD2DGpio_v2.v:7-29`) is purpose-built for exactly this "one-slot-off can
  never fire it" gate.
- **Breaks:** nothing structural; it only *refuses* to enter data mode on a bad anchor
  (State A/B) rather than making a bad anchor good — converts silent shear into a visible
  bring-up retry.
- **Does NOT fix** the within-bring-up drift (§2 INFERRED) — a *verified* anchor can still
  drift once the beacon is off. Pairs naturally with (a).
- **Sim/HW risk:** low (firmware/recipe). Highest value-per-risk as an *immediate*
  mitigation; ship alongside (a) for the durable fix.

### (d) Unmask all lanes (`LANE_MASK_RESET=0xFF`) — **enabler, not a fix**
**[VERIFIED-RTL mechanism]** Masked lanes get `lane_off=0` and never bit-align
(`:1490-1493`). With `0xE4`, lanes 0/1/3/4 are never corrected. `0xFF` lets the anchor
correct all 8 (and is the best-tested sim default). **But** memory
(`lanes_not_dead…` §5) already measured that the 8-lane rebuild **did not move throughput
or reliability** — it is necessary for full-width correction but **not** the delivery-
lottery fix. Include it in any rebuild for (a)/(b); do not expect it to fix intermittency
alone.

---

## Summary

- **[VERIFIED-RTL]** The V2 build's active corrector is the **SYNC-beacon re-anchor**
  (`SYNC_REANCHOR_EN=1`), and its `reanchored` latch is **one-shot sticky** with **no
  data-mode re-measure** (`tidelink_lane_deskew_v2.sv:1479-1508`).
- **[GROUNDING]** The recipe turns the beacon off in data mode, so the **last pre-DATA
  SYNC is the only anchor** — a per-bring-up lottery over States A (never engaged →
  zero-correction), B (wrong-slot / cross-lane-inconsistent → sheared), C (correct).
- **[INFERRED]** The *within-bring-up* first-delivers-then-zeros needs the extra step that
  the static offsets do not track the wandering per-lane word-clock phase, and nothing
  re-anchors in data mode — so a marginal anchor drifts out over successive packets.
- **Fix ranking:** **(a)** beacon-free periodic data-mode re-anchor is the durable fix
  (highest work/risk); **(c)** a firmware-gated verified handoff is the cheapest immediate
  mitigation and pairs with (a); **(b)** `EPOCH_ANCHOR_EN=1` is beacon-independent and
  available now but eye-risky and disables the autonomy stack; **(d)** `0xFF` is an enabler,
  not a fix.
- **HW read pair to disambiguate:** `0x2140.bit0` (reanchored) + raw slice
  `0x212C–0x2138`, on a delivered vs a dropped packet. Distrust `0x2144` (livematch, lies)
  and treat `0x215C` (sync_seen) as lane-0-blind.
