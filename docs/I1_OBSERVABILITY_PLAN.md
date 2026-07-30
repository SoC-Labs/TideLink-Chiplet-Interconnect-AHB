# I1 FCSM bring-up — observability & locus-isolation plan (2026-07-30)

**Scope:** analysis + instrumentation design only. No RTL built, no FPGA build, no
deploy, no push. Every tap point below was grepped and confirmed to exist; no
signal name is invented.

## The failure this plan isolates

The I1 flow-control-recovery override (`src/rtl/local_overrides/WlinkGenericFCSM.v`
+ `_1..4`, the five AXI FC nodes) prevents KR260 eth-chiplet bring-up:
`SWI_LANE_STATUS @ 0x2E03_2108 = 0x00100000` → `cr_seen=0 crack_seen=0 cal_done=0
fcsm=0`, **both dies**. Deps FCSM brings up (fcsm=4); the sideband `WlinkGenericFCSM_6`
brings up. An emit-gate (state-exit) fix and a CRC-default fix were both
silicon-refuted; `cr_seen` never so much as flickers ⇒ the break is **at/before the
state-1 CR emit**. See `nanosoc-ethernet-chiplet/docs/I1_FCSM_BRINGUP_REGRESSION.md`.

Four candidate loci, none observable on silicon today:
- **H1** — an AXI node never **emits** CR (TX path dead in FSM states 0–3).
- **H2** — it emits but the round-robin **arbiter never grants** it (starvation/deadlock).
- **H3** — it emits but the CR is **malformed** (wrong `data_id`/format) so the broadcast RX never latches it.
- **H4** — TX-enable/clock is **gated** off during bring-up.

---

## (a) What is observable TODAY, and the blind spots

### Register read path (all inside the decoded aperture)

`axi_chiplet_controller.sv` builds `ctrl_reg_rdata` from a region mux keyed on
`ctrl_reg_addr[4:3]` (`:1103-1111`); `apb_region = paddr[8:5]` (`tidelink_apb_regs.sv:210`).
Regions relevant here:

| Region | `paddr[8:5]` | SoC offset | chiplet backdoor | Selected by |
|---|---|---|---|---|
| 8 (SWI_*/LANE_STATUS) | `1000` | `0x4403_2100-11C` | `0x2E03_2100-11C` | `ctrl_reg_addr[4:3]==2'b10` |
| C (autoneg/CAL/FC_CREDIT) | `1100` | `0x4403_2180-19C` | `0x2E03_2180-19C` | `2'b11` |
| F (AXI data-node obs) | `1111` | `0x4403_21E0-1FF` | `0x2E03_21E0-1FF` | `apb_ctrl_reg_rf` (`:228`, `:1109`) |

### SWI_LANE_STATUS (0x2108) — the bring-up criterion — and why it is blind here

`region8_rdata`, slot `3'h2` (`axi_chiplet_controller.sv:2716-2738`):
- `[23]` `sync_obs_cr_seen_1`  ← `obs_cr_pkt_seen_rx_w`
- `[24]` `sync_obs_crack_seen_1` ← `obs_crack_pkt_seen_rx_w`
- `[19:17]` `sync_obs_fcsm_state_1` ← `obs_fcsm_state_w`
- `[16]` `sync_cal_done_1`

Those `obs_*_w` nets are outputs of the Wlink instance (`:6386-6390`). **Inside
Wlink they are driven from the SIDEBAND node only:**
`Wlink.v:1123` `assign obs_fcsm_state_o = tl2wl_io_obs_fcsm_state;` and
`:1124` `obs_cr_pkt_seen_rx_o = tl2wl_io_obs_cr_pkt_seen_rx` — `tl2wl` = the
TideLink sideband FC node = router channel 6 (see channel map below). **The five
AXI FC nodes contribute nothing to SWI_LANE_STATUS.** So the criterion register
tells us the sideband is dark but cannot say why, nor anything about the AXI nodes.

### Region C / Region F today

- `OBS_FC_CREDIT` (Region C slot 7, `:2840-2864`) surfaces `fe_rx_credit_max`/`fe_rx_ptr`
  of the **sideband** FCSM_6 only (comment says so at `:2846`).
