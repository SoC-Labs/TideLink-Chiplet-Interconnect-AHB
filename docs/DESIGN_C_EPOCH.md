# DESIGN C — the EPOCH_ANCHOR_EN=1 path, and the deterministic-correct handoff

Panel seat C. Read-only RTL analysis + design proposal. Target
`/home/dam1n19/SoCLabs/tidelink`, V2 FPGA build (`flists/tidelink_fpga_v2.flist`).
Prepared for the 2026-07-22 KR260 intermittent-delivery panel, alongside 1A's
root-cause (`docs/DESKEW_ANCHOR_ROOTCAUSE.md`), Design A (LANE_MASK=0xFF) and Design B
(active re-anchor).

Every claim is tagged **[VERIFIED-RTL]** (traced to file:line the V2 flist compiles),
**[INFERRED]** (consistent with RTL + the HW measurements, not provable from RTL text) or
**[HW]** (measured on the 2026-07-22 KR260 session).

---

## TL;DR — my assigned approach loses. EPOCH is a red herring for THIS failure.

I was assigned to argue EPOCH_ANCHOR_EN=1 (beacon-independent anchor) + a firmware-gated
verified handoff. After decoding the actual hardware evidence against the RTL, **I cannot
honestly recommend it as the fix.** The single decisive fact:

**[HW+VERIFIED-RTL] The die_b "sheared SYNC word" is NOT a deskew shear — it is 4
correctly-deskewed active lanes plus 4 *masked* lanes reading zero. The lanes that read
their exact SYNC slice are EXACTLY the 0xE4 active-mask set; the lanes that read 0 are
EXACTLY the masked set.** The SYNC re-anchor already aligns every active lane byte-perfect.
EPOCH would compute the *same* offsets on those lanes and park the masked lanes at 0
**identically** (`tidelink_lane_deskew_v2.sv:1301-1303` vs the SYNC twin `:1490-1493`). It
produces a **bit-identical** out_data word. **EPOCH cannot help, because the deskew is not
what is wrong.**

The real levers are **Design A (LANE_MASK=0xFF — train all 8 lanes)** if the receive path
needs the full word, or **Design B (a data-mode re-anchor that tracks drift)** if it does
not — EPOCH is one-shot-per-training-window and fixes neither. Details and the decode
proof below; §4 is the load-bearing section.

---

## The decode that settles it (§4 preview, put first because it drives everything)

`TIDELINK_SYNC_WORD = 128'hF1E2_D3C4_B5A6_9788_796A_5B4C_3D2E_1F00`
(`deps/tidelink-phy/rtl/tidelink_sync_word.svh:37-38`, **[VERIFIED-RTL]**). Per-lane
16-bit slice `[16*gi +: 16]`:

| lane | correct slice | die_b measured [HW] | verdict |
|---|---|---|---|
| 0 | `1F00` | `0000` | **ZERO** |
| 1 | `3D2E` | `0000` | **ZERO** |
| 2 | `5B4C` | `5B4C` | correct ✓ |
| 3 | `796A` | `0000` | **ZERO** |
| 4 | `9788` | `0000` | **ZERO** |
| 5 | `B5A6` | `B5A6` | correct ✓ |
| 6 | `D3C4` | `D3C4` | correct ✓ |
| 7 | `F1E2` | `F1E2` | correct ✓ |

(measured raw post-deskew slice `0x212C-0x2138` =
`[0x00000000, 0x00005b4c, 0xb5a60000, 0xf1e2d3c4]`, **[HW]** 2026-07-22 Phase-1 probing,
identical across 6 re-SYNC + 3 full.py bring-ups.)

Lanes reading their **correct** slice: **{2, 5, 6, 7}**.
Lanes reading **zero**: **{0, 1, 3, 4}**.
Negotiated `LANE_MASK_RESET = 0xE4 = 1110_0100` → active bits **{2, 5, 6, 7}**, masked
**{0, 1, 3, 4}**.

**The correct-reading set is the active-mask set, exactly. The zero-reading set is the
masked set, exactly.** This is not a coincidence and it is not framer drift:

