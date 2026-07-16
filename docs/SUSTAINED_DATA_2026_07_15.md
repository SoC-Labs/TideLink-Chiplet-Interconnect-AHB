# Sustained / continual data — status, and what "drops first ~2 words" actually was

**Date:** 2026-07-15  ·  **Branch:** `wip/sustained-data` (based on `cd2db38`)
**Scope:** sim only — no hardware (boards locked by a certification soak).

---

## 1. The headline

**IT REPRODUCES — but only under `EPOCH_PROFILE=silicon`.**

> **Correction (same day).** An earlier draft of this document concluded "does
> not reproduce". That conclusion was drawn from `EPOCH_PROFILE=zero` runs
> ONLY, and it was wrong. `zero` models an ideal, skew-free link; the bug needs
> the marginal cross-lane skew of the `silicon` profile (the v37 fingerprint,
> 3-7 words on the master's RX). Sweeping burst length under a perfect eye
> proves the datapath is sound and proves nothing about the channel. The
> profile is part of the experiment, not a detail.

Measured at `EPOCH_PROFILE=silicon`, `TD_SWEEP_LENS="8"`, each direction with
its **own** bring-up (so neither is cascade):

| direction | payload_len=8, isolated | signature |
|---|---|---|
| **s2m** (B→A, the marginal direction) | **FAIL** | `first_bad_idx=0`; `got[0] = 0xb2a00002` = **payload[2]** where the header should be |
| **m2s** (A→B) | **PASS** in isolation — but **FAIL** in a sweep after len=2 and len=4 | an **accumulated-traffic** effect, not a size threshold |

`got[0] == payload[2]` is the recorded silicon signature *verbatim*: the
phantom-pop entry describes the same burst coming back as **"26 words starting
at payload[2]"**. Under `zero` the same test is byte-exact at every size up to
126 words in both directions.

### This is already root-caused on another branch

`fix/stream-start-loss` commit **`330e2a7`** — *"fc: kill B→A stream-start
NACK/revert storm (L9c backward-mismatch re-ACK)"* — **is NOT in this base**
(`cd2db38`). Its analysis matches the s2m failure exactly: in
`WlinkGenericFCSM_6.v`, a data beat whose `ll_rx_pktnum` is *behind*
`exp_pkt_num` is treated as `isNotExpPacket` → NACK → the a2l replay reverts and
re-walks → a NACK→revert→re-walk storm that *"ratchets to credit-max and WEDGES
exp (POR-only clear), **losing the leading words of the transfer (silicon
26/28)**"*. Its fix re-ACKs a backward pktnum instead of NACKing it.

It also explicitly parks a residual **"a2b credit-return stall"** as out of
scope — which is very likely the m2s accumulation failure measured above.

**Recommended next step: validate `330e2a7` against this suite at
`EPOCH_PROFILE=silicon`.** Two independent instruments agreeing (its
`test_v2_stream_start_28w` and this burst sweep) would close the s2m half; the
m2s accumulation failure needs separate attention and is currently owned by
nobody.

### So what about the phantom-pop explanation?

The phantom-pop is **also** real, **also** produces a leading-word shift, and
was **also** recorded against a 28-word burst. Both mechanisms are live and
they alias onto the same silicon symptom, which is exactly why this bug has
been mis-attributed twice. Do not treat either as "the" answer without
re-measuring: the phantom-pop is a *reader* defect (fixed, `f9b94b7`), the
storm is a *link* defect (unfixed here, `330e2a7`).

The rest of this section (the 07-11 vs 07-14 record comparison) remains
accurate about the phantom-pop, but it is **no longer a sufficient explanation**
of the silicon report. The `project_allchan_soak_0of6_was_test_bugs`
memory entry that records it as a *"remaining REAL nuance … (FC/framer warmup)"*
was written on **07-11** and never updated after the **07-14** root-cause landed.

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

**Status: the phantom-pop is fixed; the FCSM stream-start storm is NOT (in this
base) and reproduces at `EPOCH_PROFILE=silicon`.** It has never been
re-tested on hardware since the fix. `fpga/hw_regression/sustained_data_soak.sh`
is the instrument to confirm it.

---

## 2. What sim now proves — UNDER `EPOCH_PROFILE=zero` ONLY

Everything in this section is the **ideal-link** result. It says the datapath,
the framer, the FIFO pointers and the credit accounting are sound when the eye
is perfect. It says **nothing** about the channel under real skew — see §1 for
the `silicon`-profile result, which FAILS.

`cocotb/tidelink_top_pair_v2/test_v2_pair_sustained.py` (`EPOCH_PROFILE=zero`):

| test | coverage | result |
|---|---|---|
| `test_10/11` | burst sweep **2, 4, 8, 16, 32, 64, 126** payload words, M→S and S→M | **PASS** every size, every word |
| `test_12/13` | 4 **back-to-back** packets, no inter-packet idle, both directions | **PASS** all packets |
| `test_14` | **bidirectional concurrent** bursts (both directions in flight) | **PASS** |

A 126-payload-word (128-word) burst lands with **0 missing, 0 shifted**,
`write_ptr=512`, `credit=3968` (= 4096−128, exact). There is **no leading-word
loss at any burst length in either direction — at zero skew.** Under
`EPOCH_PROFILE=silicon` the same suite fails s2m at len=8 (§1).

**The gate wires the `zero` profile only** (`sim_gate_v2_sustained`), because
the `silicon` profile is currently RED in this base and a known-red test cannot
block the gate. Once `330e2a7` (or an equivalent) lands, add a
`silicon`-profile run to the aggregate — that is the one that would actually
have caught this.

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

## 5. Throughput

**We still have no throughput number.** It cannot be obtained in this sim: the
pair TB models an idealised PHY and cocotb drives AHB directly, so any
words/sec figure would measure the testbench, not the channel.

`fpga/hw_regression/sustained_data_soak.sh` is board-ready and produces the
first real numbers. Invoke (boards free):

```sh
cd fpga/hw_regression
./sustained_data_soak.sh --sizes "4 16 64" --packets 8 --cycles 1
# full sweep:
./sustained_data_soak.sh --sizes "4 8 16 32 64 128" --packets 8 --cycles 3
# caller already holds the lease:
./sustained_data_soak.sh --no-lease
```

Read its header before quoting any number: `tx_wps` is the **PS store rate**
unless the burst exceeds the RX FIFO (the link word clock is 2.343 MHz / 426.7 ns
UI — compare against it), and `e2e_wps` includes SSH and is a **lower bound**.

---

## 6. What can only be answered on silicon

1. **Does the "first ~2 words" loss still occur at all?** Sim says the datapath
   is clean; the evidence says the silicon report was the phantom-pop. Only the
   board can confirm the fix holds.
2. **Real throughput** — sim cannot produce it (see above).
3. **Sustained traffic over the marginal lane 7** (~7 ns capture-clock skew,
   `project_lane7_is_clock_skew_not_eye`). Sim runs a perfect eye; a bit-error
   rate under *sustained* load is exactly what the clean-skew model cannot show.
   This is the most likely place a real sustained-data defect still hides.
4. **die_a FC fragility under repeated data-mode toggling** (needs a fresh
   deploy per trial) — a multi-cycle, real-hardware effect.
5. **Whether a truncated packet ever actually occurs in the field** (i.e. does
   `TX_STALL_TIMEOUT` ever fire). The fix is cheap insurance either way; the
   soak surfaces it via the `CREDIT_ABOVE_MAX` / `underrun` flags.
