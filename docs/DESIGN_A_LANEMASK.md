# DESIGN A — LANE MASK / training path

Read-only RTL trace + design proposal for the intermittent KR260 A→B delivery.
Target: `/home/dam1n19/SoCLabs/tidelink`, V2 FPGA build (`TIDELINK_PHY_V2=1`).
Panel role: DESIGN-A (lane-mask / training). Competes with a beacon-free-re-anchor
design (B) and an `EPOCH_ANCHOR_EN` design (C).

Every claim is tagged **[VERIFIED-RTL]** (traced to file:line the V2 flist compiles)
or **[INFERRED]** (consistent with RTL + HW measurement, not provable from RTL text).

---

## TL;DR — the honest verdict, up front

**My assigned hypothesis does NOT survive contact with the RTL + the new HW measurement.**
The measurement that was handed to me as "the strongest evidence for the lane-mask shear"
is, when decoded against the LinkLayer RX gather, **proof that the 4-lane word assembles
perfectly**. Lane-0 = 0 is **not** a shear — it is the *designed, correct* appearance of a
masked lane on a 0xE4 link. Therefore:

- **A `LANE_MASK_RESET=0xFF` rebuild will NOT fix intermittent delivery.** It is a
  bandwidth/robustness *enabler*, not the delivery fix. It strictly *raises* alignment
  risk (wider word → more lanes that must co-align, doubled deskew span, new bytesPerCycle
  the peer must match).
- The delivery bug lives **downstream of the mask** — in the one-shot data-mode anchor
  (Design B / C territory: `tidelink_lane_deskew_v2.sv:1479-1508`, no data-mode
  re-measure), not in which lanes are trained.
- I document the exact 0xFF build recipe anyway (it is a one-line env change, the sim
  default, and should ride along with whatever the real fix is), and I state the single
  measurement that would *change my mind* if I am wrong.

The rest of this doc shows the decode that forces this conclusion, so the panel can audit it.

---

## 0. The measured slice, decoded — this is the whole argument

**New HW evidence (2026-07-22 freeze build, die_b A→B receive):**
raw post-deskew slice `0x212C–0x2138` reads
```
[0x00000000, 0x00005b4c, 0xb5a60000, 0xf1e2d3c4]
```
**identical across 6 re-SYNC retries AND 3 full `full.py` bring-ups (0/5 delivery each);
re-rolls ONLY at a full PL reload.**

**Register→lane map [VERIFIED-RTL]** (`fpga/hw_regression/td_v2_hwlib.sh:195` and
`axi_chiplet_controller.sv:2321-2324`): each 32-bit APB word holds two 16-bit lane slices,
`out_data[16*gi +: 16]`:

| APB | value | lane (low 16) | lane (high 16) |
|---|---|---|---|
| 0x212C | 0x0000_0000 | lane0 = `0x0000` | lane1 = `0x0000` |
| 0x2130 | 0x0000_5b4c | lane2 = `0x5b4c` | lane3 = `0x0000` |
| 0x2134 | 0xb5a6_0000 | lane4 = `0x0000` | lane5 = `0xb5a6` |
| 0x2138 | 0xf1e2_d3c4 | lane6 = `0xd3c4` | lane7 = `0xf1e2` |

**Correct `TIDELINK_SYNC_WORD` per-lane slices** (from the delivered-anchor reference
`f1e2d3c4_b5a69788_796a5b4c_3d2e1f00`, per `docs/DESKEW_ANCHOR_ROOTCAUSE.md:247`):
lane0=`1f00`, lane1=`3d2e`, lane2=`5b4c`, lane3=`796a`, lane4=`9788`, lane5=`b5a6`,
lane6=`d3c4`, lane7=`f1e2`.

**Overlay:**

