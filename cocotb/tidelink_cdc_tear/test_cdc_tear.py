"""Silicon-FAITHFUL reproduction of the TideLink a2l/l2a replay-FIFO ACK-pointer
CDC-tear / false-FULL self-heal bug class (the campaign's single biggest sim
fidelity gap).

DUT: WlinkGenericFCReplayV2_13 (app->link replay FIFO), instanced standalone in
tb_cdc_tear with INDEPENDENT, INCOMMENSURATE (async) app_clk and link_clk and a
sim-only torn-capture injector on the synced-ACK accumulator register
(link_addr_to_app_clk.raddr inside WavMultibitSync_18's app-clk read side).

The bug (proven on silicon, OBS tap 0x44032158): the mailbox push-enable is
EDGE-TRIGGERED  (w_inc = a2l_link_addr != a2l_link_addr_in), so it only pushes
when the link-domain ACK pointer CHANGES.  Once the ACK stream is quiescent, a
single metastable multibit mis-capture of the 5-bit synced ACK pointer NEVER
heals -> if it lands a lap ahead of the write ptr, a2l_full latches 1 ->
app_ready=0 -> FIFO winc stalls -> A->B data dropped after ~6 words.

The fix under test:  w_inc = 1'b1  (continuous resend / self-heal).  The bench
MODELS it via the top-level winc_force1 port (a sim-only hierarchical force of
the mailbox push-enable), so ONE test binary proves both polarities:

  * TEAR_FIX=0 (default): edge-triggered w_inc left in place  -> tear WEDGES
                          -> the correctness assertions FAIL (red gate).
  * TEAR_FIX=1          : winc_force1=1 models w_inc=1         -> tear HEALS
                          -> the correctness assertions PASS (green).

An idealized coherent RTL sim can never generate the multibit tear, which is
exactly why the existing idealized gate passes with AND without the fix.  The
injected force is the one event RTL sim cannot produce; the RTL's *response*
(heal vs wedge) is genuine and is what this test measures.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# ── clock periods (INCOMMENSURATE -> genuinely async app/link ratio) ─────────
# app_clk ~50 MHz; link_clk deliberately NOT an integer multiple of app so the
# two domains drift through every phase relationship (silicon-faithful async).
APP_PERIOD_NS  = int(os.environ.get("TL_APP_PERIOD_NS",  "20"))
LINK_PERIOD_NS = int(os.environ.get("TL_LINK_PERIOD_NS", "333"))   # 333/20 = 16.65

# TEAR_FIX=1 -> drive winc_force1=1 (model the w_inc=1 self-heal fix).
FIX = os.environ.get("TEAR_FIX", "0") == "1"
# DUT_KIND=a2l -> WlinkGenericFCReplayV2_13 (has ack-update/revert strobes)
# DUT_KIND=l2a -> WlinkGenericFCReplayV2_12 (die_b RX; ack is a held addr, no strobe)
DUT_KIND = os.environ.get("DUT_KIND", "a2l")
DUT_PROV = "deps (pristine, pre-fix)" if os.environ.get("USE_DEPS_DUT") == "1" \
           else "local_override (production)"

NWORDS = 6        # the silicon signature: false-FULL manifests after ~6 words


def _i(sig):
    try:
        return int(sig.value)
    except ValueError:
        return -1     # X/Z


def probe(dut):
    return dict(
        wbin_ptr   = _i(dut.dbg_wbin_ptr),
        synced_ack = _i(dut.dbg_synced_ack),
        a2l_full   = _i(dut.dbg_a2l_full),
        link_ack   = _i(dut.dbg_link_ack),
        w_inc      = _i(dut.dbg_w_inc),
        app_ready  = _i(dut.app_ready),
        link_empty = _i(dut.link_empty),
    )


async def start_clocks(dut):
    cocotb.start_soon(Clock(dut.app_clk,  APP_PERIOD_NS,  units="ns").start())
    # start link_clk after a deliberately odd phase offset so no edge ever
    # aligns with app_clk -> the two domains are truly asynchronous.
    await Timer(7, units="ns")
    cocotb.start_soon(Clock(dut.link_clk, LINK_PERIOD_NS, units="ns").start())


def tie_idle(dut):
    dut.app_enable.value       = 1
    dut.app_data.value         = 0
    dut.app_valid.value        = 0
    dut.link_ack_addr.value    = 0
    dut.link_advance.value     = 0
    dut.tear_arm.value         = 0
    dut.tear_val.value         = 0
    if DUT_KIND != "l2a":          # _12 has no ack-update / revert strobes
        dut.link_ack_update.value  = 0
        dut.link_revert.value      = 0
        dut.link_revert_addr.value = 0


async def apply_fix_model(dut):
    """(Re)apply the winc_force1 fix-model cleanly for this test: release any
    prior force, then set to the desired polarity so the internal-net force is
    guaranteed to take on the 0->1 (or 1->0) edge the tb's always@ needs."""
    dut.winc_force1.value = 0
    await Timer(1, units="ns")
    dut.winc_force1.value = 1 if FIX else 0
    await Timer(1, units="ns")


