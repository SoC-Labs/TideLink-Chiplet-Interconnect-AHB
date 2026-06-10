"""I2 gate (PLAN_TIDELINK_INTEGRATION §3) — dual-die POR reset-skew sweep.

test_22 proved the simultaneous-POR path is clean and explicitly warned
that "a real fix is still needed for any asymmetric POR (warm-restart,
partial-reconfig, etc.)". This test is that gate: the master die comes
out of POR first and the slave die's reset release is delayed by a
swept amount, with ZERO APB activity on either die. The RTL POR
defaults (NEGO_CFG_RESET=0x61, NEGO_TRAIN_CFG_RESET=0x0001,
role_strap-derived priority) must resolve roles and train on both dies
for every skew point.

Skew points (chosen against the autoneg timescales at 50 MHz hclk and
the 100 kHz I2C prescale):

  200 us  — slave arrives while master is still in its first
            ST_NEGO_WAIT backoff / early CLAIM (an I2C byte is ~80 us);
            classic "deploy second board a beat late".
  1 ms    — slave arrives mid-CLAIM-retry: master has already NACK'd
            against the absent peer at least once (ITEM-2 retry path +
            slave re-arm must absorb this).
  3 ms    — slave arrives after several full CLAIM retries; this is the
            silicon Bug-N11 cascade window in miniature.

Mechanics: tb_top.sv exposes per-die reset gates (m_por_gate /
s_por_gate, default 1). The test holds s_por_gate=0 across the global
poresetn release, then raises it after the skew. The tb also squashes
the in-reset die's PHY pads to 0 so the live master's RX is not
X-poisoned (matches real silicon: pads driven low / Hi-Z under reset).

IMPORTANT — RTL POR defaults vs the tb force block: the tb's
BYPASS_AUTONEG=0 force window lasts 5 us from t=0. For every nonzero
skew the slave's POR-reset clause re-runs AFTER that window, so the
slave boots from the genuine RTL parameter resets — exactly the
contract I2 wants gated. (The master still gets the t=0 force, which
matches the RTL POR values anyway.)

Pass bar per skew point: both dies role_locked=1 with opposite roles,
the WINNER (whichever die arbitrated to master) has train_ok=1, and
NEITHER die parked in ST_ERROR / ST_TRAIN_FAIL.

OBSERVED BEHAVIOUR (2026-06-10, first run of this gate): at every
nonzero skew the early die exhausts its solo claim against the absent
peer and parks ST_NEGO_DONE-lost (role-locked SLAVE); the late die then
wins arbitration unopposed and trains (ST_TRAIN_DONE, train_ok=1). So
the Bug-N11-era asymmetric-POR cascade RESOLVES with the merged
N-series + ITEM-2 NACK-retry + slave re-arm machinery — but boot order
overrides the strap preference. If a deployment needs the strap to be
authoritative regardless of boot order, that is a separate (currently
unrequested) feature: the early die would need to re-arbitrate when a
late peer appears instead of honouring its solo-loss park.

Run
---
    cd cocotb/tidelink_top_pair
    BYPASS_AUTONEG=0 TB_TOP_NO_DUMP=1 \\
        make MODULE=test_24_por_skew_sweep
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


CLK_PERIOD_NS     = 20.0     # 50 MHz hclk
REF_CLK_PERIOD_NS = 8.0

ST_NAMES = {
    0:  "ST_IDLE", 1: "ST_NEGO_INIT", 2: "ST_NEGO_WAIT", 3: "ST_NEGO_CLAIM",
    4:  "ST_NEGO_POLL", 5: "ST_NEGO_DONE", 6: "ST_BYPASS", 7: "ST_ERROR",
    8:  "ST_NEGO_MASK_RES_TX", 9: "ST_NEGO_MASK_RD_ADDR",
    10: "ST_NEGO_MASK_RD_DATA", 11: "ST_NEGO_DONE_PRE", 12: "ST_TRAIN_ENTER",
    13: "ST_TRAIN_RUN", 14: "ST_TRAIN_POLL_PEER", 15: "ST_TRAIN_EXIT",
    16: "ST_TRAIN_DONE", 17: "ST_TRAIN_FAIL",
}

ST_TRAIN_DONE = 16
ST_TRAIN_FAIL = 17
ST_ERROR      = 7

# Skew points in microseconds (see module docstring for rationale).
SKEWS_US = [200.0, 1000.0, 3000.0]

# Budget per skew point for autoneg + training to resolve on BOTH dies.
# test_22 resolved at ~15 ms from simultaneous POR; add the skew itself
# plus headroom for the master's solo CLAIM/retry spinning.
BUDGET_MS = 120.0


def _safe_int(sig, default=-1):
    try:
        return int(sig.value)
    except (ValueError, AttributeError, TypeError):
        return default


def _state_name(st):
    return ST_NAMES.get(st, f"UNKNOWN({st})")


def _autoneg(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    return top.u_chiplet_controller.u_autoneg


def _idle_stimulus(dut):
    for prefix in ("m", "s"):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0xF
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_tx_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_tx_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_tx_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_tx_hready_in").value = 1
        getattr(dut, f"{prefix}_ahb_fifo_hsel").value      = 0
        getattr(dut, f"{prefix}_ahb_fifo_haddr").value     = 0
        getattr(dut, f"{prefix}_ahb_fifo_htrans").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hsize").value     = 2
        getattr(dut, f"{prefix}_ahb_fifo_hwrite").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hwdata").value    = 0
        getattr(dut, f"{prefix}_ahb_fifo_hready_in").value = 1


async def _run_one_skew(dut, skew_us, log):
    """One full POR cycle with the slave's reset release delayed skew_us."""
    m_an = _autoneg(dut, "m")
    s_an = _autoneg(dut, "s")

    # Assert global reset with the slave gate already closed.
    dut.m_por_gate.value = 1
    dut.s_por_gate.value = 0
    dut.poresetn.value = 0
    dut.hresetn.value  = 0
    await ClockCycles(dut.hclk, 50)

    # Master comes out of POR alone.
    dut.poresetn.value = 1
    await ClockCycles(dut.hclk, 5)
    dut.hresetn.value  = 1

    # Hold the slave in reset for the skew window.
    skew_cycles = int(skew_us * 1000.0 / CLK_PERIOD_NS)
    await ClockCycles(dut.hclk, skew_cycles)
    log.info(f"  [skew={skew_us:.0f}us] releasing slave reset "
             f"(master autoneg state={_state_name(_safe_int(m_an.state_r))})")
    dut.s_por_gate.value = 1

    # Poll to terminal states.
    poll = 200
    budget_cycles = int(BUDGET_MS * 1_000_000 / CLK_PERIOD_NS)
    waited = 0
    last_log = 0
    log_every = 250_000   # ~5 ms

    while waited < budget_cycles:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        m_st = _safe_int(m_an.state_r)
        s_st = _safe_int(s_an.state_r)

        if waited - last_log >= log_every:
            last_log = waited
            log.info(
                f"  [skew={skew_us:.0f}us] t={waited * CLK_PERIOD_NS / 1000:>8.1f} us  "
                f"M st={m_st}({_state_name(m_st)})  "
                f"S st={s_st}({_state_name(s_st)})  "
                f"M role={_safe_int(dut.m_role_locked)} "
                f"S role={_safe_int(dut.s_role_locked)}  "
                f"M ok={_safe_int(m_an.train_ok_r)} "
                f"M fail={_safe_int(m_an.train_fail_r)}  "
                f"S ok={_safe_int(s_an.train_ok_r)} "
                f"S fail={_safe_int(s_an.train_fail_r)}"
            )

        m_terminal = m_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR, 5}
        s_terminal = s_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR, 5}
        if m_terminal and s_terminal:
            if (m_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR}) or \
               (s_st in {ST_TRAIN_DONE, ST_TRAIN_FAIL, ST_ERROR}):
                break

    sim_t_ms = waited * CLK_PERIOD_NS / 1_000_000

    res = {
        "skew_us":      skew_us,
        "sim_t_ms":     sim_t_ms,
        "m_state":      _safe_int(m_an.state_r),
        "s_state":      _safe_int(s_an.state_r),
        "m_role":       _safe_int(dut.m_role_locked),
        "s_role":       _safe_int(dut.s_role_locked),
        "m_is_master":  _safe_int(dut.m_role_is_master),
        "s_is_master":  _safe_int(dut.s_role_is_master),
        "m_train_ok":   _safe_int(m_an.train_ok_r),
        "s_train_ok":   _safe_int(s_an.train_ok_r),
        "m_train_fail": _safe_int(m_an.train_fail_r),
        "s_train_fail": _safe_int(s_an.train_fail_r),
    }
    log.info(
        f"  [skew={skew_us:.0f}us] FINAL @ {sim_t_ms:.2f} ms: "
        f"M={_state_name(res['m_state'])} role={res['m_role']}/mst={res['m_is_master']} "
        f"ok={res['m_train_ok']} fail={res['m_train_fail']}  "
        f"S={_state_name(res['s_state'])} role={res['s_role']}/mst={res['s_is_master']} "
        f"ok={res['s_train_ok']} fail={res['s_train_fail']}"
    )
    return res


