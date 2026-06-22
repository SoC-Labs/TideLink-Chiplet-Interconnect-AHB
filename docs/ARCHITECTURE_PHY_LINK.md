# TideLink Chiplet Interconnect — Architecture (PHY + Link Layers, As-Implemented)

> **Scope.** This document describes the **high-level components of the TideLink PHY and Link layers as actually implemented in RTL** (V2 path, `TIDELINK_PHY_V2=1`), so a hardware engineer can understand what exists, where it lives, and how data flows end-to-end. It cites `file:line` where the citation is load-bearing, distinguishes the **V2** path (current default build) from the legacy **V1** path, and flags **dormant / compiled-out** blocks. It is deliberately *component-level*, not line-by-line.

---

## 1. Overview

**TideLink** is a die-to-die (D2D) chiplet interconnect that carries AHB/AXI traffic between two chiplets over a **GPIO-style parallel PHY**: 8 single-ended data lanes plus a forwarded source-synchronous clock, running at a low link rate (~4.7–25 MHz on the FPGA rig, ~100 MHz on the TSMC ASIC target). The logical link is the Chisel-generated **Wlink** controller (CR/CRACK link-up handshake, credit-based flow control, ACK/NACK replay, ECC-protected framing). On top of Wlink, TideLink wraps a single **flow-control (FC) node** and an **`fc_adapter`** that maps an AHB-Lite write aperture into 48-bit FC words and commits inbound words into an RX FIFO.

The reference platform is a **PYNQ-Z2 FPGA pair** — `z2_02` (master) / `z2_01` (slave) — built from one bitstream with role chosen at runtime, plus a **TSMC65 ASIC** target. The current silicon-validated configuration runs a **reduced-lane mask `0xe4`** (4 active lanes) under **SW-driven, autoneg-off** bring-up.

The **V2 PHY** (the focus of the current build) adds three things over V1: (a) **cross-lane word-EPOCH deskew** with a content-only training-exit **epoch anchor**, (b) a **mask-aware SYNC beacon** (TX insert + RX detect) for mid-link byte-phase re-acquisition, and (c) a **lane-mask-aware eye-centre calibrator** plus an **autonomous word-pin matcher**. All of these are additive: with their enables defaulted off, the datapath is bit-identical to V1.

> **Critical build gotcha (from MEMORY):** rebuilds silently fall back to V1 if `TIDELINK_PHY_V2=1` is not defined — this was the root cause of a prior dead link. V1 and V2 share **module names** (`WavD2DGpio`, `tidelink_lane_deskew`, `tidelink_phy_align_calibrator`) and **must never co-compile**.

---

## 2. Component Hierarchy

Top-down instantiation tree (V2 / `pynq-z2-pair-all`). Siblings shown for the deskew, calibrator, fc_adapter, and replay FIFOs.

```
PS7 (Zynq) ── GP0 (control) ─→ APB  0x4403_0000
            └ GP1 (data)    ─→ AHB_TX 0x8400_0000 / RX FIFO 0x8401_0000
                              └ ahb_sub 0x4000_0000 (GP0, full addr fwd)
   │
   ▼
tidelink_top.sv  (chiplet subsystem wrapper; unified APB decode; data apertures)
   ├── tidelink_fc_adapter.sv ........... AHB-Lite ⇄ Wlink-app FC bridge (TX skid + RX commit)
   ├── tidelink_rx_fifo / RX FIFO RAM .... 0x8401_0000 readback
   ├── XHB500 bridges (u_xhb_sub/u_xhb_mng) + u_addr_translator
   ├── tidelink_idelay_rx.sv ............. per-lane IDELAYE2 tap bank (FPGA-only)
   │
   └── axi_chiplet_controller.sv (u_chiplet_controller)  [L3 glue]
         ├── Role register block + mask-HS role_lock gate
         ├── I2C master/slave + autoneg FSM ............ (present, BYPASSED on this build)
         ├── §9 lane_checker + tidelink_phy_align_calibrator (recovered-RX-clk)
         └── Wlink.v (u_wlink)  [Chisel link controller]
               ├── WlinkTxRouter / WlinkRxRouter ....... packet-bus arbiters
               ├── WlinkTxLinkLayer (lltx) ............. TX framer  → 128b io_link_data
               ├── WlinkRxLinkLayer (llrx) ............. RX framer  ← 128b post-deskew word
               ├── TideLinkToWlink (tl2wl)  ◀── THE FC node TideLink uses
               │     └── WlinkGenericFCSM_6 ............ CR/CRACK + credit + LINK_IDLE/DATA
               │           ├── WlinkGenericFCReplayV2_13  a2l (app→link, REPLAYABLE)
               │           ├── WlinkGenericFCReplayV2_12  l2a (link→app, no revert)
               │           └── ack_nack_fifo (WavFIFO_1)  rx_clk→tx_clk notifiers
               ├── AXI4ToWlink (axi2wl) ................ present, UNUSED on app port
               ├── GeneralBusToWlink (gb2wl) ........... present, UNUSED
               ├── ShortPacketToWlink (sp2wl) .......... present, UNUSED (sideband only)
               │
               └── WlinkGPIOPHY → WavD2DGpio.v  [V2 PHY top, deps/tidelink-phy]
                     ├── tidelink_phy_sync_insert ...... TX SYNC beacon (default passthrough)
                     ├── tidelink_phy_tx_segmenter ..... 128b → 8×16b
                     ├── tidelink_phy_tx_mask .......... zero disabled lanes' DATA
                     ├── WavD2DGpioTx ×8 (gpiotx_0..7) . per-lane serializer → pad_tx[N]
                     ├── WavD2DGpioRx ×8 (gpiorx_0..7) . per-lane deserializer ← pad_rx[N]
                     ├── tidelink_phy_rx_demask ........ zero masked lanes (pre-deskew)
                     ├── tidelink_lane_deskew.sv ....... CROSS-LANE word-EPOCH deskew (V2 core)
                     └── tidelink_phy_sync_detect ...... mask-aware RX SYNC detector (RO/re-hunt)
```