async def reset_with_skew(dut, skew_link_cycles):
    """Assert both resets then deassert app_reset first and link_reset
    skew_link_cycles later (app domain releases EARLY -- the silicon condition)."""
    tie_idle(dut)
    dut.app_reset.value  = 1
    dut.link_reset.value = 1
    await ClockCycles(dut.link_clk, 4)
    await RisingEdge(dut.app_clk)
    dut.app_reset.value = 0
    if skew_link_cycles > 0:
        await ClockCycles(dut.link_clk, skew_link_cycles)
    await RisingEdge(dut.link_clk)
    dut.link_reset.value = 0
    await ClockCycles(dut.app_clk, 8)
    await ClockCycles(dut.link_clk, 2)
    await ClockCycles(dut.app_clk, 8)


async def app_write(dut, data, timeout=400):
    """Drive exactly ONE app word with the app_ready handshake (single winc)."""
    cycles = 0
    while True:
        dut.app_data.value  = data
        dut.app_valid.value = 1
        await RisingEdge(dut.app_clk)
        if _i(dut.app_ready) == 1:
            dut.app_valid.value = 0
            break
        cycles += 1
        assert cycles < timeout, "app_ready never asserted (FIFO stuck full?)"
    await RisingEdge(dut.app_clk)
    return _i(dut.dbg_wbin_ptr)


async def link_read_one(dut):
    cycles = 0
    while _i(dut.link_valid) != 1:
        await RisingEdge(dut.link_clk)
        cycles += 1
        assert cycles < 400, "link_valid never asserted"
    data = _i(dut.link_data)
    dut.link_advance.value = 1
    await RisingEdge(dut.link_clk)
    dut.link_advance.value = 0
    await RisingEdge(dut.link_clk)
    return data


async def link_ack(dut, addr, pulses=2):
    if DUT_KIND == "l2a":
        # _12: the link-domain accumulator simply FOLLOWS link_ack_addr, so hold
        # the acked address at `addr` (the reader's consumed ptr) -- do NOT clear
        # it, or the accumulator would rewind and the false-full math would break.
        dut.link_ack_addr.value = addr
        for _ in range(pulses + 2):
            await RisingEdge(dut.link_clk)
    else:
        dut.link_ack_addr.value = addr
        for _ in range(pulses):
            dut.link_ack_update.value = 1
            await RisingEdge(dut.link_clk)
        dut.link_ack_update.value = 0
        dut.link_ack_addr.value = 0


