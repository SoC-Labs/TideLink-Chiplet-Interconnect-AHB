# Sustained / continual data — status, and what "drops first ~2 words" actually was

**Date:** 2026-07-15, **substantially corrected + measured on silicon 2026-07-16**
**Branch:** `wip/sustained-data` (based on `cd2db38`)

---

## 1. The headline — SETTLED ON SILICON: it does NOT reproduce

**The recorded "long-burst drops first ~2 words (both directions)" does NOT
reproduce on hardware, at any burst length from 4 to 1024 payload words, in
either direction, with a validated instrument.**

Measured 2026-07-16 on the certified `cd2db38` bitstream, zero-poke autonomous
bring-up (fcsm 4/4, reanchored both), byte-checking **every** word including
the leading two:

| payload words | A→B | B→A |
|---|---|---|
| 4, 8, 16, 32, 64, 128 (×8 back-to-back packets) | **PASS** 8/8 each | **PASS** 8/8 each |
| 256, 512, 1024 | **PASS** | **PASS** |

**24/24 measurements byte-exact. Zero dropped words.** The instrument was
adversarially validated on the *same live link* immediately before each sweep
(`--negctl`, see §3a) — a no-send drain, a wrong-seed compare, and a
deliberately 2-word-shifted expectation all came out RED (the shift detected at
`FIRSTBAD=0`, i.e. the exact recorded signature IS visible), while the positive
control was GREEN.

This confirms the **07-14 phantom-pop attribution**: the 07-11 report was the
harness's pre-send `rxn` drain popping a phantom packet and walking `read_ptr`
2 words. Both halves of that fix are in this base (RTL `f9b94b7`, harness
`f3c5359`), and with them the symptom is gone from silicon.

### RETRACTED: "it reproduces at `EPOCH_PROFILE=silicon`"

> An earlier revision of this document (commits `cd33ca0`, `25a06bb`) claimed
> the bug **did** reproduce under `EPOCH_PROFILE=silicon`, having first claimed
> it did not. **Both the claim and its "correction" were wrong.** The claim was
> drawn from a comparison with no valid control.
>
> **The control that settles it** (run 2026-07-16): under the *same*
> `EPOCH_PROFILE=silicon` compile, the baseline single-packet suite
> `test_v2_pair_data` — one 4-word packet — **also fails, 2 of 3**, including
> `test_01_bilateral_linkup`. A profile that **cannot bring the link up** cannot
> be used to demonstrate a *burst-length* effect. The sustained suite's failures
> there are that same pre-existing redness, not a sustained-traffic defect.
>
> Verified **not** caused by this branch: reverting `tidelink_fifo_ctrl.sv` to
> pristine `cd2db38` and recompiling reproduces the identical 2/3 failure.
>
> Why it went unnoticed: **every `sim_gate` target runs `EPOCH_PROFILE=zero`.**
> The `silicon` profile lives only in the un-gated `v2_gate` target, so nothing
> keeps it green and it has evidently been red for some time.
>
> A previous revision pointed at `fix/stream-start-loss` (`330e2a7`, a B→A
> FCSM NACK/revert storm, not in this base) as the culprit behind the s2m
> failure. That attribution rested entirely on the retracted result above. It
> may still be a real defect on its own merits, but **this suite provides no
> evidence for it**, and the silicon measurement above argues against it being
> the recorded burst symptom. Do not cite this document as support for it.

**Lesson, re-earned for the third time in this file's own history: a FAIL
proves nothing about your hypothesis until a control shows the setup is green
when the hypothesis is false.** The instrument trap in §3 was caught; this
control trap was not, and it inverted the headline twice.

### The phantom-pop IS the explanation

The silicon sweep above (24/24 byte-exact, 4..1024 words) closes this: with the
phantom-pop fixed, the symptom is gone. The `project_allchan_soak_0of6_was_test_bugs`
memory entry that records it as a *"remaining REAL nuance … (FC/framer warmup)"*
was written on **07-11**, never updated after the **07-14** root-cause landed,
and is the misdiagnosis. It should be corrected to point at the phantom-pop.

