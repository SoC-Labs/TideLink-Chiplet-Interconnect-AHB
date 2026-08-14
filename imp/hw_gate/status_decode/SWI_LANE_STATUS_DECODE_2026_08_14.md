# SWI_LANE_STATUS[31:24] — RTL decode of the die_b bring-up predictor

Date: 2026-08-14
Branch: `integ/tidelink-consolidated-2026-08-07`
Tree: `/home/dam1n19/SoCLabs/nanosoc-ethernet-chiplet/tidelink`
Method: static RTL read only. No hardware was touched. No files outside this
document were modified. Nothing committed.

Input measurement (not re-derived here, taken as given from
`imp/hw_gate/PREREG_DIEB_STATUS_PREDICTOR_2026_08_13.md`):

| die_b `SWI_LANE_STATUS` @ bring-up | runs | delivery |
|---|---|---|
| `0x05890000` | 17 | 17/17 byte-exact |
| `0x27890000` | 3 | 0/3 (all-zeros at far end) |

---

## Summary

- The two discriminating bits are **[29] `llrx_valid`** and **[25] `is_short_pkt`**
  — Wlink link-layer RX **packet-classification** bits. They are **not** anchor,
  epoch, or deskew state. The hypothesis "bits [31:24] encode anchor/epoch state"
  is **refuted**.
- They are not even two independent bits: in the byte-align state both words
  report, **bit 29 is bit 25 delayed one clock**. One observation, not two.
- With header ECC hard-bypassed in this tree, bit 25 reduces to a raw range test:
  *the current RX header byte is in `0x01`..`0x7F`*.
- A weaker version survives: these bits sit **downstream of the very latch
  `EPOCH_STATUS` bit0 reports** — `reanchored` selects the per-lane read pointer
  that frames the RX word. So they are a *consequence* of anchor state, not an
  *encoding* of it.
- **The correlation is weaker than it looks.** The same `0x27890000` occurs
  harmlessly at bring-up time in three *passing* runs. The bits are free-running
  instantaneous samples with no stickiness. Predictive value is entirely
  dependent on sampling at one exact point.
- **Recommendation: gate on the anchor pair, not on this word.** Reject
  specifically die_a=1 / die_b=0.
- **TL-031 is NOT wrong** — it claims no *eye/BER margin* metric, and these bits
  are not one. The pre-registration's paraphrase of TL-031 is what is inaccurate.
- Side finding: the leading mechanism for the YES/NO-only failure is a
  **unilateral beacon retire** at `axi_chiplet_controller.sv:4931`.

---

## 0. Where the register is assembled

`SWI_LANE_STATUS` is **Region 8, slot `3'h2`** of the chiplet controller's
register decoder — SoC APB offset `0x2108`.

- Region 8 decode (`paddr[8:5] == 4'b1000` → `0x100`-`0x11C`):
  `src/rtl/local_overrides/axi_chiplet_controller.sv:596`
- Region 8 read mux declaration:
  `src/rtl/local_overrides/axi_chiplet_controller.sv:1144`
- `assign region8_rdata =`
  `src/rtl/local_overrides/axi_chiplet_controller.sv:2846`
- Region 8 read mux body, slot `3'h2` (the word in question):
  `src/rtl/local_overrides/axi_chiplet_controller.sv:2883-2905`
- Merge into `ctrl_reg_rdata`:
  `src/rtl/local_overrides/axi_chiplet_controller.sv:1173`

The whole word is assembled **inside the controller**. `src/rtl/tidelink_top.sv`
does not compose it; it only carries the APB plumbing. Seven of the eight bits of
`[31:24]` are 2-flop `apb_clk` synchronisers of nets sourced from the Wlink core
and the calibrator (bit 27 is the exception — combinational, see the table); the
sync block is `src/rtl/local_overrides/axi_chiplet_controller.sv:1905-2020`
(reset arm `:1905-1935`, capture arm `:1975-2020`).

### V1 vs V2 packing — resolved structurally, not assumed