**Where the FC node connects up:** `TideLinkToWlink` flattens the FCSM's 48-bit app streams into `bore_1` (in) / `tl_bus_out_0` (out), and `tidelink_top.sv` wires those straight to `tidelink_fc_adapter`. Only the **tl2wl** node is on the data path; `axi2wl`/`gb2wl`/`sp2wl` are instantiated but their app ports are tied/unused.

---

## 3. PHY Layer (GPIO-style D2D, 8 lanes, V2)

### 3.1 Component table

| Component | File | Role |
|---|---|---|
| **WavD2DGpio** (PHY top) | `deps/tidelink-phy/rtl/wav/WavD2DGpio.v:33` | V2 PHY top: 8 TX + 8 RX lanes, cross-lane deskew, SYNC insert/detect, TX mask / RX demask. Presents a 128-bit `io_link_tx`/`io_link_rx` word interface to Wlink. |
| **WavD2DGpioTx** (TX leaf) | `…/wav/WavD2DGpioTx.v:85` | One per lane. Serializes a 16-bit word bit-by-bit onto `io_pad` via a `count`-keyed 16:1 mux; lane 0 forwards the /16 word clock as `io_pad_clk_tx`. |
| **WavD2DGpioRx** (RX leaf) | `…/wav/WavD2DGpioRx.v:84` | One per lane. Deserializes `io_pad` using the shared `pad_clk_rx`; applies sub-bit **phase**, post-capture **bit-slip**, and the **word-pin** window. |
| **RX recovered-clock gen** | `…/wav/WavD2DGpioRx.v:543` | Splits clock buffering into a **capture axis** (`USE_CAP_CLKBUF`) and a **link-clock axis** (`USE_LNK_CLKBUF`, from free-running `~count[3]`). |
| **tidelink_idelay_rx** | `src/rtl/tidelink_idelay_rx.sv:79` | FPGA-only IDELAYE2 tap bank between `pad_rx[*]` and the RX leaves; per-lane delay driven by calibrator phase. |
| **tidelink_lane_deskew** | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:168` | **V2 core.** 8 per-lane write FIFOs + one common read pointer → re-aligns 8 lanes into one coherent 128-bit word (prime-and-continuous occupancy + content-only EPOCH anchor). |
| **tidelink_phy_align_calibrator** | `deps/tidelink-phy/rtl/tidelink_phy_align_calibrator.sv:211` | Per-lane (slip × phase) eye-centre FSM; asserts `training_mode`, sweeps the 128-point grid, selects eye centre, releases. Outputs `bit_slip[23:0]`, `phase_offset[31:0]`. |
| **tidelink_phy_sync_insert** | `deps/tidelink-phy/rtl/tidelink_phy_sync_insert.sv:32` | TX SYNC beacon: overrides one idle word with `SYNC_WORD` every `SYNC_PERIOD`. **Default-off → pure passthrough.** |
| **tidelink_phy_sync_detect** | `deps/tidelink-phy/rtl/tidelink_phy_sync_detect.sv:1` | RX mask-aware SYNC detector on the **post-deskew** word; ANDs only masked-in lanes (Hamming tolerance). Read-only observability + optional robust re-hunt. |
| **tx_segmenter / tx_mask / rx_demask** | `…/tidelink_phy_tx_segmenter.sv:22`, `…_tx_mask.sv:41`, `…_rx_demask.sv:32` | Combinational lane front-end. Segmenter: 128b → 8×16b (lane `i = [16*i +: 16]`). Mask: zero a disabled lane's **DATA** (training still TX'd). Demask mirrors pre-deskew. |

### 3.2 TX path (this die → wire)

Wlink presents `io_link_tx_tx_link_data[127:0]` + `io_link_tx_tx_lane_mask[7:0]` in the TX link-clock domain (`io_hsclk/16`):

```
 io_link_tx (128b) + lane_mask
        │
        ▼
 [1] tidelink_phy_sync_insert   ── optionally overrides ONE idle word with SYNC_WORD
        │                          (tx_sync_en_w, WavD2DGpio.v:522; default passthrough)
        ▼
 [2] tidelink_phy_tx_segmenter  ── 128b → 8 × 16b  (lane0 = LSBs)
        │
        ▼
 [3] tidelink_phy_tx_mask       ── masked (disabled) lane's DATA word → 0
        │                          (bit 1 = lane enabled = pass)
        ▼  8 × 16b
 [4] WavD2DGpioTx ×8            ── each lane: count-keyed 16:1 mux serializes 16b → io_pad_tx[N]
        │                          training_mode=1 ⇒ {training_pattern,training_pattern}
        ▼                          lane 0 also drives io_pad_clk_tx (the /16 strobe)
   io_pad_tx[7:0] + io_pad_clk_tx  ──→ 8 GPIO lanes + forwarded clock