- Each of the 4 **active** lanes {2,5,6,7} is byte-perfect — its SYNC slice is present and
  correctly time-aligned into the assembled word. **The SYNC re-anchor deskew is working
  perfectly on every lane it is allowed to touch.**
- Each of the 4 **masked** lanes {0,1,3,4} reads 0 because the Wlink RX gather drops it and
  the deskew parks its offset at 0 by construction (`:1301-1303` / `:1490-1493`,
  **[VERIFIED-RTL]**). lane-0 = 0 is a **mask artifact**, not a mis-anchor.

So "the anchor lands deterministically WRONG" (1A's framing) is more precisely: *the anchor
lands deterministically RIGHT on the 4 lanes it owns, and the other 4 lanes are simply not
in the link.* `reanchored=1 / span=0` is therefore **honest, not vacuous** — it correctly
reports "the active lanes are anchored." The word looks sheared only because it is a
4-of-8-lane word displayed as if 8.

Consequence for my assigned lever: **[INFERRED, RTL-grounded]** EPOCH changes *which edge*
computes the offsets and *what triggers a re-measure*; it does **not** change *which lanes
are in the mask*, and it applies the **same** `lane_mask ? offset : 0` gate. On this board
state it lands the **identical** word. The knob is a red herring for the die_b A→B failure.

---

## 1. What EPOCH_ANCHOR_EN=1 actually changes [VERIFIED-RTL]

**Param + wiring.** `WavD2DGpio_v2.v:145` `parameter EPOCH_ANCHOR_EN = 1'b0`. The deskew
instance at `:837` drives `.SYNC_REANCHOR_EN(!EPOCH_ANCHOR_EN)` and `:882`
`.EPOCH_ANCHOR_EN(EPOCH_ANCHOR_EN)`. They are **mutually exclusive** — the deskew `$fatal`s
if both are set (`tidelink_lane_deskew_v2.sv:426-427`). So EPOCH_ANCHOR_EN=1 flips the whole
corrector: **SYNC re-anchor OFF, EPOCH anchor ON.**

**The knob is LIVE now (confirming the memory note).** Before the 2026-07-17 plumbing fix
(w2 `1c7684d`) the param arrived at WavD2DGpio but was **dropped** — u_deskew was hard-wired,
so EPOCH_ANCHOR_EN was a dead knob (`WavD2DGpio_v2.v:833-836`, header `:138-144`). Now it is
**forwarded**. Default is deliberately kept `1'b0` so the shipping build stays SYNC re-anchor
(bit-identical to the historical hard `1'b1`, `:831-833`). **[VERIFIED-RTL]** memory's
warning holds: leaving EPOCH_ANCHOR_EN=1 would silently switch the anchor over now that the
knob is live. Setting it requires a defparam/Wlink/WlinkGPIOPHY override + a **rebuild** (it
is an elaboration-time generate select, `:857 if (EPOCH_ANCHOR_EN)`, not a runtime strap).

**How the EPOCH anchor works, beacon-free** (`g_epoch_capture`,
`tidelink_lane_deskew_v2.sv:857-939` — note: this logic is in the DESKEW module, not in
WavD2DGpio; the task's "WavD2DGpio_v2.v:857-939" is really the deskew instantiation-parameter
block):

1. Each lane Hamming-scores its incoming word against its own **constant training pattern**
   slice `PATTERN_W[gi]` (`:858-863`), band `dist ≤ EPOCH_MATCH_THRESH(5)` or `≥ 11`
   (`:862-863`, thresh set at `WavD2DGpio_v2.v:866`).
2. After a match streak ≥ `EPOCH_STREAK_MIN` (8), the **first non-matching** word — the
   training-pattern→data transition — snapshots that lane's write index
   `ep_cand_idx <= wr_ptr_l` (`:928`), confirmed over `EPOCH_EXIT_CONFIRM` (2) non-matches
   with a single-match soft-abort (`:905-936`), then commits `ep_anchor_idx <= ep_cand_idx`
   (`:918`).
3. Read side (`:1234-1327`): per-lane offset from anchor-index **differences**
   `ep_delta[di] = ep_idx_sync1[di] - ep_idx_sync1[0]` over **active lanes only**
   (`:1238-1250`); gated by all-fresh + `EPOCH_SETTLE` (32) stable beats + span check.

**[VERIFIED-RTL] This anchors on the training-EXIT CONTENT edge and needs NO SYNC beacon.**
The pattern→data transition is present at *every* training exit. So EPOCH genuinely gives a
handoff anchor the SYNC path cannot: the SYNC re-anchor needs a SYNC beacon that the recipe
turns off in data mode (1A §2), whereas EPOCH triggers on the training-exit edge itself.
That is the *one* real advantage of my assigned lever, and it is a real one — **for the
bring-up handoff.**

**Does it re-anchor in data mode? NO — one-shot per training window, same as SYNC.**
`epoch_anchored` is sticky (`:1305`); offsets reload **only** on a *new* coherent, all-fresh,
span-OK anchor set — i.e. a **new training window** advancing the freshness counters
(`:1287 if (ep_apply)`, one-shot; `:1285-1286` "one-shot application per coherent anchor
set"). Between training windows — all through data mode — it is exactly as frozen as the SYNC
path. It buys a beacon-independent anchor **at each training exit**, not continuous tracking.

**[VERIFIED-RTL] It applies the identical mask gate.** `:1301-1303`
`lane_off_e[lo] <= lane_mask[lo] ? (ep_max_d - ep_delta[lo]) : '0`. Masked lanes → offset 0.
Span is measured over active lanes only (`:1240`). **Structurally identical masking to the
SYNC path** (`:1490-1493`). This is why EPOCH cannot change the die_b word (§0/§4).

---

## 2. The unstable-span risk [VERIFIED-RTL]

On a marginal eye the EPOCH matcher measures **noise**, producing a growing cross-lane span.
`ep_span > EPOCH_OFF_MAX (=24)` triggers the SPAN-REJECT self-heal
(`tidelink_lane_deskew_v2.sv:1292-1318`): offsets revert to 0 and `epoch_anchored <= 0`
(`:1314-1317`) — i.e. drop to plain prime-and-continuous **zero-correction**. The in-code
history records the exact silicon symptom (`:347-354`): *"die_a anc=0 on silicon, die_b a
noisier eye anchored with a garbage growing span."*

**When it bites:** on the KR260 marginal eye EPOCH risks either (die_a class) **failing to
anchor at all** (streak never satisfies, `anc=0`) or (die_b class) **anchoring on a garbage
span that self-heals to zero-correction**. It trades the SYNC path's wrong-slot risk for a
span-instability risk. `WavD2DGpio_v2.v:866-873` records the direct A/B result: on the
epoch-blind training pattern the "silicon span [was] unstable 0..12", which is why the build
was switched to SYNC re-anchor in the first place (2026-06-22).

**Can a firmware gate avoid it?** Partly, and only as a *veto*: firmware can read the span
before committing to data mode and refuse the handoff if the span is over budget or
`epoch_anchored` dropped — see §3. But a firmware gate cannot *make* a noisy eye produce a
stable span; it can only convert a silent bad-anchor into a visible bring-up retry. And per
§4 the die_b active-lane deskew is **already clean** under SYNC, so switching to EPOCH would
*introduce* this span-instability risk for no alignment benefit. Net: on this hardware the
unstable-span risk is pure downside.

---

## 3. `obs_anchor_verified` and the firmware-gated handoff — weaker than 1A hoped

1A flagged `obs_anchor_verified` as a strong "anchor landed exactly-right" latch. I confirm
its **meaning** but must **downgrade its usability**:

**[VERIFIED-RTL] Meaning.** `obs_anchor_verified_w` (`axi_chiplet_controller.sv:979`, comment
`:978`) feeds the winscan `ws_verify_q` — the zero-tolerance criterion that, with
`reanchored` engaged, a post-deskew word matches `TIDELINK_SYNC_WORD` **exactly on every
active lane** (`WavD2DGpio_v2.v:7-29`). A one-slot-off anchor can never fire it. Genuinely
strong.

**[VERIFIED-RTL] APB exposure — NOT a clean positive latch.** The raw `obs_anchor_verified_w`
wire is **not** directly muxed to any APB slot. What is exposed at **0x21B8 WINSCAN_OBS bit
[14]** is `ws_verify_stuck_q` (`axi_chiplet_controller.sv:2560`, decode `:1519-1520`): a
**sticky FAILURE latch** — set when `ws_anchor_q=1` (anchor latched) while `ws_verify_q=0`
(verify never asserted). So firmware reads the **negative**: `ws_verify_stuck_q==1` = "anchored
but NOT verified = bad." A clean positive "verified=1" is only inferable as
`reanchored(0x2140.bit0)==1 AND ws_verify_stuck_q(0x21B8[14])==0 AND attempts>0`.

**[HW-CAUTION] Address hazard.** 0x21B8 sits immediately adjacent to
`0x21AC / 0x21B0 / 0x21B4`, which memory (`reference_tidelink_address_map`) records as
**HARD-STALLing the CPU when probed**. 0x21B8 is decoded in the mux I read (slot 6) and is
*not* on the blacklist, but it is one word away — **a firmware read of 0x21B8 must be proven
safe on the deployed image before any bring-up depends on it.**

**The firmware-gated handoff spec (design #3), honestly rated:**

```
# hold R8 in SYNC (beacon on), do NOT switch to DATA until the anchor is verified
for attempt in range(N_RETRY):            # e.g. 8
    poke  R8 = 0x1C                       # SYNC mode, beacon flooding
    settle()                              # >= EPOCH_SETTLE / SYNC_CONFIRM periods
    reanchored = rd(0x2140) & 1
    stuck      = (rd(0x21B8) >> 14) & 1   # ws_verify_stuck_q  (VERIFY 0x21B8 SAFE FIRST)
    slice      = [rd(a) for a in (0x212C,0x2130,0x2134,0x2138)]  # ground-truth word
    if reanchored and not stuck and slice_matches_sync_on_active_lanes(slice):
        poke R8 = 0x10                    # ONLY NOW enter DATA mode
        break
    pulse R8 SYNC_OBS_CLR / re-SYNC       # re-arm and retry
else:
    fail_bringup()                        # refuse to enter data mode on a bad anchor
```

**Verdict on #3:** it is a real, low-cost mitigation for **State A/B** handoff failures
(never-engaged / wrong-slot), and `slice_matches_sync_on_active_lanes` is the trustworthy
check (raw slice is ground truth). **But it does not require EPOCH** — it works identically on
the shipping SYNC build, and it is really Design B's / 1A's fix-(c), not a property of my
assigned EPOCH lever. And critically, on the die_b evidence **this gate would PASS on every
retry** — the active lanes already match SYNC exactly, `reanchored=1`, so firmware would
happily enter data mode, and delivery would still be intermittent. **The gate cannot fix a
failure whose cause is downstream of the (already-correct) active-lane anchor.**

---

## 4. The killer question — would EPOCH land DIFFERENTLY? No. And the shear is UNTRAINED LANES.

**Does EPOCH land differently (correct) than SYNC?** **[INFERRED, RTL+HW grounded] No — it
lands identical.** Reasoning:

1. The SYNC re-anchor already aligns the 4 active lanes {2,5,6,7} **byte-perfect** (§0/§4
   decode — each reads its exact SYNC slice). There is **no residual shear on any active lane
   for EPOCH to correct.** Best case, EPOCH reproduces the same correct alignment.
2. EPOCH and SYNC apply the **identical** `lane_mask ? offset : 0` gate (`:1301-1303` vs
   `:1490-1493`, **[VERIFIED-RTL]**). Both park lanes {0,1,3,4} at 0. Both compute span over
   active lanes only. EPOCH **cannot** put a masked lane into the word.
3. Therefore EPOCH produces a **bit-identical** out_data word on this board state:
   `[0, 0x5b4c, 0xb5a60000, 0xf1e2d3c4]`. It does not "land differently" — there is nothing
   different for it to land on.
4. **Is EPOCH subject to the same per-lane-phase problem?** For the active lanes, both paths
   derive per-lane offsets from per-lane index differences measured on each lane's own
   `lane_clk` (SYNC: confirming `wr_ptr_l` `:766`; EPOCH: training-exit `wr_ptr_l` `:928`).
   Both equalise only if every active lane commits on the same event within the correctable
   span. On die_b the SYNC path *already* achieves this (exact slices) — so EPOCH is at best a
   lateral move on the axis that is already solved, and at worst it re-opens the §2
   span-instability that SYNC has closed.

**The concession — the zero lanes mean UNTRAINED lanes, and EPOCH is orthogonal.**
**[VERIFIED-RTL + HW]** lane-0 slice = 0 (and 1,3,4 = 0) because those lanes are **masked out
of the 0xE4 link and never trained** — the winscan recipe (`td_v2_hwlib.sh:135`, memory
`lane_mask_defect_is_the_winscan_recipe`) trains only {6,2,5,7}; the mask 0xE4 admits only
{2,5,6,7}; masked lanes are dropped by the Wlink RX gather and parked at offset 0 by the
deskew. **You cannot assemble an 8-lane word from 4 trained lanes, and no anchor knob —
SYNC, EPOCH, or a new one — changes that.** The deskew corrects *phase between lanes that are
in the link*; it does not *add lanes to the link*. If the receive path needs the full 8-lane
word, **the fix is Design A: `LANE_MASK_RESET=0xFF` + retrain all 8 lanes (a rebuild).**
EPOCH is orthogonal to it.

**Honest caveat that keeps me from over-crowning Design A too:** B→A delivered byte-exact on
the *same* 4-lane-class config (die_a RX), which proves a **4-lane word CAN cross** — the
Wlink RX gather genuinely drops masked lanes (`:1296` comment), so the masked-lane zeros are
**cosmetic** to the framer. If that is so for die_b too, then the die_b active lanes are
correct AND consumed correctly, and the A→B intermittency is the **within-bring-up drift /
framer re-hunt** (1A §2, **[INFERRED]**) — which is **Design B's** territory (a data-mode
re-anchor that TRACKS drift), and EPOCH's one-shot-per-training-window anchor does **not**
fix that either. So:

- **If the receive path needs 8 lanes** → root cause = the 0xE4 mask → **Design A** (rebuild
  0xFF). EPOCH orthogonal.
- **If 4 lanes suffice** (B→A proves it can) → root cause = data-mode drift with no
  re-measure → **Design B** (active/periodic re-anchor). EPOCH one-shot, doesn't help.

**EPOCH_ANCHOR_EN=1 does not win under either branch.** That is my honest competitive
finding.

---

## 5. Interactions — what EPOCH_ANCHOR_EN=1 costs

**[VERIFIED-RTL]** EPOCH_ANCHOR_EN=1 forces `SYNC_REANCHOR_EN=0` (`WavD2DGpio_v2.v:837`),
which **disables the SYNC re-anchor + `sync_dist` metric stack that the on-chip autonomy
depends on**: `v2_winscan_fsm` and `v2_autonomous_sync_detect` require the deskew
`reanchored` latch + `sync_dist` (`WavD2DGpio_v2.v:138-144`, header note). So EPOCH loses:

- the **winscan** eye-search FSM (its input metric `sync_dist` goes dead),
- the **autonomous SYNC detect / autoneg** path (the b2a autonomy channel — memory
  `drainguard_necessary_not_sufficient_b2a_residual`, closed via RETIRE_EN on the SYNC path),
- the `obs_anchor_verified`/`ws_verify_stuck` winscan verify observability from §3 (the
  winscan FSM is what produces it).

**Is that acceptable for a 4-lane deterministic-rate KR260 data build?** For a *bench* build
that boots with a fixed recipe (`full.py`, `R8` staged by hand) and a fixed rate — arguably
yes, autonomy is not exercised. **But** losing `obs_anchor_verified` removes the very signal
the §3 firmware-gated handoff wanted to read, so EPOCH and the verified-handoff idea are in
**tension**: choosing EPOCH throws away the winscan verify latch. And David's standing
requirement is that **hardware autonomy is MANDATORY for a deliverable** (memory
`hardware_autonomy_required` — "a firmware recipe is not a deliverable"). Disabling the
autonomy stack to select a knob that doesn't fix delivery is a bad trade for tapeout.

---

## 6. Effort + the single confirming measurement

**Effort.**
- EPOCH_ANCHOR_EN=1: **param flip → full FPGA rebuild** (elaboration-time generate,
  `:857`; not a runtime strap) → bench A/B. Medium. The `EPOCH_PROFILE=silicon` sim path is
  historically **RED/ungated** (memory `verification_audit`), so sim gives little assurance —
  it needs a real HW A/B, exactly what memory says EPOCH has always needed.
- Firmware-gated handoff (#3): **firmware/recipe only, no rebuild** — but works on the
  *shipping SYNC build* and doesn't need EPOCH. Low. (Verify 0x21B8 is safe to read first.)
- vs **Design A** `LANE_MASK_RESET=0xFF`: rebuild (one param) + re-run winscan over 8 lanes.
- vs **Design B** data-mode re-anchor: RTL change to the read-side latch semantics
  (one-shot→periodic) + keep a low-rate beacon alive; more work, but the only one that
  targets the within-bring-up drift.

**The single confirming hardware measurement (kills EPOCH cheaply, no rebuild):**
On the CURRENT SYNC build, with the mask at 0xE4, read the raw post-deskew slice
`0x212C-0x2138` on a **delivered** packet vs a **dropped** packet in the same bring-up:

- The active-lane slices {2,5,6,7} already read their exact SYNC values on a drop (proven
  2026-07-22). If they **also** read exact on a delivery and the word is otherwise identical,
  the deskew is provably NOT the discriminator → **EPOCH (which only changes the deskew
  anchor) cannot possibly be the fix.** Confirmed without ever building the EPOCH image.
- To decide A-vs-B: rebuild once with `LANE_MASK_RESET=0xFF`, retrain 8 lanes, re-measure
  delivery rate. If lanes {0,1,3,4} now carry their true slices AND delivery becomes reliable
  → the mask was the root cause (Design A). If 8 lanes train but delivery is still
  intermittent → drift/framer is the cause (Design B). Either way EPOCH is not implicated.

---

## Summary (competing honestly)

- **[VERIFIED-RTL]** EPOCH_ANCHOR_EN=1 is live now (w2 `1c7684d`), beacon-independent, anchors
  on the training-exit content edge — a real advantage **for the handoff** over the
  beacon-dependent SYNC path. But it is **one-shot-per-training-window** (no data-mode
  re-track), carries the **unstable-span** eye risk (`:1292-1318`, `:347-354`), and applies
  the **identical mask gate** (`:1301-1303`).
- **[HW+VERIFIED-RTL — decisive]** The die_b "sheared" word is 4 correctly-deskewed active
  lanes + 4 masked lanes reading zero: correct-set = `{2,5,6,7}` = exactly the 0xE4 active
  mask; zero-set = `{0,1,3,4}` = exactly the masked set. **The SYNC deskew already aligns
  every lane it owns byte-perfect.** EPOCH computes the same offsets and lands the
  **bit-identical** word.
- **Killer question answered:** EPOCH would **not** land differently — there is no active-lane
  shear to correct, and it cannot un-mask a lane. The zero lanes are **untrained/masked**, so
  EPOCH is **orthogonal**; the levers are **Design A (LANE_MASK=0xFF)** if 8 lanes are needed,
  or **Design B (data-mode re-anchor)** if 4 suffice (B→A proves 4 can cross). EPOCH wins
  under neither.
- **`obs_anchor_verified`** is real but exposed only as the **negative** `ws_verify_stuck_q`
  at **0x21B8[14]** (an address adjacent to CPU-hard-stall regs — verify safe first); the
  firmware-gated handoff it enables is worthwhile but belongs to the SYNC build, not EPOCH,
  and would PASS on die_b (active lanes already verify) without fixing delivery.
- **Recommendation:** **do not flip EPOCH_ANCHOR_EN.** It rebuilds the image, disables the
  mandatory autonomy stack, adds eye risk, and lands the identical word. Spend the effort on
  the LANE_MASK=0xFF rebuild (Design A) and/or the data-mode re-anchor (Design B), and
  disambiguate with the one delivered-vs-dropped slice read above before building anything.
