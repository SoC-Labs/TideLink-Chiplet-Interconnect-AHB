# WS2 — make AUTONOMOUS bring-up behave like the MANUAL recipe

`src/rtl/local_overrides/axi_chiplet_controller.sv` (+ `src/rtl/tidelink_top.sv`,
`fpga/vivado_ip/tidelink_vivado_wrapper.v` plumbing)

Author: WS2 (FSM behaviourist), 2026-07-11. Phase A — design + build-ready
diffs only, no Vivado build, no rig.

## 0. The failure this addresses (and its real boundary)

MEASURED smoking gun: on the autonomous (zero-poke) path a die that has linked
up **degrades** over ~minutes; disarming autonomy (`NEGO_CFG=0`) restores BOTH
dies to golden `sync_seen_vec = 0xe4`.

Mechanism the MANUAL recipe avoids and the autonomous FSM does not:

* MANUAL `enter_data_mode()` takes **one** sample, fires the one-shot re-anchor
  (`swi_sync_obs_clr` is a W1-pulse), then **quiesces** — a human retries a bad
  draw.
* AUTONOMOUS leaves the calibrator re-arming and the winscan re-clearing:
  `swreset = swi_recal_r | local_swreset_pulse_w`, and the winscan
  `WS_FIN_CLRLOW` retry re-pulses `ws_obs_clr` up to 5×. Each re-clear **wipes
  every lane's sticky `sync_seen_l`**, so the machine re-rolls the *all-active-
  lanes-in-one-clear-to-clear-window* commit — a `p^N` lottery (N = active
  lanes; `0xe4` ⇒ N=4). One marginal lane eventually loses the draw and takes
  the whole link down.

**Boundary (from prior RTL-verified work, memory 2026-07-11):** the residual
degrade on the current builds is a **physical lane-7 eye** (the degrading die
reads `sync_seen=0x64`, bit-7 missing). Winscan-stop already *works as designed*
— it cannot lock when a lane is physically down, and it should not. So the value
here is **determinism + a decisive instrument**, not a promise of link-up on a
dead lane. Every change below is DEFAULT-OFF and cannot regress the manual/master
path.

## 1. What shipped on the candidate (part a, CONVERGE-LOCK) — finalized

`WINSCAN_CONVERGE_LOCK_EN` (default `1'b0`; the FPGA wrapper drives `1'b1`) was
already threaded wrapper → `tidelink_top` → controller. It latches
`ws_conv_lock_q` on first convergence and gates `ws_kick_evt` + the FINALIZE
clear-retry storm so a later training episode cannot re-arm the sweep. Verified
present and correct; both re-roll paths are stopped once converged (the
calibrator re-sweep is independently masked by `cal_eye_converged_r`).

### 1a finalize — VERIFY-gate the lock (new param `WINSCAN_CONVLOCK_VERIFY_EN`, default 0)

**Latent hazard in the shipped SEEN-only lock:** `ws_conv_lock_q` sets on
`all_sync_seen_apb` (SEEN). A lane can read `sync_seen=1` yet be **mis-anchored**
— it committed an *adjacent* SYNC slot (tol-5 Hamming on a marginal eye; the
`0x24->0x5c` byte-lane signature). `reanchored` then latches offsets from the
wrong indices, `ws_anchor_q` rises, the SEEN-path FINALIZE preempt releases, and
`ws_conv_lock_q` **permanently blocks the winscan re-clear/re-roll that would fix
the mis-anchor** — a stranding lock.

Fix: with `WINSCAN_CONVLOCK_VERIFY_EN=1` the lock additionally requires
`ws_verify_q` (`io_anchor_verified` — the ENGAGED anchor reproduced the KNOWN
beacon EXACTLY on every active lane on one post-deskew beat; a wrong-slot lane
can pass SEEN but never VERIFY). So the durable lock can never latch a
mis-anchored link. If verify never asserts, the lock simply never engages and the
winscan keeps re-rolling (== the pre-lock behaviour) — the **safe** failure,
never a wrong-anchor lock. Default 0 keeps the FPGA-validated SEEN-only lock
bit-identical; recommend driving it 1 from the wrapper once verify is
silicon-trusted.