Line the two records up — they are the **same experiment**:

| record | date | observation | attribution |
|---|---|---|---|
| `project_allchan_soak_0of6_was_test_bugs` | 07-11 | "a 28-word A→B burst delivered words 2..27 clean but dropped the first ~2" | "FC/framer warmup" |
| `project_rxfifo_empty_read_phantom_pop` | 07-14 | "a pre-send `rxn` drain made a byte-exact 28-word burst read back as **26 words starting at payload[2]**; removing the drain restored byte-exactness (soak 0/6 → 8/8)" | **pre-send drain → phantom pop → `read_ptr` walks exactly 2 words** |

Same burst size, same two leading words, same direction. The 07-11 entry is the
**misdiagnosis**; the 07-14 entry is the root cause. The RX aperture is
address-translated by `read_ptr` (`tidelink_fifo_ctrl.sv:141`), so a 2-word
pointer walk shifts *every* later read by 2 words — which reads exactly like
"the first 2 words were dropped".

Both halves of the phantom-pop fix are in this base:
* RTL `f9b94b7` — `&& !rx_fifo_empty` on the length-latch arm.
* Harness `f3c5359` — `gate_data` no longer pre-drains.

**Status: the phantom-pop is fixed, and 2026-07-16 CONFIRMED that fix on
hardware** — `fpga/hw_regression/sustained_data_soak.sh --negctl`, 24/24
byte-exact, 4..1024 payload words, both directions (§1). The claim that an
"FCSM stream-start storm reproduces at `EPOCH_PROFILE=silicon`" is RETRACTED
(§1): that profile is red at link-up in this base, so it demonstrates nothing.

---

## 2. What sim proves — UNDER `EPOCH_PROFILE=zero` ONLY

Everything in this section is the **ideal-link** result. It says the datapath,
the framer, the FIFO pointers and the credit accounting are sound when the eye
is perfect. It says **nothing** about the channel under real skew. (The
`silicon` profile cannot fill that gap: it is red at link-up in this base — §1.
Real skew coverage comes from the **silicon** measurement in §1, not from sim.)

`cocotb/tidelink_top_pair_v2/test_v2_pair_sustained.py` (`EPOCH_PROFILE=zero`):

| test | coverage | result |
|---|---|---|
| `test_10/11` | burst sweep **2, 4, 8, 16, 32, 64, 126** payload words, M→S and S→M | **PASS** every size, every word |
| `test_12/13` | 4 **back-to-back** packets, no inter-packet idle, both directions | **PASS** all packets |
| `test_14` | **bidirectional concurrent** bursts (both directions in flight) | **PASS** |

A 126-payload-word (128-word) burst lands with **0 missing, 0 shifted**,
`write_ptr=512`, `credit=3968` (= 4096−128, exact). There is **no leading-word
loss at any burst length in either direction — at zero skew.** This now agrees
with silicon (§1), where the same is true up to 1024 payload words under real
skew.

**The gate wires the `zero` profile only** (`sim_gate_v2_sustained`), matching
every other `sim_gate` target. **This is a known gate hole:** the `silicon`
profile is red at link-up in this base (§1) and nothing gates it, so nobody
noticed. Getting `EPOCH_PROFILE=silicon` green and gated is a real piece of
work and is **unowned** — it is the coverage that would make the epoch-skew
deskew trustworthy in sim rather than only on a board.

### Why the old oracle could not have seen it
`send_and_check` (the `v2_pair_data` gate) asserts only `got[0]`, `got[2]`,
`got[3]` — it never checks `got[1]`, and it only ever runs at `payload_len=2`.
A 2-word shift is invisible to it. `send_and_check_burst` diffs **all**
`length+2` words.

