# TideLink GPIO PHY — Architecture Reference

**Audience:** engineers about to rewrite `tidelink_phy_align_calibrator.sv` and
its surrounding glue.

**Goal:** describe what the PHY actually IS, how the calibrator drives it,
where the asymmetric M→S sideband bug came from, and what an HW-realistic
calibrator MUST do that the current FSM does not. Read-only static reference.
No idealised "what we wished we'd built" — only what the RTL elaborates today.

**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-phy-archdoc`
(branch `doc/phy-architecture-ref`).

**Build path:** `flist/tidelink_fpga.flist` (cocotb `tidelink_top_pair`). The
flist replaces `WavD2DGpio.v` / `WavD2DGpioRx.v` / `WavD2DGpioTx.v` with the
local overrides under `src/rtl/local_overrides/`; the deps copies are NOT in
the elaboration set. Sim parameter defaults: `USE_IDELAY=0`, `USE_CLKBUF=0`,
`USE_T3A=0`. `AUTOCAL_ENABLE` is hard-wired to `1'b1` at
`src/rtl/tidelink_top.sv:1630`.

---

## 1. Executive summary

The TideLink GPIO PHY is the 8-lane data-and-clock GPIO link between two
TideLink chiplets. On each die it is comprised of (a) **Wavious GPIO D2D**
serialisers / deserialisers (`WavD2DGpio.v` + 8× `WavD2DGpioTx.v` + 8×
`WavD2DGpioRx.v` — SoC Labs invention, not real Wavious upstream), (b) a
per-lane sub-bit **sample-point selector** (`io_phase_offset`) and 16-bit
post-capture **right-rotation** (`io_bit_slip`), (c) the SoC Labs
**calibrator FSM** (`tidelink_phy_align_calibrator.sv`) that walks an 8 × 16
× DWELL search space looking for a per-lane (bit_slip, phase) pair that
makes the local **lane checker** (`tidelink_lane_checker.sv`) lock onto a
known training byte, and (d) parameter-gated FPGA-only auxiliary primitives
(`tidelink_idelay_rx.sv` IDELAYE2 + `tidelink_rxclk_buf.sv` BUFG).

The calibrator solves one problem and one only: **at boot the per-lane phase
between this die's RX `count` register (in the peer's recovered RX clock
domain) and the peer's TX `count` register is unknown**, in a [0..15]-cycle
window randomised by async reset deassert + per-deploy routing skew. With
`USE_T3A=0` (sim/ASIC default) it is a pure deserialiser bit-select
(`adj_count = count + io_phase_offset`) plus a 16-bit right-rotate
(`io_bit_slip`); on FPGA `USE_T3A=1` adds a one-shot comma-hunt that slips
`count` itself once after POR. The calibrator drives both phase and slip
through an OR-merge with APB soft-strap regs into the per-lane PHY inputs,
and decides per-lane when "lock" has been seen long enough to latch.

The current calibrator is broken in a specific, reproduced way:
**independent searches on M and S converge on different per-lane (slip,
phase) tuples** (Agent D dump: M=(0,0) S=(1,1) on all 8 lanes), with
M's TX framed under M's tuple and S's RX deserialised under S's tuple. M→S
data is misaligned; S→M happens to work because (0,0)/(1,1) lands inside
S→M's eye. The new calibrator must produce **compatible cross-die tuples**,
not "best score" per side.

---

## 2. Block-level architecture

```
                  MASTER DIE                                                              SLAVE DIE
   ┌───────────────────────────────────────────────────┐                  ┌────────────────────────────────────────────────────┐
   │ apb_clk    hclk    io_clk(hsclk)   pad_clk_tx     │  fwded clock     │  pad_clk_rx  w_cnt_clk   w_lnk_clk  hclk  apb_clk  │
   │                                                   │  ─────────────►  │                                                    │
   │  ┌──APB Region 8 regs─┐                           │                  │                                                    │
   │  │ swi_recal_r        │                           │   8 data pads    │                                                    │
   │  │ swi_training_mode_r│   ┌────────────────────┐  │  ─────────────►  │  ┌────────────────────┐                            │
   │  │ swi_bit_slip_lo_r  │   │  Wlink LL TX       │  │                  │  │ WavD2DGpio (RX)    │                            │
   │  │ swi_phase_offset_r │   │   (128b/16b/lane)  │  │                  │  │  ┌──gpiorx_N──────┐│                            │
   │  └─────────┬──────────┘   └─────────┬──────────┘  │                  │  │  │ pad → shifter ││  ◄─── pad_clk_rx           │
   │            │OR-merge                │             │                  │  │  │ count++ /16    ││                            │
   │            ▼                        ▼             │                  │  │  │ adj_count =    ││                            │
   │  cal_bit_slip_w ──────► swi_bit_slip_w[23:0]      │                  │  │  │   count+phase  ││                            │
   │  cal_phase_offset_w ──► swi_phase_offset_w[31:0]──┼─────────────┐    │  │  │ link_data_pad  ││                            │
   │  cal_training_mode_w ─► swi_training_mode_w ──────┼──┐          │    │  │  │ ~adj_count[3]→ ││                            │
   │            ▲                                      │  │          │    │  │  │   link_data_reg││                            │
   │            │                                      │  │          ▼    │  │  │ {reg,reg}      ││                            │
   │  ┌─────────┴───────────┐                          │  │   ┌─────────┐ │  │  │   [slip+:16]   ││                            │
   │  │ tidelink_phy_align  │ ◄─ lane_locked[7:0] ─────┼──┼───┤ idelay  │ │  │  └─→ link_data[15:0]│                           │
   │  │   _calibrator       │      (lane_checker)      │  │   │ (FPGA)  │ │  └────────┬───────────┘                            │
   │  │ FSM: IDLE→ARM→PROBE │ ◄─ role_locked ──────────┤  │   └────┬────┘ │           │ x8 lanes packed                        │
   │  │  →SWEEP→FINISH→HOLD │ ◄─ swi_recal (swreset) ──┤  │        │      │           ▼                                        │
   │  │  →DONE / CANCEL     │                          │  │        ▼      │  ┌──────────────────┐                              │
   │  └─────────┬───────────┘                          │  │   per-lane    │  │ Wlink LL RX      │                              │
   │            │                                      │  │   sub-tap     │  └──────┬───────────┘                              │
   │            │ phy_link_rx_rx_link_data_w           │  │   delay       │         │                                          │
   │            │ phy_link_rx_rx_link_clk_w (recovered)│  │               │         │                                          │
   │            ▼                                      │  │               │         ▼                                          │
   │  ┌────────────────────┐                           │  │               │  ┌──────────────────┐                              │
   │  │ tidelink_lane      │ ──► lane_locked_w[7:0]    │  │               │  │ FCSM / FC adapter│                              │
   │  │   _checker (×8)    │                           │  │               │  └──────────────────┘                              │
   │  └────────────────────┘                           │  │               │                                                    │
   └───────────────────────────────────────────────────┘                  └────────────────────────────────────────────────────┘

   M TX:  Wlink-LL[128b] → 8×16b per-lane → WavD2DGpioTx (count++ mod 16, /16 word clk, count==4'hf bit) → pad_tx[7:0] + pad_clk_tx
   S RX:  pad_rx[7:0] + pad_clk_rx → (IDELAY/BUFG) → WavD2DGpioRx (w_cnt_clk++ count, adj_count=count+phase, /16 word clk) →
          {link_data_reg,link_data_reg}[slip+:16] → 16b/lane → 128b → Wlink-LL
```

Clock domains:

* `apb_clk` — config writes; the calibrator runs here in principle but is
  ACTUALLY clocked from the **recovered RX clock** (see §4 / §6).
* `hclk` / `app_clk` — application interconnect.
* `io_hsclk` / `io_clk` — local TX bit rate. ~100 MHz on v1 ASIC (per
  `project_tidelink_v1_asic_target` memory); 25 MHz on Pynq-Z2 FPGA.
* `io_pad_clk_tx` = peer's `gpiotx_0_io_pad_clk` = `~count[3]` divided word
  clock derived from the local TX serialiser.