| lane | measured | correct SYNC | in 0xE4 mask? | verdict |
|---|---|---|---|---|
| 0 | `0x0000` | 1f00 | **masked** | zero — *expected* |
| 1 | `0x0000` | 3d2e | **masked** | zero — *expected* |
| 2 | `0x5b4c` | **5b4c** | active | **EXACT MATCH** |
| 3 | `0x0000` | 796a | **masked** | zero — *expected* |
| 4 | `0x0000` | 9788 | **masked** | zero — *expected* |
| 5 | `0xb5a6` | **b5a6** | active | **EXACT MATCH** |
| 6 | `0xd3c4` | **d3c4** | active | **EXACT MATCH** |
| 7 | `0xf1e2` | **f1e2** | active | **EXACT MATCH** |

`0xE4 = 8'b1110_0100` → active lanes **{2,5,6,7}**. **All four active lanes carry their
EXACT, correctly-deskewed SYNC slice.** The four zeros are precisely the four masked lanes.
This is not a sheared word — **it is a flawless 0xE4 4-lane SYNC word.** The deskew is doing
its job perfectly on the active subset.

**Why the zeros are correct-by-design and NOT a shear [VERIFIED-RTL].** The Wlink RX
LinkLayer *gathers only active lanes and discards masked ones* — it never reads the masked
positions. `LinkLayer.scala:765-777`:
```
// Enabled lane at logical position p_k contributes its low byte to byte_index[p_k]
// and its high byte to byte_index[p_k + K], where K = popcount(lane_mask)...
// Masked-out lane data is ignored.
val rxLaneCount = PopCount(io.lane_mask)            // = 4 for 0xE4
val rxLanePos   = PopCount(io.lane_mask(i-1, 0))    // compacted position
when(io.lane_mask(i)) { link_data_byte_index(rxLanePos) := ... }   // masked → no assign
```
Lanes {2,5,6,7} are **compacted** into contiguous byte positions 0..3 (low) / 4..7 (high);
lanes {0,1,3,4} are simply never sampled. Their raw slice reading `0x0000` has **zero
effect** on the assembled packet. So "lane-0 slice = 0" is the framer working as designed,
not a structural shear.

**Conclusion of §0:** the measurement *refutes* the premise it was offered to support. The
128-bit raw word is not sheared; the active 4-lane word is coherent and exact. Whatever
drops the data-mode packets is **not** the lane mask.

> The framing that "only lanes {2,5,6,7} are trained, lane 0 never bit-aligns, so the word
> is structurally sheared" is **false for a 0xE4 link**: lane 0 is *deliberately excluded*
> from the word, not failing to join it. The hypothesis would only hold if an **active**
> lane read zero/wrong — and none does.

---

## 1. WHY lane-0 slice = 0, and whether 0xFF fixes it

**Where the mask is latched [VERIFIED-RTL].**
- POR default: `src/rtl/local_overrides/Wlink.v:2438-2454`.
  ```
  `ifdef TD_AUTO_LANE_MASK_E4
    localparam [7:0] LANE_MASK_RESET = 8'hE4;   // bridge1 good lanes 2,5,6,7   :2439
  `else
    localparam [7:0] LANE_MASK_RESET = 8'hFF;                                    :2441
  ...
  swi_tx_lane_mask            <= LANE_MASK_RESET;   // TX mask POR                :2445
  out_prepend_swi_rx_lane_mask<= LANE_MASK_RESET;   // RX mask POR                :2452
  ```
  These two registers feed `bytesPerCycle = popcount(lane_mask)*2` via the popcount adders
  at `Wlink.v:996-1014` → LinkLayer `active_lanes`/`bytesPerCycle`
  (`LinkLayer.scala:484-489`, `:625-658`; `active_lanes = popcount−1`, a 3-bit value).