```

**Order deviation (documented):** the TX mask is applied **before** the per-lane training mux inside `WavD2DGpioTx`, so a masked lane **still transmits its training pattern** — the mask only zeroes *data* words. Per-lane training bytes are wired at the instances (`0xA3,0xB5,0xC9,0xD3,0x65,0x4B,0x59,0x2D`); V2 also passes a full `TRAINING_WORD16` (`0x12EB` even / `0xED14` odd). The training↔data mux switch is latched at `count==4'hf` (clean 16-bit word boundary, `WORD_ALIGN_MUX`, tdif-03).

### 3.3 RX path (wire → this die)

```
 io_pad_rx[7:0]  + io_pad_clk_rx (peer's forwarded clock)
        │
        ▼  (FPGA only)
 [1] tidelink_idelay_rx        ── per-lane IDELAYE2 tap (calibrator phase ×2 → sub-UI delay)
        │
        ▼
 [2] WavD2DGpioRx ×8           ── deserialize per lane in pad_clk_rx domain:
        │                          • io_phase_offset (sub-bit, adj_count) at capture
        │                          • io_bit_slip     (post-capture rotation)
        │                          • word-pin window (manual OR training-derived auto matcher)
        │                          → 16b recovered word on gpiorx_N_io_link_clk (= ~count[3] /16)
        ▼  8 × 16b (phase-skewed clocks)
 [3] tidelink_phy_rx_demask    ── zero masked lanes
        │
        ▼
 [4] tidelink_lane_deskew      ── 8 per-lane write FIFOs (each in its gpiorx_N clock)
        │                          → one common read pointer on gpiorx_0's clock
        │                          → re-aligned coherent deskew_aligned_data[127:0]
        ▼
   io_link_rx_rx_link_data[127:0]  on gpiorx_0_io_link_clk  ──→ Wlink RX framer
        │
        └── tapped by tidelink_phy_sync_detect (mask-aware) + rawobs decoder (read-only)
```

The **calibrator runs in parallel**, sweeping each lane's `(slip, phase)` against the `lane_checker` to find each lane's eye centre, holding `training_mode` until release.

### 3.4 The deskew engine (V2 core, in detail)

`tidelink_lane_deskew` (`…:168`) is **the central V2 addition**. Instanced from `WavD2DGpio.v:666` with `LANES=8, WIDTH=16, DEPTH_LOG=5` (32 entries), `EPOCH_ANCHOR_EN=1`, `SYNC_REANCHOR_EN=0` (dormant), `EPOCH_MATCH_THRESH=5`.

- **Occupancy deskew (always on):** Each lane writes into its own FIFO in its own RX link clock. Per-lane write pointers are Gray-coded and CDC'd to the read clock (`gpiorx_0`). Read waits for **all_primed** (≥ `PRIME_THRESH=5` words/lane), then advances **one word per `out_clk`**, gated by `all_ready = &(lane_has_data | ~lane_mask)`.
- **EPOCH anchor (content-only):** Each lane detects the peer's pattern→data Hamming-streak exit (`EPOCH_STREAK_MIN=8`, `EPOCH_EXIT_CONFIRM=2`) and latches its write index. The read side 2-flop-syncs these, and when `ep_all_fresh` + `EPOCH_SETTLE=32` quiet beats + `span ≤ EPOCH_OFF_MAX(=24)` hold, it loads per-lane **backward** read offsets (`rd_ptr_l[gi] = rd_ptr − lane_off`, `…:841`). Span-reject self-heals to zero-offset.
- Exposes `epoch_anchored_o` + `epoch_span_o`.

> **Why `EPOCH_MATCH_THRESH` was relaxed 3→5** (silicon fix, see inline note at the instance): die_a's skewed RX lanes **LOCK** at Hamming distance 4–5 but never satisfied a stricter epoch match — so the streak never built and the anchor never fired. The matcher must accept exactly what the lane-checker LOCK accepts.

### 3.5 PHY key params & registers

| Param (WavD2DGpio) | Value | Meaning |
|---|---|---|
| `USE_CLKBUF` | `0` | Deprecated combined alias (sim/ASIC prunes BUFGs → bit-exact) |
| `USE_CAP_CLKBUF` | `0` | **Per-lane capture BUFGs pruned**; BD does ONE shared `IBUFG→BUFG` on `pad_clk_rx` (commit `10563e3`) |
| `USE_LNK_CLKBUF` | `=USE_CLKBUF` | Per-lane BUFG on free-running `~count[3]` (glitch-immune to phase) |
| `USE_T3A` | `0` | Per-lane comma-hunt re-align FSM **dead** (byte-counter framing, no SOP) |
| `WORD_PIN_AUTO` | `1` | Autonomous training-derived word-pin matcher |
| `EPOCH_ANCHOR_EN` | `1` | Content-only training-exit anchor enabled |
| `USE_IDELAY` | `1` (FPGA via component.xml) | IDELAYE2 tap bank active |

**SYNC:** `TIDELINK_SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00`, `SYNC_PERIOD=32`. **Deskew:** `DEPTH_LOG=5`, `PRIME_THRESH=5`, `EPOCH_OFF_MAX=24`, `EPOCH_SETTLE=32`. **Calibrator:** `DWELL_CYCLES=64`, `LOCK_THRESH=16`, `min_lock_dwells` default 2 (APB-overridable). **Reduced-lane mask:** `0xe4` (disables lanes 0,1,3,4; keeps 2,5,6,7).