---

## 3. The trap: the first "reproduction" was the instrument

The bug appeared to reproduce beautifully — clean threshold, PASS at
payload_len ≤ 8, FAIL at ≥ 16, with **~2 words destroyed every ~16 words**. It
was **entirely a harness artifact**.

`ahb_tx_write_word`'s two `for _ in range(50)` waits had **no else-clause**. The
FC adapter *honestly* back-pressures (holds `HREADYOUT` low) whenever its
1-entry skid / replay FIFO is full — the normal condition for any burst longer
than the replay depth on a link ~20× slower than `hclk`. Past 50 cycles the
loops silently fell through:

* the address phase was driven while `hready=0`, so `tx_valid_addr_phase`
  (`tidelink_fc_adapter.sv:278`, requires `ahb_tx_hready`) never accepted it →
  the address was dropped;
* the data phase then executed **`hwdata = 0`** → a zero word was left on the bus.

**The tell was the injected zero.** Dumping the FC write stream at the RX FIFO
showed `slot=18 data=0x00000000` — real data never turns into a clean zero at a
16-word cadence. Note how convincing the artifact was: a stable threshold, a
periodic signature, and "~2 words" matching the recorded silicon bug exactly.

### The same hazard is in 5 more environments (LATENT — not fixed here)

`grep -rln "for _ in range(50)" cocotb/` — the identical "wait 50 cycles for
`hready`, then fall through and zero `hwdata`" pattern also lives in:

* `cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`
* `cocotb/tidelink_top_pair/test_data_path_compliant.py`
* `cocotb/tidelink_top_pair_wordskew/test_tidelink_pair_doorbell.py`
* `cocotb/tidelink_top/test_tidelink_top.py`
* `cocotb/tidelink_system/test_tidelink_system.py`

(The repo convention is a per-environment copy of the helpers, so the bug was
copied with them.) They are **dormant**: each only ever sends short (~4-word)
packets, which never fill the replay FIFO, so back-pressure never reaches 50
cycles. **Only `tidelink_top_pair_v2` is fixed here** — deliberately: fixing
five more envs would change the drivers under `t30`/`t31`/`t32`/`t33` without
the budget to re-validate each, which is risk with no demonstrated need.

**But the moment anyone lengthens a burst in those envs, the bug wakes up and
will look exactly like an RTL data-loss defect.** Fix the driver there *first*,
before believing any long-burst result from them.

---

## 3a. The silicon sweep's controls (`--negctl`) — why its PASS is believable

§3 is why a green result from this family of harnesses is not self-evidently
true. The silicon sweep came back **12/12 then 24/24 PASS on its first runs** —
exactly the shape that has burned this project before (the pair TB delivered
B→A "byte-exact" on RTL that was 0/10 on silicon; it was blind to the SRAM
X-init phantom-pop).

So `sustained_data_soak.sh --negctl` runs three adversarial controls **on the
same live link, immediately before the sweep**. Each must come out RED:

| control | what it would catch | result |
|---|---|---|
| **NEG-1** drain with nothing sent | oracle reading residue / stale bytes | **RED** `ok=0 bad=1`, credit=4096=MAX |
| **NEG-2** send seed X, expect seed Y | oracle not comparing payload at all | **RED** `ok=0 bad=1` |
| **NEG-3** correct send, expectation shifted 2 words | **the recorded signature being invisible** | **RED** `FIRSTBAD=0` |
| **POS** correct send, correct expectation | link sick ⇒ reds prove nothing | **GREEN** |

NEG-3 anchors on `FIRSTBAD=0`, not on the verdict alone: `underrun` is *sticky*
and NEG-1's deliberate empty read sets it, so a bare RED could otherwise have
meant "packet never arrived" rather than "the shift was seen".

**NEG-3 is the load-bearing one**: it proves that if silicon *were* dropping the
first two words, this instrument would say so. That is what makes §1's PASS a
result rather than a shrug.