async def bringup_to_matched_state(dut):
    """Drive NWORDS words fully across the FIFO (write, read, ACK) so the write
    ptr, read ptr and BOTH ACK accumulators sit at NWORDS with an EMPTY
    outstanding window -- the quiescent, healthy state silicon reaches after a
    burst.  Returns the probe snapshot."""
    payloads = [(0x0ABCDE << 24) | ((i + 1) << 4) | (i + 1) for i in range(NWORDS)]
    for i, p in enumerate(payloads):
        wp = await app_write(dut, p)
        assert wp == i + 1, f"setup write {i}: wbin_ptr={wp}, expected {i+1}"

    await ClockCycles(dut.link_clk, 4)
    got = [await link_read_one(dut) for _ in range(NWORDS)]
    assert got == payloads, f"setup readback mismatch {[hex(g) for g in got]}"

    # ACK the whole burst up to NWORDS (in-window: rbin_ptr==NWORDS)
    await link_ack(dut, NWORDS, pulses=2)
    # let the synced ACK ptr cross into app_clk
    for _ in range(200):
        await RisingEdge(dut.app_clk)
        if _i(dut.dbg_synced_ack) == NWORDS:
            break
    st = probe(dut)
    assert st["synced_ack"] == NWORDS, (
        f"setup: synced ACK ptr did not reach {NWORDS} (got {st['synced_ack']}); "
        f"cannot establish the quiescent matched state.")
    assert st["a2l_full"] == 0 and st["app_ready"] == 1, \
        f"setup: FIFO not healthy after matched ACK ({st})"
    return st


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  BASELINE (no injection) -- must PASS on BOTH polarities                   ║
# ║  Proves the harness itself is sound: the tear test's failure is caused     ║
# ║  by the injected tear, not by incidental bench breakage.                   ║
# ╚══════════════════════════════════════════════════════════════════════════╝
@cocotb.test()
async def test_baseline_no_tear(dut):
    dut._log.info("DUT source = %s ; fix-model winc_force1 = %d ; "
                  "app/link period = %d/%d ns (ratio %.3f)",
                  DUT_PROV, int(FIX), APP_PERIOD_NS, LINK_PERIOD_NS,
                  LINK_PERIOD_NS / APP_PERIOD_NS)
    await start_clocks(dut)
    await apply_fix_model(dut)
    await reset_with_skew(dut, 3)
    await bringup_to_matched_state(dut)

    # a further (NWORDS+1)-th write must be accepted normally (no tear)
    wp = await app_write(dut, 0x0770_0000_0007)
    st = probe(dut)
    dut._log.info("baseline after extra write: %s", st)
    assert wp == NWORDS + 1 and st["a2l_full"] == 0 and st["app_ready"] == 1, (
        f"BASELINE broke without any injection (wbin_ptr={wp}, a2l_full="
        f"{st['a2l_full']}, app_ready={st['app_ready']}). The harness is unsound.")
    dut._log.info("baseline PASS: harness sound on this polarity")


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  THE CDC-TEAR GATE -- FAILs on edge-triggered w_inc, PASSes on w_inc=1     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
@cocotb.test()
async def test_cdc_tear_false_full_selfheal(dut):
    """Reach the quiescent matched state, inject a ONE-SHOT torn multibit capture
    of the synced ACK pointer that lands a lap ahead of the write ptr (a2l_full
    goes falsely 1), then check the RTL self-heals and keeps accepting data.

    Edge-triggered w_inc  -> no re-push while ACKs are quiescent -> torn value
    is latched forever -> a2l_full stuck 1 -> app_ready stuck 0 -> the next
    write is DROPPED (the silicon 'false-FULL after ~6 words').  ==> FAIL.
    w_inc=1               -> mailbox re-pushes the correct ACK ptr every
    handshake -> raddr heals within a few link clocks -> a2l_full clears ->
    the next write is accepted.                                      ==> PASS.
    """
    await start_clocks(dut)
    await apply_fix_model(dut)
    await reset_with_skew(dut, 3)
    st = await bringup_to_matched_state(dut)
    dut._log.info("quiescent matched state: %s", st)

    wbin = st["wbin_ptr"]                       # == NWORDS
    torn = (wbin & 0x0f) | 0x10                 # lap-ahead: bit4 flipped, low4 equal
    dut._log.info("injecting torn synced-ACK capture = %d (0b%05b) "
                  "against wbin_ptr=%d -> should make a2l_full falsely 1",
                  torn, torn, wbin)

    # ── SIM-ONLY one-shot torn capture of the synced-ACK register ──
    dut.tear_val.value = torn
    dut.tear_arm.value = 1
    await RisingEdge(dut.app_clk)
    await RisingEdge(dut.app_clk)
    dut.tear_arm.value = 0                       # release -> RTL governs raddr
    await RisingEdge(dut.app_clk)

    st_inj = probe(dut)
    dut._log.info("immediately after tear: synced_ack=%d a2l_full=%d app_ready=%d "
                  "link_ack=%d w_inc=%d",
                  st_inj["synced_ack"], st_inj["a2l_full"], st_inj["app_ready"],
                  st_inj["link_ack"], st_inj["w_inc"])
    assert st_inj["synced_ack"] == torn and st_inj["a2l_full"] == 1, (
        f"tear injection did not take (synced_ack={st_inj['synced_ack']}, "
        f"a2l_full={st_inj['a2l_full']}); expected a false-FULL. Check the bench.")

    # ── present the (NWORDS+1)-th write and watch whether it ever lands ──
    heal_ack = None
    accepted_wp = None
    dut.app_data.value  = 0xFACE_0000_0007
    dut.app_valid.value = 1
    for cyc in range(500):
        await RisingEdge(dut.app_clk)
        s = probe(dut)
        if heal_ack is None and s["synced_ack"] == wbin and s["a2l_full"] == 0:
            heal_ack = cyc
        if s["wbin_ptr"] == wbin + 1:
            accepted_wp = cyc
            break
    dut.app_valid.value = 0

    final = probe(dut)
    dut._log.info("after write attempt: synced_ack=%d a2l_full=%d app_ready=%d "
                  "wbin_ptr=%d (heal@%s accept@%s cyc)",
                  final["synced_ack"], final["a2l_full"], final["app_ready"],
                  final["wbin_ptr"], heal_ack, accepted_wp)

    assert final["synced_ack"] == wbin, (
        f"SYNCED-ACK NEVER HEALED: raddr stuck at {final['synced_ack']} "
        f"(0b{final['synced_ack'] & 0x1f:05b}) a lap ahead of wbin_ptr={wbin}. "
        f"With EDGE-TRIGGERED w_inc no re-push occurs while ACKs are quiescent, "
        f"so the torn capture is permanent. This is the silicon false-FULL. "
        f"The fix is w_inc=1'b1 (continuous resend / self-heal).")
    assert final["a2l_full"] == 0 and final["app_ready"] == 1, (
        f"FALSE-FULL STUCK: a2l_full={final['a2l_full']} app_ready="
        f"{final['app_ready']} after the tear -- FIFO reports full at "
        f"{wbin}/16 occupancy. A->B data is dropped.")
    assert accepted_wp is not None and final["wbin_ptr"] == wbin + 1, (
        f"WRITE DROPPED: the {wbin + 1}-th word was never accepted "
        f"(wbin_ptr stuck at {final['wbin_ptr']}). winc never fired -> FCSM "
        f"stalls -> A->B data lost after {wbin} words.")
    dut._log.info("CDC-tear SELF-HEALED and write accepted: PASS "
                  "(heal @ %d cyc, accept @ %d cyc)", heal_ack, accepted_wp)