**Proven link-up recipe (MEMORY):** POR → autonomy-off (`0x210C=0`) → mask `0xe4e4` → per-lane-AUTO word-pin (`0x104=0`, *not* word-pin5) → SYNC mask+tol5 (`0x128=0x5e4`) → R8=`0x1D` (train+sync_insert+force_always+robust_detect) → recal; dwell ~18 s. Link-up is a **marginal-eye lottery**: die_b SRCC jitter pins its eye at width 2 while die_a MRCC eye is 16.

---

## 4. Link Layer (Wlink controller + TideLink FC adapter)

### 4.1 Component table

| Component | File | Role |
|---|---|---|
| **tidelink_fc_adapter** | `src/rtl/tidelink_fc_adapter.sv:34` | AHB-Lite ⇄ Wlink-app bridge. TX: latches AHB-TX writes → 48-bit FC words → 1-entry skid → FC node. RX: 3-state FSM replays inbound 48-bit words as RX-FIFO writes / APB-sideband / TideChart. |
| **Wlink** | `src/rtl/local_overrides/Wlink.v:42` | Chisel-generated link controller top: app ingress/egress adapters, TX/RX routers, lltx/llrx framers, the GPIO PHY. TideLink uses only the tl2wl node. |
| **TideLinkToWlink** (tl2wl) | `src/rtl/local_overrides/TideLinkToWlink.v:1` | Wraps one `WlinkGenericFCSM_6`; exposes 48-bit a2l/l2a as flattened `bore_1` / `tl_bus_out_0`. |
| **WlinkGenericFCSM_6** | `src/rtl/local_overrides/WlinkGenericFCSM_6.v:174` | The FC node heart: 8-state FSM (CR/CRACK + credit + ACK/NACK + LINK_IDLE→DATA send-gate). Hosts a2l/l2a replay FIFOs. |
| **WlinkGenericFCReplayV2_13** (a2l) | `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v:1` | TX app→link **replayable** FIFO (revert/ack for NACK retransmit), async Gray-pointer CDC. |
| **WlinkRxLinkLayer** (llrx) | `src/rtl/local_overrides/WlinkRxLinkLayer.v:66` | RX byte-align/packet framer: byte-counter FSM, header ECC, short/long classify, V2 in-band SYNC re-align. |
| **WlinkTxLinkLayer** (lltx) + **ShortPacketToWlink** (sp2wl) | `src/rtl/local_overrides/Wlink.v:1469` | lltx serializes routed packets → 128b `io_link_data`; sp2wl is a sideband-only node (not the data path). |

### 4.2 TX path (host write → wire)

```
 AHB-TX aperture write (0x8400_0000)
        │
        ▼
 tidelink_fc_adapter:
   latch addr+data → 48-bit FIFO_DATA word {00, addr_offset, data}
   arbiter: returner-sideband > servo > TX-aperture  (MAX_SIDEBAND_BURST=4)
   1-entry skid:  skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready   (sv:469)
                  tl_fc_a2l_valid = skid_valid_r                       (sv:488)
        │  drains when tl_fc_a2l_ready
        ▼
 Wlink bore_1 → TideLinkToWlink → FCSM io_app_a2l
        │
        ▼
 a2l REPLAY FIFO (WlinkGenericFCReplayV2_13)   ── app_clk(hclk) → link_clk CDC
   app_ready = ~a2l_full & app_enable           → word becomes a2l_fc_replay_link_valid
        │
        ▼
 FCSM state 4 (LINK_IDLE):
   ┌─────────────────────────────────────────────────────────────┐
   │  SEND GATE  _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full │  (FCSM:675)
   └─────────────────────────────────────────────────────────────┘
        │ true ⇒ state 5 (LINK_DATA): frame long pkt
        │        data_id = swi_data_id_1 (0xa1), word_count = 16'h7  (FCSM:680)
        │        link_data = {a2l_replay_link_data, cur_addr}
        ▼
 txrouter → lltx → 128b io_link_data → WlinkGPIOPHY → WavD2DGpio TX → 8 GPIO lanes
```

### 4.3 RX path (wire → host)

```
 8 GPIO lanes + pad_clk_rx
        │
        ▼  (PHY capture + cross-lane deskew → 128b post-deskew word)
 WlinkRxLinkLayer (llrx):
   byte-counter framer; hunt_holdoff = 63 link_clk post-reset (tdif-08)
   header ECC (WlinkEccSyndrome); short/long classify; id whitelist {0x44,0x45,0x46,0x47}
   V2 SYNC re-align: sync_detected = (io_link_data == SYNC_WORD) → STRIP to idle + sync_resync
        │
        ▼
 rxrouter → peer FCSM l2a REPLAY FIFO (WlinkGenericFCReplayV2_12)  ── link_clk → app_clk CDC
        │  io_app_l2a_valid
        ▼
 peer Wlink tl_bus_out_0 → peer fc_adapter RX FSM:
   rx_accept = tl_fc_l2a_valid & RX_IDLE & ~rx_pending_r   (sv:538)
   decode pkt_type:
     00 FIFO_DATA → single-cycle direct write fc_rx_fifo_* (addr = addr_offset)
     01 SIDEBAND  → drives APB master (psel/penable)
     10 PKT_EXT   → TideChart AXIS
        │
        ▼
 RX FIFO memory  ──→ readable at ahb_fifo (0x8401_0000, GP1) or ahb_sub window (0x4000_0000, GP0)
```