## 2. Part (b) — per-lane STICKY-ACCUMULATE: STOPPED at a reviewed design; instrument shipped

### 2a Why a naive datapath accumulate is a stranding hazard (NOT shipped)

Within one clear-to-clear window `sync_seen_l` is **already** sticky per lane —
a committed lane stays committed until the next `sync_obs_clr`. The `p^N` lottery
exists ONLY because the winscan retry keeps **re-clearing** before the slowest
lane joins. To "accumulate across clears" you must make a lane's commit survive
`sync_obs_clr`. But that **directly defeats the mis-anchor re-roll** (the R-A
safety): a lane that latched a *wrong-but-consistent* index would stick forever
and pin `reanchored` on a garbled alignment that never re-confirms. That is the
exact PARTIAL-LOCK / stranding hazard, and it is **critical at 100 MHz** where a
late/marginal lane joins after the others.

To do it safely you would need **per-lane VERIFIED** (not just SEEN) as the
accumulate gate + a **bounded watchdog** that resets the whole accumulator if the
active set is not verified within a bound (mandatory re-roll, kills stranding).
The per-lane VERIFIED signal exists (`dbg_lane_any_match_w` — zero-tolerance
post-deskew exact per-lane compare in `WavD2DGpio_v2.v`), BUT it is **post-deskew**
so it presupposes the anchor already engaged on that lane — it can *sustain* a
lock, it cannot *bootstrap* the first latch (circular). Combined with the
measured fact that the dominant residual is a **physically-down** lane (where
accumulate yields zero benefit and only adds stranding surface), and Phase-A
having **no build/silicon** to validate the watchdog, shipping a datapath
accumulate would ship the stranding hazard the task forbids. **STOPPED here.**

### 2b What IS shipped — `PERLANE_STICKY_ACC_OBS_EN` (default 0), observability only

A per-lane accumulator `sync_seen_acc_r` (apb_clk) latches the **UNION** of every
active lane that has committed `sync_seen` since the last training-mode RISE —
i.e. across all of this episode's clear-retries — exposed at
**`0x4403_215C[15:8]`**. It feeds **no gate and no datapath**, so it cannot
strand a lane. It answers the open question on silicon, decisively:

* union reaches `0xe4` while the SIMULTANEOUS `all_sync_seen` never does ⇒ the
  `p^4` one-window lottery is the blocker → a *safe* datapath accumulate (2a)
  would win, and is worth the design cost.
* union ALSO stuck sparse (`0x64`) ⇒ the missing lane is **physically down** →
  accumulate is useless; spend the effort on the lane-7 eye, not the FSM.

This is instrument-before-fix: it converts "should we build the risky
accumulate?" from a guess into a register read.

## 3. Part (c) — fold `enter_data_mode` into the FSM (`AUTO_DATA_MODE_EN`, default 0)

The FC data-mode **handoff** (the `0x208` LL-swreset bootstrap) is ALREADY
autonomous (`test_v2_autonomous_fc_handoff` reaches byte-exact A→B data with zero
pokes). The only remaining piece of the manual `enter_data_mode()` is the
**SYNC-strip** (`R8=0x10`, `swi_sync_insert_en → 0`). The D2 history deleted the
old *timed* SYNC-off because it RACED the peer's `WS_FINALIZE` re-anchor.

`AUTO_DATA_MODE_EN=1` re-introduces it on a **deterministic** gate instead of a
timer: `auto_data_mode_q` engages (and the heal drives `insert_en→0`) only once
`ws_conv_lock_q & ws_verify_q & ws_anchor_q & fch_done_r` hold for
`AUTO_DM_SETTLE` cycles, and **re-arms** (re-inserts beacons) the instant
`ws_anchor_q` drops. Requires `WINSCAN_CONVERGE_LOCK_EN=1`.