@cocotb.test()
async def test_24_por_skew_sweep(dut):
    """Asymmetric-POR sweep: slave reset release delayed 200us/1ms/3ms.
    RTL POR defaults only — no APB writes. Both dies must role-lock with
    opposite roles and neither may park in ST_ERROR/ST_TRAIN_FAIL."""
    log = dut._log
    log.info(f"I2 POR reset-skew sweep: {SKEWS_US} us, budget {BUDGET_MS} ms/point")

    cocotb.start_soon(
        Clock(dut.hclk, int(round(CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS * 1000)), unit="ps").start()
    )
    _idle_stimulus(dut)
    await ClockCycles(dut.hclk, 10)

    failures = []
    for skew_us in SKEWS_US:
        res = await _run_one_skew(dut, skew_us, log)
        errs = []
        if res["m_role"] != 1:
            errs.append("die_a role_locked=0")
        if res["s_role"] != 1:
            errs.append("die_b role_locked=0")
        if res["m_role"] == 1 and res["s_role"] == 1 and \
           res["m_is_master"] == res["s_is_master"]:
            errs.append(f"role collision (both is_master={res['m_is_master']})")
        # The WINNER (whichever die is_master) must complete the training
        # sub-flow. Under asymmetric POR the early die runs solo autoneg,
        # exhausts its claim against the absent peer and parks
        # ST_NEGO_DONE-lost; the late die then wins arbitration unopposed —
        # boot order overrides the strap preference. That role swap is
        # within the I2 contract (roles resolve, opposite, autonomously);
        # only a swap-with-no-winner-training is a failure.
        winner = "m" if res["m_is_master"] == 1 else "s"
        if res["m_role"] == 1 and res["s_role"] == 1 and \
           res[f"{winner}_train_ok"] != 1:
            errs.append(f"winner ({winner}) train_ok=0")
        if res["m_is_master"] == 0 and res["m_role"] == 1:
            log.info(f"  [skew={skew_us:.0f}us] note: role swap — late die won "
                     f"(boot order beat strap preference)")
        for side in ("m", "s"):
            if res[f"{side}_state"] in (ST_ERROR, ST_TRAIN_FAIL):
                errs.append(f"{side} parked in {_state_name(res[f'{side}_state'])}")
        if errs:
            failures.append((skew_us, errs, res))
            log.error(f"  [skew={skew_us:.0f}us] FAIL: {'; '.join(errs)}")
        else:
            log.info(f"  [skew={skew_us:.0f}us] PASS")

    assert not failures, (
        "POR skew sweep failed at "
        + "; ".join(f"{s:.0f}us ({'; '.join(e)})" for s, e, _ in failures)
    )
    log.info(f"I2 POR skew sweep: all {len(SKEWS_US)} points PASS")