Two ordering lessons, both already in the feedback files and both re-earned:
1. **Measure before theorising.** Dumping the RX SRAM by hierarchy (no AHB read)
   split "arrived wrong" from "read back wrong" in one run and killed four
   competing theories.
2. **Isolate every data point.** The first sweep was cumulative: sizes 32/64/126
   all returned *identical stale bytes* because the len=16 failure desynced the
   FIFO. Only the first failure was real data; the rest were cascade artifacts.

---

## 4. A real defect found on the way: credit minted ABOVE max

`tidelink_fifo_ctrl.sv` — the credit counter saturated at **zero** on
`write_complete` (the BUG-002 underflow fix) but had **no ceiling** on
`read_complete`. Reproduced with **no harness misbehaviour**: `credit 4096 →
4106` after a *protocol-legal* drain of a **truncated** packet.

The `f9b94b7` guard does **not** cover this. It stops an AHB read of offset 0
from *arming* the length latch on an empty FIFO — but `packet_active_r` /
`packet_word_length_r` / `read_target_addr_r` are **also** armed by the FC
**write** path (`fc_write_addr0`). If a header arrives and the packet never
completes, they stay armed; a later legal drain hits `read_target_addr`,
`read_complete` fires (gated only by `packet_active_r`), and credit is minted
above max. The RX then **over-advertises buffer space to the peer**.

**Reachable by design on silicon:** after `TX_STALL_TIMEOUT` (2^16 hclk) of
continuous back-pressure the FC adapter *deliberately* abandons the in-flight
beat with an AHB ERROR (`tidelink_fc_adapter.sv:250-300`). If that beat is a
packet's last word, this is exactly the state entered. Link errors and a
data-mode toggle mid-packet do the same.

**A/B verified 2026-07-16** (the fix is not decorative, and the test is not
vacuous): reverting `tidelink_fifo_ctrl.sv` to pristine `cd2db38` and
recompiling makes `test_v2_truncated_pkt_credit` **FAIL** with
`credit=4106 > MAX=4096`; with the fix restored it reads `credit=4096` and
**PASSES**. Same test, same TB, only the RTL differs.

**Fix:** saturate at `MAX_CREDITS` — the exact mirror of the write side.
**Inert on the healthy path:** a committed packet decrements by the same
`packet_delta` the matching read increments by, so credit never legitimately
reaches MAX from below and the clamp cannot fire on a correct exchange.
**Gated:** `test_v2_truncated_pkt_credit`, wired into `sim_gate` (now 14 suites).

This is the **third** pointer/credit defect in this subsystem
(phantom-pop → truncated-packet credit), all of the same family: *a completion
signal that fires for a packet the FIFO is not actually holding.* The remaining
untouched sibling is the **write-side twin** (`:184` — a write to offset 0
latches a new packet length, so writing zeros to "clear" the window walks
`write_ptr`); it may be an intended CPU-inject path — check before changing.

---

## 5. Throughput — MEASURED (2026-07-16). ~48.8k words/s, ~2.1% of ceiling

**The first throughput number TideLink has ever had.**

`sustained_data_soak.sh`'s Python sender reports ~24-27k words/s. **That number
is not the channel.** The same ctypes store loop into *anonymous memory* (no
AXI, no link) tops out at **96k words/s** on this PS — the instrument's own
ceiling is ~24× *below* the 2.343 MHz link, so it can never saturate the
channel. Every words/sec figure Python has printed is a property of CPython.

`fpga/hw_regression/td_tput.c` (compiled C, volatile stores into the mmap'd TX
aperture, timed on-board) measures it properly:

| payload words | total | words/s | ns/word |
|---|---|---|---|
| 4 | 6 | 107,687 | 9,286 |
| 16 | 18 | 52,806 | 18,937 |
| 64 | 66 | 49,159 | 20,342 |
| 256 | 258 | 48,731 | 20,521 |
| 1024 | 1026 | 48,876 | 20,460 |
| 2040 | 2042 | 48,829 | 20,480 |