**Recommendation: leave OFF.** Idle-gated insert (`insert_en=1`, `force_always=0`)
is already data-safe (it costs one idle slot per 32 words, never a payload slot),
so the strip is cosmetic. Worse, a **full** strip re-opens a residual
mutual-starvation window: if die_a strips its TX beacon after it converges and
die_b later loses anchor, die_b's RX needs die_a's beacons to re-anchor but
die_a (still anchored) keeps them stripped. The re-arm only reacts to the LOCAL
anchor. A truly safe (c) needs a **bilateral-converged** handshake before either
die strips. Shipped default-OFF so "true zero-poke" is available for a bench
experiment, but not recommended for silicon until the bilateral gate exists.

## 4. Bit-identical guarantee (params OFF == manual/master path)

Every effect is gated on its own param AND (a/c) on `autonomy_armed`:

* `WINSCAN_CONVLOCK_VERIFY_EN=0` ⇒ `ws_conv_lock_ok = all_sync_seen_apb & (… | ~0)`
  = the shipped SEEN-only condition.
* `PERLANE_STICKY_ACC_OBS_EN=0` ⇒ `sync_seen_acc_r` never written, `sync_seen_acc_w`
  tied 0 ⇒ `0x215C` read unchanged.
* `AUTO_DATA_MODE_EN=0` ⇒ `auto_data_mode_q` const-0 ⇒ the F1b heal's `else` arm
  always runs (D2 permanent idle-gated `insert_en=1`).

The new per-lane-obs and (c) logic is additionally `` `ifdef TIDELINK_PHY_V2 ``
(the per-lane deskew sync_seen path is V2-only), so V1 is untouched. Params are
default-OFF at all three levels (wrapper, `tidelink_top`, controller); the manual
(`nego_en=0`) path never enters the `autonomy_armed` blocks.

## 5. Verification

MEASURED (VCS 2022.06-SP2, `flists/tidelink_fpga_v2.flist`, `TIDELINK_PHY_V2`,
`cocotb/tidelink_top_pair_v2`):

* Elaboration params ON (all four params `1'b1` on BOTH dies via
  `+define+TB_TOP_WS2_ON`): `simv` built, **0 errors / 0 warnings**.
* `test_v2_autonomous_fc_handoff` params ON, `BYPASS_AUTONEG=0`: **PASS** —
  `train_ok=True` (228k cycles), bilateral **FCSM=4 (cr=crack=1)** on both dies,
  a **byte-exact** packet crossed M→S over the V2 deskew, ZERO host pokes.
* Params-OFF (`test_v2_autonomous_fc_handoff`, no `TB_TOP_WS2_ON`): **PASS** —
  same VERDICT, and the run reaches it at the **identical sim-time
  (4642580.00 ns)** as params-ON, i.e. a bit-for-bit identical bring-up
  trajectory. No regression.

INFERENCE (by construction, section 4): the params-OFF netlist is the pre-change
netlist; the OFF path exercises none of the new logic. NOTE the sim is zero-skew,
so it does NOT stress the marginal-lane p^4 lottery (that needs a marginal-eye /
silicon rig — Phase B); the sim proves elaboration + no-regression + that
enabling the params does not break the zero-poke handoff, not the lottery fix
itself (which is why (b) ships as an instrument, not a datapath change).

Exact commands (from `cocotb/tidelink_top_pair_v2/`, after `source ../../set_env.sh`):

```
# params ON, silicon-faithful autonomous handoff:
make BYPASS_AUTONEG=0 MODULE=test_v2_autonomous_fc_handoff EXTRA_DEFINES=+define+TB_TOP_WS2_ON
# params OFF baseline (must stay byte-exact and identical to pre-change):
make BYPASS_AUTONEG=0 MODULE=test_v2_autonomous_fc_handoff
```

Follow-ups needing a build/rig (Phase B/C): read `0x4403_215C[15:8]` on the
degrading die with `PERLANE_STICKY_ACC_OBS_EN=1` to settle p^4-vs-physical;
enable `WINSCAN_CONVLOCK_VERIFY_EN` on the FPGA once verify is trusted.