Bits `[27]` and `[26]` have different meanings under `` `ifdef TIDELINK_PHY_V2 ``.
`fpga/build_design.tcl:477-500` warns at length that a fileset/synth-run
`-verilog_define` **never reaches the packaged IP's out-of-context synthesis**,
and concludes that these `ifdef` blocks "have been DEAD in every FPGA bitstream".

**That comment is stale for the eth-chiplet target.** The packaged IP source is
materialised with the define baked in per-file:

- `src/rtl/v2shims/v2_axi_chiplet_controller.sv:4` — `` `define TIDELINK_PHY_V2 ``
  then `` `include "axi_chiplet_controller.sv" ``
- `fpga/filelist.tcl:112,201` — materialises each `v2shims/` entry into a
  standalone generated file
- **Decisive check**: `imp/fpga/eth_chiplet_ip/src/axi_chiplet_controller.sv:1-3`
  reads:
  ```
  // AUTO-GENERATED (TIDELINK_PHY_V2 build) - DO NOT EDIT. Source: .../axi_chiplet_controller.sv
  `define TIDELINK_PHY_V2
  `define TD_AUTO_LANE_MASK_E4
  ```

So the shipping eth-chiplet bitstream uses the **V2 packing**. An independent
consistency check from the data agrees: under V1, bit`[26]` is `is_long_pkt` and
bit`[25]` is `is_short_pkt`, and those two are mutually exclusive by construction
(`WlinkRxLinkLayer.v:97-98`). The measured `0x27` has **both** set, which is
impossible under V1 packing but perfectly consistent under V2
(`[26]` = `cal_in_hold`). Two independent lines of evidence, same answer.

---

## 1. Full bit table for `[31:24]` (V2 packing, as shipped)

All citations are to
`src/rtl/local_overrides/axi_chiplet_controller.sv` unless stated otherwise.

| Bit | RTL signal (synced) | Source net | Definition site | Meaning | `0x05` | `0x27` |
|-----|--------------------|-----------|-----------------|---------|:-----:|:-----:|
| 31 | `sync_obs_fe_rx_full_1` | `obs_fe_rx_is_full_w` | mux `:2883`; sync `:2014`; port `:6766` | FC-node RX FIFO reports full — the FCSM 4→5 SEND credit gate | 0 | 0 |
| 30 | `sync_obs_a2l_replay_v_1` | `obs_a2l_replay_link_valid_w` | mux `:2884`; sync `:2010`; port `:6764` | a2l replay FIFO has a valid word on the **link** side | 0 | 0 |
| 29 | `sync_obs_llrx_valid_1` | `obs_llrx_valid_w` | mux `:2885`; sync `:2000-2001`; decl `:1025`; port `:6758` | **LL_RX is presenting a valid received packet** (see §2) | 0 | **1** |
| 28 | `sync_obs_pkt_crack_1` | `obs_pkt_is_crack_pkt_w` | mux `:2886`; sync `:1992`; port `:6754` | current RX packet is a CRACK (credit-ack) packet — instantaneous | 0 | 0 |
| 27 | `ws_fin_wait_lvl \| (autonomy_armed & winscan_done & ~role_is_master)` | — (combinational, **not** synced) | mux `:2888`; `ws_fin_wait_lvl` `:5281`; `autonomy_armed` `:1428`; `winscan_done` decl `:1647` | R-B asymmetric peer-serve / finalize-rendezvous bit. Master advertises "parked in `WS_FIN_WAITPEER`"; slave advertises "ready to serve" | 0 | 0 |
| 26 | `sync_cal_in_hold_1` | `cal_in_hold_w` (phy_align calibrator `S_HOLD`) | mux `:2893`; sync `:1981`; decl `:1778` | Calibrator locally parked in `S_HOLD` (L4 training-exit rendezvous) | 1 | 1 |
| 25 | `sync_obs_short_1` | `obs_is_short_pkt_w` | mux `:2897`; sync `:1996-1997`; decl `:1023`; port `:6756` | **RX packet header decodes as a short packet** (see §2) | 0 | **1** |
| 24 | `sync_obs_crack_seen_1` | `obs_crack_pkt_seen_rx_w` | mux `:2898`; sync `:1988`; port `:6752` | **Sticky**: a CRACK packet has been seen since clear | 1 | 1 |

For completeness, the bits the existing decoder does print (`[23:16]`) are
consistent with the reported fields in both words: `[23]` `cr_seen`=1,
`[22:21]` `llrx_state`=0, `[20]` `a2l_app_valid`=0, `[19:17]` `fcsm`=4,
`[16]` `cal_done`=1. Lower half is `0x0000` → `lane_fault`=0, `lane_locked`=0.

### Nothing in `[31:24]` is UNKNOWN

All eight bits resolve to named nets. Bit 27 is the only one that is a
combinational expression rather than a single synced signal, and both of its
terms are named and cited above.

---

## 2. The two discriminating bits

`0x05 ^ 0x27 = 0x22` → **bit 29** and **bit 25** of the word.

- **bit 25 = `is_short_pkt`** —
  `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v:97`:
  ```verilog
  wire is_short_pkt = corrected_ph[7:0] <= io_swi_short_packet_max
                    & corrected_ph[7:0] != 8'h0
                    & ~ecc_check_corrupted;
  ```
  `swi_short_packet_max` POR default is `8'h7f`
  (`deps/axi-chiplet-controller/logical/wlink/Wlink.v:2068`).

