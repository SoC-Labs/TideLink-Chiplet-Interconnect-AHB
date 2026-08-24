"""TL-027 `w_inc` CONTINUOUS-RESEND self-heal — the CDC-TEARING regression.

WHY THIS FILE EXISTS
====================
The pre-existing tests in this env (test_a2l_replay_cdc*.py) do NOT test the
`w_inc` arm of TL-027 at all.  Their primary stimulus is a lap-ahead ACK (9 / 33)
which the override's `a2l_ack_valid` WINDOW GUARD rejects outright, so
`a2l_link_addr` never moves and no false-FULL can occur.  Their pass is
explained *entirely* by the window guard.  The other half of TL-027 —

    assign link_addr_to_app_clk_w_inc = 1'b1;   // continuous resend

— was never exercised, because an idle single-clock sim never tears.  The
override files say so in their own header ("Idle single-clock sim never tears ->
silicon is the verifier for the w_inc half").  That gap applied to EVERY node,
including _1/_3/_5 which ship in the ASIC today.  This file closes it.

THE MECHANISM (RTL-verified, deps/axi-chiplet-controller/logical/wlink/)
=======================================================================
WavMultibitSync.v:
     31   wire we = w_inc & w_ready;
     44   assign w_ready = ~(rptr_wclk_demet_io_out ^ wptr);

`w_ready` drops LOW while the ping-pong mailbox is still carrying a previous
value (wptr toggled; rptr has not yet round-tripped back through the two-FF
demet on the *write* clock).  An update presented in that window computes we=0
and is DROPPED.  What happens next is the whole of TL-027:

  deps form   `w_inc = (a2l_link_addr != a2l_link_addr_in)` — a ONE-CYCLE pulse
              coincident with the ACK.  Once `a2l_link_addr` has latched the new
              value, w_inc falls back to 0 forever.  The dropped update is NEVER
              retried => the app-clock side keeps the STALE ack ptr for the rest
              of time => `a2l_full` is computed against a stale ACK ptr.
  override    `w_inc = 1'b1` — the guard-clamped `a2l_link_addr_in` is re-pushed
              on the very next `w_ready`, so a torn update self-heals in ~1
              mailbox round trip.

THE STIMULUS
============
Two ACKs.  The first opens the mailbox busy window (it toggles wptr).  The
second is injected `d` link cycles later, *while `w_ready` is LOW*, and then
everything goes quiet — no further ACK, no further traffic, nothing that could
re-trigger an edge-form w_inc.  The second value must still reach
`a2l_link_addr_app_clk` (= tb_synced_ack).

Both ACKs are chosen to SATISFY the override's window guard
(`a2l_ack_off_req <= a2l_ack_off_max <= DEPTH`), so unlike the lap-ahead tests
the guard is deliberately NOT the thing under test here — it is held open, and
the only remaining difference between the two arms is the w_inc form.

  USE_DEPS_DUT=1 (edge-triggered w_inc)  -> value NEVER arrives  -> FAIL (repro)
  default        (w_inc = 1'b1)          -> value arrives, bounded -> PASS

ANTI-VACUITY (a test that cannot fail proves nothing)
=====================================================
Three separate guards, all of which FAIL the test rather than skip:
  A1  at least one swept offset must have MEASURED `w_ready == 0` at the exact
      link edge that samples the 2nd ACK.  If the tearing condition was never
      constructed, the run is vacuous and says so.
  A2  a MUST-BE-PRESENT CONTROL: at least one offset with MEASURED
      `w_ready == 1` must DELIVER.  This proves the stimulus and the probe path
      work at all, so a "never arrived" verdict is a real drop and not a broken
      bench / mis-typed hierarchy path.  This control passes on BOTH arms.
  A3  the setup preconditions (rbin_ptr advanced far enough for the guard to be
      open) are asserted, not assumed.

The clocks are genuinely asynchronous: 20 ns app vs 317 ns link, ratio 15.85,
gcd(20,317)=1, so the app-edge grid slides through the link cycle.  The
injection phase is swept and the MEASURED app/link phase at each injection is
logged, so "which offsets hit the window" is data, not an assumption.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer
from cocotb.utils import get_sim_time

# ── genuinely asynchronous clocks (non-integer ratio, coprime periods) ─────
APP_PERIOD_NS  = 20
LINK_PERIOD_NS = 317          # 317/20 = 15.85, gcd = 1

# how long we let the design sit QUIET waiting for the torn value to self-heal.
# One mailbox round trip is ~3 link cycles; 700 app_clk = 14 us = ~44 link
# cycles, i.e. >14 round trips.  Bounded, and generous by an order of magnitude.
SETTLE_APP_CYCLES = 700

PRIME_WORDS = 4               # app writes / link pops before the ACKs

# injection sweep: `d` = link cycles from the 1st ACK's sampling edge to the
# 2nd's; `phi` = ns of absolute-time skew applied before the scenario, which
# slides the app-clock edge grid relative to the link edges.
SWEEP_D   = (1, 2, 3, 4, 5)
SWEEP_PHI = (0, 7, 13, 19)

USE_DEPS_DUT   = os.environ.get("USE_DEPS_DUT", "0") == "1"
USE_PREFIX_DUT = os.environ.get("USE_PREFIX_DUT", "0") == "1"


def _src_label():
    if USE_DEPS_DUT:
        return "deps(pristine, w_inc=edge)"
    if USE_PREFIX_DUT:
        return "tl027only(w_inc=1)"
    return "local_override(w_inc=1)"


def _sigint(sig):
    try:
        return int(sig.value)
    except ValueError:
        return -1     # X/Z


# ── hierarchy resolution ───────────────────────────────────────────────────
# The mailbox handshake nets live two levels down:
#   tb_top . dut (WlinkGenericFCReplayV2_N) . link_addr_to_app_clk
#          (WlinkGenericFCReplayAddrSync[_3]) . addrsync_w_ready
# Resolve it explicitly and LOUDLY, so a rename can never silently turn this
# test into a no-op that reads -1 forever and "passes".
def _resolve(dut):
    node = dut.dut
    sync = getattr(node, "link_addr_to_app_clk")
    handles = {}
    for name in ("addrsync_w_ready", "addrsync_w_inc", "addrsync_w_data"):
        handles[name] = getattr(sync, name)
    mb = getattr(sync, "addrsync")             # WavMultibitSync[_3]
    handles["wptr"] = getattr(mb, "wptr")
    handles["rptr"] = getattr(mb, "rptr")
    # sanity: w_ready must be a real 0/1, not X and not missing
    return handles


def _geom(dut):
    ptr_bits  = len(dut.link_ack_addr)
    data_bits = len(dut.app_data)
    return dict(ptr_bits=ptr_bits, ptr_mask=(1 << ptr_bits) - 1,
                depth=1 << (ptr_bits - 1), data_bits=data_bits)


def _tie_idle(dut):
    dut.app_enable.value       = 1
    dut.app_data.value         = 0
    dut.app_valid.value        = 0
    dut.link_ack_update.value  = 0
    dut.link_ack_addr.value    = 0
    dut.link_revert.value      = 0
    dut.link_revert_addr.value = 0
    dut.link_advance.value     = 0


async def _reset(dut):
    _tie_idle(dut)
    dut.app_reset.value  = 1
    dut.link_reset.value = 1
    await ClockCycles(dut.link_clk, 4)
    await RisingEdge(dut.app_clk)
    dut.app_reset.value = 0
    await RisingEdge(dut.link_clk)
    dut.link_reset.value = 0
    await ClockCycles(dut.link_clk, 3)
    await ClockCycles(dut.app_clk, 8)


async def _prime(dut, g, n):
    """Push n words app-side then pop them link-side, so fifo_io_rbin_ptr
    advances.  This is what OPENS the override's ACK window guard
    (a2l_ack_off_max = rbin_ptr - a2l_link_addr), so the guard cannot be the
    thing that decides this test."""
    dut.app_data.value  = ((1 << g["data_bits"]) - 1) & 0x5A5A5A5A5A5A5A5A5A5A5A5A5A
    dut.app_valid.value = 1
    for _ in range(n * 10):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.fifo_io_wbin_ptr) >= n:
            break
    dut.app_valid.value = 0
    await ClockCycles(dut.link_clk, 3)          # let wptr cross into link domain
    dut.link_advance.value = 1
    for _ in range(n * 6):
        await RisingEdge(dut.link_clk)
        if _sigint(dut.dut.fifo_io_rbin_ptr) >= n:
            break
    dut.link_advance.value = 0
    await RisingEdge(dut.link_clk)
    return _sigint(dut.dut.fifo_io_rbin_ptr)


async def _scenario(dut, g, h, d, phi):
    """One injection.  Returns a dict of MEASURED facts (nothing inferred)."""
    if phi:
        await Timer(phi, unit="ns")
    await _reset(dut)
    rbin = await _prime(dut, g, PRIME_WORDS)

    a1, a2 = 1, 2      # off_req = 1 for both ACKs; off_max = rbin / rbin-1

    # ── ACK #1 : opens the mailbox busy window (toggles wptr) ──────────────
    dut.link_ack_addr.value   = a1
    dut.link_ack_update.value = 1
    await RisingEdge(dut.link_clk)          # T1: ACK#1 sampled here
    dut.link_ack_update.value = 0
    t1 = get_sim_time("ns")

    # ── wait d-1 whole link cycles, then present ACK #2 for edge T1+d ──────
    for _ in range(d - 1):
        await RisingEdge(dut.link_clk)
    dut.link_ack_addr.value   = a2
    dut.link_ack_update.value = 1

    # sample w_ready mid-cycle (it only changes on link posedges, so the value
    # here IS the value the `we = w_inc & w_ready` term uses at the next edge)
    await FallingEdge(dut.link_clk)
    wready_at_inject = _sigint(h["addrsync_w_ready"])
    winc_at_inject   = _sigint(h["addrsync_w_inc"])

    await RisingEdge(dut.link_clk)          # T1+d: ACK#2 sampled here
    dut.link_ack_update.value = 0
    t2 = get_sim_time("ns")
    # MEASURED app/link phase at the injection edge: ns since the last app edge
    phase_meas = t2 % APP_PERIOD_NS

    # ── QUIET.  Nothing changes.  Only a continuous resend can deliver now. ─
    arrived_at = None
    for i in range(SETTLE_APP_CYCLES):
        await RisingEdge(dut.app_clk)
        if _sigint(dut.dut.a2l_link_addr_app_clk) == a2:
            arrived_at = i
            break

    return dict(d=d, phi=phi, rbin=rbin,
                wready=wready_at_inject, winc=winc_at_inject,
                phase=phase_meas,
                link_reg=_sigint(dut.dut.a2l_link_addr),
                synced=_sigint(dut.dut.a2l_link_addr_app_clk),
                target=a2, arrived=arrived_at,
                dt_link=(t2 - t1) / LINK_PERIOD_NS)


@cocotb.test()
async def test_wready_low_ack_must_self_heal(dut):
    """TL-027 w_inc: an ACK presented while the AddrSync mailbox is BUSY
    (w_ready=0) is dropped by `we = w_inc & w_ready`.  With continuous resend
    (w_inc=1) it must still reach the app clock domain after everything goes
    quiet; with the deps edge-triggered w_inc it never can."""
    src = _src_label()
    cocotb.start_soon(Clock(dut.app_clk,  APP_PERIOD_NS,  unit="ns").start())
    cocotb.start_soon(Clock(dut.link_clk, LINK_PERIOD_NS, unit="ns").start())

    await _reset(dut)
    g = _geom(dut)
    h = _resolve(dut)

    dut._log.info("[wready-tear %s] geometry: ptr_bits=%d depth=%d data_bits=%d",
                  src, g["ptr_bits"], g["depth"], g["data_bits"])
    dut._log.info("[wready-tear %s] clocks: app=%dns link=%dns (ratio %.3f, async)",
                  src, APP_PERIOD_NS, LINK_PERIOD_NS, LINK_PERIOD_NS / APP_PERIOD_NS)

    # the probe itself must be alive before we trust any verdict from it
    w0 = _sigint(h["addrsync_w_ready"])
    assert w0 in (0, 1), (
        f"INSTRUMENT DEAD: addrsync_w_ready reads {w0} (X/Z or unresolved) at idle. "
        f"Refusing to report a DUT verdict from a broken probe.")

    results = []
    for phi in SWEEP_PHI:
        for d in SWEEP_D:
            r = await _scenario(dut, g, h, d, phi)
            results.append(r)
            dut._log.info(
                "[wready-tear %s] d=%d phi=%2dns | rbin=%d w_ready@inject=%d "
                "w_inc@inject=%d app/link phase=%5.1fns | ack_reg=%d synced=%d "
                "target=%d arrived=%s",
                src, r["d"], r["phi"], r["rbin"], r["wready"], r["winc"],
                r["phase"], r["link_reg"], r["synced"], r["target"],
                ("app_cyc+%d" % r["arrived"]) if r["arrived"] is not None else "NEVER")

    # ── A3: setup precondition — the guard must have been held OPEN ────────
    bad_setup = [r for r in results if r["rbin"] < 3]
    assert not bad_setup, (
        f"SETUP FAILED (not a DUT verdict): fifo_io_rbin_ptr never reached 3 in "
        f"{len(bad_setup)}/{len(results)} scenarios ({[r['rbin'] for r in bad_setup]}). "
        f"The override's ACK window guard would reject the stimulus, so the run "
        f"would be measuring the guard, not w_inc.")
    # the ACK must actually have LANDED in the link-clk accumulator; if it did
    # not, we are testing the guard again and not the CDC.
    bad_latch = [r for r in results if r["link_reg"] != r["target"]]
    assert not bad_latch, (
        f"SETUP FAILED (not a DUT verdict): a2l_link_addr (link-clk side) is not "
        f"the injected ACK in {len(bad_latch)}/{len(results)} scenarios "
        f"(got {[r['link_reg'] for r in bad_latch]}, want {results[0]['target']}). "
        f"The ACK was rejected before the CDC — the window guard, not w_inc, is "
        f"what this run would be measuring.")

    torn = [r for r in results if r["wready"] == 0]
    open_ = [r for r in results if r["wready"] == 1]

    dut._log.info("[wready-tear %s] SWEEP: %d/%d injections landed in the "
                  "w_ready-LOW (mailbox busy) window: %s",
                  src, len(torn), len(results),
                  [(r["d"], r["phi"]) for r in torn])
    dut._log.info("[wready-tear %s] SWEEP: %d/%d landed with w_ready HIGH "
                  "(control): %s", src, len(open_), len(results),
                  [(r["d"], r["phi"]) for r in open_])

    # ── A1: the tearing condition must actually have been constructed ──────
    assert torn, (
        f"VACUOUS RUN — refusing to report a pass. Not one of the {len(results)} "
        f"swept injections (d={list(SWEEP_D)} x phi={list(SWEEP_PHI)}ns) was "
        f"sampled with w_ready=0, so the `we = w_inc & w_ready` drop was never "
        f"constructed and NOTHING about w_inc was tested.")

    # ── A2: must-be-present CONTROL — the bench can deliver at all ─────────
    ctrl_ok = [r for r in open_ if r["arrived"] is not None]
    assert ctrl_ok, (
        f"CONTROL FAILED — the bench cannot deliver an ACK even with w_ready=1 "
        f"({len(open_)} such injections, none arrived). A 'never arrived' verdict "
        f"from this run would be a broken stimulus/probe, not a DUT drop. "
        f"Refusing to score the DUT.")
    dut._log.info("[wready-tear %s] CONTROL OK: %d/%d w_ready-HIGH injections "
                  "delivered (fastest %d app_clk) — stimulus + probe path proven live.",
                  src, len(ctrl_ok), len(open_), min(r["arrived"] for r in ctrl_ok))

    # ── THE ASSERTION ──────────────────────────────────────────────────────
    lost = [r for r in torn if r["arrived"] is None]
    assert not lost, (
        f"TL-027 w_inc SELF-HEAL ABSENT ({src}): {len(lost)}/{len(torn)} ACKs "
        f"injected while the AddrSync mailbox was BUSY (w_ready=0 measured at the "
        f"sampling edge) NEVER reached a2l_link_addr_app_clk within "
        f"{SETTLE_APP_CYCLES} quiet app_clk (~{SETTLE_APP_CYCLES*APP_PERIOD_NS/LINK_PERIOD_NS:.0f} "
        f"link cycles, >10 mailbox round trips). "
        f"link-clk a2l_link_addr={[r['link_reg'] for r in lost]} but app-clk "
        f"synced ack stuck at {[r['synced'] for r in lost]} (want "
        f"{[r['target'] for r in lost]}). "
        f"Offsets lost (d, phi_ns): {[(r['d'], r['phi']) for r in lost]}. "
        f"MECHANISM: WavMultibitSync.v:31 `we = w_inc & w_ready` dropped the "
        f"update, and w_inc = (a2l_link_addr != a2l_link_addr_in) had already "
        f"fallen back to 0, so it is never retried. The app clock domain now "
        f"computes a2l_full against a PERMANENTLY STALE ack ptr. "
        f"The fix is `assign link_addr_to_app_clk_w_inc = 1'b1;` (continuous "
        f"resend) as carried by src/rtl/local_overrides/.")

    dut._log.info("[wready-tear %s] PASS: all %d torn injections self-healed "
                  "(worst %d app_clk = %.1f link cycles).",
                  src, len(torn), max(r["arrived"] for r in torn),
                  max(r["arrived"] for r in torn) * APP_PERIOD_NS / LINK_PERIOD_NS)
