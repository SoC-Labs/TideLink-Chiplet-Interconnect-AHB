"""A7: compute's auto-anchor SYNC beacon must never overwrite a live link word,
and must stop once AXI traffic flows.

Two defects, measured in the three-die tb_ce3 (handoff-haps3-20260930):
 (1) PHY. WavD2DGpio_v2 inserts the SYNC word when auto_anchor_force &
     io_link_tx_tx_idle. WlinkTxLinkLayer's io_link_idle is COMBINATIONAL
     ((state==0) & ~sop) while io_link_data is the REGISTERED link_data_reg, so
     on the cycle after a packet's last word is formed idle already reads 1
     while that word is still on the bus. A SYNC inserted there replaces it; a
     single-word packet (a B) is lost outright and nothing follows to NACK it.
 (2) Controller. The beacon's "app active" stop input is the TideLink-channel
     FC node only; AXI traffic never stops it (runs to the ~4-8 s cap).

forced_beacon_writes (build: default): the beacon is FORCED on both dies
(declared sim-only intervention: auto_anchor_pulse_q forced to 1, which also
turns SYNC insertion on), then 64 master->slave non-bufferable writes are
issued with the idle gap stepped 0..63 cycles so the B responses sweep the
32-word SYNC grid. Every write must complete with a real B (well under the
2^16 backstop) and land. Non-vacuity: both dies' TX SYNC-insert counters must
advance during the traffic.

beacon_stops_on_axi (build: AUTO_ANCHOR=1): holds each controller's TL-channel
activity input low (the silicon condition, declared sim-only), waits until both
dies' beacons are running, issues one write master->slave, and requires each die's beacon to
latch done within STOP_MAX cycles of that die's first AXI app->link valid
(master: AW/W, slave: B). Precondition asserted: the beacon was running.
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

import test_v2_burst_encodings as be
import test_v2_ahb_compliant as ac

N_WRITES = 64
BASE_OFF = 0xC00
REAL_B_MAX = 5_000
TIMEOUT = 300_000
STOP_MAX = 16


def cc(tb, side):
    return tb.top(side).u_chiplet_controller


def sync_ins(tb, side):
    try:
        return int(cc(tb, side).u_wlink.phy.gpio.tx_sync_ins_cnt_q.value)
    except Exception:
        return None


async def one_write(dut, addr, data):
    t = dict(addr=addr, data=data, htrans=ac.NONSEQ, hburst=be.BUR_SINGLE, hprot=0x1)
    err = {"v": 0}
    done = {"v": False}

    async def watch():
        while not done["v"]:
            await ReadOnly()
            try:
                if int(dut.m_ahb_sub_hresp.value):
                    err["v"] = 1
            except ValueError:
                pass
            await RisingEdge(dut.hclk)
    w = cocotb.start_soon(watch())
    res = await ac.CompliantAHBMaster(dut).run([t], timeout=TIMEOUT)
    done["v"] = True
    await RisingEdge(dut.hclk)
    w.kill()
    return res, err["v"]


@cocotb.test()
async def forced_beacon_writes(dut):
    tb, _ = await be._bringup(dut)
    for i in range(N_WRITES):
        dut.u_s_mng_bram.mem[(BASE_OFF >> 2) + i].value = 0
    for side in ("m", "s"):
        cc(tb, side).auto_anchor_pulse_q.value = Force(1)
    await ClockCycles(dut.hclk, 2000)
    ins0 = {s: sync_ins(tb, s) for s in ("m", "s")}
    bad = []
    for i in range(N_WRITES):
        await ClockCycles(dut.hclk, 1 + i)
        v = 0xA7000000 | (i << 8) | (0x3C ^ i)
        res, err = await one_write(dut, be.APERTURE_BASE + BASE_OFF + 4 * i, v)
        await ClockCycles(dut.hclk, 200)
        landed = be._bram_peek(dut, BASE_OFF + 4 * i)
        ok = res["completed"] and not err and res["cycles"] < REAL_B_MAX and landed == v
        if not ok:
            bad.append(i)
            tb.log.info(f"[a7f] w{i} BAD cycles={res['cycles']} err={err} landed={landed} want={v:#x}")
    ins1 = {s: sync_ins(tb, s) for s in ("m", "s")}
    for side in ("m", "s"):
        cc(tb, side).auto_anchor_pulse_q.value = Release()
    tb.log.info(f"[a7f] {N_WRITES - len(bad)}/{N_WRITES} writes clean; first bad={bad[:1]}; "
                f"SYNC inserts during traffic m={ins1['m'] - ins0['m'] if None not in (ins0['m'], ins1['m']) else '?'} "
                f"s={ins1['s'] - ins0['s'] if None not in (ins0['s'], ins1['s']) else '?'}")
    assert None not in ins0.values() and None not in ins1.values(), "SYNC-insert counter not readable"
    assert ins1["m"] > ins0["m"] and ins1["s"] > ins0["s"], "beacon forced but no SYNC word was inserted (vacuous)"
    assert not bad, f"{len(bad)} writes lost or late under the beacon, first w{bad[0]}"


@cocotb.test()
async def beacon_stops_on_axi(dut):
    # Silicon condition (tb_ce3): compute misses the single TideLink-channel word
    # of the link-up doorbell exchange, so nothing on the TL channel stops its
    # beacon. Reproduced here by holding the controller's TL-channel activity
    # input low on both dies (declared sim-only intervention; observation net,
    # not datapath). Without it this symmetric bench stops both beacons at
    # link-up, as the KR260 does.
    tl_in = [dut.u_master.u_chiplet_controller.obs_a2l_replay_app_valid_w,
             dut.u_slave.u_chiplet_controller.obs_a2l_replay_app_valid_w]
    for h in tl_in:
        h.value = Force(0)
    # The sim build caps the beacon at 4096 cycles (silicon: 200M, seconds), which
    # expires before bring-up returns. Model the silicon cap by holding the length
    # counter at 0 (declared sim-only intervention; the stop logic under test,
    # pulse_q/done_q and their inputs, is untouched).
    len_h = [dut.u_master.u_chiplet_controller.auto_anchor_len_q,
             dut.u_slave.u_chiplet_controller.auto_anchor_len_q]
    for h in len_h:
        h.value = Force(0)
    tb, _ = await be._bringup(dut)
    # precondition: both beacons running
    for _ in range(20000):
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if all(int(cc(tb, s).auto_anchor_pulse_q.value) for s in ("m", "s")):
            break
    state = {s: (int(cc(tb, s).auto_anchor_pulse_q.value), int(cc(tb, s).auto_anchor_done_q.value)) for s in ("m", "s")}
    tb.log.info(f"[a7s] before the write (pulse, done): {state}")
    assert all(p == 1 and d == 0 for p, d in state.values()), f"beacons not both running before the write: {state}"
    await RisingEdge(dut.hclk)          # leave the ReadOnly phase before driving

    first_v = {"m": None, "s": None}
    done_at = {"m": None, "s": None}
    cyc = {"n": 0}
    stop = {"v": False}

    async def watch():
        while not stop["v"]:
            await RisingEdge(dut.hclk)
            await ReadOnly()
            cyc["n"] += 1
            m, s = cc(tb, "m"), cc(tb, "s")
            if first_v["m"] is None and (int(m.axi_tgt_0_aw_valid.value) or int(m.axi_tgt_0_w_valid.value)):
                first_v["m"] = cyc["n"]
            if first_v["s"] is None and int(s.axi_ini_0_b_valid.value):
                first_v["s"] = cyc["n"]
            for side, c in (("m", m), ("s", s)):
                if done_at[side] is None and int(c.auto_anchor_done_q.value):
                    done_at[side] = cyc["n"]
    w = cocotb.start_soon(watch())
    res, err = await one_write(dut, be.APERTURE_BASE + BASE_OFF, 0xA7A7A7A7)
    await ClockCycles(dut.hclk, 200)
    stop["v"] = True
    await RisingEdge(dut.hclk)
    w.kill()
    lat = {s: (done_at[s] - first_v[s]) if None not in (done_at[s], first_v[s]) else None for s in ("m", "s")}
    tb.log.info(f"[a7s] write completed={res['completed']} cycles={res['cycles']} err={err}; "
                f"first a2l valid m@{first_v['m']} s@{first_v['s']}; done m@{done_at['m']} s@{done_at['s']}; "
                f"stop latency m={lat['m']} s={lat['s']}")
    assert res["completed"] and not err
    for h in tl_in + len_h:
        h.value = Release()
    for side in ("m", "s"):
        assert lat[side] is not None and 0 <= lat[side] <= STOP_MAX, \
            f"die {side}: beacon did not stop within {STOP_MAX} cycles of its first AXI app->link valid (latency {lat[side]})"


@cocotb.test()
async def silicon_beacon_write_sweep(dut):
    """The tb_ce3 silicon condition end to end (build: AUTO_ANCHOR=1): the real
    beacon running (TL-channel stop input held low, sim cap removed), then 64
    single writes, each one's B the last packet on the link, with the idle gap
    stepped 0..63 so the B's sweep the SYNC grid. af3a5d67: the beacon never
    stops and B's are overwritten (writes wedge to the 2^16 backstop). Fixed:
    the first B is protected by the PHY guard and the beacon stops on it."""
    tl_in = [dut.u_master.u_chiplet_controller.obs_a2l_replay_app_valid_w,
             dut.u_slave.u_chiplet_controller.obs_a2l_replay_app_valid_w]
    len_h = [dut.u_master.u_chiplet_controller.auto_anchor_len_q,
             dut.u_slave.u_chiplet_controller.auto_anchor_len_q]
    for h in tl_in + len_h:
        h.value = Force(0)
    tb, _ = await be._bringup(dut)
    for _ in range(20000):
        await RisingEdge(dut.hclk)
        await ReadOnly()
        if all(int(cc(tb, s).auto_anchor_pulse_q.value) for s in ("m", "s")):
            break
    running = all(int(cc(tb, s).auto_anchor_pulse_q.value) for s in ("m", "s"))
    await RisingEdge(dut.hclk)
    assert running, "precondition: both beacons must be running before the first write"
    for i in range(N_WRITES):
        dut.u_s_mng_bram.mem[(BASE_OFF >> 2) + i].value = 0
    bad = []
    for i in range(N_WRITES):
        await ClockCycles(dut.hclk, 1 + i)
        v = 0xA5510000 | (i << 8) | (0x5A ^ i)
        res, err = await one_write(dut, be.APERTURE_BASE + BASE_OFF + 4 * i, v)
        await ClockCycles(dut.hclk, 200)
        landed = be._bram_peek(dut, BASE_OFF + 4 * i)
        if not (res["completed"] and not err and res["cycles"] < REAL_B_MAX and landed == v):
            bad.append(i)
            tb.log.info(f"[a7w] w{i} BAD cycles={res['cycles']} err={err} landed={landed} want={v:#x}")
    st = {s: (int(cc(tb, s).auto_anchor_pulse_q.value), int(cc(tb, s).auto_anchor_done_q.value)) for s in ("m", "s")}
    for h in tl_in + len_h:
        h.value = Release()
    tb.log.info(f"[a7w] {N_WRITES - len(bad)}/{N_WRITES} writes clean; first bad={bad[:1]}; beacon (pulse, done) after: {st}")
    assert not bad, f"{len(bad)} writes lost under the running beacon, first w{bad[0]}"