- **bit 29 = `valid`** —
  `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v:100,946`,
  registered at `:1509-1516`.

### These two are NOT independent

In byte-align FSM `state == 2'h0` — which is the state **both** measured words
report (`[22:21]` = `00`) — the `valid` register is fed by
(`WlinkRxLinkLayer.v:1512-1513` → `_GEN_67` `:575` → `_GEN_46` `:572` →
`_GEN_40` `:546`):

```
valid <= enable & (is_long_pkt ? endOfPacket : is_short_pkt)
```

So with `active_lanes != 0` and no long packet in flight, **bit 29 is bit 25
delayed by one link clock**. The two discriminating bits are one observation,
not two. That is why they move together across all 20 runs.

### What the observation actually is

Header ECC is **bypassed** in this tree —
`deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v:300-308`:

```verilog
// SoC Labs bring-up patch (2026-05-05): force ECC bypass.
assign corrected_ph = ph_in;
assign corrected    = 1'h0;
assign corrupted    = 1'h0;
```

With `ecc_check_corrupted` tied to 0, bit 25 reduces to a **pure range test on
the raw received header byte**:

> **bit 25 = 1  ⇔  the byte currently sitting in the RX packet-header position is
> in the range `0x01`..`0x7F`.**

There is no validity checking of any kind behind it. Note the AXI FC-node
`data_id`s (AW `0x80`, W `0x81`, B `0x82`, AR `0x83`, R `0x84`, sideband
`0xA1`) are all `> 0x7f` and therefore decode as *long* packets — so the bits
cannot be reporting AXI data traffic. The passing signature (`0x05`, bit 25 = 0)
is consistent with the header position holding `0x00`, i.e. no packet being
classified at that instant.

> **Not proven:** I did not establish what the link actually carries between
> packets. `link_data_reg` is zeroed only on reset
> (`WlinkTxLinkLayer.v:987`), not demonstrably during idle, and forced-SYNC
> beacon insertion is active during bring-up. So "idle ⇒ header byte `0x00`" is
> a plausible reading, not a verified one.

### These bits are instantaneous, and the evidence shows they flicker

The sync block (`:1996-2001`) has **no enable and no stickiness** — bits 25/29
are free-running samples of a live combinational classification, unlike the
`_seen` bits at `[24]`/`[23]` which are sticky. Whatever they report is true only
at the instant of the APB read.

The overnight evidence confirms this empirically, and it is the single most
important operational fact in this document:

- `0x27890000` **also occurs at bring-up time in three PASSING runs** (06, 17,
  18 — `run_NN/tl035_baseline/04_bringup_{a,b}.log:16`).
- In the three FAILING runs (09, 15, 19) the **bring-up-time** read was
  `0x05890000`; the word only became `0x27890000` by the step-5 sample.

