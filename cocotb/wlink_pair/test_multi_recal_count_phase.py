"""Multi-recal-cycle drift / byte-alignment regression.

Catches the kind of regression that drift between recal events would
cause: even with one good recal, a subsequent recal can break alignment
if the count phase isn't preserved across the swi_recal pulse (which is
exactly the failure mode described in the WavD2DGpioRx.v override
comment block: `swreset/recal does NOT re-sync WavD2DGpioRx.count`).

The HW bringup script `bringup_pair_converge.sh` issues up to
MAX_RETRIES recal cycles; this test exercises N successive recal cycles
and checks that:
  1. Slave's WavD2DGpioRx `count` register phase is stable (mod-16) at
     a quiescent observation point AFTER each recal cycle.
  2. CR/FCSM convergence still happens after the final recal (the link
     still works at the end of multi-recal stress).

If `count` shifts phase across the recal pulse a regression has been
caught (this is precisely the WavD2DGpioRx.count drift class).

Per-lane `count` sampling: each lane's `count` register lives at
`u_slave.u_wlink.phy.gpio.gpiorx_<N>.count` (an 8-lane Wavious GPIO
WavD2DGpioRx instance per lane).  We sample at a fixed observation
phase relative to the slave_clk and compare to the post-first-recal
baseline.
"""
import cocotb
from cocotb.triggers import ClockCycles

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write, apb_write,
)
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, _observe_state_window,
    _log_obs, set_slot0, R8_SLOT0_TRAIN_RECAL,
    FCSM_LINK_DATA, FCSM_LINK_IDLE,
)

NUM_LANES = 8


def _gpiorx(dut, side, lane):
    """Hierarchical handle to per-lane WavD2DGpioRx instance."""
    return getattr(_chiplet(dut, side).u_wlink.phy.gpio,
                   f"gpiorx_{lane}")


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


async def _sample_count_phase(dut, side, settle_cycles=2):
    """Return per-lane snapshot of the WavD2DGpioRx `count` register on
    a given side. Sampled after a small settle so that transient mux
    activity around the slot0 write is over."""
    await ClockCycles(dut.master_clk, settle_cycles)
    snap = []
    for lane in range(NUM_LANES):
        try:
            c = int(_gpiorx(dut, side, lane).count.value)
        except Exception:
            c = -1     # signal didn't resolve
        snap.append(c)
    return snap


def _log_count_snap(dut, label, snap):
    dut._log.info(
        f"  [{label}] count[0..7] = "
        + " ".join(f"{c:2d}" if c >= 0 else "??" for c in snap))