- `OBS_CAL` (slot 6), `OBS_MASK_HS` (slot 5) — calibrator + autoneg mask, not FC emit.
- **Region F** (`tidelink_axinode_obs u_axinode_obs`, `:2890-2913`) taps the AXI
  **application-layer** handshakes (`axi_tgt_0_*` / `axi_ini_0_*` valid/ready,
  `tidelink_axinode_obs.sv:52-63`) — stall/wedge/resp-error. It sees whether AXI
  *transactions* stall; it sees **nothing** of the FC link-layer CR/CRACK emit, the
  arbiter grant, or the TX-enable. Slot 0 (`0x21E0`) carries its word; **slots
  1–7 read `32'h0`** (`:2912-2913`) — i.e. **free**.

### Blind spots (exactly the four hypotheses)

| Question | Signal that answers it | Exposed today? |
|---|---|---|
| Does AXI node N enter CR emit / present a packet? | `txrouter_auto_in_N_sop` | **No** |
| Does the arbiter grant node N? | `txrouter_auto_in_N_advance` / `curr_ch` | **No** |
| What `data_id` does node N emit? | `txrouter_auto_in_N_data_id` | **No** |
| Is the shared TX serializer enabled / advancing? | `txrouter_io_enable`, `txrouter_auto_out_advance` | **No** |

---

## The structure being instrumented

`WlinkTxRouter` (`deps/.../wlink/WlinkTxRouter.v`) is an 8-input fair round-robin:
`curr_ch_reg[2:0]` (`:65`) is the granted channel; `auto_in_N_advance = auto_out_advance
& curr_ch==N` (`:142-149`); `io_enable` forces `curr_ch=0` when low (`:90,:161`). It is
instantiated once as `txrouter` in the editable local override
`src/rtl/local_overrides/Wlink.v:1478`, clocked by `phy_link_tx_tx_link_clk`
(`Wlink.v:2106`).

**Channel map** (from the `txrouter_auto_in_N_*` assigns, `Wlink.v:2108-2145`):

| ch | source module | role | tap prefix |
|---|---|---|---|
| 0 | `axi2wl_..._axiawFC` | **AXI AW** | `txrouter_auto_in_0_*` |
| 1 | `axi2wl_..._axiwFC` | **AXI W** | `txrouter_auto_in_1_*` |
| 2 | `axi2wl_..._axibFC` | **AXI B** | `txrouter_auto_in_2_*` |
| 3 | `axi2wl_..._axiarFC` | **AXI AR** | `txrouter_auto_in_3_*` |
| 4 | `axi2wl_..._axirFC` | **AXI R** | `txrouter_auto_in_4_*` |
| 5 | `gb2wl_...generalbusgb` | general bus | `txrouter_auto_in_5_*` |
| 6 | `tl2wl_...tidelinktl` | **SIDEBAND** (= SWI_LANE_STATUS source) | `txrouter_auto_in_6_*` |
| 7 | `sp2wl` | SW register port | `txrouter_auto_in_7_*` |

RX is broadcast; each FCSM self-selects by `data_id`
(`WlinkGenericFCSM.v:188` `pkt_is_cr_pkt = ... auto_rx_in_data_id == swi_cr_id`).
The reset-default handshake IDs (identical for every FCSM instance) are:
**CR `= 0x8`** (`WlinkGenericFCSM.v:720`), **CRACK `= 0x9`** (`:727`),
ACK `= 0xa` (`:734`), NACK `= 0xb` (`:741`).

---

## (b) Proposed taps, register layout, H1–H4 truth table

### Tap points — all in local-override `Wlink.v`, `phy_link_tx_tx_link_clk` domain

All are **pure fan-out reads** of existing declared nets (no datapath change).
Tap the five AXI channels (0–4) and the sideband (6) as reference:

| Tap | Net (per ch N ∈ {0,1,2,3,4,6}) | Decl / assign |
|---|---|---|
| emit-presented (SOP) | `txrouter_auto_in_N_sop` | decl `Wlink.v:665(0),659(1),641(4),629(6)`; assign `:2141,2136,2131,2126,2121,2111` |
| grant/advance | `txrouter_auto_in_N_advance` | decl `:670(0),634(6)`; port `:1526,1520,1502,1490`; eq `:2353(0),2435(6)` |
| emitted data_id | `txrouter_auto_in_N_data_id` | assign `:2142,2137,2132,2127,2122,2112` |
| serializer accept (global) | `txrouter_auto_out_advance` | decl `:676`; `= txpstate_auto_in_advance` `:2146` |
| shared TX enable (global, H4) | `txrouter_io_enable` | decl `:677`; `= ~axi2wl_io_tx_reset_tx_link_clk_reset` `:2147` |

Reference constants for the H3 check: `swi_cr_id`=0x8 / crack=0x9 defaults cited above.

### New module `src/rtl/tidelink_fcemit_obs.sv`

Mirrors the proven `tidelink_axinode_obs.sv` pattern exactly (detect in the tap
clock, 2-flop CDC to `apb_clk`, packed word + presence marker — see
`tidelink_axinode_obs.sv:91-168`), but the **detect domain is `phy_link_tx_tx_link_clk`**
(not app_clk). It is instantiated inside local-override `Wlink.v` beside `txrouter`,
consumes the taps above, registers four packed words in the tx-link-clk domain, CDCs
them to `apb_clk`, and drives four new `obs_fcemit_{0..3}_o[31:0]` Wlink ports. The
controller wires those into Region F slots 1–4 (like it wires `obs_fcsm_state_w`
today). **No `deps/` edit** — the router boundary is entirely visible in the local
override; `AXI4ToWlink`/`WlinkGenericFCSM` are untouched. **No write path** — all four
words RO.

Detection primitives (per channel N): `sop_seen[N]` sticky (`|` of `auto_in_N_sop`);
`grant_seen[N]` sticky (`|` of `auto_in_N_advance`); `last_id[N]` (latched on
`auto_in_N_advance`); global `out_adv_ever` sticky, `out_adv_cnt` 24-bit saturating,
`io_enable` live level, `any_sop_live`.

### Register layout (free Region F slots; RO)

SoC `0x4403_21xx` = chiplet `0x2E03_21xx` = PS backdoor `0x4_2E03_21xx`.

**Slot 1 — `OBS_FCEMIT_STAT` @ 0x2E03_21E4** (the one-read verdict)
```
[ 4:0] axi_sop_seen   {R,AR,B,W,AW} sticky — node ever presented SOP to router
[ 5]   sb_sop_seen                  sticky — sideband(ch6) ever presented SOP
[ 6]   gb_sop_seen                  sticky — generalbus(ch5) ever presented SOP
[12:8] axi_grant_seen {R,AR,B,W,AW} sticky — node ever granted+advanced
[13]   sb_grant_seen                sticky — sideband ever granted
[14]   gb_grant_seen                sticky — generalbus ever granted
[16]   router_io_enable_lvl         live   — txrouter_io_enable (1 = TX link-clk out of reset)
[17]   out_advance_ever             sticky — serializer accepted >=1 word
[18]   any_sop_live                 live   — some channel presenting SOP now
[31:24] 0xE1                        presence marker
```
**Slot 2 — `OBS_FCEMIT_ID_LO` @ 0x2E03_21E8**  `{last_id_ar[31:24], last_id_b[23:16], last_id_w[15:8], last_id_aw[7:0]}`
**Slot 3 — `OBS_FCEMIT_ID_HI` @ 0x2E03_21EC**  `{0xE2[31:24], rsvd[23:16], last_id_sb[15:8], last_id_r[7:0]}`
**Slot 4 — `OBS_FCEMIT_OUTCNT` @ 0x2E03_21F0**  `{0xE3[31:24], out_advance_cnt[23:0]}` (saturating)

### H1–H4 truth table (read on BOTH dies)