**Credit / replay:** the receiver FCSM emits **ACK (0x46)** packets that advance the sender's credit ring; on **NACK (0x47)** the sender's a2l replay FIFO rewinds via `link_revert`. `fc_rx_is_first = data & addr_offset==0` marks a burst start.

### 4.4 The FC node FSM (the heart)

`WlinkGenericFCSM_6` runs an 8-state (3-bit) machine: `0` reset/ack-seen, `1` emit-CR, `2` emit-CRACK, `3` transition, `4` **LINK_IDLE**, `5` **LINK_DATA**, `6` SEND_ACK, `7` SEND_NACK.

- **Handshake packets:** CR `data_id=0x44`, CRACK `0x45`, ACK `0x46`, NACK `0x47`. CR/CRACK carry `word_count=16'h1f1f`, which **loads `fe_tx/rx_credit_max`**.
- **Send gate (THE key transition):** `_T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full` (`FCSM:675`). When true in state 4, the FSM advances to state 5 and emits a long data packet (`data_id=0xa1`, `word_count=7`).
- **`fe_rx_is_full`** (`FCSM:498`) is a credit-ring-full compare (`ne_rx_ptr_next` vs `fe_rx_ptr` modulo `fe_rx_credit_max_txsync`). It **only flags `credit==0`** — a credit value garbled to a *small nonzero* passes the gate and exhausts after 1–4 packets (the documented ~40% CR-credit-decode lottery; must be read via `OBS_FC_CREDIT 0x219C`, not `0x2108[31]`).

**SoC Labs FCSM fixes layered in:** L6 `SOCL_L6_MIN_CR_EMITS=32` (min-CR-hold, asymmetric bring-up); L7 `SOCL_L7_MIN_CRACK_EMITS=32` (symmetric deadlock); L7 state-7 watchdog `SOCL_L7_WDOG_THRESHOLD=16'h4000` (drain spurious NACKs); L9 spurious-`exp_pkt` mask; `SOCL_REACK_THRESHOLD=16'h0100` (credit recovery); Bug-C `fe_rx_credit_max_txsync` CDC fix. Internally **three clock domains:** `io_app_clk`(=hclk), `io_tx_clk`(=link_clk), `io_rx_clk`(recovered RX).

### 4.5 Link key params & registers

**FC word:** 48-bit `{pkt_type[47:46], addr_offset[45:32], payload[31:0]}` — `00`=FIFO_DATA, `01`=SIDEBAND, `10`=PKT_EXT(TideChart). **data_id:** `0xa1`=data, `0x44`/`0x45`/`0x46`/`0x47`=CR/CRACK/ACK/NACK. **fc_adapter:** `TX_STALL_TIMEOUT_LOG2=16` (~1.3 ms @50 MHz → AHB ERROR rather than hang). **llrx:** `short_packet_max=0x7F`, `hunt_holdoff=63`, ids hard-tied `0x44/0x45/0x46/0x47`.

**Key OBS registers** (APB base `0x4403_0000`):
- `0x2108` **SWI_LANE_STATUS** — `[7:0]` lane_locked, `[15:8]` fault, `[16]` cal_done, `[19:17]` **fcsm_state** *(RTL packing — authoritative)*, `[22:21]` llrx_state, `[23]` cr_seen, `[24]` crack_seen, `[30]` **a2l_fc_replay_link_valid** (send app-valid gate), `[31]` **fe_rx_is_full** (send credit gate, ==0 only).
- `0x2158` **OBS_A2L** — `[0]` a2l_replay_app_ready, `[1]` a2l_replay_link_empty (localizes app-stuck vs CDC-crossed-but-stalled).
- `0x219C` **OBS_FC_CREDIT** — `[7:0]` fe_rx_credit_max, `[15:8]` fe_rx_ptr, `[16]` is_full mirror, `[31:24]` presence `0xFC`.

---

## 5. Clock & Reset Domains

### 5.1 Clock domains

```
 clk_wiz (1 MMCM, 3 outputs)
   ├─ clk_out1 ──┬─ hclk = apb_clk = app_clk   ── L3/AHB/APB/XHB500/fc_adapter/FIFO/role/cal-ctrl
   │             ├─ user_ref_clk = user_hsclk   ── PHY hi-speed clock (pad clk 1:1 on this target)
   │             └─ scan_clk
   │                  │  /16 (inside PHY + FCSM)
   │                  ▼
   │             link_clk = io_hsclk/16  ── lltx, txrouter, FCSM io_tx_clk,
   │                                          a2l/l2a replay-FIFO READ side, sync_insert/segmenter/mask
   ├─ clk_out2 ── phc_clk (25 MHz)  ── PHC REMOVED from BD; pin still driven
   └─ clk_out3 ── 200 MHz  ── IDELAYCTRL ref only

 pad_clk_rx  (peer's forwarded clock, recovered)
   └─ ONE shared IBUFG→BUFG → pad_clk_rx_buf   (USE_CAP_CLKBUF=0)
        │  per-lane capture of io_pad_rx[N] in WavD2DGpioRx
        ▼
   gpiorx_N_io_link_clk = ~count[3] (free-running /16, phase-independent)
        │  per-lane clocks are phase-skewed from each other
        ▼
   gpiorx_0_io_link_clk  ◀── deskew out_clk = the single RX-link domain
        └── framer (llrx), lane_checker, calibrator, SYNC detector, all RX OBS
```