- The **`TD_AUTO_LANE_MASK_E4` define is injected by the flist, not present in the RTL
  source.** The task pointed at `fpga/filelist.tcl:119`; **that line is only a comment**
  inside the shim proc. The real injection is in `tidelink_materialise_v2_shim`, gated by
  `$_lane_mask_e4` (set to `1` at **`filelist.tcl:59`**, overridable by env at `:60`):
  ```
  filelist.tcl:151-155
      if { $_lane_mask_e4 } { puts $fo "`define TD_AUTO_LANE_MASK_E4" }
      else                  { puts $fo "// ...OMITTED... -> LANE_MASK_RESET = 8'hFF" }
  ```
  So the knob is **`TD_AUTO_LANE_MASK_E4=0` at build time → no define → `0xFF`**.
  Default remains `0xE4` (`:59`), matching every current CI/build path.

**How the mask gates `lane_off` in the deskew [VERIFIED-RTL].**
`tidelink_lane_deskew_v2.sv` consumes `lane_mask` (`:370`) and:
- excludes masked lanes from the anchor-ready test:
  `all_sync_seen = &(sync_seen_sync1 | ~lane_mask)` (`:1350`) — masked lanes' term forced 1;
- **parks a masked lane's offset at 0**: `lane_off[lo] <= lane_mask[lo] ? (max_dist −
  sync_dist[lo]) : '0` (`:1491`; EPOCH twin `:1301`);
- so a masked lane reads the raw common pointer (`rd_ptr_l[gi] = reanchored ? rd_ptr −
  lane_off[gi] : rd_ptr`, `:1514`) and is **never bit-aligned**.

**Does the deskew try to assemble all 8 lanes or only masked ones?** Neither shears the
active word. The deskew *aligns only the unmasked lanes* and leaves masked lanes at
offset 0; the **LinkLayer RX gather then discards the masked lanes entirely** (§0,
`LinkLayer.scala:767-777`). So masked lanes being un-aligned and reading 0 is invisible to
the packet. The active {2,5,6,7} subset is aligned and gathered — and the measurement
proves it lands exactly.

**Would 0xFF make lane 0 train and the word assemble?** 0xFF would make the deskew *also*
align lanes {0,1,3,4} and the gather *also* consume them (bytesPerCycle 8→16). Lane 0 would
then carry `0x1f00` instead of `0x0000`. **But the 4-lane word is already assembling
correctly**, so 0xFF changes *what the word is* (8-lane, double width, all 8 must
co-align), not *whether delivery is reliable*. **It does not address the delivery failure.**
[VERIFIED-RTL for the mechanism; the "does not fix delivery" is [INFERRED] from §0 + the
prior measured 8-lane rebuild that moved neither throughput nor reliability —
`memory/project_lanes_not_dead_proven_2x_needs_rebuild_2026_07_17`.]

> Note on runtime pokes: `swi_tx/rx_lane_mask` *are* APB-writable (`Wlink.v:2447/2454`), so
> a runtime `0x214` poke changes `bytesPerCycle`. But the **deskew's** `lane_mask` and the
> per-lane winscan tap-centering are latched by the autonomous mask-handshake **at
> bring-up** (`td_v2_hwlib.sh:67` "the mask handshake latches the POR value at bring-up"),
> so a runtime 0xFF poke does **not** re-train lanes {0,1,3,4} — only a **rebuild** does.
> This matches memory and is why the change is rebuild-only.

---

## 2. The exact build change for `LANE_MASK_RESET=0xFF`

Three things must move together or the winscan leaves the new lanes untrained.

