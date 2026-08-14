# CORRECTION: the step-6c liveness verdict in 00_run.log is INVALID — ignore it

`00_run.log` records:

    LIVENESS: 17 samples, 1 distinct low-words, stall bits moved = False
    => stall bits NEVER moved under active write load. Treat the sampler as DEAD
       (TL-039/TL-040) ... including TL-009's 0xad800000.

**That conclusion does not follow, and the test that produced it is not valid.**
Do not cite it, and do not use it to void TL-009.

## Why the test is underpowered

`stall_live[9:0]` and `any_stall_live[22]` are **combinational** — `valid & ~ready`
*on that cycle* (`src/rtl/tidelink_axinode_obs.sv:78-90`). They are a live snapshot,
not a latching event recorder.

The step-6c sampler polls `0x21E0` over SSH, one `eth_tlapb_poke.py` invocation per
sample: roughly **1 sample/second**. The app_clk domain runs at order 10^8 cycles/s,
and an individual AXI backpressure stall lasts order nanoseconds. So each sample
inspects ~1 cycle out of ~10^8, and 17 samples inspect ~17 cycles out of ~10^9.

Probability of catching a stall is ~0 **even if the sampler is perfectly healthy.**
The observed "never moved" is therefore fully consistent with a working instrument
and carries no information about liveness. A negative result from a test with no
power is not evidence of absence.

## What would be a valid liveness test

The bits that can survive a slow poll are the ones that **latch**:

1. **wedge_sticky[19:10]** — latches after `2**WEDGE_LOG2` stalled cycles and holds.
   Provoke a real sustained stall and read the sticky at leisure. This is the
   sampler-liveness proof that slow APB polling *can* observe.
2. **On-board per-beat sampling** — `kr260_eth_soak_fwd.py snap_health()` samples
   Region F per beat, on the board, at loop speed rather than SSH speed. That path
   already ran in step 6b and returned `data_healthy=1` with no sticky. It is orders
   of magnitude better powered than step 6c, though it still cannot prove liveness
   without a provoked stall.
3. **Deliberate backpressure** — hold the AXI target off (or run the guard-disabled
   variant) so a stall is guaranteed present, then confirm the bits report it.

## Status of the surrounding claims

- **TL-009's `0xad800000` is still an UNSOUND INFERENCE** — but for the original,
  independent reason: `wedge_sticky`/`stall_live` need `valid & ~ready` and
  `resp_err` latches only on a completed handshake, so a never-driven B is invisible
  to this word **by construction**. That argument stands on the RTL and does not
  depend on this liveness test at all.
- **TL-039/TL-040 remain open as instrument concerns**, unproven either way. This run
  did NOT convict the sampler and did NOT clear it.
- Pre-registration note: `PREREGISTERED_PREDICTIONS_2026_08_13.md` prediction 3 framed
  this as a binary that would either validate or convict the instrument. That framing
  was wrong — there was a third outcome, "the test cannot see either way", and that is
  what happened. Recording it rather than quietly dropping it.
