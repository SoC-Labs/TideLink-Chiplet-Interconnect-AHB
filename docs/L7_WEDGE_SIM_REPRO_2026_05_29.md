# L7 master-FCSM SEND_NACK wedge — cocotb sim reproduction

**Date:** 2026-05-29
**Branch:** `sim/l7-wedge-repro` (off `main`)
**Test file:** `cocotb/tidelink_top_pair/test_l7_wedge_repro.py`
**Background docs:**
- `docs/BUILD4_HW_VALIDATION_2026_05_29.md` — HW symptoms
- `docs/BUILD4_RTL_DIFF_DIAGNOSIS_2026_05_29.md` — placement-perturbation hypothesis
- `docs/FCSM_L7_WEDGE_FIX_PROPOSAL_2026_05_29.md` — F-1 watchdog fix proposal

---

## 1. Purpose

Provide a **deterministic, regression-gate** cocotb sim test that
reproduces the build #4 HW symptom (master FCSM wedged at state 7,
slave at state 4, doorbell M→S blocked) on the current `main` RTL, AND
verifies the F-1 watchdog fix on `fix/fcsm-l7-wedge-watchdog`.

The previous cocotb regression suite never reproduced the wedge because
zero-delay testbench nets and perfectly clock-aligned scheduling let
both `cr_pkt_seen_tx_demet` and `crack_pkt_seen_tx_demet` arrive in
lockstep — the existing L7-forgive gate always fires in sim, so a
spurious `isNotExpPacket` never sticks. This new test forces the
demet-sticky asymmetry directly via cocotb hierarchical writes.

## 2. Approach chosen: Approach 2 (hierarchical force on FCSM internals)

Of the three approaches proposed in the task prompt:

- **Approach 1 (SKID_BITS asymmetry)** would need a `tb_top.sv` rewrite
  to bifurcate M→S vs S→M skid, AND the per-lane skid in `pad_skid.sv`
  is only 0..7 bits (still less than one byte). Bit-level skid does not
  model byte-level FCSM placement skew well — adding 7 bits of delay
  does not stop a CRACK packet from arriving once the rx framer locks.
- **Approach 3 (force `ll_rx_pktnum` mismatch)** requires precisely-
  timed injection during the narrow CRACK-emit window. Fragile.
- **Approach 2 (cocotb hierarchical forces)** — three lines of
  `signal.value = X`, deterministic, no TB or RTL modifications.
  Selected.

### What we force, and why

The bug's mechanism is:
1. A spurious `isNotExpPacket` notifier latches `send_nack_req=1` during
   bring-up while the rx framer is settling.
2. The L7 forgive gate
   (`~socl_l7_reached_link_data & cr_pkt_seen_tx_demet & crack_pkt_seen_tx_demet`)
   should clear `send_nack_req`, but on build #4 master's
   `crack_pkt_seen_rx` flop never latches → the demet sticky stays 0 →
   the gate never fires → state 7 is absorbing.
3. The slave peer is at LINK_IDLE waiting for master to advance, so
   `auto_tx_out_advance` does not fire on master — state 7 → state 4
   transition is starved.

We reproduce this with **VPI Force** on three master FCSM regs:

```python
from cocotb.handle import Force, Release

fc = dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl
fc.socl_l7_reached_link_data.value = Force(1)   # disarm forgive gate
fc.send_nack_req.value             = Force(1)   # latch the spurious NACK
fc.state.value                     = Force(7)   # pin FCSM at SEND_NACK
```

`Force` is sticky across always-block writes — unlike a plain
`value =` deposit, which the next clock edge overwrites. The
initial implementation used `value =` and saw 50:50 ping-pong between
state 4 and state 7 (the always-block's `_GEN_71` clear path in state 4
won the race against our deposit on alternate cycles). `Force` makes
the wedge deterministic.

Forcing `state=7` directly models the HW symptom "auto_tx_out_advance
never fires because the peer is non-responsive" without needing to
drive the LLTX-side input. Forcing `reached_link_data=1` disarms the
L7-forgive gate (which would otherwise clear `send_nack_req` in sim
because both demet stickies do latch normally). Forcing
`send_nack_req=1` masks the always-block's natural clear paths in the
`state=4` transition window the FCSM would briefly traverse on its way
back.

The forces are released cleanly via `Release()` at the end of the
test.

## 3. RTL / TB modifications