So the discriminator is not "the word `0x27890000`". It is *"die_b's word is
`0x27890000` **at the post-bring-up step-5 sample point**"*. The register takes
that value harmlessly at other points in bring-up. This is exactly the behaviour
the RTL predicts for a non-sticky sample of a packet-classification signal.

---

## 3. Verdict

**The tidy hypothesis as literally stated is REFUTED; a weaker and more precise
version SURVIVES.**

- **Bits 29 and 25 are not anchor, epoch, or deskew status bits.** They are
  Wlink link-layer RX header-decode observations. Nothing in their definition
  references `reanchored`, `epoch_anchored`, `auto_anchor`, or the deskew block.
  So "`SWI_LANE_STATUS[31:24]` encodes anchor state" is **false**.

- **The one anchor-adjacent bit in the byte is bit 27, and it carries zero
  discriminating information** — it reads 0 in both the passing and the failing
  word. (`autonomy_armed` `:1428` depends on `autonomy_retire_q`, which is
  driven by the anchor; `winscan_done`'s WS_FINALIZE gate is held until
  `reanchored` `:1592`.) Whatever separates pass from fail, this byte does not
  report it *as* anchor state.

- **However, bits 29/25 sit directly downstream of the latch that
  `EPOCH_STATUS` bit0 reports.** `reanchored` is the mux select on the per-lane
  read pointer that assembles the RX word:

  `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1486`
  ```systemverilog
  assign rd_ptr_l[gi] = reanchored ? (rd_ptr - lane_off[gi]) : rd_ptr;
  ```
  and `:1524` `assign epoch_anchored_o = reanchored;` — the same net that reaches
  `EPOCH_STATUS 0x2140` bit0 (confirmed by the CDC comment at
  `axi_chiplet_controller.sv:4691-4695`).

  `reanchored = 0` ⇒ every lane reads the **common** pointer with no per-lane
  skew compensation ⇒ `out_data` is mis-framed ⇒ `corrected_ph[7:0]` is a
  wrong-offset byte ⇒ with ECC bypassed it is accepted as a short packet
  whenever it lands in `0x01`..`0x7F`.

  So the status word is a **symptom of the local die's framing**, and framing is
  selected by the local `reanchored`. The bits are a *consequence* of the anchor
  state, not an *encoding* of it. That distinction matters for how you gate on
  them (§4).

### The asymmetry has a named RTL mechanism (supported, not yet proven)

The cross-tab shape — only die_a=YES / die_b=NO fails — matches a specific
unilateral retire in the RTL. `autonomy_retire_q`
(`axi_chiplet_controller.sv:4904-4952`) fires on **either** of two branches:

- **Branch 1** (`:4923`) — `winscan_done && ws_anchor_q && fcsm==4`. The comment
  at `:4921-4923` calls this the "**SIM mutual gate**: `winscan_done` proves the
  rendezvous completed (**both dies anchored**) so the master's beacons are no
  longer needed." Note this mutual guarantee is itself soft: the WS_FINALIZE
  anchor gate that holds `winscan_done` until `reanchored`=1 has a **fail-loud
  timeout that releases anyway** (`ws_anchor_timeout_q`, `:1591-1597`), so
  `winscan_done`=1 does not strictly prove either die anchored.
- **Branch 2** (`:4931`) — `ws_anchor_q && fcsm==4` held for `RETIRE_DWELL_SI`
  (`24'd8_000_000`, ~160 ms @50 MHz, `:4900`). Labelled "**SILICON** reanchored
  timer". **This branch has no peer-anchored term at all.**

