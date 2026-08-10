# Functional Behaviour

This page describes what TideLink **does**: how a link comes up, how credit and
back-pressure work, what actually happens to a transaction that crosses the
wire, how time is distributed, and — importantly — which errors are caught and
which are silently dropped.

For the module structure behind all of this, see {doc}`architecture`. For the
registers named here, see {doc}`register_map`.

Every claim is cited to a file and line in this checkout (branch
`fix/z2-drop-park-hook`, `9eaafb7`), to a measurement recorded in `docs/`, or is
marked **UNVERIFIED**.

---

## 1. Link bring-up, end to end

### The sequence

| # | Phase | What happens | Gating condition |
|---|---|---|---|
| 1 | **POR** | `poresetn` releases. `wlink_por_reset = ~poresetn \| ~role_locked` (`axi_chiplet_controller.sv:2921`) holds the whole Wlink in reset; `app_clk_reset = ~hresetn \| ~role_locked` (`:2926`) holds the a2l replay FIFO's write side. Both sides of that Gray-pointer CDC therefore deassert on the **same** event. | — |
| 2 | **Role selection** | Before lock, `role_effective` follows `role_strap_i`; during negotiation it follows `nego_role_w`; after lock it follows `ROLE_CFG[0]` (`axi_chiplet_controller.sv:642-644`). `role_is_master = ~role_effective` (`:645`) also selects which I²C core is out of reset and drives the pins. | `nego_en`, `role_locked` |
| 3 | **Role lock** | `ROLE_CFG[1]` is **W1S** and latches only when `mask_hs_gate_open = mask_hs_match \| mask_hs_bypass_i` (`:711`). It is cleared **only** by `poresetn`. | mask handshake |
| 4 | **PHY training** | Wlink POR deasserts. The calibrator asserts `training_mode` and sweeps 8 bit-slip × 16 phase per lane against the lane checker. `DWELL_CYCLES = 64` per point, `LOCK_THRESH = 16` consecutive matched words (`tidelink_phy_align_calibrator.sv:215,218`). | `role_locked` rising |
| 5 | **Cross-lane deskew** | The 8 per-lane 16-bit words are re-aligned into one coherent 128-bit word. | all lanes primed |
| 6 | **Credit handshake** | CR (`0x44`) / CRACK (`0x45`) exchange loads the credit maxima. FCSM reaches **state 4 = LINK_IDLE**. | `cr_pkt_seen`, `crack_pkt_seen` |
| 7 | **Data mode** | FCSM 4 → 5 on the send gate; `tl_data_mode_o` asserts (FCSM state ≥ 4). | see [§4](#4-flow-control-and-credits) |

### The FCSM states

`WlinkGenericFCSM_6` is an 8-state (3-bit) machine
(`docs/ARCHITECTURE_PHY_LINK.md:241`, consistent with the RTL transitions at
`WlinkGenericFCSM_6.v:768-798`):

| State | Name | Meaning |
|---|---|---|
| 0 | reset / ack-seen | `_ack_seen_before_T = state == 3'h0` (`:557`) |
| 1 | emit CR | held for at least `SOCL_L6_MIN_CR_EMITS = 32` CR packets (`:189`) |
| 2 | emit CRACK | held for at least `SOCL_L7_MIN_CRACK_EMITS = 32` (`:192`) |
| 3 | transition | |
| 4 | **LINK_IDLE** | credits loaded, link ready |
| 5 | **LINK_DATA** | a long packet is being framed |
| 6 | SEND_ACK | `_GEN_67 = send_ack_req & _T_54 ? 3'h6 : …` (`:782`) |
| 7 | SEND_NACK | `_GEN_76 = send_nack_req ? 3'h7 : …` (`:790`) |

### What each phase looks like over APB

| Phase reached | `0x2108` `SWI_LANE_STATUS` | `0x2114[31:16]` | `0x2198` `OBS_CAL[3:0]` |
|---|---|---|---|
| training in progress | `lane_locked` climbing, `[16] calibration_done = 0` | 0 | `S_SWEEP` (2) |
| calibration done | `[16] calibration_done = 1` | may be 0 | `S_DONE` (4) |
| deskew delivering coherent words | — | `sync_detected` **> 0** | `S_DONE` |
| CR/CRACK seen | `[23] cr_pkt_seen_rx = 1`, `[24] crack_pkt_seen_rx = 1` | — | `S_DONE` |
| LINK_IDLE | `[19:17] fcsm_state = 4` | — | `S_DONE` |
| carrying data | `fcsm_state` toggles 4 ↔ 5 | — | `S_DONE` |

:::{danger}
**`link_active` is not "the link works".** `assign link_active = role_locked_o`
(`tidelink_top.sv:2784`), which asserts roughly 5 µs *earlier* than data
capability — at role lock, when the link cannot yet carry anything. The RTL
comment at `:459-467` records the concrete failure: gating a downstream root
election on `link_active` let both dies settle their election before any CLAIM
crossed the die boundary, producing a silent dual-root. **Gate on
`tl_data_mode_o`.**
:::

:::{danger}
**`fcsm_state == 4` is not proof of liveness either.** Measured on a *wedged*
link, `fcsm` reads 4, `cal_done`/`cr`/`crack` read 1/1/1, the `llrx` framer state
reads 0, EPOCH reads `0x00000000` and `crc_errors` reads 0 — identical to a
healthy link (`docs/LINK_RECOVERY_MECHANISM.md` §5). See
[§9 Wedge detection](#9-recovery-and-wedge-detection).
:::

---

## 2. Role negotiation

Two identical dies must agree which is master. `tidelink_autoneg`
(`src/rtl/local_overrides/tidelink_autoneg.sv`, 2418 lines) resolves this over
the I²C sideband **before** role lock, so Wlink stays in reset throughout.

**Protocol** (`tidelink_autoneg.sv:8-11`): priority-based backoff with SDA
early-exit detection. The side with the **lower numeric priority** claims master
first by switching to I²C master mode and writing a claim byte to the peer's I²C
slave; the peer detects the SDA START condition and adopts slave.

Preconditions that follow from that: **both dies must start with the I²C slave
core active** (neither drives SCL), and the winner must switch to master
*without* first locking the role.

Key defaults (all read from RTL):

| Item | Value | Source |
|---|---|---|
| Negotiation slave address | `7'h7E` | `axi_chiplet_controller.sv:726` |
| I²C prescaler | `16'd125` → 100 kHz SCL at 50 MHz `apb_clk` | `axi_chiplet_controller.sv:745` |
| `NEGO_TIMEOUT` POR | `32'd131_082_000` cycles (~1.31 s at 100 MHz) | `tidelink_autoneg.sv:27` |
| `NEGO_TICK` | 1000 `apb_clk` cycles per priority unit | `tidelink_autoneg.sv:25` |
| `NEGO_BASE_DELAY` | 2000 cycles minimum before any claim | `tidelink_autoneg.sv:26` |
| `nego_en` POR | **`7'h00` → OFF** in RTL; `7'h61` only on the FPGA IP wrapper | `tidelink_top.sv:141` vs `tidelink_vivado_wrapper.v:147` |

The autonomy chain is
`autonomy_armed = nego_en & role_locked & nego_train_cfg_r[0] & ~autonomy_retire_q`
(`axi_chiplet_controller.sv:1369-1370`).

### Surviving a dead I²C bus

Two parameters exist purely to make the design work when the I²C sideband is
unavailable:

| Parameter | Default | Effect |
|---|---|---|
| `ROLE_FROM_STRAP` | `1'b1` (`tidelink_top.sv:224`) | The I²C-NACK terminal role **and** the timeout fallback derive from `role_strap_i`, so a (master, slave) strap survives a dead bus. At `1'b0` — the legacy trap — an I²C NACK makes **both** dies slave and autonomy is structurally dead. |
| `TRAIN_ENTRY_FALLBACK` | `1'b0` (`tidelink_top.sv:229`) | At 1, training entry starts from the strap on a dead bus, so the SYNC beacon lights and the link can self-start without a peer I²C ACK. Surfaced on the FPGA IP face at `tidelink_vivado_wrapper.v:201`. |

### The peer-mask handshake and its history

`mask_hs_gate_open` is what allows `ROLE_CFG[1]` to latch. The current
expression is:

```verilog
wire mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;   // :711
```

:::{warning}
**Widely-repeated documentation says this OR also contains
`apb_debug_unlock_i`. It does not — that term was removed on 2026-07-24.** The
RTL comment at `axi_chiplet_controller.sv:695-710` records why, and it is worth
reading in full: the single strap served two unrelated purposes (bypass the
peer-mask gate; enable external-APB writes to Wlink on a slave die), so the
handshake could never be honest while bring-up worked.

Measured on `kr260-pair-onchip`: with the strap welded 1 the slave showed
`gate_open = 1` while `mask_hs_match = 0` — a **sham handshake** (2026-07-23);
with it driven 0 the gate became honest but the slave's Wlink config writes were
silently dropped read-only, so FC never bootstrapped and **both dies stuck at
`fcsm = 2`** (2026-07-24). Dropping the term decouples them.
:::

The remaining escape hatch is the dedicated `mask_hs_bypass_i` strap, plus the
parameter tie: at `HONEST_MASK_HS = 1'b0` the controller's `mask_hs_bypass_i` is
tied `1'b1` (`tidelink_top.sv:2512`), forcing the gate permanently open. The
FPGA wrapper ships `1'b0`; `tidelink_top`'s own default is `1'b1`.

---

## 3. PHY training, calibration and deskew

### Calibration

The calibrator sweeps, per lane and in parallel, 8 bit-slip positions × 16
sub-bit phase steps, dwelling `DWELL_CYCLES = 64` at each point and requiring
`LOCK_THRESH = 16` consecutive matched words from the lane checker
(`tidelink_phy_align_calibrator.sv:215-218`). It then holds `training_mode` for
`HOLD_CYCLES = 8 × 128 × DWELL_CYCLES` (`:237`) so the peer converges, and
enters `S_DONE`.

`MIN_LOCK_DWELLS` defaults to 2 (`tidelink_phy_align_calibrator.sv:259`) and is
APB-overridable at `0x210C[23:20]` (`:164`, `:311`; register at
`axi_chiplet_controller.sv:2167`, POR `4'd0` = use the parameter).

:::{caution}
**There is no firmware-reachable PHY retrain.**
`tidelink_phy_align_calibrator.sv:652-661` latches `calibrated_once_q` on the
first `S_DONE` and gates **both** re-trigger edges off forever:

```verilog
reg calibrated_once_q;
// :654-656
if (rst)                      calibrated_once_q <= 1'b0;
else if (cur_state == S_DONE) calibrated_once_q <= 1'b1;
// :660-661
wire role_locked_rise_eff = role_locked_rise & ~calibrated_once_q;
wire swreset_fall_eff     = swreset_fall     & ~calibrated_once_q;
```

Only `rst` (POR) clears it. `SWI_RECAL` (R8 bit `[1]`) is the only software path
to that `swreset`, and it is a **measured no-op** after first lock —
`docs/LINK_RECOVERY_MECHANISM.md` §4 sampled the FSM 60 times on both dies and
it never left `S_DONE`.

This is a deliberate fix for a real bug: the autoneg winner's spurious
training-exit recal re-entered training mid-handshake and wedged the master FCSM
at state 2 with zero TX credit (`tidelink_phy_align_calibrator.sv:607-630`). But
it closed the only software retrain path. A dedicated `SWI_FORCE_RECAL` W1P
bypassing `calibrated_once_q` is **proposed only** in
`docs/LINK_RECOVERY_MECHANISM.md` §6.1 — **no such bit exists**.
:::

### Cross-lane deskew

Two mechanisms, one always on and one selected by parameter.

**Occupancy deskew (always on).** Each lane writes into its own FIFO in its own
RX link clock; per-lane write pointers are Gray-coded and CDC'd to the read
clock. The read side waits for `all_primed` (≥ `PRIME_THRESH = 5` words per
lane) then advances one word per output clock gated by
`all_ready = &(lane_has_data | ~lane_mask)`
(`deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:41-47`).

:::{warning}
Occupancy deskew alone is **not** sufficient. A 2026-06-24 experiment setting
both whole-word anchors off was sim-refuted: occupancy aligns zero and sub-word
skew but **shears whole-word cross-lane skew**, and the integrated V2 gate's
staircase profile corrupts data (`WavD2DGpio_v2.v:833-841`). V1's historical
"byte-exact A→B" was the ~13 % lottery — the times the real silicon skew
happened to land sub-word.
:::

**Whole-word corrector (one of two, mutually exclusive).**
`WavD2DGpio_v2.v:851` drives `.SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN)`:

| `EPOCH_ANCHOR_EN` | Corrector compiled in | Behaviour |
|---|---|---|
| `1'b0` (default everywhere in this tree) | SYNC-beacon re-anchor | Re-anchors on the periodic 128-bit SYNC word. **Never arms on real silicon** because the idle-gated beacon cannot fire (`local_overrides/Wlink.v:68-71`). |
| `1'b1` | training-EXIT epoch anchor | Each lane detects the peer's pattern→data exit and latches its write index; the read side loads per-lane backward read offsets. |

The epoch parameters are `EPOCH_STREAK_MIN = 8`, `EPOCH_EXIT_CONFIRM = 2`,
`EPOCH_SETTLE = 32` and `EPOCH_MATCH_THRESH = 5` (`WavD2DGpio_v2.v:880`;
declarations at `local_overrides/tidelink_lane_deskew_v2.sv:323-356`). The
threshold was relaxed from 3 to 5 for a measured reason recorded at
`WavD2DGpio_v2.v:872-880`: die_a's skewed RX lanes lock at Hamming distance 4–5,
so a stricter epoch match never built a streak and the anchor never fired — **the
matcher must accept exactly what the lane-checker LOCK accepts.**
`SYNC_REANCHOR_TOL` was raised 4 → 5 for the same class of reason (`:852-871`).

A span greater than `EPOCH_OFF_MAX` is rejected and self-heals to zero offset.
Results are exposed at APB `0x2140`.

---

## 4. Flow control and credits

### Four independent planes

`docs/ARCHITECTURE.md` §5 separates the traffic into four planes, and keeping
them apart is the key to reasoning about a stall:

| Plane | Carried on |
|---|---|
| **Data** | `ahb_sub` / `ahb_tx` / `ahb_fifo` / `ahb_mng` / `tc_axis`, over TideLink FC `0xA1` plus AXI FC `0x80`–`0x84` |
| **Control** | returner credits and doorbells as `0xA1` SIDEBAND words, plus Wlink short packets `0x44` CR / `0x45` CRACK / `0x46` ACK / `0x47` NACK |
| **Management** | APB, role straps, negotiation, PUF, I²C — **does not cross the data link** |
| **Time** | PTP short packets `0x50` SYNC / `0x51` DELAY_REQ, plus TideLink SIDEBAND servo words |

### Link-layer credit — the Wlink FC ring

CR and CRACK carry `word_count = 16'h1f1f` (`WlinkGenericFCSM_6.v:729`), and
that value is what **loads** `fe_tx_credit_max` / `fe_rx_credit_max`.

The transition that matters is the **send gate** in state 4:

```verilog
wire _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full;   // :768
// true  ⇒  state 5, frame a long packet with
//          data_id   = swi_data_id_1  (0xA1)   // :772
//          word_count = 16'h7                  // :773
```

Receiver ACK (`0x46`) advances the sender's credit ring; NACK (`0x47`) rewinds
the a2l replay FIFO via `a2l_fc_replay_link_revert` (`:1126`).

:::{danger}
**`fe_rx_is_full` only flags credit == 0.** The RTL comment at
`WlinkGenericFCSM_6.v:317` and `axi_chiplet_controller.sv:2840-2851` both say it
outright: a credit value garbled to a small **non-zero** number passes the send
gate and then exhausts after 1–4 packets, invisible to `fe_rx_is_full`. That is
the documented CR-credit-decode lottery.

**You must read the credit *value* at `OBS_FC_CREDIT` (`0x219C[7:0]`), not just
`0x2108[31]`.** Expect the peer's programmed credit count (e.g. `0x1F`).
:::

Three SoC Labs guards keep this handshake from wedging, all in
`WlinkGenericFCSM_6.v`:

| Guard | Value | Prevents |
|---|---|---|
| `SOCL_L6_MIN_CR_EMITS` | 32 (`:189`) | The asymmetric CR-loss bug: a slave whose RX framer locks first leaves state 1 too early and "shuts the door" before the master's framer byte-aligns (`:85-110`) |
| `SOCL_L7_MIN_CRACK_EMITS` | 32 (`:192`) | The same failure on the CRACK side |
| `SOCL_L7_WDOG_THRESHOLD` | `16'h4000` (`:193`) | A stuck state 7: the watchdog pulls SEND_NACK back to LINK_IDLE after 16384 cycles |
| `SOCL_REACK_THRESHOLD` | `16'h0100` (`:199`) | A silent stall when no data has arrived for a long idle window |

There is also an **L7 "bring-up forgive" gate** (`:16-82`, implemented at
`:622`): until the FCSM has
been observed in state 5 once, and only while the bidirectional CR/CRACK sticky
bits prove the link is structurally healthy, a stale `isNotExpPacket` cannot
latch `send_nack_req`. A genuine CRC error during bring-up **still** latches it.

### Application-level credit — the mailbox counter

`src/rtl/fifo/tidelink_fifo_ctrl.sv`:

```verilog
localparam MAX_CREDITS = (1 << (RAM_ADDR_W - 2));            // :110  → 4096
localparam MAX_PACKET_LEN = RAM_ADDR_W'(MAX_CREDITS - 2);    // :242
wire rx_fifo_empty = (credit_count_r == MAX_CREDITS);        // :138
wire [RAM_ADDR_W-1:0] packet_delta = packet_word_length_r + RAM_ADDR_W'(2'd2); // :125
```

At `RAM_ADDR_W = 14` the 16 KB SRAM is credited in 32-bit words with a 2-word
header reserve. Two clamps in this file are silicon-defect fixes:

- **Consume clamps at 0** (`:386-389`) — no underflow.
- **Mint saturates at `MAX_CREDITS`** (`:424-427`) — the 2026-07-15 fix for the
  phantom-pop chip-killer, in which a drain after a truncated packet minted
  credit *above* `MAX_CREDITS`, an impossible state. The comment at `:391-400`
  is explicit that the earlier `!rx_fifo_empty` read guard (`:321-331`) does
  **not** cover this case.

Software-visible mailbox credit registers (full detail in {doc}`register_map`):
`CREDIT_COUNT` (RO) `0x200C`, `RELEASE_THRESHOLD` (RW, POR 20) `0x2004`,
`RELEASE_ACC` (RO) `0x2018`, `PAIR_CREDIT_COUNTER` (RO) `0x2028`,
`PAIR_CREDIT_CONSUME` (WO) `0x202C`, `PAIR_CREDIT_COUNTER_EN` (RW, POR 1)
`0x2030`.

### The returner

Credit gets back to the peer with no CPU involvement. When the local RX FIFO
drains past `RELEASE_THRESHOLD`, `tidelink_returner` issues a single-beat AHB
write on channel 0; the FC adapter intercepts it and turns it into a `SIDEBAND`
FC word addressed at the peer's `PAIR_BASE_ADDR`. Channels 1 and 2 carry the
doorbell and reset-doorbell. Pending registers ensure a short pulse is never
lost even if the returner is busy (`tidelink_returner.sv:5-7`).

---

## 5. Back-pressure semantics

This is the single most consequential behavioural fact in the design, so it is
stated plainly and with the RTL that proves it.

### The AHB TX aperture *does* back-pressure — honestly

The FC adapter drops `ahb_tx_hreadyout` while the 1-entry skid is full —
`assign ahb_tx_hreadyout = tx_err1_r ? 1'b0 : tx_data_phase_r ? (skid_can_accept & ~sideband_grant) : 1'b1;`
(`tidelink_fc_adapter.sv:371-375`, with `skid_can_accept` at `:553`). Past
`TX_STALL_TIMEOUT_LOG2 = 16` hclk (≈ 1.3 ms at 50 MHz) it terminates the beat
with a standard two-cycle AHB **ERROR** (`:311-346`). The comment at `:300-310`
records why the old behaviour was wrong: the previous "wedge watchdog" forced
`HREADY` and dropped burst beats **with OKAY**, which is invisible to the
master.

So on the local side, an over-eager writer is stalled and then errored — not
silently dropped.

### The peer's RX FIFO write side does *not* back-pressure

```verilog
// src/rtl/fifo/tidelink_fifo_mem.sv:92
assign fc_wr_ready = 1'b1;  // SRAM completes writes in 1 cycle
```

```verilog
// src/rtl/fifo/tidelink_fifo_ctrl.sv:482-484
wire overrun_event  = ((fc_wr_valid && fc_wr_write) || (hsel && ...))
                      && (credit_count_r == '0);
```

A word arriving at the peer with zero credit is **silently discarded**. The only
trace is a sticky `overrun` bit that stays set until FLUSH
(`tidelink_fifo_ctrl.sv:474-478`).

:::{danger}
**Therefore: poll the peer's credit before every mailbox write.** There is no
end-to-end back-pressure that will stop you overrunning the far side's FIFO.
`tidelink_tx_gen`'s own header states the rule for hardware
(`src/rtl/tidelink_tx_gen.sv:25-35`):

> HARDWARE CREDIT GATE IS MANDATORY. The peer's RX FIFO write side has NO
> backpressure … A line-rate generator without this gate would destroy data at
> line rate. We gate on `pair_credit_count` — the local view of the PEER's free
> credit, maintained in hardware by the peer's returner — **never** on the local
> FIFO's own credit (that is the wrong buffer) and **never** on the Wlink `fe_*`
> credit (that protects the 16-deep replay FIFO, i.e. the wire, not the peer's
> 16 KB RX SRAM).

The generator's implementation of that rule is
`credit_ok = pair_credit_en && (pair_credit_count >= need_total)`
(`tidelink_tx_gen.sv:171-172`), fail-closed because `pair_credit_count` PORs to
0, and **reserve-then-send**: the whole `(len + 2)` is consumed at packet start
(`:314`, `:364-366`), because the adapter accepts one word per `hclk` and a
completion-time consume would let the next packet arm against credit already
spoken for.
:::

### Summary table

| Interface | Back-pressure? | On overflow |
|---|---|---|
| `ahb_tx_*` (local TX aperture) | **yes** — `hreadyout` low while skid full | after ~1.3 ms, two-cycle AHB ERROR; `tx_dropped_cnt_r` increments |
| a2l replay FIFO (app → link) | **yes** — `app_ready = ~a2l_full` | writer stalls |
| Wlink FC send gate (state 4→5) | **yes** — `~fe_rx_is_full` | but only detects credit **== 0**; see the warning in §4 |
| Peer RX FIFO write port | **no** — `fc_wr_ready` tied 1 | **silent drop**, sticky `overrun` only |
| `ahb_sub_*` (transparent path) | **yes** — the bus simply stalls | AHB has no SPLIT/RETRY, so the CPU stalls for the full round trip |

---

## 6. End-to-end walkthroughs

### 6.1 A mailbox write: host AHB → peer RX FIFO

Thirteen steps, with the gate at each. Cited against the RTL; the same walk is
narrated in `docs/ARCHITECTURE_PHY_LINK.md` §6.

| # | Stage | Gate / detail |
|---|---|---|
| 1 | Host master → `ahb_tx_*` (14-bit aperture) | AHB address phase latches `haddr` on a valid write |
| 2 | `tidelink_fc_adapter` builds `{2'b00, addr_offset, data}` | arbiter (`:529-546`), then the 1-entry skid — **gate `skid_can_accept` (`:553`)** |
| 3 | `tl_fc_a2l_valid` / `_data[47:0]` / `_ready` → Wlink `bore_1` → `TideLinkToWlink` → FCSM `io_app_a2l` | — |
| 4 | **a2l replay FIFO** `WlinkGenericFCReplayV2_13` | `app_clk` (= `hclk`) → `link_clk` CDC; `app_ready = ~a2l_full`; output `a2l_fc_replay_link_valid` |
| 5 | FCSM state 4 **send gate** | `_T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full` (`:768`) → state 5, long packet `data_id = 0xA1`, `word_count = 7` |
| 6 | `txrouter` → `lltx` | header ECC + CRC, 128-bit `io_link_data` |
| 7 | PHY TX | `sync_insert` (passthrough by default) → segmenter 128 b → 8×16 b → `tx_mask` → 8 serialisers → `pad_clk_tx` + `pad_tx[7:0]` |
| — | **═══ wire ═══** | |
| 8 | Peer `pad_clk_rx` + `pad_rx[7:0]` | one shared `IBUFG`→`BUFG` on FPGA (`docs/ARCHITECTURE_PHY_LINK.md` §6); optional `tidelink_idelay_rx`; 8× `WavD2DGpioRx` (phase / bit-slip / word-pin) |
| 9 | `tidelink_lane_deskew` | re-align to one coherent 128-bit word |
| 10 | `WlinkRxLinkLayer` | byte-counter framer; `hunt_holdoff` = 63 `link_clk` post-reset; header check; short/long classify; short-ID whitelist `{0x44,0x45,0x46,0x47}` (`WlinkRxLinkLayer.v:25,63-66`) |
| 11 | `rxrouter` → **l2a replay FIFO** `WlinkGenericFCReplayV2_12` | `link_clk` → `app_clk` CDC; **no revert** |
| 12 | Peer `fc_adapter` RX FSM | **gate `rx_accept = tl_fc_l2a_valid & (rx_state_r == RX_IDLE) & ~rx_pending_r` (`:622`)**; then decode `pkt_type`: `00` → single-cycle direct write on `fc_rx_fifo_*` at `addr_offset`; `01` → the internal APB master; `10` → TideChart AXIS |
| 13 | RX FIFO SRAM | readable at `ahb_fifo_*`, or through the `ahb_sub` peer window |

:::{tip}
**On hardware the RX FIFO must be read strided, not at a fixed offset.** It is a
streaming FIFO: packet *k* lands at `ahb_fifo + 0x10*k + 8`. A fixed-offset read
sees only packet 0 and falsely reports "intermittent delivery". This cost
multiple days before it was corrected on 2026-07-22 — see {doc}`hardware_tests`.
:::

### 6.2 A transparent AHB read: `ahb_sub` → peer memory → back

This path is completely separate from the mailbox and uses the AXI FC nodes.

1. Host master issues an AHB read on `ahb_sub_*` (full 32-bit address).
2. `tidelink_addr_translator` remaps `addr[31:24]` via the 8-rule CAM;
   `addr[23:0]` passes through unchanged.
3. `u_xhb_sub` (XHB500 AHB→AXI) converts it to an AXI4 read: `s_axi_ar*`
   (12-bit ID, 36-bit address with the upper 4 bits tied 0, 32-bit data —
   `tidelink_top.sv:584-600`).
4. `AXI4ToWlink` packs the AR beat into FC `data_id = 0x83` with its own
   credit/ACK short IDs `0x14`–`0x17`.
5. The AR long packet crosses the link exactly as steps 6–11 above.
6. On the peer, `AXI4ToWlink` re-emits `m_axi_ar*`; `u_xhb_mng` (XHB500
   AXI→AHB) converts it to an AHB read on `ahb_mng_*`, which the peer SoC
   decodes as an ordinary local access.
7. The read data returns on the **R** channel as FC `data_id = 0x84` (short IDs
   `0x18`–`0x1B`), crosses back, and `u_xhb_sub` completes the originating AHB
   transfer.

:::{warning}
**The originating CPU is stalled for the entire round trip.** AHB has no
SPLIT/RETRY and Cortex-M-class matrices cannot release the core. That is the
whole reason the mailbox path exists. On an FPGA board the transparent window
must also stay on the control-plane AXI port (GP0 on Zynq-7000) — the full
address is forwarded and the peer decodes it. See {doc}`boards`.
:::

The five AXI channels have **distinct** data IDs — AW `0x80`, W `0x81`, B
`0x82`, AR `0x83`, R `0x84` — not a shared `0x80`
(`docs/reference/FC_NODE_REGISTRY.md:29-33`). Each has its own FCSM, its own
credit ring and its own replay FIFO, so one channel wedging does not
automatically wedge the others.

---

## 7. PTP time distribution

### The wire protocol

Wlink **short** packets, 32 bits on the link
(`src/rtl/tidelink_ptp.sv:18-21`):

```
[31:24] ECC       — Hamming SEC/DED
[23:8]  payload   — 16 usable bits (sequence number or metadata)
[7:0]   data_id   — 0x50 or 0x51
```

```verilog
localparam [7:0] DATA_ID_SYNC      = 8'h50;   // :130
localparam [7:0] DATA_ID_DELAY_REQ = 8'h51;   // :131
```

A **two-message** exchange (SYNC + DELAY_REQ), no follow-up message.

### Timestamping

`tidelink_ptp` contains **no counter** (`:10-12`). It pulses `phc_hw_capture` at
the exact short-packet handshake cycle:

```verilog
assign phc_hw_capture = tx_handshake | rx_accept;   // :322
```

and the timestamp values live in the external PHC's `HW_CAP_*` registers.

TX is **idle-gated**: the FSM waits in `TX_WAIT_IDLE` until `tx_router_idle`
(the Wlink link-layer TX `link_idle` output) before handing the packet over
(`:178`, `:251-260`), so the framer contributes no jitter to t1/t3.

| Timestamp | Captured by | Event |
|---|---|---|
| t1 | grandmaster | SYNC TX (`sync_tx_done`, `:327`) |
| t2 | subordinate | SYNC RX (`sync_rx_done`, `:329`) |
| t3 | subordinate | DELAY_REQ TX (`dreq_tx_done`, `:328`) |
| t4 | grandmaster | DELAY_REQ RX (`dreq_rx_done`, `:330`) |

### The mailbox and the servo

t1 and t4 are shipped to the subordinate over **TideLink SIDEBAND FC words** —
four 32-bit words per timestamp, written into the Region-3 timestamp mailbox via
the existing FC RX config path, so no additional short-packet `data_id` is
needed (`src/rtl/tidelink_ptp_servo.sv:13-16`).

`tidelink_ptp_servo` then closes the loop **in hardware**: a PI controller whose
`servo_mode` selects grandmaster or subordinate, driving `phc_hw_set_time`,
`phc_hw_set_seconds`, `phc_hw_set_nanoseconds`, `phc_hw_adj_valid` and
`phc_hw_adj_ns_incr_frac`, and asserting `servo_locked`. Discipline strategy
(`:17-19`): a large offset (beyond `STEP_THRESH`, default 1000 ns, or a seconds
mismatch) triggers a `SET_TIME` phase step; a small offset steers frequency
through `NS_INCR_FRAC`. Default gains are `KP = 32'h0000_B333` (~0.7) and
`KI = 32'h0000_4CCC` (~0.3) in Q0.32 (`:35-37`).

:::{important}
**The mailbox is peer-write-only, and that is enforced structurally as of
2026-07-31.** `tidelink_apb_regs` computes `mbox_reg_write` from the raw shared
bus with no source qualifier, so an ordinary external APB write to the mailbox
address used to overwrite the assembled cross-die timestamp. The fix is
`mbox_reg_write_fc_only = mbox_reg_write && fc_cfg_apb_active`
(`tidelink_top.sv:917`) — see the full comment at `:900-916`. Gated by
`sim_gate_v2_mbox_writeprotect`.
:::

### Multi-hop chaining

Chaining PTP across more than one link is gated by
`parameter PHC_LOCK_GATE_EN` (default 0, `tidelink_top.sv:58`) acting on the
`phc_locked_i` input. **For a single-link deployment, tie `phc_locked_i` to
`1'b1`.**

`tidelink_phc_cdc` bridges six paths between `hclk` and `phc_clk` — see
{doc}`architecture`.

---

## 8. Error detection: what is caught, what is silent

### The protection mechanisms

| Mechanism | Scope | Where |
|---|---|---|
| **Link CRC** | one per long packet | generated in `lltx`, checked per FC node; error count at FC-node offset `0x20` |
| **Header ECC** | Hamming SEC/DED over the packet header | `WlinkEccSyndrome` |
| **Short-ID whitelist** | short packets only during framer bootstrap | `WlinkRxLinkLayer.v:1263-1277` |
| **`hunt_holdoff`** | framer bootstrap | `WlinkRxLinkLayer.v:63-66` |
| **Sticky overrun/underrun** | mailbox FIFO | `tidelink_fifo_ctrl.sv:474-503` |

**CRC can be turned off.** Each FC node's SM Control register (offset `0x14`)
has bit `[16] disable_crc`, POR 0 (`WlinkGenericFCSM_6.v:1194-1196`). Disabling
it saves 2 bytes per long packet. See {doc}`register_map`.

:::{danger}
**Header ECC is BYPASSED in this tree.** The `WlinkEccSyndrome` that all four
build flists compile
(`flists/tidelink_fpga.flist:179`, `tidelink_fpga_v2.flist:243`,
`tidelink_top_full_asic.flist:123`, `tidelink_top_full_asic_v2.flist:233` — all
pointing at `deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v`)
ends with a bring-up patch:

```verilog
// SoC Labs bring-up patch (2026-05-05): force ECC bypass.
// ... Bypass: accept ph_in as-is, never flag corruption, never claim correction.
// Real fix is to audit the syndrome polynomial vs the TX-side ECC RTL.
assign corrected_ph = ph_in;
assign corrected    = 1'h0;
assign corrupted    = 1'h0;
```

Consequences, all of them real:

1. **A corrupted packet header is not detected.** `ecc_check_corrupted` is
   constant 0, so `is_short_pkt` is never gated by it.
2. Both ECC counters are structurally dead: `0x2114[15:0]` (`ecc_corrupted`) and
   the Wlink Link-Interrupt bits `0x0240[8]` / `[16]` always read 0.
3. `0x2114[31:16]` was **repurposed** to a 16-bit saturating `sync_detected`
   count (SoC Labs, 2026-06-08) precisely because the ECC field was worthless.
   That field **is** live and useful — a read > 0 proves the RX assembled a
   coherent 128-bit SYNC word.

**This is tracked as TL-006** (`docs/BUG_REGISTRY.yaml:339-354`, severity high,
status `sim_proven`). The fix — a `_T` gate on the `syndrome == 0` clean case,
in a `src/rtl/local_overrides/WlinkEccSyndrome.v` — exists on branch
`integ/axirec-on-chiplet` @ `1aaed00` and is **not present on this branch**.
That override file does not exist in this checkout. See {doc}`known_issues`.
:::

### Detected versus silently dropped

The distinction follows directly from **what the CRC covers**. A Wlink data
packet is 13 bytes (`docs/ERROR_INJECTION_FINDINGS.md:329-334`):

| Byte(s) | Field |
|---|---|
| 0 | `data_id` |
| 1–2 | `word_count` |
| 3 | ECC over the 24-bit header |
| 4–10 | `ll.data[55:0]` — 48-bit app data + 8-bit FC packet number |
| 11–12 | CRC-16 |

and `rx_crc_computed = WlinkCrcGen(ll_rx.data)` covers **the whole 56-bit data
field and nothing else**.

Error injection is available at Wlink `0x023C` (inject `data_id`, byte, bit,
enable). The three interesting injection points behave very differently:

| Injected byte | Field | Outcome | Mechanism |
|---|---|---|---|
| **byte 0** | `data_id` | **Silent drop** | The CRC comparison is itself gated on `data_id === swi_data_id`, so a corruption that changes the `data_id` makes the packet *not a data packet* and it is **discarded before the CRC is ever consulted** (`docs/ERROR_INJECTION_FINDINGS.md:338-341`). Nothing counts a missing packet. |
| **byte 4** | `pktnum` | **Detected** | The FC packet number is inside the CRC-covered field and drives the expected-sequence check; `isNotExpPacket` asserts (`WlinkGenericFCSM_6.v:838`) and a NACK is requested. |
| **byte 5** | payload | **CRC only** | Inside the CRC-covered field. Caught provided `disable_crc` is 0; NACKed and replayed from the a2l FIFO. |

:::{warning}
**A byte-0 injection leaves no counter moving anywhere** — not `crc_errors`, not
the ECC counters (which are dead anyway, see the box above), not `fcsm`. The
only evidence is that the payload never arrives. That is what makes it the
sharpest test vector for the silent-corruption class, and it is why the wedge
detection recipe in §9 ends in a data canary rather than a register read.
:::

:::{caution}
**With the CRC inert, the only thing standing between a corrupted packet and the
RX FIFO is an address match in the FIFO controller**
(`docs/ERROR_INJECTION_FINDINGS.md` §4.3):

```verilog
// src/rtl/fifo/tidelink_fifo_ctrl.sv:146-166  (re-located since the report was
// written; the report cites :102-111 against an older revision of this file)
wire fc_write_valid    = fc_wr_valid && fc_wr_write && packet_active_r;
wire fc_write_complete = fc_write_valid && (fc_wr_addr == write_target_addr_r);
assign write_complete  = fc_write_complete || ahb_write_complete;
```

where
`write_target_addr_nxt = (packet_word_length_nxt + 1) << 2` (`:353`) and
`packet_word_length_nxt = clamp_length(fc_wr_wdata)` (`:298`) is latched from the
received header word's length field. The acceptance rule is therefore "commit
iff the number of words that actually arrived matches the length the header
claimed" — a **length** check, not an integrity check.
:::

---

## 9. Recovery and wedge detection

### What actually recovers, measured

`docs/LINK_RECOVERY_MECHANISM.md` (2026-07-18) ran a recovery ladder in
`cocotb/tidelink_error_injection/` under V2, `EPOCH_PROFILE=zero`,
`BYPASS_AUTONEG=1`, against three disturbance classes:

| Disturbance | Minimal recovery | Field-recoverable? |
|---|---|---|
| **W4** — lane-2 stuck-1 (a silicon-meaningful single-lane fault) | **none — self-heals after ~1 retry round** | yes |
| **W1** — all-lane corruption | **none — self-heals after ~3 retry rounds** | yes |
| **W2** — link-clock dropout | **POR of both dies** | **no — power cycle** |

Every firmware-reachable rung failed against W2: `SWI_RECAL`, SYNC beacon bursts
at R8 = `0x04`/`0x0C`/`0x1C`, a tolerance-opened beacon, LL `swreset` on one or
both dies, a full PHY retrain, and a single-die POR.

The self-healing of W1/W4 is consistent with the FC layer's own machinery: the
a2l replay FIFO plus the state-7 NACK watchdog `SOCL_L7_WDOG_THRESHOLD =
16'h4000` (`WlinkGenericFCSM_6.v:193`), which pulls a stuck state 7 back to 4
after 16384 cycles.

:::{caution}
**Two claims that were refuted by their own controls — do not re-derive them.**

1. **The SYNC beacon is non-causal** for the classes that recover. A
   matched-dwell zero-write control recovered at the same count
   (`LINK_RECOVERY_MECHANISM.md` §3).
2. **A forced beacon can destroy a still-working direction.** W2 m→s was healthy
   through rungs 0/a/b1 and died at the first `SWI_SYNC_FORCE_ALWAYS` burst
   (§2.2).
:::

### Wedge detection — the liveness recipe

Measured **identical** on healthy and wedged links, i.e. useless as a liveness
check (`LINK_RECOVERY_MECHANISM.md` §5): `fcsm` state (reads 4), `cal_done` /
`cr_seen` / `crack_seen` (1/1/1), the `llrx` framer state (0), EPOCH `0x2140`,
TX SYNC-insert count `0x2120`, RX SYNC-detect count `0x2124`, and `crc_errors`.

The **only** observable that moved is the a2l replay backlog
(`wptr − synced_ack`): healthy steady state is **exactly 1** outstanding;
wedged reads 9–16.

The two-stage recipe, as implemented in `recovery_common.is_link_alive()`:

1. **Cheap:** read the a2l backlog on both dies. More than 2 outstanding ⇒
   declare wedged.
2. **Definitive, and not optional:** a **tagged data canary** — drain both RX
   FIFOs, then send a payload carrying a value never previously sent in *each*
   direction, and require byte-exact receipt.

:::{important}
**The canary IS the check.** There is no register you can poll instead. Every
"the link is up, fcsm = 4" report on a V2 build is unfounded unless a
uniquely-tagged packet crossed and was compared.

**And re-probe before declaring a wedge.** Because W1/W4 self-heal over 1–3
probe rounds, a single failed canary is not a wedge — that is precisely the
error that made the original lane's results look like permanent wedges.
:::

Also excluded as misleading: `0x2144` (live-match) saturates and lies, and
`0x215C` `sync_seen` is retired in V2 and reads 0 by construction.

---

## 10. Performance characteristics

Only figures that can be cited from this repository appear here. No throughput
number is quoted that is not backed by a file.

| Quantity | Value | Source |
|---|---|---|
| Lanes | 8 data + 1 forwarded clock, single-ended | `tidelink_top.sv:51` (`NUM_PHY_LANES = 8`) |
| Link word | 128 bit, segmented 8 × 16 bit | `WavD2DGpio_v2.v:577` |
| FC word | 48 bit (2 + 14 + 32) | `tidelink_fc_adapter.sv:152-158` |
| Long TideLink packet | `data_id = 0xA1`, `word_count = 16'h7` | `WlinkGenericFCSM_6.v:773` |
| Mailbox capacity | 16 KB = 4096 credited 32-bit words, `MAX_PACKET_LEN = 4094` | `tidelink_fifo_ctrl.sv:110,242` |
| SYNC beacon tax | one SYNC every `SYNC_PERIOD = 32` words ⇒ **≈ 3 %** in continuous payload | `deps/tidelink-phy/rtl/tidelink_sync_word.svh:41-42` |
| CRC saving if disabled | 2 bytes per long packet, **≈ 9–20 %** of bandwidth depending on payload size | `docs/REGISTER_MAP.md`, carried into {doc}`register_map` |
| TX aperture rate | the adapter accepts **1 word per `hclk`** | `tidelink_tx_gen.sv:36-38` |
| PS→PL cost on FPGA | **≈ 96 PL cycles per word** of Zynq store round trip, against **≈ 16** needed by the link ⇒ **the link is ≈ 83 % idle** | `docs/TXGEN_V1_DESIGN.md:22-23` |
| TX stall backstop | `2^16` hclk ≈ **1.3 ms at 50 MHz** | `tidelink_fc_adapter.sv:41-44` |
| NACK watchdog | 16384 cycles (`16'h4000`) ≈ 660 µs at 100 MHz | `WlinkGenericFCSM_6.v:153,193` |
| PHC CDC cost | ~526 flops (~3200 gates) at `BYPASS_CDC = 0`; ~20 flops at `BYPASS_CDC = 1` | `tidelink_phc_cdc.sv:14-16` |
| Address-translator area | 8-rule CAM ≈ 169 flops/channel vs 2048 for a 256-entry table | `tidelink_addr_translator.sv:5-8` |

:::{warning}
**The measured per-word cost on a PS-driven FPGA workload is dominated by the
Zynq bridge, not the link.** Every link-side throughput improvement (FC
batching, deeper skid, address suppression) is therefore invisible to a
PS-driven benchmark. `tidelink_tx_gen` exists specifically to remove that
bottleneck from the measurement — it is the instrument, not an optimisation
(`docs/TXGEN_V1_DESIGN.md:21-27`).
:::

:::{note}
**Link bit rate is not specified in this repository.** `docs/` carries two
different FPGA bring-up figures — `~4.7–25 MHz` (`ARCHITECTURE_PHY_LINK.md:9`)
and `6.25 MHz` (`ARCHITECTURE.md:190,199`) — because bring-up deliberately runs
the bit cell slower to open the per-lane eye. The v1 ASIC target is 100 MHz
GPIO (UI = 10 ns, calibrator phase step ≈ 0.625 ns). Any end-to-end MB/s figure
for a specific board is **UNVERIFIED** here; measure it on your target with
`tidelink_tx_gen` armed.
:::

---

## See also

- {doc}`architecture` — module hierarchy, clocks, overrides
- {doc}`register_map` — every observability register named above
- {doc}`bringup` — the board-side bring-up procedures
- {doc}`verification` — the simulation gate that protects all of this
- {doc}`known_issues` — TL-006 header ECC, TL-001 peer-write drop, and the
  two-trees-diverge warning