| Observable | **H1** TX dead | **H2** arbiter starve | **H3** malformed CR | **H4** TX gated |
|---|---|---|---|---|
| `axi_sop_seen[4:0]` | **0** | ≥1 | ≥1 | 0 or ≥1 |
| `axi_grant_seen[4:0]` | 0 | **0** for stuck node | ≥1 | 0 |
| `sb_grant_seen` (ch6) | maybe 1 | **0** (starved by AXI) | 1 | 0 |
| `router_io_enable_lvl` | 1 | 1 | 1 | **0** |
| `out_advance_ever` / `_cnt` | maybe >0 | >0 (other ch) | >0 | **0 / not climbing** |
| `last_id_*` vs {0x8,0x9} | n/a | 0x8/0x9 | **∉ {0x8,0x9}** | n/a |

Decision rules:
- **H1** if `axi_sop_seen==0` (nodes never present a packet) while a healthy build shows `sb_sop_seen=1`. The AXI FCSM never reaches state-1 CR emit.
- **H2** if `axi_sop_seen!=0` **and** `axi_grant_seen==0`/`sb_grant_seen==0` **and** `out_advance_ever==1` — the serializer runs but the round-robin never advances to the starved channel(s). This is the leading candidate: the five AXI nodes hold SOP under contention and starve ch6, so the sideband CR never reaches the wire ⇒ bilateral `cr_seen=0`. (Matches the doc's 5-way-multiplex structural root cause.)
- **H3** if `axi_sop_seen!=0` **and** `axi_grant_seen!=0` (packets DO advance) **but** `last_id_axi ∉ {0x8,0x9}` — the node emits with a wrong/absent CR id so no peer self-selects it.
- **H4** if `router_io_enable_lvl==0`, **or** `any_sop_live==1` with `out_advance_ever==0` and `out_advance_cnt` not climbing — nodes want to emit but the shared serializer/link-clk never accepts a single word.

Bilateral read disambiguates "my sideband is starved" (H2, this die's `sb_grant_seen=0`)
from "peer never emits" (peer die's `sb_sop_seen`/`sb_grant_seen` reveal its side).

**Optional Tier-2 (needs `deps/` port additions, defer unless Tier-1 is inconclusive):**
export each AXI FCSM's own `cr_pkt_seen_rx` (`WlinkGenericFCSM.v:197`) and internal
`state[2:0]` so H1 can be split (stuck in state 0 vs 1) and H3 confirmed on the RX side
(a node granted CR whose peer's matching node still shows `cr_pkt_seen_rx=0`). Tier-1
already discriminates H1–H4 at the router boundary in one build; Tier-2 is a deeper
localizer, not required for the verdict.

---

## (c) One-board-cycle triage plan

**Single instrumented build.** Take the build that reproduces the failure — the I1
recovery FCSM (`local_overrides` FCSM 0–4, e.g. tidelink `90fe6cc`) — and add ONLY
`tidelink_fcemit_obs` + the four Region F words. Because every tap is a RO fan-out,
the failing signature (`SWI_LANE_STATUS=0x00100000`) is preserved. Build ONE FPGA
image (both dies share it, per the kr260-pair/flip convention).

**Bench sequence (respects the wedge hazard — every read is inside a decoded aperture):**
1. Remote power-cycle both KR260 boards; deploy the image to both; bring up. Expect the failure (`0x2E03_2108 = 0x00100000`).
2. On **each** die, over the `eth_ss_0` backdoor, read only:
   - `0x4_2E03_21E4` `OBS_FCEMIT_STAT` — the verdict word
   - `0x4_2E03_21E8`, `0x4_2E03_21EC` `OBS_FCEMIT_ID_LO/HI` — emitted data_ids
   - `0x4_2E03_21F0` `OBS_FCEMIT_OUTCNT` — serializer liveness (read twice, a few ms apart, to see it climb or not)
   - `0x4_2E03_2108` `SWI_LANE_STATUS` — sideband reference
3. Apply the truth table → the locus (H1/H2/H3/H4) is pinned this session, both directions.

**Wedge guard.** `0x21E4/21E8/21EC/21F0` and `0x2108` are all inside decoded Region F /
Region 8 (`0x2E03_21E0-1FF`, `0x2E03_2100-11F`). No undecoded-PL access ⇒ no PS hang.
Presence markers (`0xE1/0xE2/0xE3`) let the host confirm it is reading the new image,
not a stale bitstream (top byte `0x00` = obs absent).

**Negative control (recommended, second image, can run in parallel/after).** Build the
SAME four obs words onto the WORKING deps-FCSM baseline (`0ed6d46`) and read them on a
brought-up link: expect `axi_grant_seen`+`sb_grant_seen` set, `out_advance_cnt` climbing,
`last_id_* ∈ {0x8,0x9}`. This proves the instrument reads "healthy" correctly and gives
the reference pattern to diff the failing read against.

---

## (d) Sim-side validation (before the board cycle)

**Unit env — `cocotb/tidelink_fcemit_obs/`** (clone of `cocotb/tidelink_axinode_obs/`:
same `tb_top.sv` + `Makefile` shape, `VERILOG_SOURCES = src/rtl/tidelink_fcemit_obs.sv`).
`tb_top` instantiates the obs module standalone and drives the tap inputs; the test
forces each hypothesis and asserts the packed word matches its truth-table row:
- **H1**: `auto_in_{0..4}_sop=0`, sideband sop toggling ⇒ `axi_sop_seen=0`, `sb_sop_seen=1`.
- **H2**: `auto_in_0_sop=1` held, `auto_out_advance` pulsing but per-channel advance never reaching ch6 ⇒ `axi_sop_seen!=0`, `sb_grant_seen=0`, `out_advance_ever=1`.
- **H3**: pulse `auto_in_0_advance` with `data_id=0x20` ⇒ `last_id_aw=0x20` (flagged ∉ {0x8,0x9}).
- **H4**: `io_enable=0` (and separately `auto_out_advance=0` with sops high) ⇒ `router_io_enable_lvl=0`, `out_advance_ever=0`.
This validates the decode + CDC + packing deterministically, no board needed.

**Integration env — `cocotb/tidelink_top_pair_v2/` or `cocotb/eth_tidelink_pair/`**
(real `txrouter` + five AXI FCSMs + sideband elaborated). Run with the tap-instrumented
`Wlink.v`; diff the obs word between a deps-FCSM run (healthy reference) and a
`local_overrides`-FCSM run. This confirms the taps carry sane values against the live
router.

**Documented sim-gap (do not over-claim).** Per
`I1_FCSM_BRINGUP_REGRESSION.md:116-126`, current pair sims do **not** reproduce the
silicon bring-up failure (RX byte-align latency after reset, async reset-release phase
between two real dies, and the 5-way contention are unmodeled). `cocotb/tidelink_fcsm_silicon_ratio/`
contains only a leftover flist (`tidelink_fpga_v2_fcsm_local.flist`) and `sim_build_*`
dirs — **no runnable test** — consistent with the doc. Therefore the integration sim
validates the obs *plumbing and the healthy pattern*; the *failing* pattern is supplied
by silicon. The obs itself is fully validated by the unit env (each hypothesis forced
and asserted). Building the genuine two-die, multiplexed, async-reset, RX-align pair TB
remains the long-term fix vehicle but is **not** a prerequisite for this observability.

---

## Files touched by the eventual implementation (for the dev — NOT done here)

- **new** `src/rtl/tidelink_fcemit_obs.sv` (pattern: `src/rtl/tidelink_axinode_obs.sv`)
- **edit** `src/rtl/local_overrides/Wlink.v` — instantiate the module on the `txrouter_*`
  taps; add four `obs_fcemit_{0..3}_o` ports (local override; no `deps/` change)
- **edit** `src/rtl/local_overrides/axi_chiplet_controller.sv` — 4 wires + wire the new
  Wlink ports into `regionF_axinodes_rdata` slots `3'h1..3'h4` (`:2912`)
- **new** `cocotb/tidelink_fcemit_obs/` (clone of `cocotb/tidelink_axinode_obs/`)
- flists: add `tidelink_fcemit_obs.sv` beside `tidelink_axinode_obs.sv`

All additions are RO fan-out; the shipping datapath and the failing signature are
preserved, so the one instrumented build both reproduces the bug and reads out its locus.