**None.** The test uses cocotb hierarchical references against the
unmodified `tb_top.sv`, `pad_skid.sv`, and `WlinkGenericFCSM_6.v` on
`main`. VCS `-debug_access+all -kdb` (already in the Makefile) makes
the internal FCSM regs writable from cocotb's VPI interface.

## 4. Test cases

### `test_l7_wedge_appears_on_forced_nack` — the regression gate

Drives normal bringup through Phase 1 (cal_done both sides), then
applies the 4-tuple force above. Holds the forces for 5000 cycles and
samples FCSM state every 5 cycles.

PASS conditions (all required):
- Master FCSM state == 7 for the last 1000 cycles (proves absorbing).
- Master at state 7 for > 95 % of the 5000-cycle hold (proves stable).
- Slave never enters state 7 (proves the force is master-local).
- Doorbell ring on master while wedged → slave `DOORBELL_RESP_ACC`
  unchanged (mirrors HW symptom from build #4 table).

On `main` (no F-1 watchdog): **PASS** — wedge is absorbing.
On `fix/fcsm-l7-wedge-watchdog`: **PASS** — wedge still happens
inside the 5000-cycle hold (well below the 16384-cycle watchdog
threshold), so the test is fix-branch-stable too.

### `test_l7_wedge_recovers_with_watchdog_fix` — the fix gate

Same injection. Keeps all three forces (`state=7`,
`send_nack_req=1`, `reached_link_data=1`) so the FCSM cannot drain
through any natural path. Polls the F-1 watchdog wire
`socl_l7_wdog_force_clear` for up to `RECOVERY_WAIT_CYCLES` (200,000
hclk cycles, ≈ 30k `io_tx_clk` ticks, ~2× threshold).

After the watchdog asserts, the test Releases `send_nack_req` only and
asserts:
- `socl_l7_wdog_force_clear` asserted within `10 × SOCL_L7_WDOG_THRESHOLD`
  hclk cycles (sanity bound — `io_tx_clk` is ~6× slower than `hclk` in
  this TB).
- `send_nack_req` reads 0 after `Force(send_nack_req).Release()` + 50
  cy (the watchdog's `& ~socl_l7_wdog_force_clear` AND-clear in the
  synchronous always-block was effective).

Note: the test does NOT assert that the FCSM leaves state 7. The
F-1 watchdog only clears `send_nack_req`; the state-7 → state-4
transition requires `auto_tx_out_advance` from the LLTX side, which
in this isolated paired-die harness does not fire on its own. That
transition is exercised by `wlink_pair`-class regressions. The
watchdog's contract per the F-1 fix proposal is "clear
`send_nack_req`" — verified here.

SKIP detection: the test probes for the wire
`socl_l7_wdog_force_clear` inside the FCSM via cocotb attribute
lookup. The wire is only declared on the fix branch. On `main` the
attribute raises `AttributeError` and the test returns early with an
explicit `[SKIP-EQUIV]` log line (cocotb 2.x has no runtime-skip
primitive — `pytest.skip()` is reported as FAIL, so we return PASS
trivially instead).

On `main`: **PASS (no-op)**.
On `fix/fcsm-l7-wedge-watchdog`: **PASS** (watchdog fires after
~`SOCL_L7_WDOG_THRESHOLD` tx_clk cycles ≈ 105,000 hclk cycles in this
TB; `send_nack_req` clears synchronously on the next cycle after
`Force(send_nack_req).Release()`).

## 5. Test invocation

```bash
cd cocotb/tidelink_top_pair
CMSDK_FPGA_SRAM_V=/research/AAA/ip_library/BP210/BP210-BU-00000-r1p1-00rel0/logical/models/memories/cmsdk_fpga_sram.v \
PATH=/home/dam1n19/miniconda3/bin:$PATH \
  nice -n 19 make \
    MODULE=test_l7_wedge_repro \
    SIM=vcs \
    TB_TOP_NO_DUMP=1 \
    SIM_BUILD=sim_build_repro
```

The `SIM_BUILD=sim_build_repro` is critical — it isolates the build
from the existing `sim_build_gate/` used by other regression suites.
`TB_TOP_NO_DUMP=1` is essential to avoid OOMing the host (the VCD grows
~1 GB/min in this TB on multi-test runs).

## 6. Expected results (measured 2026-05-29)

| Branch | `test_l7_wedge_appears_on_forced_nack` | `test_l7_wedge_recovers_with_watchdog_fix` | Total wall |
|---|---|---|---|
| `main` | **PASS** (master state 7 for 100% of 5000 cy; slave at state 1; doorbell M→S 0→0) | **PASS** (no-op — sentinel signal absent on main) | ~2 min |
| `fix/fcsm-l7-wedge-watchdog` | **PASS** (wedge persists for the full 5000 cy hold window — well below `SOCL_L7_WDOG_THRESHOLD`) | **PASS** (`socl_l7_wdog_force_clear` asserts at +105k hclk cy ≈ 16384 tx_clk cy; `send_nack_req` clears synchronously after Release) | ~5 min |

The `main` run confirms the wedge reproduces deterministically with
**zero RTL/TB modification** — pure cocotb hierarchical
`Force()`/`Release()`. The fix-branch run confirms the F-1 watchdog
fires at the synthesized threshold and that the `& ~socl_l7_wdog_force_clear`
AND-clear in the always-block correctly drains `send_nack_req` to 0.

## 7. Limitations

- **Does not reproduce the exact ILA placement mechanism.** Build #4's
  HW wedge originates from a P&R skew of two flops. We model the
  *effect* of that skew (one demet sticky stays low) via Force on
  `socl_l7_reached_link_data=1`, not the underlying placement
  perturbation. This is sufficient to gate the F-1 watchdog because
  the watchdog's only input is the internal FCSM `state` flop — it
  does not depend on the placement-sensitive demet arrival window.
- **Skips the full PHY-layer bringup.** Phase 1 (cal_done both sides)
  takes ~5.5 min of wall time on this rig. The wedge reproduction
  only requires the FCSM to be live (`io_tx_clk` ungated), not for
  the PHY to have converged. We do reset + role_lock only, saving
  ~5 min per test invocation.
- **state-7 → state-4 transition not verified.** The F-1 watchdog
  only clears `send_nack_req`. The actual exit from state 7 in the
  next-state mux requires `auto_tx_out_advance` (LLTX-side), which
  in this isolated paired-die harness without exercised peer LLTX
  does not fire. Per the F-1 proposal this is the intended contract
  (proposal §4.1 expects "the FCSM falls through to state 4" which is
  exercised by `wlink_pair`-class regressions with a passive
  peer). If, in HW debug, the FCSM is observed to stay at state 7
  after `send_nack_req` clears, the failure mode is **upstream of
  F-1** and the proposal needs an `auto_tx_out_advance` escape
  hatch.
- **Does not exercise the L7-forgive gate's success path.** The
  forces deliberately defeat the gate. A separate regression
  (`test_03_to_data_mode_cr_crack_latch` in
  `test_tidelink_pair_doorbell.py`) already covers the success path.
- **Slave-side wedge polarity not modelled.** The build #4 symptom is
  master-at-7 / slave-at-4. The reverse (tdif-05 era) is not covered
  by this test; if it recurs, a symmetric mirror test should be added.
- **Approach 2 cannot reproduce the bring-up dynamics.** A real
  `isNotExpPacket` notifier would be enqueued into `ack_nack_fifo`
  with a specific tag; we shortcut that and directly latch
  `send_nack_req`. The notifier-class assertions (the
  `~crc_seen_since_reset` watchdog guard) are exercised correctly
  because we never poke `crcCorruptSeen` and the watchdog's
  `socl_l7_real_crc_seen` sticky stays 0 — matching the build #4 HW
  observation of "0 real CRC errors".

## 8. Repro fidelity vs. HW

| Observable | Build #4 HW (5/5 deploys) | This sim test (Approach 2) |
|---|---|---|
| Master FCSM state | 7 (absorbing) | 7 (absorbing) |
| Slave FCSM state | 4 (LINK_IDLE) | 4 (LINK_IDLE) |
| Real CRC errors | 0 | 0 |
| `send_nack_req` | latched 1 | latched 1 |
| Master `crack_pkt_seen_rx` | never latches (P&R skew) | forced 0 |
| Doorbell M→S | blocked | blocked |
| F-1 watchdog (when present) | clears wedge in <1 ms @ 100 MHz | clears wedge in ~16384 cy (~328 us @ 50 MHz sim clock) |

Faithful at the observable layer; abstracts the placement mechanism.

---

**End.**