Three principal PHY domains: **(1) TX link-clock** `io_hsclk/16`; **(2) RX capture** `pad_clk_rx` (one shared BUFG to cut die_b SRCC jitter — slave `pad_clk_rx` is a Y7-MRCC, not Y9-SRCC, pin); **(3) RX link-clock** `gpiorx_0_io_link_clk`. The deskew CDC (Gray write pointers + 2-flop epoch sync) crosses each per-lane RX clock into `gpiorx_0`'s domain. **All PHY/link observables** (epoch, sync_seen, fcsm_state, credit) are **2-flop synced into `apb_clk`** in `axi_chiplet_controller.sv`.

> **FPGA quirk:** `clk_out1` feeds `hclk`, `user_ref_clk` **and** `scan_clk` off one net — link/pad rate is **1:1 with hclk** on this target (differs from the ASIC 250 MHz / ÷16 model).

### 5.2 Reset tree

```
 proc_sys_reset/peripheral_aresetn
   └─ on FPGA fans to hresetn == poresetn == phc_resetn (BD ties all three)
        │      ⇒ warm/POR distinction collapses; role_lock clears on ANY reset here
        ▼
 axi_chiplet_controller.sv:
   apb_reset      = ~hresetn                        (alive PRE-lock so SW can drive the recipe)   :416
   wlink_por_reset = ~poresetn | ~role_locked       (holds Wlink in POR until role latches)       :1730
   app_clk_reset   = ~hresetn | ~role_locked        (COHERENT-RELEASE fix, 2026-06-21)            :1732
        │              └── mirrors wlink_por_reset's ~role_locked gating so the a2l replay FIFO's
        │                  WRITE (app) and READ (link) sides deassert on the SAME bring-up event
        │                  → Gray ACK-pointer synchronizer initializes consistently
        ▼
 role_locked = role_lock_reg   (POR-only domain; latches via ROLE_CFG[1] W1S
                                 when mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i | apb_debug_unlock_i)
 i2c_mst_reset / i2c_slv_reset  ── hold the inactive core in reset by role
```

The **`role_locked` gate is the master switch**: until `ROLE_CFG[1]` is written (W1S), `wlink_por_reset` and `app_clk_reset` hold Wlink and the a2l write side in reset. On this build `apb_debug_unlock_i=1` + `mask_hs_bypass_i=1` are forced, so SW latches `role_lock` **without** the I2C peer-mask handshake (autoneg-off bring-up).

> **Recently-fixed coherent reset (2026-06-21):** `app_clk_reset` was changed from a plain `~hresetn` to `~hresetn | ~role_locked` so the replay FIFO's app/link reset domains deassert together — see the inline comment block at `axi_chiplet_controller.sv:417/1731`.

---

## 6. End-to-End Data Path (host AHB write → peer RX FIFO)

Every block and the key gates, in order:

```
 1. PS M_AXI_GP1 → axi_smc_data → axi_ahb_tx bridge → tidelink_0/ahb_tx  (SoC 0x8400_0000, RAM_ADDR_W=14)
 2. tidelink_fc_adapter: build 48b FIFO_DATA word {00, addr_offset, data}
       arbiter (returner > servo > TX-aperture) → 1-entry SKID
       GATE: skid_can_accept = ~skid_valid_r | tl_fc_a2l_ready           (fc_adapter.sv:469)
 3. tl_fc_a2l_valid/data[47:0]/ready → Wlink bore_1 → TideLinkToWlink → FCSM io_app_a2l
 4. a2l REPLAY FIFO (WlinkGenericFCReplayV2_13)
       GATE/CDC: app_clk(hclk) → link_clk; app_ready = ~a2l_full
       output: a2l_fc_replay_link_valid (link side)
 5. WlinkGenericFCSM_6 state 4 (LINK_IDLE):
       GATE: _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full           (FCSM:675)
       ── ~fe_rx_is_full = CREDIT available (==0 catch only; see §4.4 caveat)
       true ⇒ state 5: frame long pkt (data_id=0xa1, word_count=7)
 6. txrouter → lltx (header ECC + CRC) → 128b io_link_data
 7. WlinkGPIOPHY → WavD2DGpio TX: sync_insert(passthrough) → segmenter → mask → 8× serialize
       → pad_clk_tx + 8× pad_tx
 ───────────────────────────  WIRE (8 GPIO lanes + fwd clk)  ───────────────────────────
 8. peer pad_clk_rx (shared BUFG) + 8× pad_rx (IDELAY) → WavD2DGpioRx ×8 (phase/slip/word-pin)
 9. tidelink_lane_deskew: re-align 8 lanes → coherent 128b post-deskew word (epoch anchor)
10. WlinkRxLinkLayer (llrx): byte-align FRAMER + ECC + id-whitelist + V2 SYNC re-align
11. rxrouter → l2a REPLAY FIFO (WlinkGenericFCReplayV2_12)
       CDC: link_clk → app_clk; output io_app_l2a_valid
12. peer Wlink tl_bus_out_0 → peer fc_adapter RX FSM
       GATE: rx_accept = tl_fc_l2a_valid & RX_IDLE & ~rx_pending_r        (fc_adapter.sv:538)
       decode FIFO_DATA → single-cycle direct write fc_rx_fifo_* (addr = addr_offset)
13. RX FIFO memory  ──→ readable at ahb_fifo (0x8401_0000, GP1) / ahb_sub window (0x4000_0000, GP0)

 Credit return (reverse): receiver FCSM → ACK(0x46) advances sender credit ring.
 Replay (reverse): NACK(0x47) → a2l link_revert rewinds the sender's read pointer.
```