When `autonomy_retire_q` sets, it drops `autonomy_armed` (`:1428`), which fires
the LOOP-9 DISARM-PARK arc that drops `winscan_force_sync` / `ws_serve_active_r`
— "the FORCED-SYNC chain OR'd into the Wlink insert_en+force_always+robust
ports" (`:1415-1418`). And the re-arm comment at `:4911-4913` states the purpose
plainly: "Fresh training episode => re-arm: restore the forced-SYNC chain for the
new scan (**the peer's re-anchor needs it**)."

Chain, entirely from the RTL and its own comments:

1. die_a re-anchors; die_b has not.
2. die_a's **branch 2** timer sees only die_a's own `ws_anchor_q` and fires after
   ~160 ms — with no check that die_b anchored.
3. die_a retires autonomy and drops its forced-SYNC beacon.
4. die_b still needs that beacon to anchor, and now never gets one.
5. die_b's deskew stays on the common pointer (`:1486`), RX stays mis-framed.
6. Mis-framed header byte lands in `0x01`..`0x7F`, ECC bypassed ⇒ bits 25/29
   assert on garbage; delivery is all-zeros.

That is a coherent, RTL-supported account of why *only* YES/NO fails, and it is
consistent with the previously recorded beacon-starvation root causes. **It is
not proven by this static read.** Confirming it needs a paired sim showing
branch 2 firing on one die while the peer's `reanchored` is still 0. I am
flagging it as the leading mechanism, not as an established result.

### Honest caveats — these are strong enough to change the recommendation

- **n = 3 on the failing side**, and the bits are an instantaneous snapshot, not
  a latched verdict.
- **The same value appears benignly at a different sample point** (runs 06, 17,
  18 above). A signal that reads "bad" in three passing runs and "good" in three
  failing runs — merely at a different moment in the same bring-up — is not
  behaving like a health verdict. It is behaving like a sampled transient that
  happened to be collinear at the step-5 point across three failures.
- A *randomly* mis-framed byte lands in `0x01`..`0x7F` roughly half the time. 3/3
  is what you would see by chance about 1 time in 8. Combined with the flicker
  above, the correlation is **materially weaker than 17/17 vs 0/3 makes it look**.
- Because these bits are a *downstream consequence*, any other cause of RX
  mis-framing would produce the same signature. They do not identify the anchor
  specifically.
- die_a's step-5 status was `0x05890000` in **all 20** runs — zero variance, so
  the die_a side of this register carries no information at all.

Net: the RTL decode does not promote this correlation into a mechanism. It
explains *why* the correlation is fragile.

---

## 4. Retry gate

The measured discriminator, as a named mask:

```c
/* SWI_LANE_STATUS, die_b, read at bring-up before any data is sent. */
#define SWI_LANE_STATUS_LLRX_VALID    (1u << 29)  /* WlinkRxLinkLayer.valid        */
#define SWI_LANE_STATUS_IS_SHORT_PKT  (1u << 25)  /* WlinkRxLinkLayer.is_short_pkt */

#define SWI_LANE_STATUS_MISFRAME_MASK \
    (SWI_LANE_STATUS_LLRX_VALID | SWI_LANE_STATUS_IS_SHORT_PKT)   /* 0x2200_0000 */

/* PASS (proceed): (status & SWI_LANE_STATUS_MISFRAME_MASK) == 0
   FAIL (re-run bring-up): non-zero                                */
```

**This should be the secondary check, not the gate.** Reasons, in order of
weight:

- **Sample-point sensitivity is disqualifying for a naive implementation.** The
  same value occurs harmlessly at bring-up time in passing runs (§2). A gate that
  polls this register *during* bring-up rather than at the single post-bring-up
  step-5 point would have produced **3 false positives out of 20 on this very
  dataset**. If this mask is used at all, it must be sampled at exactly the
  step-5 point — one read, after bring-up completes, before any peer write.
- The gate is only meaningful **while the link is idle**. Once real traffic
  flows, legitimate short packets set both bits and the mask means nothing.
- **Minimal discriminator is bit 25 alone** (`0x0200_0000`). Bit 29 is its
  registered copy in byte-align state 0, so requiring both is a coherence check
  rather than extra information — but it is the safer form, since a single
  metastable sample cannot trip the gate alone.

**The principled gate is the anchor pair.** It is mechanistic, it is already
printed by the bring-up script, and it is not sample-point-fragile:
  - `EPOCH_STATUS` (SoC `0x2140`) bit0 = `reanchored`, on **both** dies. The
    failing configuration is specifically `die_a=1, die_b=0`.
  - `AUTO_ANCHOR_OBS` (SoC `0x21F4`) bit[21] = `reanchored (ws_anchor_q)`,
    bit[16] = `pulsed_ever` (a SYNC beacon did emit), bit[15:0] = `dwell_max`
    (`:3122-3130`). One read explains *why* the anchor did or did not latch —
    this is the register that distinguishes "beacon never fired" from "beacon
    fired, anchor still failed".

  Recommended gate: **reject the specific die_a=1 / die_b=0 configuration and
  re-run bring-up**, treating `(status & 0x22000000) != 0` at step 5 only as a
  corroborating symptom. Note the evidence rules out the two simpler rules:
  requiring `reanchored`=1 on both dies would needlessly reject the 8 NO/NO runs
  that all passed, and rejecting mere asymmetry would needlessly reject the 4
  NO/YES runs that all passed.

- Address caution: `0x21AC`, `0x21B0`, `0x21B4` hard-stall the CPU on this
  design and must not be read. `0x2140`, `0x21F4` and `0x2108` are the registers
  named above and are the only ones this document recommends. `WINSCAN_OBS`
  (`0x21B8`, `ws_anchor_timeout_q` at bit[2], `:1590-1596`) would also be
  informative, but it sits immediately adjacent to the three lethal addresses
  and is **not** recommended here without separate validation of its decode.

---

## 5. TL-031 — premise status: **NOT wrong**

The question was posed as "TL-031 claims no SW-readable bring-up-margin indicator
exists — if these bits are one, that entry is wrong". Having read the entry, the
answer is **no, TL-031 is not wrong, and it should not be amended.**

TL-031's actual wording (`docs/BUG_REGISTRY.yaml:1235-1237`):

> "there is no SW-readable end-of-bring-up **eye/BER margin**, so the
> orchestrator cannot reject a marginal eye and re-winscan (**reanchored=1 +
> FCSM=4 do NOT imply a good eye**)"

That claim is about a **graded eye/BER margin metric**. Bits 25/29 are not one:

- They are **binary**, not graded. They cannot rank two passing links, cannot
  express "marginal", and give the orchestrator nothing to threshold.
- They are a **packet-classification sample**, not a channel-quality measure.
  Nothing in their derivation touches BER, eye width, or tap margin.
- They are **sample-point-fragile** (§2), which is precisely the property a
  margin metric must not have.
- TL-031's parenthetical is untouched: `reanchored=1 + FCSM=4` still do not imply
  a good eye. Nothing here changes that.

**What is wrong is not TL-031 but the pre-registration's paraphrase of it.**
`PREREG_DIEB_STATUS_PREDICTOR_2026_08_13.md:27-28` restates TL-031 as "no
SW-readable **margin indicator** exists" — dropping "eye/BER" and broadening the
claim to something TL-031 never asserted. The prereg's own closing section
(`:105-109`, "Nobody has yet decoded bits [31:24]") is also now superseded: the
bit names were already documented at `docs/REGISTER_MAP.md:245-263`,
`pynq_host/throughput_gui/regmap.py:199-222` and `pynq_host/scripts/tlchar.py:88-105`.
This document's contribution is not the names — it is the **semantics** behind
them (the ECC bypass that reduces bit 25 to a raw range test, the bit-29/bit-25
dependency, and the deskew coupling).

Recommended registry actions:

1. **Leave TL-031's premise as written.** Optionally add this document to its
   `evidence:` list as a negative result: the `0x2108` status byte was evaluated
   as a margin candidate and does not qualify. If a graded proxy is wanted,
   `AUTO_ANCHOR_OBS` `dwell_max[15:0]` (`:3122-3127`) is the better candidate.
2. **Correct the prereg**, not the registry — its paraphrase of TL-031 and its
   "decoding still owed" caveat are both inaccurate.
3. **Open a new entry** for the unilateral **branch 2** retire at
   `axi_chiplet_controller.sv:4931`: it retires the forced-SYNC beacon the peer
   needs on *this* die's anchor alone, with no peer-anchored term. That is the
   leading mechanism for the YES/NO-only failure and is a defect in its own right
   regardless of anything in this decode.

---

## Appendix — file:line index

| Item | Path:line |
|---|---|
| Region 8 decode | `src/rtl/local_overrides/axi_chiplet_controller.sv:596` |
| Region 8 read mux decl | `src/rtl/local_overrides/axi_chiplet_controller.sv:1144` |
| `assign region8_rdata` | `src/rtl/local_overrides/axi_chiplet_controller.sv:2846` |
| Slot `3'h2` packing (the word) | `src/rtl/local_overrides/axi_chiplet_controller.sv:2883-2905` |
| `ctrl_reg_rdata` merge | `src/rtl/local_overrides/axi_chiplet_controller.sv:1173` |
| CDC sync block (bits 31,30,29,28,26,25,24) | `src/rtl/local_overrides/axi_chiplet_controller.sv:1905-2020` |
| bit 29/25 sync assignments | `src/rtl/local_overrides/axi_chiplet_controller.sv:1996-2001` |
| Wlink obs port map | `src/rtl/local_overrides/axi_chiplet_controller.sv:6750-6766` |
| `autonomy_armed` | `src/rtl/local_overrides/axi_chiplet_controller.sv:1428` |
| `ws_fin_wait_lvl` | `src/rtl/local_overrides/axi_chiplet_controller.sv:5281` |
| `autonomy_retire_q` drive (branch 1 / branch 2) | `src/rtl/local_overrides/axi_chiplet_controller.sv:4904-4952` |
| forced-SYNC drop on disarm (comment) | `src/rtl/local_overrides/axi_chiplet_controller.sv:1415-1418` |
| `ws_anchor_q` = CDC'd `reanchored` | `src/rtl/local_overrides/axi_chiplet_controller.sv:4691-4705` |
| `AUTO_ANCHOR_OBS` packing | `src/rtl/local_overrides/axi_chiplet_controller.sv:3122-3130` |
| Wlink obs promotion | `deps/axi-chiplet-controller/logical/wlink/Wlink.v:856-859` |
| `short_packet_max` POR default `0x7f` | `deps/axi-chiplet-controller/logical/wlink/Wlink.v:2068` |
| `is_short_pkt` / `is_long_pkt` | `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v:97-98` |
| `valid` register + feed | `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v:100,546,572,575,1509-1516` |
| LLRX obs outputs | `deps/axi-chiplet-controller/logical/wlink/WlinkRxLinkLayer.v:943-946` |
| ECC bypass (`corrupted = 0`) | `deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v:300-308` |
| `reanchored` selects read pointer | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1486` |
| `epoch_anchored_o = reanchored` | `deps/tidelink-phy/rtl/tidelink_lane_deskew.sv:1524` |
| V2 shim | `src/rtl/v2shims/v2_axi_chiplet_controller.sv:4` |
| v2shim materialisation | `fpga/filelist.tcl:112,201` |
| Packaged IP has the define baked in | `imp/fpga/eth_chiplet_ip/src/axi_chiplet_controller.sv:1-3` |
| Stale "ifdefs are dead" comment | `fpga/build_design.tcl:477-500` |
| Bit names already documented (pre-existing) | `docs/REGISTER_MAP.md:245-263`; `pynq_host/throughput_gui/regmap.py:199-222`; `pynq_host/scripts/tlchar.py:88-105` |
| Decoder (never prints `[31:25]`) | `pynq_host/scripts/kr260_eth_bringup.py:145-169` |
| Register addresses used by the harness | `pynq_host/scripts/kr260_eth_bringup.py:81-85` |
| Step-5 sample point | `imp/hw_gate/tl035_ab.sh:116-118` |
| `0x27890000` benign at bring-up in passing runs | `imp/hw_gate/overnight/run_{06,17,18}/tl035_baseline/04_bringup_{a,b}.log:16` |
| TL-031 entry | `docs/BUG_REGISTRY.yaml:1226-1257` (claim at `:1235-1237`) |
| Prereg paraphrase of TL-031 / "decoding owed" | `imp/hw_gate/PREREG_DIEB_STATUS_PREDICTOR_2026_08_13.md:27-28`, `:105-109` |