The rate **bends and plateaus at ~48.8k words/s = 20.48 µs/word**, flat across
a 32× burst-size range.

**Headline:** ~**48.8k words/s ≈ 195 kB/s** sustained payload = ~**2.1% of the
2.343 Mword/s theoretical ceiling** — i.e. **~48 link UIs per 32-bit word**.

### Why the plateau is the DUT and not the host

20.48 µs is *simultaneously* 48.0 link UIs (426.67 ns) and 2048 hclk (100 MHz).
The link clock is derived from hclk, so **arithmetic alone cannot separate**
"link back-pressure" from "the PS↔PL bridge is slow". `td_tput --busref` is the
control: a **non-link** PS→PL access (APB STATUS read — same GP port, same AHB
bridge, never touches the FC adapter) costs **7.94 µs**, non-posted.

The plateau is DUT-imposed because it is:
1. **2.6× above** the non-link bus cost;
2. **below the sender's own unblocked rate** — the 4-word point runs at 107k
   words/s because the CPU write buffer absorbs a short burst; and
3. **invariant across 64..2040 words**, landing on an *exact integer* multiple
   of the link UI.

A host- or bus-imposed limit would not bend with burst size and would not land
on 48.0 UIs.

**This is not a correctness defect** — the same bursts are byte-exact (§1).
Whether the ~48 UI/word cost is inherent to Wlink LL packetisation + credit
return, or is a tunable inefficiency, is now **the biggest open performance
question** and is unowned.

```sh
# throughput (link must be up):   sudo ./td_tput --sweep ; sudo ./td_tput --busref
# correctness sweep + controls:
./sustained_data_soak.sh --sizes "4 8 16 32 64 128" --packets 8 --negctl
```

---

## 5a. Held-link duration — and the "1/40 link death" that wasn't

`linkhold_soak.sh` had **never been run** (its own header said so). Its first
run: **1/40 bursts byte-exact over 20 min, first failure at t=+30 s** — a
textbook time-correlated death, the exact V1-saga signature it was built to
hunt.

**It was the instrument.** The tell was on every failing line:

```
HOLD_BURST 7 t=+180s FAIL rx=0x00000000 ... fcsm_a=4 fcsm_b=4 credit_b=31 reanchored_b=1
```

A dead link does not report fcsm 4/4 + reanchored + full credit. And the data
was all-**zeros**, not corruption — a pointer symptom, not a channel one.