**(a) Bitstream — the POR mask [VERIFIED-RTL].**
Build with env `TD_AUTO_LANE_MASK_E4=0`. This omits the `` `define TD_AUTO_LANE_MASK_E4 ``
(`filelist.tcl:151-155`) → `Wlink.v:2441` selects `8'hFF`. The build banner confirms it:
`filelist.tcl:82-86` prints `LANE_MASK_RESET = 8'hFF (8 lanes, bytesPerCycle=16)`.
**Verify the banner in the build log — a silent 0xE4 "looks exactly like a working build
that merely fails to go faster" (`filelist.tcl:80-81`).** No RTL edit; `fpga/filelist.tcl:119`
is unchanged (it's a comment; the live injection is `:59-60` + `:151-155`).

**(b) Recipe defaults — must match the bitstream mask [VERIFIED-RTL].**
`fpga/hw_regression/td_v2_hwlib.sh` is already parameterised on `TD_MASK` (`:60-84`); run
the 8-lane campaign with **`TD_MASK=0xff`**. That single var propagates to:
- `TD_LANEMASK32 = 0x0000ffff` (`:83`) → written to `R_LANEMASK 0x44030214` in `rcp()` (`:209`);
- `R_SYNCTOL_VAL = 0x000005ff` (`:84`, tol=5 | mask) → `R_SYNCTOL 0x44032128` (`:213`);
- `EXP_SYNC_SEEN = 0xff` (`:79`) — the expected `0x215C[7:0]` all-8-armed check;
- **the winscan lane loop** (`:265-268`): the old hardcoded `[6,2,5,7]` was replaced by
  `_wsl` derived from `MASK_ACTIVE_LANES`, so `TD_MASK=0xff` scans **all 8 lanes** — this
  is the critical fix (the in-code comment `:266-267`: the hardcoded `[6,2,5,7]` "silently
  left lanes 0/1/3/4 untrained on any wider mask").
  **⚠️ Verify the deployed `td_v2_hwlib.sh` on the board actually has the derived `_wsl`
  (`:265-268`) and not the old literal `[6,2,5,7]`.** If it still hardcodes `[6,2,5,7]`, a
  0xFF bitstream will run with lanes {0,1,3,4} untrained → active lanes reading garbage →
  **worse than 0xE4**. This is the single highest-risk step.

The recipe warns explicitly (`:65-73`): "the mask MUST match the bitstream's
LANE_MASK_RESET; a 0xff recipe on a 0xE4 bitstream does not negotiate 8 lanes." The
converse is equally fatal: a 0xE4 recipe (or `[6,2,5,7]` winscan) on a 0xFF bitstream.

**(c) validLaneSeq / power-of-2 whitelist — VERIFIED it is a non-issue.**
The task flagged a "validLaneSeq power-of-2 whitelist in LinkLayer.scala." **It does not
exist in LinkLayer.scala** — `grep validLaneSeq` over `wav-wlink-hw/src/main/scala/` returns
nothing. The only gate is structural: `active_lanes` is a **3-bit** field
(`LinkLayer.scala:973,1041,1155`) and `bytesPerCycle = (active_lanes+1)*2`. `active_lanes =
popcount−1`, so 0xE4→3 (bytesPerCycle 8) and 0xFF→7 (bytesPerCycle 16) are both legal
3-bit values. **0xFF passes; no whitelist blocks it.** (If a `validLaneSeq` popcount∈{1,2,4,8}
check exists elsewhere in the autoneg/winscan FSM, both 4 and 8 are powers of two and pass —
but I found no such check in the compiled Scala.)

**Peer symmetry:** both dies must build the same mask — `bytesPerCycle` sets the framing
stride on both TX and RX; a width mismatch mis-frames every packet. Deploy the 0xFF
bitstream to **both** boards, `TD_MASK=0xff` on both.

---

## 3. Risks

1. **0xFF is the sim default — best-tested. [VERIFIED, in favour.]** The V2 cocotb oracles
   run 0xFF (`filelist.tcl:148-149`: the define "reaches only the FPGA build, never the
   sims — keeping the V2 8-lane sim oracles green"). So 0xFF is *more* simulated than 0xE4,
   which has **no sim coverage at all**. This is a genuine argument to prefer 0xFF on
   principle — but it is an argument about test coverage, not about the delivery bug.

2. **Datapath widening / framing change. [VERIFIED-RTL, against.]** 0xFF doubles
   `bytesPerCycle` 8→16 (`LinkLayer.scala:489/658`). This changes packet framing stride,
   `byte_count`, `endOfPacket = incrByteCount >= topIndex` (`:660-662`), and the FC word
   length. The current recipe, credit tuning, and RX-FIFO length latch were all validated
   at 4-lane (bytesPerCycle=8); at 16 they are **re-tuned territory** and interact with the
   known RX-FIFO write-length twin (`memory/project_rxfifo_twins_rootcause`). Non-trivial
   re-validation.

3. **Timing / utilisation. [INFERRED.]** 8 lanes doubles the deskew FIFOs
   (`LANES=8, WIDTH=16, DEPTH=32`) actually exercised, the popcount/gather logic, and the
   capture-clock fan-out on 4 more lanes. The lottery-killing BUFG hoist
   (`memory/project_pb_lottery_killed`) was characterised on the *current* build; adding 4
   live capture lanes perturbs that placement. Needs a fresh route + static-timing check.

4. **Marginal-lane regression — the ribbon continuity story. [INFERRED; VERIFIED that the
   premise was never measured.]** The 0xE4 set was **never** chosen from a real
   bad-lane measurement — `memory/project_lane_census_0xE4_never_measured_2026_07_16`
   records it as a *sim placeholder* (`ef48bb1`) that crossed into HW config, and
   `project_lanes_not_dead_proven_2x_needs_rebuild` shows all 8 lanes conduct both
   directions. **So there is no evidence that lanes {0,1,3,4} are electrically bad.**
   *However* — and this is the honest counter to my own case — "conducts" ≠ "has margin at
   rate." If any of {0,1,3,4} is genuinely marginal on the KR260 ribbon/onchip route, 0xFF
   pulls it **into** the word (it can no longer be discarded by the gather), so a marginal
   lane that was previously invisible now **shears the whole 8-lane word**. 0xE4 masking is
   a *deliberate robustness margin* under this reading. Net: 0xFF trades "known-good 4-lane"
   for "possibly-marginal 8-lane" — a **reliability risk, not a reliability gain**, unless
   an eye/winscan sweep first proves all 8 lanes have margin at the target rate.
   (`kr260-pair-onchip` has no ribbon — 4 IOB, on-chip — so continuity is a non-issue there;
   the ribbon-margin risk is specific to the cross-board KR260 pair.)

---

## 4. Predicted outcome on hardware

**Prediction: a 0xFF rebuild will make lane-0's slice non-zero (`0x1f00`) but will NOT make
A→B delivery reliable.** Confidence **~80%** that it does not fix intermittency.

Reasoning:
- The 4-lane word already assembles exactly (§0) — the failure is downstream of assembly
  (one-shot data-mode anchor with no re-measure, `deskew:1479-1508`; §2 of
  `DESKEW_ANCHOR_ROOTCAUSE.md`). Widening to 8 lanes does not add a data-mode re-measure.
- The intermittency signature (delivers-then-drops *within* one bring-up; identical raw
  slice on delivered vs dropped per that doc's §2) is a **drift/framer** signature, not a
  lane-count signature. More lanes cannot fix drift; they add more drifting lanes.
- Empirically, the prior 8-lane rebuild "did not move throughput or reliability"
  (`memory/project_lanes_not_dead...` §5).

**The single measurement that confirms/refutes MY approach:** build 0xFF (both dies,
`TD_MASK=0xff`, winscan all-8 verified), bring up, and read the **same raw slice
`0x212C–0x2138` on a *delivered* packet vs a *dropped* packet in the same bring-up**.
- If, on a **dropped** packet, an **active** lane's slice is **zero or wrong** while a
  delivered packet shows all-active-lanes correct → the mask/training path *is* implicated
  (a lane drops out of alignment mid-session) and 0xFF's extra margin could matter. **This
  is the only outcome that would revive my hypothesis.**
- If delivered and dropped packets show **identical** raw slices (all active lanes correct
  in both) → the deskew is not changing between packets; the drop is downstream
  (framer/drift). **This refutes lane-mask as the cause** and points at Design B/C.

Given §0 already shows the 0xE4 slice is *deterministically perfect and unchanging across
retries/bring-ups*, the second outcome is the expected one.

---

## 5. Effort

**Rebuild-only. No RTL logic change.** [VERIFIED-RTL: the mask is a build-time
`localparam` selected by an already-present env knob.]

- Build: set `TD_AUTO_LANE_MASK_E4=0`, re-run `package_ip` + `build_design` for both KR260
  dies. ~1 bitstream build cycle per target (2 targets).
- Recipe: run existing `td_v2_hwlib.sh` with `TD_MASK=0xff`; **verify** the deployed copy's
  winscan loop is the derived `_wsl` (`:265-268`), not literal `[6,2,5,7]` — a 1-line
  audit, but a hard prerequisite.
- Bench: deploy both, bring up, read the delivered-vs-dropped slice pair (§4).
- **Estimate: ~0.5 day** (two rebuilds can run in parallel; the science is one bench
  session). No RTL, no new sim required (0xFF is the existing sim default).

Contrast with the sibling designs (for the panel): Design B (beacon-free periodic data-mode
re-anchor) and Design C (`EPOCH_ANCHOR_EN=1`) both target the actual root — the one-shot,
no-data-mode-re-measure anchor — and both need RTL/param work + new sim coverage. **They are
where the delivery fix lives; Design A is not.**

---

## 6. Where my approach could still be right (steelman) — and why I don't buy it

To be fair to the assignment, the lane-mask path is the root cause **iff** one of these holds
— none of which the current evidence supports:

- **(i) An active lane {2,5,6,7} intermittently un-aligns in data mode.** Then it's a
  training/eye-margin problem on an *active* lane, and 0xFF is irrelevant (it wouldn't
  help an already-active lane). The §4 delivered-vs-dropped slice read tests this directly.
  *Current evidence against:* the active-lane slices are exact and unchanging across 6
  re-SYNCs + 3 bring-ups.
- **(ii) The gather/`active_lanes` handshake latched a `bytesPerCycle` that disagrees with
  the mask** (e.g. mask 0xE4 but `active_lanes` = 7). Then the framer mis-strides and drops
  packets structurally. *Testable:* read `0x214` (mask) and confirm `bytesPerCycle` via the
  autoneg obs (`0x2194`). *Against:* this would fail **all** packets, not intermittently;
  and a byte-exact packet does cross.
- **(iii) A masked lane's raw `0x0000` is *not* actually discarded** because the deployed
  gather differs from `LinkLayer.scala:767-777`. *Against:* that Scala is the compiled RX
  gather; the measurement's masked-lane zeros with a still-delivered first packet is only
  self-consistent if masked lanes are ignored — which is what the code says.

The shear framing survives only under (i), and (i) is an **active-lane eye** problem, not a
**mask** problem. So even the steelman redirects to Design B/C, not to 0xFF.

---

## Summary

- **[VERIFIED-RTL] The measured die_b slice `[0x00000000,0x00005b4c,0xb5a60000,0xf1e2d3c4]`
  is a flawless 0xE4 4-lane SYNC word**: active lanes {2,5,6,7} carry their exact correct
  SYNC slices; masked lanes {0,1,3,4} read 0 **by design** (LinkLayer RX gather discards
  masked lanes, `LinkLayer.scala:765-777`). Lane-0 = 0 is not a shear.
- **[INFERRED, high confidence] `LANE_MASK_RESET=0xFF` will not fix intermittent delivery.**
  The 4-lane word already assembles correctly; the failure is the one-shot data-mode anchor
  downstream (Design B/C). 0xFF changes bandwidth/width and *raises* alignment risk.
- **The 0xFF build is a one-line env change** (`TD_AUTO_LANE_MASK_E4=0`) + matching recipe
  (`TD_MASK=0xff`, winscan-all-8) + both-die deploy. Rebuild-only, ~0.5 day. It should ride
  along with the real fix (best-tested config, 2× bandwidth) — but not be sold *as* the fix.
- **Confirming/refuting measurement:** delivered-vs-dropped raw slice `0x212C–0x2138`. An
  **active** lane going zero/wrong on a dropped packet would revive lane-mask; identical
  slices (the expected result) refute it and hand the problem to the re-anchor designs.
- **Honest panel recommendation:** do **not** rank Design A as the delivery fix. Adopt 0xFF
  only as a coverage/bandwidth upgrade bundled into whichever re-anchor design wins, and
  only after a winscan eye sweep proves all 8 KR260 lanes have rate margin (ribbon risk, §3.4).