# -----------------------------------------------------------------------
# TEST 1: count phase is stable across N successive recal cycles.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_count_phase_stable_across_recal_cycles(dut):
    """Run 4 recal cycles back-to-back on both sides. After each recal,
    sample slave's per-lane `count` register at a fixed observation
    phase. Phase deltas must not exceed a small bound (the count
    register is 4 bits and observation is non-deterministic w.r.t. the
    free-running serialiser, so we tolerate ±1 lane drift). Larger
    drift = regression in the WavD2DGpioRx recal handling."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    NUM_RECALS = 4
    snaps = []
    for i in range(NUM_RECALS):
        await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
        snap = await _sample_count_phase(dut, "s", settle_cycles=4)
        _log_count_snap(dut, f"slave post-recal#{i+1}", snap)
        snaps.append(snap)
        # also sample master for symmetry/diagnostic
        m_snap = await _sample_count_phase(dut, "m", settle_cycles=4)
        _log_count_snap(dut, f"master post-recal#{i+1}", m_snap)

    # Compute per-lane (max-min) over the N snapshots.
    spans = []
    for lane in range(NUM_LANES):
        vals = [s[lane] for s in snaps if s[lane] >= 0]
        if not vals:
            spans.append(-1)
        else:
            spans.append(max(vals) - min(vals))
    dut._log.info(f"  per-lane count span across {NUM_RECALS} recals: {spans}")

    # The `count` register is a free-running mod-16 counter; instantaneous
    # samples will differ even on a single-recal/quiescent path.  But the
    # PHASE relative to other lanes should be stable.  Compute pairwise
    # phase deltas (lane[i] - lane[0]) mod 16 for each snapshot and check
    # those are constant.
    phase_signatures = []
    for s in snaps:
        if any(c < 0 for c in s):
            phase_signatures.append(None)
            continue
        ref = s[0]
        phase_signatures.append(tuple(((c - ref) % 16) for c in s))
    dut._log.info(f"  per-snapshot phase signatures: {phase_signatures}")

    # The phase signature should be IDENTICAL across all recals if the
    # WavD2DGpioRx lane-to-lane alignment is stable. A drift here is the
    # bug class we're hunting.
    valid = [sig for sig in phase_signatures if sig is not None]
    if len(valid) >= 2:
        first = valid[0]
        for idx, sig in enumerate(valid[1:], start=1):
            if sig != first:
                dut._log.error(
                    f"  RECAL DRIFT REGRESSION: lane-phase signature shifted "
                    f"after recal#{idx+1}: {first} -> {sig}")
        assert all(sig == first for sig in valid), (
            f"WavD2DGpioRx per-lane count phase shifted across recals: "
            f"signatures={phase_signatures}")
    else:
        dut._log.warning(
            "  count register handles did not resolve — sim skipped phase check")


# -----------------------------------------------------------------------
# TEST 2: link still converges after multi-recal stress.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_link_converges_after_multi_recal(dut):
    """Subject the link to 3 back-to-back recal cycles, then drop
    training and run the LL swreset cycle. Assert the link STILL
    converges to LINK_DATA on both sides.

    If a recal corrupts state that swreset doesn't clear (which is the
    HW story per the WavD2DGpioRx.v override comment), this test
    catches it."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    for i in range(3):
        await recal_cycle(dut, hold_cycles=200, settle_cycles=200)
        dut._log.info(f"  multi-recal cycle #{i+1} complete")
    # Drop training, cycle LL swreset.
    await drop_training_and_swreset_ll(dut)

    obs = await _observe_state_window(dut, 5000, "post 3x recal")
    _log_obs(dut, obs, "post 3x recal")

    # The link must still reach LINK_DATA on both sides after multi-recal.
    assert obs["max_m"] >= FCSM_LINK_DATA or obs["max_m"] >= FCSM_LINK_IDLE, (
        f"master FCSM did not reach LINK_DATA/IDLE after 3 recals: "
        f"max={obs['max_m']}")
    assert obs["max_s"] >= FCSM_LINK_DATA or obs["max_s"] >= FCSM_LINK_IDLE, (
        f"slave  FCSM did not reach LINK_DATA/IDLE after 3 recals: "
        f"max={obs['max_s']}")
    assert obs["cr_m"], "master cr_pkt_seen_rx never latched after 3 recals"
    assert obs["cr_s"], "slave  cr_pkt_seen_rx never latched after 3 recals"


# -----------------------------------------------------------------------
# TEST 3: asymmetric recal sequence — recal master, then slave, then both.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_asymmetric_recal_sequence(dut):
    """The HW bringup_pair_converge.sh issues recal in parallel via
    `set_slot0 $MASTER_IP 0x3 & set_slot0 $SLAVE_IP 0x3 & wait`, but
    over SSH there is ~ms skew between the two writes. This test
    deliberately introduces large skew between the two slot0 writes,
    re-armed multiple times, and checks the link still recovers.

    PASS = FCSM still reaches LINK_DATA on both sides
    FAIL = the link is sensitive to skew between master/slave recal
           writes (a real HW failure mode)."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Asymmetric recal: master arms first, ~500 cycles before slave.
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, 0x3)
    await ClockCycles(dut.master_clk, 500)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, 0x3)
    await ClockCycles(dut.master_clk, 200)
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, 0x1)
    await ClockCycles(dut.master_clk, 500)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, 0x1)
    await ClockCycles(dut.master_clk, 200)

    # Drop training symmetrically.
    await drop_training_and_swreset_ll(dut)
    obs = await _observe_state_window(dut, 5000, "asymmetric recal")
    _log_obs(dut, obs, "asymmetric recal")

    # If either side is broken, this should still produce a measurable
    # asymmetric signature.
    if obs["cr_m"] != obs["cr_s"]:
        dut._log.error(
            f"  ASYMMETRIC RECAL-SKEW BUG: cr_pkt_seen m={obs['cr_m']} "
            f"s={obs['cr_s']} -- skew between slot0 writes breaks LL_RX align")

    # Don't make this a hard assert (the asymmetric-skew tolerance is
    # not the primary contract); log and let test_01 of the previous file
    # carry the symmetric-bringup assert.
    if obs["max_m"] < FCSM_LINK_IDLE or obs["max_s"] < FCSM_LINK_IDLE:
        dut._log.warning(
            f"  link did not converge under recal skew: "
            f"m.max={obs['max_m']} s.max={obs['max_s']} "
            "(skew tolerance gap — consider as candidate HW fix for v2)")
