# Sustained / continual data — status, and what "drops first ~2 words" actually was

**Date:** 2026-07-15  ·  **Branch:** `wip/sustained-data` (based on `cd2db38`)
**Scope:** sim only — no hardware (boards locked by a certification soak).

---

## 1. The headline

The recorded silicon bug **"long-burst drops first ~2 words (both directions)"**
**does NOT reproduce in sim**, and the evidence says it was never a link or
framer defect in the first place: it is the **phantom-pop**, which was already
root-caused and fixed on 2026-07-14. The `project_allchan_soak_0of6_was_test_bugs`
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

Both halves of the fix are in this base:
* RTL `f9b94b7` — `&& !rx_fifo_empty` on the length-latch arm.
* Harness `f3c5359` — `gate_data` no longer pre-drains.

**Status: strongly evidenced, not yet silicon-confirmed.** It has never been
re-tested on hardware since the fix. `fpga/hw_regression/sustained_data_soak.sh`
is the instrument to confirm it.

---

## 2. What sim now proves

`cocotb/tidelink_top_pair_v2/test_v2_pair_sustained.py` (`EPOCH_PROFILE=zero`):

| test | coverage | result |
|---|---|---|
| `test_10/11` | burst sweep **2, 4, 8, 16, 32, 64, 126** payload words, M→S and S→M | **PASS** every size, every word |
| `test_12/13` | 4 **back-to-back** packets, no inter-packet idle, both directions | **PASS** all packets |
| `test_14` | **bidirectional concurrent** bursts (both directions in flight) | **PASS** |

A 126-payload-word (128-word) burst lands with **0 missing, 0 shifted**,
`write_ptr=512`, `credit=3968` (= 4096−128, exact). There is **no leading-word
loss at any burst length in either direction.**

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