* `io_pad_clk_rx` = the peer's `io_pad_clk_tx` arriving over the cable.
  On FPGA (`USE_CLKBUF=1`) it's BUFG'd into `w_cnt_clk`. The per-lane
  `WavD2DGpioRx` then derives `w_lnk_clk = ~adj_count[3]` (which depends on
  the calibrator's `phase_offset`!).
* `phy_link_rx_rx_link_clk_w` — `gpiorx_0.io_link_clk` = the /16 RX word
  clock. **This is the clock the calibrator and lane checker run on.**

TX path (per lane): `io_link_data[15:0]` → `_link_data_eff` mux (training
pattern or live data, gated by per-lane `io_training_mode_q` at
`count==4'hf`, `WavD2DGpioTx.v:128-141`) → 16:1 bit MUX selected by `count`
→ `io_pad`. `io_pad_clk = ~count[3]` (`WavD2DGpioTx.v:192-202` via
WavClockMux).

RX path (per lane): `io_pad` sampled into `realign_shifter` (T3A only) on
`w_cnt_clk`; into `link_data_pad_clk[adj_count]` at every cycle (this is the
bit-position write); on `w_lnk_clk` edges the 16-bit `link_data_pad_clk` is
re-timed into `link_data_reg`; the 16-bit `io_link_data` is then
`{link_data_reg, link_data_reg}[io_bit_slip +: 16]` — a 16-bit window
right-rotated by the 3-bit slip.

The lane checker reads `io_link_data` for each lane and matches against the
per-lane training byte (period-8). The calibrator scores `lane_locked[7:0]`
(8-bit vector from the checker) over a dwell window per (slip,phase) point.

---

## 3. Per-module reference

### 3.1 `WavD2DGpio.v` (per-side PHY wrapper)

**Path (sim/build):** `src/rtl/local_overrides/WavD2DGpio.v` (1033 lines).
Upstream deps copy: `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v`
(888 lines; **NOT in elaboration**).

**Purpose:** instantiates 8× TX (`WavD2DGpioTx`) and 8× RX (`WavD2DGpioRx`),
threads per-lane training-byte parameter, exposes Region-8 APB straps to TX
mux + clock-gate, OR-merges per-lane phase/slip inputs with the
broadcast-APB soft-strap regs, and hosts the Bug-FC1 post-training hold
extension.

**Key ports (calibrator-relevant):**

| Port | Dir | Width | Domain | Semantics |
|---|---|---|---|---|
| `io_swi_bit_slip_in` | in | 24 | apb→hsclk (no sync) | Per-lane 3-bit slip [3*N+2:3*N]. OR'd with internal `swi_bit_slip` reg → `effective_bit_slip` (line 355). Distributed per-lane to `gpiorx_N.io_bit_slip`. |
| `io_swi_phase_offset_in` | in | 32 | apb→hsclk (no sync) | Per-lane 4-bit phase [4*N+3:4*N]. Per-lane OR with broadcast `swi_phase_offset` reg → `effective_phase_offset` (line 508-515 generate). Distributed to `gpiorx_N.io_phase_offset`. |
| `io_swi_training_mode_in` | in | 1 | apb→hsclk (no sync) | Wrapper-level training trigger. OR'd with internal `swi_training_mode` reg into `input_training_mode_w` (line 417). |
| `io_link_tx_tx_link_data[127:0]` | in | 128 | io_link_tx_tx_link_clk (= ~count[3] of gpiotx_0) | TX side parallel data, 16 b/lane. |
| `io_link_rx_rx_link_data[127:0]` | out | 128 | io_link_rx_rx_link_clk (= gpiorx_0.io_link_clk) | RX side parallel data, 16 b/lane. |
| `io_pad_tx_N`, `io_pad_rx_N` | bidir-by-direction | 1 ea | pad | The 8 data lanes. |
| `io_pad_clk_tx`, `io_pad_clk_rx` | dir | 1 | pad | Forwarded clock pair (lane-0 derived). |
| `io_hsclk` | in | 1 | hsclk | Local TX bit rate. |
| `io_por_reset` | in | 1 | async | Wrapper POR; fans through `WavResetSync` to all lanes. |

**Parameters:**

| Name | Default | Effect |
|---|---|---|
| `USE_CLKBUF` | `1'b0` | Threads into `WavD2DGpioRx.USE_CLKBUF`. FPGA wrapper sets 1. |
| `USE_T3A` | `1'b0` | Threads into `WavD2DGpioRx.USE_T3A`. FPGA wrapper sets 1. |
| `POST_TRAIN_HOLD_CYCLES` | `7'd64` | Bug-FC1 post-training hold; see below. |

**Internal state:**

* `swi_phase_offset[3:0]` — broadcast APB-driven global phase (legacy single-phase path, written via PHY Control reg bits[20:17]). Default 0.
* `swi_bit_slip[23:0]`, `swi_training_mode` — sim-only soft-strap registers; default 0; cocotb can force.
* `precount[7:0]` / `postcount[7:0]` — pre/post-training count window for TX `io_clk_en` gating.
* `mux_align_count_r[3:0]` / `effective_training_mode_tx_q` — inert wrapper-level word-align counter retained for ILA continuity (line 481-495). tdif-02 superseded by per-lane tdif-03.
* `post_train_hold_ctr_r[6:0]` — Bug-FC1 post-training hold counter (line 418), clocked on `io_link_tx_tx_link_clk` (= /16 word clock of gpiotx_0). Loads `POST_TRAIN_HOLD_CYCLES` while `input_training_mode_w=1`; counts down by 1 per word clock once training drops.

**Behaviour:**

1. After reset, all 8 lanes' TX and RX `WavResetSync` flops carry POR; both pad clocks come up. Per-lane `WavD2DGpioTx.count` resets to `4'hf` (line 205 of `WavD2DGpioTx.v`); per-lane `WavD2DGpioRx.count` resets to `4'hf` (line 475 of override RX, line 488 in passthrough branch).
2. SW or autoneg writes `swi_training_mode_r=1` and/or calibrator asserts `cal_training_mode_w=1` → `swi_training_mode_w=1` → `io_swi_training_mode_in=1` → `input_training_mode_w=1` → BOTH:
   * `effective_training_mode_tx_raw` (line 438) — IMMEDIATE.
   * `effective_training_mode_rx` (line 439) — same as raw plus the held `post_train_hold_ctr_r != 0` window.
3. Per-lane TX `gpiotx_N.io_training_mode` is fed `effective_training_mode_tx_raw` (lines 525, 540, …, 630). Per-lane TX `gpiotx_N.io_clk_en` is fed `... | effective_training_mode` (line 782, 789, …, 831). **Note the asymmetry:** the mux source uses the raw (un-held) signal; the clock-gate uses the held signal. This is Agent B's Suspect A.
4. RX path is per-lane independent. The calibrator-sourced `effective_phase_offset` and `effective_bit_slip` arrive combinatorially at each `gpiorx_N.io_phase_offset` / `gpiorx_N.io_bit_slip`.

**Clock-domain crossings:**

* `io_swi_*_in` (apb_clk) → wrapper internal (no sync) → per-lane RX (`w_cnt_clk` = peer's pad clock). **No CDC synchroniser** — see PHY Hole #4.
* `effective_training_mode_tx_raw` → per-lane TX `io_clk` (= hsclk). No sync — relies on per-lane re-sampling at `count==4'hf` in the TX override.
* `post_train_hold_ctr_r` is clocked on `io_link_tx_tx_link_clk` which is `~count[3]` of gpiotx_0 — a derived clock running 16× slower than hsclk.

**Diff vs deps (`deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v`):**
+145 lines. Adds:
* Bug-FC1 post-train hold extension (lines 396-441).
* `swi_phase_offset` APB reg + per-lane OR-merge (lines 305, 502-515).
* `effective_training_mode` split into `_tx_raw` (un-held) and `_rx` (held).
* Per-lane TX `io_training_mode` pin fed `_tx_raw`; per-lane `io_clk_en`
  fed the held signal.
* Inert `mux_align_count_r` retained for ILA continuity.

**Known issues:**

* **Asymmetric mux-vs-clkgate hold (Agent B Suspect A).** `io_training_mode` mux source = raw; `io_clk_en` = held. The two signals are re-sampled at `count==4'hf` inside the TX, but their source values diverge for 64 link-word cycles. Today this manifests as a 1024-hsclk window where the TX serialiser is clocked but emitting live FC data while the peer's RX has just locked on training.
* **No CDC sync on `io_swi_*_in`.** Combinational into the RX deserialiser; a glitch on `bit_slip` during a `count[3]` edge can cause a 1-cycle wrong-byte output (PHY Audit Hole #4).
* **Per-lane phase OR-merge masks zero.** A lane the calibrator drives `phase=0` AND the broadcast `swi_phase_offset_r=0` for both result in 0 — i.e. there's no way to TELL them apart at the PHY. (Concrete consequence: APB-driven SW override "force zero" cannot exclude the calibrator's contribution because they OR.)

### 3.2 `WavD2DGpioTx.v` (per-lane TX serialiser)

**Path:** `src/rtl/local_overrides/WavD2DGpioTx.v` (275 lines).
Upstream: `deps/.../WavD2DGpioTx.v` (174 lines; not elaborated).

**Purpose:** serialise a 16-bit `io_link_data` onto one `io_pad` bit at
`io_clk` rate; gate a per-lane training-pattern mux; emit a per-lane
`io_pad_clk = ~count[3]` divided word clock; emit `io_link_clk = ~count[3]`
back to the wrapper (lane 0's `io_link_clk` is the wrapper's
`io_link_tx_tx_link_clk`).

**Key ports:**

| Port | Dir | Width | Domain | Semantics |
|---|---|---|---|---|
| `io_clk` | in | 1 | hsclk | Bit-rate clock. |
| `io_clk_en` | in | 1 | hsclk (re-sampled at `count==4'hf`) | When de-asserted, the gated clock to the serialiser stops. The wrapper drives this from `io_link_tx_tx_en | postcount!=0 | effective_training_mode` (held). |
| `io_link_data[15:0]` | in | 16 | io_link_clk (= ~count[3]) | 16-bit word per lane. |
| `io_training_mode` | in | 1 | io_clk (re-sampled at `count==4'hf` by `io_training_mode_q`) | When 1, the 16-bit word is replaced with `{io_training_pattern, io_training_pattern}`. |
| `io_training_pattern[7:0]` | in (param-like) | 8 | hard-wired constant per lane | Lane-N byte: 0xA3/0xB5/0xC9/0xD3/0x65/0x4B/0x59/0x2D. |
| `io_link_clk` | out | 1 | clk | `~count[3]`, the /16 word clock. |
| `io_pad` | out | 1 | pad | Serialised bit. |
| `io_pad_clk` | out | 1 | clk | `~count[3]` via `WavClockGate` (gated by `clk_en_qual`). |

**Parameters:**

| Name | Default | Effect |
|---|---|---|
| `WORD_ALIGN_MUX` | `1'b1` | When 1 the mux source is `io_training_mode_q` (latched at `count==4'hf`); when 0 the mux is fed `io_training_mode` directly (bit-exact upstream behaviour). |

**Internal state:**

* `count[3:0]` — mod-16 free-running counter on `io_clk`. Reset value `4'hf`.
* `clk_en_qual` — re-sampled `io_clk_en` at `&count_in` (= `count==4'hf`).
* `io_training_mode_q` — tdif-03 latch of `io_training_mode` at `count==4'hf`.

**Behaviour after reset:**

1. `count <= 4'hf`. The serialiser is held clock-gated until `clk_en_qual` rises.
2. Once `io_clk_en=1`, `clk_en_qual` rises at the next `count==4'hf` boundary, the gated `io_pad_clk` starts ticking, and `count` advances 0→F repeatedly.
3. On `count==4'hf`, `io_training_mode_q` samples `io_training_mode`. The mux `_link_data_eff` selects `{io_training_pattern,io_training_pattern}` when `io_training_mode_q=1`, else `io_link_data`.
4. `io_pad <= _link_data_eff[count]` (line 192 `4'hf == count ? tx_pad_array_15 : _GEN_14`).

**Clock-domain crossings:**

* `io_training_mode` is in the wrapper's `effective_training_mode_tx_raw` domain (no sync, derived from apb_clk). Re-sampled at `count==4'hf` of THIS lane's `io_clk` — solves the timing of the mux flip; does NOT solve metastability if the source happens to glitch.
* `io_clk_en` from wrapper — re-sampled at `&count_in`.

**Diff vs deps:** +125 lines. Adds `WORD_ALIGN_MUX` parameter + `io_training_mode_q` register + mux source select. With `WORD_ALIGN_MUX=0` it is byte-identical to upstream.

**Known issues:**

* The training MUX flip is now per-lane word-aligned (tdif-03). The
  symmetric FC→training flip uses the same latch, so it is also word-aligned.
* `count[3:0]` reset value `4'hf` is **non-deterministic across lanes
  relative to the peer's RX `count`** by 0..15 cycles after async POR
  deassert (PHY Audit Hole #5).

### 3.3 `WavD2DGpioRx.v` (per-lane RX deserialiser)

**Path:** `src/rtl/local_overrides/WavD2DGpioRx.v` (567 lines).
Upstream: `deps/.../WavD2DGpioRx.v` (463 lines; not elaborated).

**Purpose:** sample `io_pad` on the recovered RX clock, reassemble into a
16-bit word, apply `io_phase_offset` (bit-position select within the 16-bit
window AND derivation of the /16 word clock), apply `io_bit_slip` (post-
capture right-rotation), emit `io_link_data[15:0]` aligned to `io_link_clk`.

**Key ports:**

| Port | Dir | Width | Domain | Semantics |
|---|---|---|---|---|
| `io_pad_clk` | in | 1 | pad | Forwarded RX clock from peer. |
| `io_pad` | in | 1 | pad | Serial bit from peer. |
| `io_phase_offset[3:0]` | in | 4 | apb→w_cnt_clk (no sync) | `adj_count = count + io_phase_offset` (line 180). Drives BOTH (a) the bit-position write at `link_data_pad_clk[adj_count]`, AND (b) the divided word clock `w_lnk_clk = ~adj_count[3]` (line 274 + gen block 289-308). |
| `io_bit_slip[2:0]` | in | 3 | apb→io_link_clk (no sync) | Right-rotation of the 16-bit window: `io_link_data = {link_data_reg, link_data_reg}[bit_slip +: 16]` (line 254). |
| `io_link_clk` | out | 1 | clk | `~adj_count[3]` (BUFG'd if USE_CLKBUF=1). |
| `io_link_data[15:0]` | out | 16 | io_link_clk | Deserialised + rotated word. |
| `io_por_reset` | in | 1 | async | Async reset; the ONLY path that re-arms T3A and `count`. |

**Parameters:**

| Name | Default | Effect |
|---|---|---|
| `USE_CLKBUF` | `1'b0` | FPGA-only BUFG on `io_pad_clk` (→ `w_cnt_clk`, `w_pad_clk`) AND on `~adj_count[3]` (→ `w_lnk_clk`). |
| `USE_T3A` | `1'b0` | Enable per-lane comma-hunt FSM with shifter, `S_SETTLE`→`S_HUNT`→`S_LOCKED`. |
| `TRAINING_BYTE[7:0]` | `8'h00` | Per-instance T3A reference byte. `WavD2DGpio` overrides per-lane: 0xA3..0x2D. |
| `T3A_CONTINUOUS` | `1'b0` | tdif-06 bounded re-arm (DWELL_MAX=63) — disabled by default. |

**Internal state:**

* `count[3:0]` — `w_cnt_clk` mod-16 counter; reset `4'hf`. T3A slips it once via `count <= count + 1 - slip_amt` on the `do_slip` pulse.
* `link_data_pad_clk[15:0]` — bit-position write buffer; one bit updated per cycle at index `adj_count`. Clocked on `w_pad_clk`.
* `link_data_reg[15:0]` — re-timed into the `~adj_count[3]` domain (`io_link_clk`).
* T3A (gated by USE_T3A): `realign_shifter[7:0]`, `align_state[1:0]`, `settle_cnt[6:0]`, `hunt_cnt[9:0]`, `slip_amt[2:0]`, `do_slip`, `dwell_cnt[5:0]`.

**T3A FSM (USE_T3A=1):**

```
   async POR
       │
       ▼
   ┌─S_SETTLE──┐ settle_cnt < 64
   │           │ (ride out IBUF + recovered-clock startup)
   └───────────┘
       │ settle_cnt == 63
       ▼
   ┌─S_HUNT────┐ realign_shifter ≠ any rotation of TRAINING_BYTE,
   │           │ hunt_cnt < 1023 → keep sampling
   └───────────┘
       │ match_any  OR  hunt_cnt == 1023 (timeout, slip=0)
       │ → slip_amt latch, do_slip pulse next cycle
       ▼
   ┌─S_LOCKED──┐ terminal under T3A_CONTINUOUS=0
   │           │ under T3A_CONTINUOUS=1: stay DWELL_MAX (=63) then →S_HUNT
   └───────────┘
       │ ONLY async POR exits (no swi_swreset → count → re-arm path)
       ▼
   (back to async POR)
```

**Behaviour after reset:** `count <= 4'hf`. `link_data_pad_clk <= 0`,
`link_data_reg <= 0`. T3A (if enabled) starts in S_SETTLE.

**Output mapping:**
* `link_data_pad_clk[adj_count] <= io_pad` (one bit per cycle).
* `link_data_reg <= link_data_pad_clk` on `io_link_clk` edges (= when `~adj_count[3]` rises).
* `io_link_data = {link_data_reg, link_data_reg}[io_bit_slip +: 16]`.

**Clock-domain crossings:**
* `io_phase_offset`, `io_bit_slip` are apb_clk-domain at source; arrive **combinationally** into the w_cnt_clk / io_link_clk domains. No CDC sync.
* `io_phase_offset` changing also produces a glitch on the derived `w_lnk_clk = ~adj_count[3]`. The BUFG (USE_CLKBUF=1) often absorbs it; not guaranteed.

**Known issues:**

* **PHY Audit Hole #1** — `io_train_rearm` input is declared in the override (line ~395) AND has a 2FF sync structure ready for it, but **no parent module drives it**, AND the override gates the whole branch behind `T3A_REARM_ON_TRAIN` (default 0). Result: the mechanism is inert.
* **PHY Audit Hole #2** — `S_LOCKED` is sticky in the default T3A_CONTINUOUS=0 path; only async POR re-arms.
* **PHY Audit Hole #5** — `count` initial phase is non-deterministic across master/slave; T3A corrects this once via slip; after any subsequent recal the `count` is left wherever it was.

**Diff vs deps:** +105 lines. Adds T3A FSM, `USE_CLKBUF` BUFG branch, `T3A_CONTINUOUS` bounded re-arm. With both params 0 the RX is bit-exact upstream.

### 3.4 `tidelink_phy_align_calibrator.sv`

**Path:** `src/rtl/tidelink_phy_align_calibrator.sv` (881 lines).

See §4 for the full FSM specification. Brief summary:

* Drives `bit_slip[23:0]` (8 × 3b), `phase_offset[31:0]` (8 × 4b), `training_mode`, `calibration_done`, `lane_fault[7:0]`, `state[3:0]`.
* Consumes `role_locked`, `swreset` (`swi_recal`), `lane_locked[7:0]`.
* Clock: `phy_link_rx_rx_link_clk_w` (= `gpiorx_0.io_link_clk`, which is the LOCAL RX's recovered word clock = peer's TX clock /16).
* Reset: `~poresetn`.

Parameters: `DWELL_CYCLES=64`, `LOCK_THRESH=16`, `NUM_LANES=8` (hard-checked), `MAX_RESWEEPS=0`, `HOLD_CYCLES=8*128*64=65536`, `EARLY_EXIT_ON_ALL_LOCKED=1'b0`.

Currently includes Agent F's `S_PROBE=4'd7` state biasing to (slip=0, phase=0) before the full sweep.

### 3.5 `tidelink_lane_checker.sv`

**Path:** `src/rtl/tidelink_lane_checker.sv` (90 lines).

**Purpose:** 8 instances of `tidelink_lane_checker_single`, one per RX lane.
Each watches the 16-bit deserialised lane word; declares `locked` when it
sees `LOCK_THRESH` (=16) consecutive cycles of `word_in == {P, P}` where
`P` is the lane's training byte.

**Per-lane behaviour:**
* `match_count` saturates at 5'd31. Locked at `match_count >= LOCK_THRESH`.
* On mismatch, `match_count <= 0` (single-cycle).
* Patterns (line 72-75): {A3, B5, C9, D3, 65, 4B, 59, 2D}. **Period-8 chosen so no rotation by 1..7 of any pattern equals itself** — guarantees exactly one `bit_slip` value [0..7] matches per lane (i.e. there is no slip-aliasing in the training pattern).

**Clock / reset:** clocked on `phy_link_rx_rx_link_clk_w` (= calibrator clock). **Reset: `~role_locked`** at the instantiation site (`axi_chiplet_controller.sv:1307`). I.e. the checker is held in reset until role lock is asserted. This is significant: the calibrator's `role_locked_rise` is the same edge that clears the checker reset.

**Known issues:**

* `lane_locked=1` reflects training pattern only. Once training drops, `word_in` stops being `{P,P}`, `match_count` resets, `lane_locked` deasserts. The (slip,phase) values latched while `lane_locked=1` are then **assumed to remain valid for real FC data** — Agent K calls out that this assumption is true in sim's bit-exact PHY and on healthy silicon but is suspect at PVT extremes.
* Reset on `~role_locked` means a `role_locked` glitch low resets the checker mid-sweep; the calibrator does not reset on the same condition.

### 3.6 `tidelink_idelay_rx.sv`

**Path:** `src/rtl/tidelink_idelay_rx.sv` (212 lines).

**Purpose:** parameter-gated per-lane IDELAYE2 (Xilinx 7-series) delay
chain on `pad_rx[N]`. Sim/ASIC default `USE_IDELAY=0` is bit-exact
passthrough (no Xilinx primitive elaborated). FPGA wrapper threads
`USE_IDELAY=1` via component.xml.

**Ports:**

| Port | Dir | Width | Notes |
|---|---|---|---|
| `idelay_ref_clk` | in | 1 | 200 MHz IDELAYCTRL reference. |
| `idelay_rst` | in | 1 | Active-high IDELAYCTRL reset. |
| `phase_tap_i[31:0]` | in | 32 | SAME per-lane phase the calibrator drives into `WavD2DGpio.io_swi_phase_offset_in`. |
| `pad_rx_i[7:0]` | in | 8 | Raw pad inputs. |
| `pad_rx_o[7:0]` | out | 8 | Delayed pads → `WavD2DGpio.io_pad_rx_*`. |

**Tap mapping:** `lane_tap = {lane_phase, 1'b0}` — 4-bit phase × 2 maps into the IDELAYE2 5-bit tap range 0..30 (line 151). 1:1 monotone. ~78 ps/tap × 2 = ~156 ps/calibrator-step at 200 MHz REFCLK.

**Behaviour:** `IDELAYE2 #(.IDELAY_TYPE("VAR_LOAD"), .LD(1'b1), .IDATAIN(pad_rx[N]))` — tap continuously tracks `phase_tap_i[4N+:4]` (CNTVALUEIN, with LD held high). One shared `IDELAYCTRL` per bank.

**Diff vs deps / non-issues:** none (this is a SoC Labs invention; not in deps).

### 3.7 `tidelink_rxclk_buf.sv`

**Path:** `src/rtl/tidelink_rxclk_buf.sv` (94 lines).

**Purpose:** FPGA-only BUFG on `pad_clk_rx` at the IP boundary. Sim/ASIC
default `USE_CLKBUF=0` is bit-exact passthrough. Threaded into the per-lane
`WavD2DGpioRx.USE_CLKBUF` for the in-PHY BUFG path too.

Trivial: one parameter, one BUFG. No internal state. No CDC.

### 3.8 `tidelink_phy_align_regs.sv`

**Path:** `src/rtl/tidelink_phy_align_regs.sv` (171 lines).

**IMPORTANT:** despite the filename, this module is **no longer the
calibrator status register file**. The §9 PHY-align soft-straps now live in
Region 8 of the chiplet-controller APB block. This shim was repurposed
(2026-05-25) as the FCSM credit-handshake debug observability block:
`CR_CRACK_COUNTS` / `FCSM_STICKY` / `CMD_FCSM_RETRY` at local APB offsets
+0x28 / +0x30 / +0x38 inside the 0x120-0x13F window. It does NOT touch the
calibrator's outputs or status today.

Calibrator visibility is via **Region 8** (`axi_chiplet_controller.sv:1300`
onwards) of the chiplet-controller APB block — search for `SWI_LANE_STATUS`
in that file. The relevant Region-8 registers:

* `SWI_CTRL` (slot 0): bit[0]=`swi_training_mode_r`, bit[1]=`swi_recal_r`.
* `SWI_BIT_SLIP_LO` (slot 1): 24-bit per-lane bit_slip.
* `SWI_PHASE_OFFSET` (slot 6): 32-bit per-lane phase.
* `SWI_LANE_STATUS` (a status slot): packs `cal_state_w[3:0]`,
  `cal_lane_fault_w[7:0]`, `sync_cal_done`, plus the lane_locked replicas.

### 3.9 Chiplet-controller glue

**Path:** `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`
(out-of-scope deps file; not modified by this project).

**Key blocks for the PHY:**

* `wlink_por_reset = ~poresetn | ~role_locked` (line 751). Drives `Wlink.por_reset` (line 1441) — used to hold the WLINK stack in reset until role-lock.
* `tidelink_lane_checker u_lane_checker` (line 1305) with `clk = phy_link_rx_rx_link_clk_w` and `rst = ~role_locked` (line 1307).
* `autocal_enable_w = AUTOCAL_ENABLE | autocal_force_enable_q` (line 1324). `calibrator_role_locked = role_locked & autocal_enable_w` (line 1325).
* `tidelink_phy_align_calibrator u_calibrator` (line 1327) with `clk=phy_link_rx_rx_link_clk_w`, `rst=~poresetn`, `role_locked=calibrator_role_locked`, `swreset=swi_recal_r`.
* **OR-merge (the critical lines)** (1365-1372):
  ```
  swi_bit_slip_w      = cal_bit_slip_w      | swi_bit_slip_lo_r;
  swi_phase_offset_w  = cal_phase_offset_w  | swi_phase_offset_r;
  swi_training_mode_w = cal_training_mode_w | swi_training_mode_r;
  ```
* `tidelink_idelay_rx u_idelay_rx` (line 1392) with `phase_tap_i=swi_phase_offset_w` — same source as Wlink's `swi_phase_offset_in`.
* `tidelink_rxclk_buf u_rxclk_buf` (line 1425) with `clk_i=pad_clk_rx`, `clk_o=pad_clk_rx_buf` — the recovered RX clock that feeds the per-lane RX deserialisers via the Wlink instance.
* `Wlink u_wlink` (line 1435) with `.swi_bit_slip_in(swi_bit_slip_w)`,
  `.swi_phase_offset_in(swi_phase_offset_w)`, `.swi_training_mode_in(swi_training_mode_w)` (lines 1609-1613).
* `apb_reset` (Wlink) is sourced from `apb_clk` reset; `por_reset = wlink_por_reset` (held by `~role_locked`).

**Critical OR-merge semantic:** the calibrator nibbles ARE passed straight through to Wlink with no priority and no mask. A SW write of "set phase[2] = 0xA" cannot DECREMENT the calibrator-driven value — it can only OR more bits in. To "neutralise" the calibrator from APB you'd need to either disable AUTOCAL_ENABLE before role_lock OR drive `apb_bit_slip_override` + `apb_override_enable` on the calibrator (line 1347/1348 — both tied off to zero in current RTL). This is the structural reason Agent E's force-bisect could only test calibrator outputs by cocotb `Force` on the internal handles.

### 3.10 `tidelink_autoneg.sv` (briefly)

**Path:** `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` (out of scope).

Establishes `role_locked` via an I²C handshake. Without `role_locked=1`,
`calibrator_role_locked=0` and the calibrator stays in `S_IDLE`. So the
calibrator's first sweep is triggered by `role_locked` rising, NOT by POR.

Within `tidelink_autoneg.sv` the master-only `ST_TRAIN_EXIT` sequence
writes the peer (slave) `SWI_TRAINING_MODE := 0` over I²C, then on
peer-ACK pulses `local_train_clr_pulse_r` to clear its own
`swi_training_mode_r`. This creates an asymmetric window where master is
still asserting training while slave has dropped (Agent A Suspect S2). The
calibrator-driven `cal_training_mode_w` is unaffected by this autoneg path
— the autoneg I²C only manipulates the SOFT-STRAP regs that OR with the
calibrator outputs.

**Swi_recal path:** Region-8 APB writes set `swi_recal_r=1`, which feeds
`u_calibrator.swreset`. The calibrator catches `swreset_fall` as a re-trigger
while `role_locked` is still high (line 301 of the calibrator).

---

## 4. The calibrator FSM in detail

### 4.1 State diagram

```
                     ┌──── async rst ────┐
                     ▼                    │
                  S_IDLE  ◄────────────────┘
                     │
       trigger_now=role_locked_rise OR (swreset_fall & role_locked)
                     │
                     ▼
                  S_ARM ───── swreset=1 ──► S_CANCEL ──!swreset──► S_ARM
                     │                              ▲                 │
                     │                              └─── swreset=1 ───┘
                     ▼  (always, after 1 cycle)
                  S_PROBE
                  (dwell DWELL_CYCLES at slip=0,phase=0)
                     │
              ┌──────┼───────────────┐
              │      │               │
       swreset│  dwell_expire    dwell_expire
              │  & probe_all_locked  & ~probe_all_locked
              ▼      │               │
          S_CANCEL   ▼               ▼
                  S_FINISH        S_SWEEP ◄────────┐
                     ▲                 │           │ swreset=0
                     │                 │ dwell_expire & iter_at_end
                     │                 │           │
                     │                 ▼           │
                     │              S_FINISH       │
                     │                 │           │
                     │   sweep_success │           │
                     │  & !tb_force ──►│           │
                     │                 ▼           │
                     │              S_HOLD ───── swreset=1 ──► S_CANCEL
                     │                 │
                     │  hold_ctr>=HOLD_MAX OR !role_locked
                     │                 │
                     │                 ▼
                     │              S_DONE ── trigger_now ──► S_ARM
                     │                 ▲
                     │                 │
                     └── sweep_success & tb_early_exit_force_q
                         OR retry_exhausted
                         OR (!role_locked) ─────────────────────┘

                     S_FINISH next-state choices (line 481-509):
                       sweep_success & !tb_force → S_HOLD     (silicon path, dwell HOLD_CYCLES)
                       sweep_success &  tb_force → S_DONE     (sim bypass)
                       retry_exhausted           → S_DONE
                       role_locked               → S_ARM      (T3 auto re-sweep)
                       (default)                 → S_DONE
```

State encoding (4-bit): `S_IDLE=0`, `S_ARM=1`, `S_SWEEP=2`, `S_FINISH=3`,
`S_DONE=4`, `S_CANCEL=5`, `S_HOLD=6`, `S_PROBE=7`. Codes 8..15 are reserved
(treated as `default → S_IDLE`).

### 4.2 Sweep iteration scheme

Single shared iterator (`sweep_slip[2:0]`, `sweep_phase[3:0]`). All 8 lanes
walk in lockstep (the sweep is fully parallel — each lane has its own
`lane_score` accumulator). Order is **phase-outer, slip-inner** (line 99-107
header comment + the actual increment block at 737-802):

```
for sweep_phase in 0..15:
    for sweep_slip in 0..7:
        for dwell_ctr in 0..DWELL_CYCLES-1:    # DWELL_CYCLES default 64
            (each lane) lane_score[i] += lane_locked[i] (saturating at 6'h3F)
        # At dwell_expire (dwell_ctr == 63):
        #   for each lane: if (lane_score[i] > best_score[i]):
        #       best_*[i] <= (sweep_slip, sweep_phase, lane_score[i])
        #   lane_score[i] <= 0
        #   advance iterator
```

Total walk = 16 × 8 × 64 = 8192 cycles in the calibrator clock domain
(= `phy_link_rx_rx_link_clk_w` ≈ peer's TX pad clock / 16). At a 25 MHz
FPGA link rate that's ~33 µs.

`DWELL_CYCLES=64` is sized to be 4 × `LOCK_THRESH=16` (lane checker
threshold). The 6-bit `lane_score` saturates at 63 — i.e. any (slip,phase)
that produces an uninterrupted 64-cycle locked run saturates at 63 in score
(actually saturates earlier at 63 if continuously locked).

`dwell_expire = (dwell_ctr == DWELL_MAX)`. `iter_at_end = (sweep_slip==7) && (sweep_phase==15)`. `sweep_exhausted = S_SWEEP && dwell_expire && iter_at_end` — single strobe at the end of the 8192-cycle walk.

### 4.3 Score function

Per-lane `lane_score[i]` is a 6-bit **run-length** of consecutive
`lane_locked[i]=1` cycles within the CURRENT dwell window. It is RESET on
any de-assert (line 689 in S_SWEEP, line 629 in S_PROBE) and SATURATES at
`LANE_SCORE_MAX = 6'h3F`. On `dwell_expire` it is captured to `best_score`
(if larger), then reset for the next window (line 730).

`lane_locked[i]` comes directly from `tidelink_lane_checker.sv:49`:
`locked = (match_count >= LOCK_THRESH)` where `match_count` is the
training-pattern's consecutive-match counter saturating at 31, threshold 16.

So `lane_score=63` means "this lane was locked for at least 64 consecutive
cycles". `lane_score >= lock_thresh_6b` (= 16) means "this lane was locked
for at least 16 consecutive cycles". Sub-16 scores never get the latch (see
4.4).

### 4.4 Best-of-sweep latch

Two latching mechanisms; they interact carefully via `lane_done[i]`.

**S_PROBE latch (Agent F):** at the S_PROBE dwell_expire, for each lane
whose `lane_score[i] >= lock_thresh_6b`:
* `slip[i] <= 0`, `phase[i] <= 0`, `lane_done[i] <= 1`
* `best_score[i] <= lock_thresh_6b`, `best_slip[i] <= 0`, `best_phase[i] <= 0`

Lanes that did NOT lock at (0,0) leave `lane_done[i] = 0` and fall through
to S_SWEEP.

**S_SWEEP score capture (line 721-728):**
```systemverilog
if (!lane_done[i]) begin
    if (lane_score[i] > best_score[i]) begin
        best_score[i] <= lane_score[i];
        best_slip[i]  <= sweep_slip;
        best_phase[i] <= sweep_phase;
    end
end
```
Critically **strict greater-than**. This means the FIRST point with a given
score wins; ties never displace. Combined with the phase-outer, slip-inner
order this means (slip=0, phase=0) wins any tie. **EXCEPT** when the score
itself saturates at 63 at every locking point and any noise bump on later
points overshoots earlier — see Agent A's S1 race-to-tie diagnosis. Agent K
notes that Agent F's S_PROBE addresses the (0,0) tuple specifically but
leaves the `>` comparator unchanged for lanes that fall through to S_SWEEP
(see §4.9).

**S_SWEEP sweep-exhaustion latch (line 750-796):** at the FINAL dwell
(`sweep_phase==15, sweep_slip==7, dwell_expire`), for each lane with
`!lane_done[i]`:
```
if      (best_score[i] >= lock_thresh_6b) → slip[i] <= best_slip[i],  phase[i] <= best_phase[i]
else if (lane_score[i] >= lock_thresh_6b) → slip[i] <= sweep_slip=7, phase[i] <= sweep_phase=15  (first-lock-at-final fallback)
else                                       → lane_fault_q[i] <= 1
lane_done[i] <= 1
```

The "first-lock-at-final fallback" is the only path where the LIVE iterator
gets latched (and only when `best_score < LOCK_THRESH` AND `lane_score >=
LOCK_THRESH` for the final dwell — i.e. the very first lock was at the very
last point). This guards against the NBA-ordering hazard at the sweep edge.

**Output mapping (line 842-854):**
```systemverilog
for i in 0..7:
    if (lane_done[i]):
        bit_slip_internal[3*i +: 3]     = slip[i]
        phase_offset_internal[4*i +: 4] = phase[i]
    else:
        bit_slip_internal[3*i +: 3]     = sweep_slip      # LIVE iterator!
        phase_offset_internal[4*i +: 4] = sweep_phase
```

**While `lane_done[i]=0`** (i.e. during S_SWEEP for that lane), the **LIVE
iterator** drives the PHY. That means **the local RX deserialiser configuration
changes for every dwell window** until the sweep is over. This is OK for the
calibrator's own scoring because the lane_checker also sees the updated
config and accumulates lane_score against it. But it means the data on the
wire being framed by THIS die's TX uses (training_pattern) gated by the same
training_mode, so the peer's RX also walks its own iterator independently.

### 4.5 Re-arming

Re-trigger sources (line 301):
* `role_locked_rise` — first lock after power-on or after a role drop.
* `swreset_fall & role_locked` — `swi_recal_r` falling edge while role lock holds. SW writes Region 8 `SWI_RECAL` bit[1] = 1 then 0.

Both edges go to `S_ARM` (from `S_IDLE`, `S_DONE`, `S_FINISH`,
`S_HOLD`/`S_CANCEL` via their own paths). `S_ARM` clears `lane_done`,
`lane_fault_q`, `sweep_slip=0`, `sweep_phase=0`, all per-lane state
(`slip[i]`, `phase[i]`, `lane_score[i]`, `best_*[i]`).

`resweep_ctr` survives across the `S_FINISH→S_ARM` T3 auto-retry edge (line
550-555). It is cleared on `trigger_now` (external retrigger). With
`MAX_RESWEEPS=0` it free-runs and `retry_exhausted` stays 0 forever.

### 4.6 S_PROBE current bias fix (Agent F)

`S_PROBE` (state 4'd7) is the recent fix landed in commit `b5f92e8` on
branch `feat/calibrator-bug-fix`. It exists between `S_ARM` and `S_SWEEP`:

* Holds the iterator at (sweep_slip=0, sweep_phase=0) — same as `S_ARM` left them.
* Dwells `DWELL_CYCLES` cycles accumulating `lane_score`.
* At dwell_expire: for each lane that scored ≥ `LOCK_THRESH`, latch (0,0)
  into `slip[i]/phase[i]` AND set `lane_done[i]=1` AND seed `best_* = (0,0,LOCK_THRESH)`.
* If ALL 8 lanes pass, skip the sweep entirely (`probe_all_locked` →
  `S_FINISH`).
* Otherwise fall through to `S_SWEEP` for the non-passing lanes; the
  already-locked lanes' output mux drives (0,0) via the `lane_done[i]` gate.
* During S_SWEEP, the score update branch at lines 679-690 skips lanes with
  `lane_done[i]=1` (keeps score at 0 so they can't promote in the best-of-sweep
  comparator).

What this PRESERVES: any lane that does NOT lock at (0,0) takes the full
128-point best-of-sweep search and the existing comparator (Agent A's S1
race-to-tie is unchanged for those lanes).

What this ABANDONS: the "eye-CENTRE" design intent (§9.9). On silicon where
(0,0) is at the EDGE of the eye but still passes LOCK_THRESH, S_PROBE will
latch (0,0) and never look for a wider eye. Agent K calls this AMBER —
works in sim, may regress on tight-eye silicon.

### 4.7 Output mapping (recap)

`bit_slip_internal[23:0]` and `phase_offset_internal[31:0]` are derived
combinationally from `slip[i]/phase[i]` or `sweep_slip/sweep_phase` per
the `lane_done[i]` gate. The final outputs are taken from these (line
868-869) when `apb_override_enable=0`, or from `apb_bit_slip_override` +
zeros when override=1.

**`training_mode` output (line 870-871):**
```
training_mode = (cur_state==S_ARM) || (cur_state==S_PROBE)
              || (cur_state==S_SWEEP) || (cur_state==S_HOLD)
```
That's a 4-state OR. It is HIGH from `S_ARM` entry through the sweep AND
through `S_HOLD`. It falls 1→0 on `S_FINISH → S_DONE` directly OR on
`S_HOLD → S_DONE` after `HOLD_CYCLES`. **`S_FINISH` itself does NOT assert
training_mode** — so `training_mode` is briefly low during the S_FINISH
cycle while next-state is decided. (Practically a 1-cycle dip; consequence
unclear — possibly absorbed by the per-lane TX `count==4'hf` resampler.)

**`calibration_done` output (line 875):** `(cur_state == S_DONE)`. Sticky
in S_DONE.

### 4.8 The OR-merge to PHY

(See §3.9.) `cal_bit_slip_w`, `cal_phase_offset_w`, `cal_training_mode_w`
OR with the apb_clk soft-strap regs (`swi_bit_slip_lo_r`,
`swi_phase_offset_r`, `swi_training_mode_r`) and feed
`Wlink.swi_bit_slip_in / swi_phase_offset_in / swi_training_mode_in`. From
there Wlink fans out to `WavD2DGpio.io_swi_*_in` and on into the per-lane
RX (`gpiorx_N.io_phase_offset` / `io_bit_slip`) and per-lane TX
(`gpiotx_N.io_training_mode`).

The same `swi_phase_offset_w` is ALSO routed to `tidelink_idelay_rx.phase_tap_i`
(line 1402) — so per-lane IDELAYE2 taps move with the calibrator (on FPGA;
on sim/ASIC the IDELAY block is passthrough).

### 4.9 Failure modes (concrete)

1. **Independent best-of-sweep convergence (Agent A S1 + Agent D dump).**
   M's and S's lane_checker observe independent training streams; their
   `lane_score` traces are uncorrelated. Strict-`>` comparator means
   subsequent dwells with equal score don't displace earlier ones, BUT
   the 6-bit saturating score can race-to-tie at later points if any noise
   bin disturbs the early-point score by ±1. Result: M latches one tuple,
   S latches a different tuple. **Visible symptom:** post-S_DONE,
   `cal_state=4` on both sides; per-lane `slip[i]/phase[i]` reads differ
   on M vs S; M→S data is misframed in the slave RX; `tl_fc_l2a_valid` on
   slave stays 0. (Agent D probe dump.)

2. **(0,0) latches with eye at the edge (Agent K H2/H3).** S_PROBE passes
   at (0,0) because `lane_score>=LOCK_THRESH` at that point in the
   relatively-quiet sim PHY. On silicon at PVT extremes the actual
   eye-centre is at (slip=3, phase=5); (0,0) passes LOCK_THRESH but only
   barely. Latched (0,0) — link works at boot, oscillates 0xf5/0xfd in
   steady state under thermal drift (the original §9.9 motivation).

3. **Lane checker reset glitch (Agent A S6).** Lane checker held in reset
   on `~role_locked`. If `role_locked` rises just before the calibrator's
   `role_locked_rise` edge, the first 1-2 dwells score reset-residual
   zeros, biasing early-sweep `best_*` to whatever comes after the reset
   pipeline clears. Mostly low-impact across a 128-point sweep but biases
   tight calls.

4. **S_HOLD asymmetric exit (Agent A S5).** `S_HOLD` exits on
   `!role_locked` immediately. If slave's `role_locked` glitches low for
   one cycle while in S_HOLD, slave drops to S_DONE prematurely — master
   continues to hold training_mode. The peer's training-pattern
   discontinuity at the moment slave's RX flips to live FC is the
   classical Phase-0 §11 byte-align loss.

5. **`bit_slip`/`phase_offset` CDC glitch (PHY Audit Hole #4).** Calibrator
   transitions `S_FINISH→S_HOLD` (or `→S_DONE`); in the same cycle the
   output mux (line 842) reads `lane_done[i]=1` and switches the per-lane
   nibble from the live iterator to the latched value. This is one
   apb_clk cycle but the consumer (per-lane RX) is in the `w_cnt_clk`
   domain — a glitch on `phase_offset[4N+:4]` can produce a derived-clock
   glitch on `w_lnk_clk = ~adj_count[3]`. Today this is masked by the
   BUFG (USE_CLKBUF=1) and by the rate-of-change being low; not safe by
   design.

6. **Re-sweep loop with `MAX_RESWEEPS=0` (Agent K Open item 5).** If
   `sweep_success` is 0 (any lane faulted), S_FINISH falls through to
   `S_ARM` while `role_locked` is high. This re-runs the sweep AND the
   S_PROBE. If `lane_locked[i]` for some lane flickers during S_PROBE
   (race with peer's training start), the FSM never escapes the
   re-sweep loop and `cal_done` never asserts. Wall time → ms-scale
   instead of ~33 µs.

7. **HW reviewer's eye-edge picks (external assessment).** On tdif-22/23/24
   builds, ILA showed `crc_corrupt=1` on every one of 4096 slave RX
   samples even though `rx_in_data_id=0xa1` decoded cleanly. The reviewer's
   interpretation: the latched (slip,phase) is at the edge of the eye on
   real HW where ribbon-cable skew shifts the eye away from (0,0). Their
   proposed fix is `MIN_LOCK_DWELLS=8` — require the picked (slip,phase)
   to have N adjacent lock points around it in the sweep grid. This is a
   different policy: prefer eye-centre, accept it costs a sweep. Not yet
   implemented.

---

## 5. Signal chain: calibrator → PHY → wire → PHY → calibrator

```
   calibrator (phy_link_rx_rx_link_clk_w domain)
     │ cal_bit_slip_w[3i+2:3i]      cal_phase_offset_w[4i+3:4i]      cal_training_mode_w
     │       (8x3 lanes)                  (8x4 lanes)                      (single bit)
     ▼
   axi_chiplet_controller.sv:1365/1371/1372 — OR-merge with apb_clk soft-straps
     │ swi_bit_slip_w  = cal_bit_slip_w  | swi_bit_slip_lo_r
     │ swi_phase_offset_w = cal_phase_offset_w | swi_phase_offset_r
     │ swi_training_mode_w = cal_training_mode_w | swi_training_mode_r
     ▼ (combinational, no synchroniser)
   tidelink_idelay_rx.phase_tap_i ──► (FPGA only) per-lane IDELAYE2 tap LD into pad_rx delay line
                                       (sim: pure passthrough)
     │
     ▼
   Wlink.swi_bit_slip_in / swi_phase_offset_in / swi_training_mode_in
     │ (Wlink internal: identity passthrough into PHY ports)
     ▼
   WavD2DGpio.io_swi_*_in
     │ effective_bit_slip = io_swi_bit_slip_in | swi_bit_slip       (line 355)
     │ effective_phase_offset[4i+3:4i] = io_swi_phase_offset_in[...] | swi_phase_offset (line 508-515)
     │ input_training_mode_w = io_swi_training_mode_in | swi_training_mode (line 417)
     │     → effective_training_mode_tx_raw (immediate)              (line 438)
     │     → effective_training_mode_rx     (held +64 word cycles)   (line 439)
     ▼
   Per-lane TX (8 instances of WavD2DGpioTx):
     │ gpiotx_N.io_training_mode = effective_training_mode_tx_raw   (lines 525, 540, 555, ..., 630)
     │ gpiotx_N.io_clk_en        = ... | effective_training_mode    (held; lines 782, 789, ..., 831)
     │
     │ Inside WavD2DGpioTx (override):
     │   io_training_mode_q <= io_training_mode @(count==4'hf)       (line 128-130)
     │   _link_data_eff = io_training_mode_q ? {pattern,pattern} : io_link_data
     │   io_pad = _link_data_eff[count]                              (line 192)
     │   io_pad_clk = ~count[3] (gated by clk_en_qual @(count==4'hf))
     ▼
   io_pad_tx[7:0] + io_pad_clk_tx ────► wire ──► io_pad_rx[7:0] + io_pad_clk_rx (peer side)
     │
     ▼
   (peer side) tidelink_idelay_rx (FPGA: IDELAYE2 with tap from peer's calibrator's phase_tap_i)
     │
     ▼
   tidelink_rxclk_buf (FPGA: BUFG on pad_clk_rx → pad_clk_rx_buf)
     │
     ▼
   Wlink → WavD2DGpio.io_pad_rx_* + io_pad_clk_rx
     │
     ▼
   Per-lane RX (8 instances of WavD2DGpioRx):
     │ Inputs: io_phase_offset = effective_phase_offset[4N+:4]
     │         io_bit_slip     = effective_bit_slip[3N+:3]
     │
     │ Inside WavD2DGpioRx:
     │   count <= count + 1                                         (line 480 / passthru 490)
     │   adj_count = count + io_phase_offset                         (line 180)
     │   link_data_pad_clk[adj_count] <= io_pad                      (line 495-500)
     │   w_lnk_clk = ~adj_count[3]                                   (line 274)
     │   on w_lnk_clk: link_data_reg <= link_data_pad_clk            (line 502-507)
     │   _link_data_rep = {link_data_reg, link_data_reg}
     │   io_link_data = _link_data_rep[{2'b00, io_bit_slip} +: 16]   (line 254)
     ▼
   io_link_rx_rx_link_data[127:0] (8 × 16b) on io_link_rx_rx_link_clk (= gpiorx_0.io_link_clk)
     │
     ▼
   tidelink_lane_checker u_lane_checker (8 × tidelink_lane_checker_single)
     │ Per lane: word_in[15:0] vs {PATTERN[i], PATTERN[i]} (period-8)
     │ match_count saturates at 31; locked = (match_count >= 16)
     ▼
   lane_locked_w[7:0]
     │
     ▼ (same clock domain as the calibrator: phy_link_rx_rx_link_clk_w)
   Calibrator.lane_locked[7:0]
     │ Score accumulation in lane_score[i]
     ▼
   Best-of-sweep / S_PROBE latch → slip[i], phase[i], lane_done[i]
```

Per-step semantics summary:

* `phase_offset` is the SAMPLE-POINT (which `count` bit selects).
* `bit_slip` is the POST-CAPTURE WORD ROTATION.
* `training_mode` is the TX MUX SELECT.
* The wire is symmetric M→S and S→M; the calibrator on each die tunes the
  LOCAL RX (which is the M→S receive side on slave, S→M on master).
* The lane checker can't tell `count` initial-phase shifts apart (period-8
  + {P,P} aliasing) — see PHY Audit §4 step 8.

---

## 6. Clock and reset architecture

### 6.1 Clocks

| Clock | Source | Frequency | Domain Users |
|---|---|---|---|
| `apb_clk` | parent SoC clock | ASIC ~25 MHz nominal, FPGA 50 MHz typical | All Region 8 regs; autoneg I²C FSM. **NOT** the calibrator's flop clock (despite some docs saying so). |
| `hclk` / `app_clk` | parent SoC | varies | App interconnect; not in PHY hot-path. |
| `user_hsclk` (= `io_hsclk` to PHY) | parent SoC | ASIC ~100 MHz, FPGA 25 MHz | TX bit rate. Drives `WavD2DGpioTx.io_clk` → `count`. |
| `io_pad_clk_tx` = `gpiotx_0.io_pad_clk` | = `~count[3]` via WavClockGate | hsclk / 16 | Forwarded RX clock to peer. |
| `io_pad_clk_rx` | peer's `io_pad_clk_tx` over cable | hsclk/16 | Wrapper input. |
| `pad_clk_rx_buf` | `tidelink_rxclk_buf` (BUFG when USE_CLKBUF=1) | same | Routed to `Wlink.io_pad_clk_rx` → per-lane RX. |
| `w_cnt_clk` | `pad_clk_rx_buf` direct (USE_CLKBUF=0) OR per-lane BUFG (USE_CLKBUF=1) | hsclk/16 | RX `count` register clock. |
| `w_pad_clk` | same as `w_cnt_clk` (when io_pol=0, scan=0 → equal edges) | hsclk/16 | `link_data_pad_clk` capture. |
| `w_lnk_clk` | `~adj_count[3]` (per-lane); BUFG'd in USE_CLKBUF=1 | hsclk/16 | `link_data_reg` re-time. |
| `gpiorx_0.io_link_clk` = `phy_link_rx_rx_link_clk_w` | lane-0 `w_lnk_clk` | hsclk/16 | **Calibrator + lane_checker clock.** |
| `io_link_tx_tx_link_clk` | `gpiotx_0.io_link_clk` = `~count[3]` | hsclk/16 | TX-side word clock; `post_train_hold_ctr_r` is here. |
| `idelay_ref_clk` (FPGA only) | clk_wiz | 200 MHz | IDELAYCTRL only. |

**Key fact:** the calibrator is clocked by **lane-0 of the LOCAL RX**,
which is derived from the PEER'S TX clock /16. So M's calibrator is in S's
TX clock domain, and vice versa. The signal `cal_training_mode_w` falling
edge on M is in S's word clock domain.

### 6.2 Reset chain

```
   poresetn (top-level, active-low)
       │
       ▼  ~poresetn (active-high) → fanned to many places
   ┌───────────────┬─────────────────────────────────┐
   │               │                                 │
   ▼               ▼                                 ▼
calibrator.rst   Wlink.por_reset = wlink_por_reset    role_locked
 (= ~poresetn)        = ~poresetn | ~role_locked    (autoneg-set; APB W1S)
                                                        │
                                                        ▼ (rising edge)
                                                  calibrator.role_locked_rise
                                                        │
                                                        ▼ S_IDLE → S_ARM

   role_locked also drives:
   * lane_checker.rst = ~role_locked
   * wlink_por_reset = ~poresetn | ~role_locked   (so Wlink LL/FCSM is held in reset until role lock)
   * calibrator_role_locked = role_locked & autocal_enable_w  (calibrator input gate)

   swi_recal_r (APB W1S Region 8 slot 0 bit[1])
       │
       ▼
   calibrator.swreset
       │ rising edge: nothing
       │ falling edge (& role_locked): trigger_now → S_ARM
       │ (level high: any state → S_CANCEL)
       ▼

   io_por_reset (PHY's own POR through WavResetSync)
       │
       ▼
   ALL of: WavD2DGpioTx.count/clk_en_qual/io_training_mode_q
           WavD2DGpioRx.count/link_data_pad_clk/link_data_reg
           WavD2DGpioRx T3A FSM (S_SETTLE)
           wrapper post_train_hold_ctr_r, mux_align_count_r
```

**Critical gap (PHY Audit Hole #1):** there is NO path from `role_locked`
or `swi_recal_r` or any SW-driven signal to `WavD2DGpioRx.count` once T3A
has reached `S_LOCKED`. Only `io_por_reset` re-arms. So after the first
calibration completes, `count` is frozen wherever T3A left it. Subsequent
calibrator sweeps cannot change `count`; they can only change
`phase_offset` (which adds to `count` to make `adj_count`) and `bit_slip`
(post-capture rotation). The new calibrator design needs to acknowledge
this constraint OR drive the `io_train_rearm` input that the override
exposes (currently dangling).

### 6.3 Known CDC gaps

* **`cal_*_w` → PHY (combinational across apb→hsclk→w_cnt_clk):** no
  synchroniser. Multi-bit shear possible on per-lane phase changes. PHY
  Audit Hole #4.
* **`swi_training_mode_w` → `effective_training_mode_*`:** no
  synchroniser; relies on per-lane `count==4'hf` resampling inside the TX.
  Each lane's `count` has its own phase relative to the source signal, so
  the lane mux flips at 8 different times. PHY Audit Hole #3.
* **`role_locked` (apb_clk) → `calibrator_role_locked` (rx_link_clk):** no
  sync; relies on calibrator's `role_locked_q` edge-detect (line 287-295)
  for metastability filtering. One-bit; acceptable.
* **`swi_recal_r` (apb_clk) → `calibrator.swreset` (rx_link_clk):** same
  pattern as `role_locked`. Edge-detect at line 293-301.
* **`lane_locked_w[7:0]` (rx_link_clk via lane_checker) → calibrator
  (rx_link_clk):** same domain — not a CDC.

---

## 7. Known design issues (5 holes + extras)

### Hole #1 — T3A re-arm port is dangling (HIGH)
**Issue:** `WavD2DGpioRx.v` declares `io_train_rearm` input and has a 2FF
sync ready, but no parent module drives it, AND `T3A_REARM_ON_TRAIN`
defaults to 0 (gates the synthesis branch out).
**Symptom:** post-bringup re-train cycles cannot re-align `count`. Only
async POR re-arms T3A. After any `bringup_pair_converge.sh` recal cycle
(slot0=0x3 → 0x1 → 0x0), if the new `bit_slip/phase_offset` differs from
the original, the first FC word post-training is at a different byte
boundary than the training pattern was — slave LL_RX byte-align lost.
**Recommended fix:** wire `io_train_rearm` from `cal_training_mode_w` at
`tidelink_top.sv`, default-on `T3A_REARM_ON_TRAIN=1'b1` for FPGA build.
**Status:** unwired today; PHY audit Fix-A.

### Hole #2 — T3A `S_LOCKED` is sticky (HIGH)
**Issue:** With `T3A_CONTINUOUS=0` (default), `S_LOCKED` only exits on
async POR. `T3A_CONTINUOUS=1` exists (bounded re-arm, DWELL_MAX=63) but
re-arms periodically against whatever happens to be on the wire — fine
during training, harmful during FC data with random patterns.
**Symptom:** same as #1 — but the proposed bounded re-arm has its own
failure mode (tdif-11 lane-lock regression with T3A_CONTINUOUS=1, then
reverted to 0).
**Recommended fix:** keep `io_train_rearm` (Hole #1) as the primary
re-arm; drop `T3A_CONTINUOUS=1` once Fix-A is HW-validated.

### Hole #3 — Per-lane `count` phase desync at training mux flip (MEDIUM)
**Issue:** `effective_training_mode_tx_raw` is combinational at the
wrapper. Each per-lane TX has its OWN `count`. The per-lane
`io_training_mode_q` resampler aligns the mux flip to THIS lane's `count`,
but `count` differs per-lane (different reset arrival times +
hsclk-distribution skew). So all 8 lanes flip at slightly different
absolute times — within the same word.
**Symptom:** in sim, harmless (bit-exact deserialiser). On silicon, the
peer's RX correlator has to absorb 8 lane-staggered flips into FC data.
Not catastrophic but uncharacterised.

### Hole #4 — Calibrator → PHY CDC (MEDIUM)
**Issue:** `cal_bit_slip_w / cal_phase_offset_w / cal_training_mode_w`
cross from `phy_link_rx_rx_link_clk_w` to `apb_clk` (in the OR-merge with
the apb_clk regs) and back to `w_cnt_clk` (the per-lane RX) entirely
combinationally. Multi-bit; no Gray code; no handshake.
**Symptom:** a glitch on `bit_slip` during a `count[3]` edge can cause a
1-cycle wrong-byte output. Today masked by the calibrator only updating
once per dwell.
**Recommended fix:** register calibrator outputs on `S_FINISH` entry and
hold through `S_HOLD`/`S_DONE`. Add explicit 2FF sync between calibrator
clock and per-lane RX clock.

### Hole #5 — `count` initial phase is non-deterministic (MEDIUM)
**Issue:** Master TX `count` and slave RX `count` come up at `4'hf` on
async POR via SEPARATE WavResetSync flops. The deassert skew + per-deploy
routing puts them in a random 0..15-cycle relative phase.
**Symptom:** per-deploy lottery — on some builds master/slave converge on
first sweep; on others they take 2-3 re-sweeps. T3A is the workaround but
only fires once (Hole #1).
**Recommended fix:** APB `PHY_COUNT_SEED[3:0]` that overrides POR `4'hf`
on a SW-driven `swi_phy_count_reload` strobe. Both sides write the same
seed → deterministic startup.

### Extra: race-to-tie in best-of-sweep (Agent A S1) — sim-reproduced, partially fixed
The strict-`>` comparator at line 723 combined with 6-bit saturating score
makes the per-lane chosen tuple race-dependent. Agent F's S_PROBE biases
(0,0) to ALWAYS win on the lanes that lock at (0,0); for lanes that don't,
the race persists. Agent K recommends flipping line 723 to `>=` so
earliest-equal wins deterministically — combined with S_PROBE this closes
the race for all lanes.

### Extra: I²C-coordinated training drop asymmetry (Agent A S2)
`tidelink_autoneg.sv:ST_TRAIN_EXIT` writes peer's `swi_training_mode_r` to
0 over I²C (slow), then clears its own — producing a ~hundreds-of-cycles
window where master and slave disagree on training_mode. Only matters
when the I²C autoneg path is driving training (i.e. when `cal_*` is NOT
the source); but the OR-merge means BOTH paths can light up.

### Extra: HW-reviewer eye-edge picks (MIN_LOCK_DWELLS proposal)
External assessment of tdif-22/23/24 ILA captures suggests that even with
S_PROBE in place, on silicon with ribbon-cable skew the picked (slip,
phase) sits at the eye edge. Proposed `MIN_LOCK_DWELLS=8` would require
the picked point to have ≥ N adjacent passing points in the sweep grid.
Not yet implemented; design intent re-introduces the §9.9 eye-centre goal
that S_PROBE partially abandoned.

---

## 8. Open questions for the calibrator rewrite

1. **Centre vs edge policy.** Should the new calibrator pick the eye
   CENTRE (the §9.9 design intent that S_PROBE partially abandons) or
   the eye EDGE (the current `>`-comparator + first-pass-wins behaviour)?
   The HW-reviewer `MIN_LOCK_DWELLS=8` suggestion implies centre. The
   M/S-must-converge constraint from Agent E suggests deterministic
   (i.e. first-pass-wins) — these are in TENSION; the rewrite needs to
   pick.
2. **`MIN_LOCK_DWELLS` numeric.** If centre-finding: is 8 the right number?
   Does it need to scale with the lane_checker's `LOCK_THRESH`? With
   `DWELL_CYCLES`? With the 128-point sweep grid density (8 × 16)?
3. **Sideband exchange of latched (slip, phase).** Per Agent E option (2),
   should M and S exchange their chosen tuples over the I²C autoneg
   sideband AFTER both reach S_DONE, then apply the PEER's values
   locally? This addresses the "M and S calibrate two DIFFERENT RX paths
   and the search is not coordinated" problem at the root, but requires
   a new I²C sub-protocol AND per-lane exchange registers AND a third
   pass that applies the peer's values.
4. **`USE_IDELAY=1` default for FPGA + sim?** Today the FPGA wrapper sets
   `USE_IDELAY=1` but sim default is 0 (pure passthrough). If the new
   calibrator does IDELAY-tap dwell instead of just slip/phase, sim
   coverage needs to be re-thought. The IDELAY tap is `{phase, 1'b0}` so
   the calibrator's full 0..15 phase sweeps half the 32-tap line.
5. **Wire up Hole #1 (`io_train_rearm`) as part of this work or defer?**
   If the new calibrator triggers re-train via this input, the existing
   T3A correctly re-aligns `count`; otherwise the existing `count`
   non-determinism (Hole #5) leaks into every recal.
6. **Should `S_FINISH` keep `training_mode=1`?** Currently `training_mode`
   is OR of (S_ARM, S_PROBE, S_SWEEP, S_HOLD) — `S_FINISH` is the gap.
   One cycle low between sweep end and HOLD entry. Probably absorbed by
   per-lane `count==4'hf` resamplers but uncharacterised.
7. **Should the OR-merge change?** The "calibrator | soft-strap" combinator
   makes SW unable to mask the calibrator output. Agent E proposed a
   "CAL_VALID" strap that defaults to 0 → APB-driven by default → set to
   1 by SW after deploy-time validation. Should the rewrite include this?
8. **Should the calibrator output the eye CENTRE explicitly as a status?**
   If the new policy is eye-centre, exposing the picked tuple and the
   sweep-derived eye width per lane via Region 8 would let SW validate
   robustness without an ILA pull.
9. **Re-sweep loop with `MAX_RESWEEPS=0`** can wedge indefinitely if any
   lane never locks (Agent K Open item 5). Should MAX_RESWEEPS default to
   non-zero (e.g. 4) with a clear `LANE_FAULT` indication, or should the
   loop continue indefinitely with SW-visible `resweep_ctr` for ops to
   watchdog?
10. **APB override path.** `apb_bit_slip_override` and
    `apb_override_enable` ports on the calibrator exist (lines 211-213)
    but are tied to 0/0 at the instantiation site (`axi_chiplet_controller.sv:1347-1348`).
    Should the rewrite wire them through to a Region 8 register so SW
    can fully bypass the calibrator without re-elaborating the design?

---

## 9. References

* Prior agent reports (this worktree's `docs/`):
  * `agent_a_calibrator_static_audit.md` — race-to-tie S1, I²C train-exit S2.
  * `agent_b_phy_interface_audit.md` — calibrator → PHY signal map.
  * `agent_d_probe_findings.md` — empirical M=(0,0)/S=(1,1) on all lanes.
  * `agent_e_force_bisect_results.md` — phase_offset OR bit_slip = 0 individually unblocks M→S.
  * `agent_f_fix_attempt.md` — S_PROBE landed, sim regression PASSES.
  * `agent_j_branch_archaeology.md` — branch / failed-fix history.
  * `agent_k_independent_review.md` (in `td-calibrator-fix/docs/`) — sceptical review of S_PROBE.
  * `CALIBRATOR_BUG_HANDOFF_2026_05_26.md` — the handoff that started this stream.
* `td-l4-option-c/docs/PHY_DESIGN_AUDIT_2026_05_26.md` — the load-bearing
  audit (5 design holes, §4 mechanism, §6 fix plan).
* `td-l4-option-c/docs/TIDELINK_PHASE0_OBS_20260524_2109.md` — §11
  root-cause (slave LL_RX byte-align loss at training mux flip).
* RTL source: `src/rtl/tidelink_phy_align_calibrator.sv` (calibrator),
  `src/rtl/tidelink_lane_checker.sv` (checker),
  `src/rtl/tidelink_idelay_rx.sv` (FPGA IDELAY),
  `src/rtl/tidelink_rxclk_buf.sv` (FPGA BUFG),
  `src/rtl/local_overrides/WavD2DGpio.v` (wrapper),
  `src/rtl/local_overrides/WavD2DGpioTx.v` (TX),
  `src/rtl/local_overrides/WavD2DGpioRx.v` (RX),
  `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`
  (glue, OR-merge at lines 1365-1372, calibrator instantiation at 1327).

---

*Read-only architecture reference. Compiled 2026-05-27 from the
`feat/calibrator-bug-fix` family of branches' calibrator-debug evidence.*