**The two send gates that pin most bring-up failures:** `0x2108[30]` (`a2l_fc_replay_link_valid` — is there a word to send?) and `0x2108[31]` (`fe_rx_is_full` — is there credit?). Both visible in `SWI_LANE_STATUS`; credit *value* (vs. just ==0) must be read at `OBS_FC_CREDIT 0x219C`.

> **Bug-A history (load-bearing):** the fc_adapter's old "wedge watchdog" silently dropped burst beats by forcing `HREADY` while the skid was full. That is **removed**; the adapter now applies honest back-pressure and, after `TX_STALL_TIMEOUT_LOG2=16` hclk, terminates the beat with a bounded 2-cycle AHB **ERROR** rather than hanging the PS AXI. `tx_dropped_cnt_r` is observability-only (must read 0 healthy).

---

## 7. Register Map Summary

**Control plane — APB, SoC base `0x4403_0000` (GP0), 15-bit PADDR decoded by `paddr[14:13]`:**

| Region | SoC addr | Contents |
|---|---|---|
| Wlink own | `0x0000–0x1FFF` | `0x0208` Enable/Reset (SWI_enable POR=1); **`0x0214` Lane Mask** TX `[15:0]`/RX `[31:16]` (POR `0xFF`; reduced-lane writes `0xe4`) |
| R0 | `0x2000` | config/status (PAIR_BASE / RELEASE_THRESHOLD / STATUS / CTRL.LOCK) |
| R4 | `0x2080` | **ROLE_CFG** `[0]`=role / `[1]`=role_lock-W1S; ROLE_STATUS; I2C_SLV_ADDR (`0x7E`); I2C_PRESCALE (`125`); NEGO_CFG (POR `0x00`), NEGO_STATUS/PRIORITY/TIMEOUT — *(POR-only reset domain)* |
| R8 | `0x2100` | **SWI_TRAINING_MODE** `[0]`=mode/`[1]`=recal; V2 `[2]`=SYNC_INSERT_EN, `[3]`=SYNC_FORCE_ALWAYS, `[4]`=SYNC_ROBUST_DETECT, `[5]`=SYNC_OBS_CLR. `0x2104` SWI_BIT_SLIP_LO (V2 `[27:24]`=word-pin, `[28]`=auto-disable). **`0x2108` SWI_LANE_STATUS** (see §4.5). `0x210C` NEGO_TRAIN_CFG (`[0]`train_auto_en, `[23:20]`MIN_LOCK_DWELLS). `0x2114` SYNC_DET/ECC (`[31:16]`=sync_detected sat-cnt = coherent-deskew health). `0x211C` PHY_ALIGN_ID=`0x5041_0100` |
| R9 *(V2-only)* | `0x2120–0x213F` | SYNC bank — `0x2128` `[7:0]`=SWI_SYNC_LANE_MASK (POR `0xFF`), `[12:8]`=SWI_SYNC_TOL (Hamming, POR 0=exact); slots 3..7 SYNC-OBS RO |
| R10 *(V2-only)* | `0x2140–0x214F` | `0x2140`=**SWI_EPOCH_STATUS** RO (`[0]`=epoch_anchored, `[6:1]`=epoch_span); `0x2144` live SYNC oracle; `0x2148/0x214C` per-lane word-pin value/enable |
| RC | `0x2180–0x219C` | autoneg/credit OBS RO; **`0x219C` OBS_FC_CREDIT** |
| addr-xlat | `0x4000–0x5FFF` *(via paddr[14:13]=10)* | CAM-based APB-configurable remap |

**Data plane — GP1 (+ GP0 for ahb_sub):**

| Aperture | SoC addr | Bus | Notes |
|---|---|---|---|
| AHB_TX | `0x8400_0000` | GP1 | host writes FC packets |
| RX FIFO | `0x8401_0000` | GP1 | inbound FIFO_DATA readback |
| ahb_sub | `0x4000_0000` | GP0 | transparent window; **full address forwarded over the link** (peer decodes) — must stay on GP0 |
| Strap / debug-unlock GPIO | `0x4404_0000` / `0x4404_1000` | — | role strap bit0 / debug-unlock |

> GP0 (control) and GP1 (data) are **independent PS7 ordering domains**, so a wedged AHB_TX write on GP1 cannot stall APB polls on GP0.
>
> **RTL/RDL divergence:** `tidelink_regs.rdl` documents an older `SWI_LANE_STATUS` packing (`fcsm_state` at `[20:17]`); the **RTL packing** (`fcsm_state [19:17]`) above is authoritative. Same for `NEGO_PRIORITY` reset.

---

## 8. V1 vs V2, and Dormant / Compiled-Out Blocks

### 8.1 V1 vs V2

**V2** = the `deps/tidelink-phy/rtl` fork compiled by `flists/tidelink_fpga_v2.flist` with `TIDELINK_PHY_V2` defined (the deps `WavD2DGpio.v`/`Rx`/`Tx` are pulled at flist L151–153). V2 **adds**: (a) cross-lane word-EPOCH deskew + training-exit epoch anchor; (b) the mask-aware SYNC beacon (insert + detect); (c) the lane-mask-aware eye-centre calibrator; (d) the autonomous word-pin matcher (`WORD_PIN_AUTO`).