**Proof it was not the link:** immediately after the 20-minute hold, with the
link untouched, a B→A framed 16-word packet came back **byte-exact** (B→A is
the direction linkhold never touches, so die_a's RX FIFO was uncorrupted). The
link had been alive the whole time.

Two bugs, both fixed (`83157d8`):
1. **`td_v2_hwlib.sh: ZP_TX_WORDS` was 3 words**, commented "header + 2
   payload". The frame is `length+2` words; header `0x00240000` declares
   `length=2` ⇒ **4** words. Every `zp_txburst` sent a **truncated** packet that
   never completed. Now identical to the certified `send_a2b` frame.
2. **`linkhold_soak.sh` pre-drained offsets 0..3** before every send. Offset 3
   is `read_target_addr = (length+1)*4` — reading it **fires `read_complete`**
   and pops `length+2 = 4` words, while the truncated writer had advanced
   `write_ptr` by only 3. `read_ptr` walked **1 word past `write_ptr` per
   burst**, so from burst 2 on every read landed on unwritten SRAM. Burst 1
   "passed" only because an incomplete packet's words are still readable in the
   RX SRAM.

The drift **persists until POR**: re-running the *fixed* script on the
already-walked FIFO still read 0/20 from burst 1, and only a power-cycle
cleared it — itself a confirmation of the mechanism.

**RESULT after POR + fix: `HOLD_RESULT 24/24 bursts byte-exact over 12min`**
(zero-poke autonomous, all 4 words checked, fcsm 4/4 + reanchored + credit 31
throughout). A clean A/B on the same script and the same link: 0/20 → 24/24.

`zeropoke_proof.sh` shares `ZP_TX_WORDS` and inherits the fix. It never read
offset 3 so it never drifted — but its `(h)` data gate had been validating a
packet that **never completed**, passing on raw SRAM readback alone.

---

## 5b. Gate status

`make sim_gate` — **14/14 PASS** on this branch (2026-07-16), including the two
suites this work added (`v2_pair_sustained`, `v2_truncated_pkt_credit`):

```
apb_fc_cfg_preempt PASS · fch_apb_watchdog PASS · fifo_rx_phantom_pop PASS
t30 PASS · t31 PASS · t32 PASS · t33 PASS · v1_elab PASS
v2_autonomous_sync_detect PASS · v2_pair_data PASS · v2_pair_sustained PASS
v2_truncated_pkt_credit PASS · v2_winscan_fsm PASS · zeropoke_por PASS
```

The manual/recipe path is untouched: the only RTL change is the §4 credit
clamp, which is inert on a correct exchange (proved by the A/B above — the
clamp cannot fire unless credit is already being minted for a packet the FIFO
does not hold).

---

## 6. Answered on silicon 2026-07-16 — and what is still open

**Answered:**
1. **Does the "first ~2 words" loss still occur?** **No.** 24/24 byte-exact,
   4..1024 payload words, both directions, validated instrument (§1, §3a).
2. **Real throughput?** **~48.8k words/s ≈ 195 kB/s, ~2.1% of ceiling** (§5).
3. **Sustained traffic over the marginal lane 7?** Exercised: B→A lands on
   die_a's RX (lane 7) and was byte-exact at every size to 1024 words, and the
   20-minute held-link soak ran A→B bursts every 30 s with no degradation.

**Still open / unproven:**
1. **The ~48 UI/word protocol cost** (§5) — the biggest performance question;
   unowned. Is it inherent to Wlink LL packetisation + credit return, or tunable?
2. **`EPOCH_PROFILE=silicon` is red at link-up and ungated** (§1, §2) — the sim
   coverage for real skew does not exist. Unowned.
3. **True link saturation.** Even compiled C tops out ~107k words/s unblocked
   (~9.3 µs/store) vs a 2.343 Mword/s link. Every instrument we have is far
   slower than the raw link; the ~48.8k plateau is the *path's* acceptance rate.
   Proving the PHY's own ceiling needs a DMA/PL-side generator, not the PS.
4. **Long-duration beyond ~20 minutes** and **bit-error rate under continuous
   load** — the held-link soak is a burst every 30 s (24/24 over 12 min, §5a),
   not saturation, and the link was separately proven alive at t=+20 min. The V1
   saga died at ~20 min; we now clear that bar, but not a multi-hour one, and
   nothing here runs the link at its ~48.8k words/s ceiling for hours.
5. **die_a FC fragility under repeated data-mode toggling** (needs a fresh
   deploy per trial) — untouched here.
6. **Whether a truncated packet ever occurs in the field** (does
   `TX_STALL_TIMEOUT` fire). The §4 fix is cheap insurance either way; the soak
   surfaces it via `CREDIT_ABOVE_MAX` / `underrun`. Note the silicon controls
   showed credit correctly pinned at 4096=MAX and **never above** it.
7. **RX-FIFO TWIN 2** (`tidelink_fifo_ctrl.sv:189` write-side length-latch,
   `project_rxfifo_twins_rootcause_2026_07_16`) — same defect family as §4,
   still live and unguarded, needs the AHB-write-intent decision. Not reachable
   by this soak (which never CPU-writes the RX FIFO), so these PASSes say
   nothing about it.