**V1** = `flists/tidelink_fpga.flist`, which compiles `src/rtl/local_overrides/{WavD2DGpio.v, tidelink_lane_deskew.sv, tidelink_phy_align_calibrator.sv}` — **same module names**, must **never co-compile** with V2. The link layer's patched modules (`Wlink.v`, `WlinkGenericFCSM_6.v`, `WlinkRxLinkLayer.v`, `TideLinkToWlink.v`, `ShortPacketToWlink.v`) come from `src/rtl/local_overrides/` in **both** flists (the deps originals are commented out).

> **Silent-V1 hazard (MEMORY):** if `TIDELINK_PHY_V2=1` is not set, the build silently uses V1 — this was the root cause of a prior dead link. Always verify the flist/define.

### 8.2 Dormant / compiled-out in the current V2 build

**PHY:**
1. `SYNC_REANCHOR_EN=0` — the deskew's SYNC-beacon mid-stream re-anchor is generate-pruned (proven net-harmful: shifts an already-locked link at the training→data transition). The content-only EPOCH anchor replaces it.
2. `USE_T3A=0` — the per-lane RX comma-hunt re-align FSM is parameter-gated off (RX is byte-counter framing, no SOP delimiter).
3. `USE_CAP_CLKBUF=0` — per-lane capture BUFGs pruned for one shared BD BUFG.
4. **SYNC insert + force_always default 0** → on a default-V2/V1 build the TX SYNC inserter is a pure passthrough and the RX SYNC detector counters stay quiescent; all rawobs/permutation-decoder taps are read-only, bit-identical to V1.
5. `S_PROBE` in the calibrator is **demoted to advisory** in centering mode (`min_lock_dwells_i != 0` bypasses it).

**Link:**
6. `axi2wl` / `gb2wl` / `sp2wl` FC-node ingress adapters are instantiated in `Wlink.v` but **unused** — TideLink wires only **tl2wl**.
7. `io_robust_sync_seen` RX re-hunt OR-term is **default-off** (`SWI_SYNC_ROBUST_DETECT=0`): out of the box the framer re-hunts only on the exact full-128 `SYNC_WORD`, so V2 SYNC re-align is bit-identical to V1 framing until SW arms robust detect.
8. Do **not** conflate the a2l buffer (`…ReplayV2_13`, **with** revert) with the l2a buffer (`…ReplayV2_12`, **no** revert).

**Integration / BD:**
9. `tidelink_eye_regs` (Region 10 eye-vis) is `` `ifndef TIDELINK_PHY_V2 `` only — **absent in V2** (RAZ-tied at `tidelink_top.sv:858`; Region 10 repurposed for word-pin/sweep + `SWI_EPOCH_STATUS`).
10. **PHC/PTP/servo subsystem + PMOD-B cross-board trigger REMOVED** from the BD (2026-06-19) for xc7z020 slice headroom (`phc_clk` pin still driven; `0x4402_0000` segment dropped). `STUB_SERVO/STUB_PERF/STUB_PTP` params exist for ILA-debug builds (default 0).
11. **ILA cores removed** (2026-05-19) — incompatible with the real IDELAYE2 IDATAIN route; this is the **no-ILA build** with `mark_debug`/`dbg_hub` scaffolding stripped.
12. `ahb_mng` (Wlink AXI initiator out) unconnected in pair-all.
13. **Autoneg is OFF:** `NEGO_CFG_RESET=7'h00`; `apb_debug_unlock_i=1` + `mask_hs_bypass_i=1` are forced so SW W1S of `ROLE_CFG[1]` latches `role_lock` **without** the I2C peer-mask handshake. The whole I2C master/slave + autoneg-FSM + mask-handshake machinery is present but bypassed (reduced-lane SW-driven recipe).

### 8.3 Build/silicon gotchas

- On FPGA `poresetn == hresetn == peripheral_aresetn` (BD ties all three) — the "role survives warm reset" POR-only domain has **no separate reset source here**; `role_lock` clears on any reset.
- `USE_IDELAY` / `USE_CLKBUF` / `USE_T3A` are **0 in RTL** and set to 1 **only via the packaged IP `component.xml`** — never by a define. Reading RTL defaults understates the FPGA build.
- `AUTOCAL_ENABLE` defaults 0 in the controller but `tidelink_top` hardwires 1 for FPGA/ASIC.
- **Capture-clock skew is the dominant real-silicon issue:** die_b SRCC (Y9) jitter holds its eye at width 2 (marginal capture); link-up is a "marginal-eye lottery." The `EPOCH_MATCH_THRESH` 3→5 relax and the single-shared-BUFG capture path both exist to fight this.

---

*Authoritative source files: PHY `deps/tidelink-phy/rtl/{wav/WavD2DGpio*.v, tidelink_lane_deskew.sv, tidelink_phy_align_calibrator.sv, tidelink_phy_sync_{insert,detect}.sv}`; link `src/rtl/{tidelink_fc_adapter.sv, local_overrides/{Wlink.v, WlinkGenericFCSM_6.v, WlinkRxLinkLayer.v, TideLinkToWlink.v}}` + `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCReplayV2_13.v`; integration `src/rtl/{tidelink_top.sv, local_overrides/axi_chiplet_controller.sv}` + `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`; flist `flists/tidelink_fpga_v2.flist`. Where this doc and `docs/REGISTER_MAP.md`/`tidelink_regs.rdl` disagree, the instantiated RTL is authoritative.*
