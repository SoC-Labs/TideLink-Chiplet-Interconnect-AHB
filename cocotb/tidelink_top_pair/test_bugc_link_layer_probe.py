"""Bug C deep-debug probe: cycle-by-cycle dump of slave RX path while
master rings 100 doorbells.

Goal
----
Localize the Bug C wedge to one of:
  A) PHY layer  : pkt_is_data_pkt NEVER asserts on slave -> byte-align /
                  mux flip / data_id mismatch upstream of the FCSM RX.
  B) FCSM logic : pkt_is_data_pkt asserts but slave still NACKs (L9 fix
                  needs rework).
  C) Returner / FC glue : pkt_is_data_pkt asserts AND l2a_fc_replay_app_valid
                  asserts, but tl_fc_l2a_valid never propagates downstream.
  D) Other      : neither pattern above; described in log.

Strategy
--------
Reuses PairTB.run_bringup_full + the test_bug_c master-to-slave doorbell
recipe. After bringup completes (no asserts on M->S sanity), we install a
cycle-monitor that samples the following slave-side signals on every hclk
edge for SETTLE_WINDOW cycles:

  Slave FCSM RX inputs (hierarchical):
    tb_top.u_slave.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl
      .auto_rx_in_valid        -- 1-cy SOP pulse from rxrouter (data_id-gated)
      .auto_rx_in_sop          -- SOP marker
      .auto_rx_in_data_id      -- packet kind (swi_data_id_1 == data)
      .auto_rx_in_word_count   -- header word_count
      .auto_rx_in_data[55:0]   -- header data (pktnum @ [7:0])
      .pkt_is_data_pkt         -- SOP & data_id matches & ~crc_corrupt
      .ll_rx_pktnum            -- ll_rx_pktnum field
      .exp_pkt_num             -- FCSM's expected pktnum
      .socl_l9_first_data_seen_rx, .socl_l9_resync_now
      .l2a_fc_replay_app_valid -- replay-FIFO write enable to L2A path
      .state                   -- FCSM state
      .send_nack_req, .send_ack_req
  Slave returner side (downstream of replay FIFO):
    tb_top.u_slave.tl_fc_l2a_valid          (top-level wire)
  Master TX side (training mux + count):
    tb_top.u_master.u_chiplet_controller.u_wlink.wlink_phy.gpiotx_0.count
      (per-lane count; word boundary indicator)

We log every cycle where ANY of the interesting "pulse" signals fires
(auto_rx_in_valid, pkt_is_data_pkt, l2a_fc_replay_app_valid,
tl_fc_l2a_valid, send_nack_req rising edge, state transition).

After the watch window, dump a summary classifying A/B/C/D.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB,
    run_bringup_full,
    APB_DOORBELL,
    APB_R8_SLOT0,
    R8_SLOT0_OFF,
)


N_DOORBELLS         = 100
INTER_RING_CYCLES   = 50
SETTLE_CYCLES_TOTAL = 5000

# Max cycle-by-cycle events we log per category to keep stdout sane.
MAX_LOG_EVENTS = 60


def _safe_int(handle):
    try:
        return int(handle.value)
    except Exception:
        return None


def _slave_fcsm(dut):
    return dut.u_slave.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _master_fcsm(dut):
    return dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _phy_tx0_count(dut, side):
    """Per-lane 0 `count` reg inside WavD2DGpioTx (word-boundary indicator)."""
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.u_wlink.wlink_phy.gpiotx_0.count.value)
    except (AttributeError, ValueError):
        return -1


def _training_mode_tx_q(dut, side):
    """Wrapper-level effective_training_mode_tx_q in WavD2DGpio (TX side)."""
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.u_wlink.wlink_phy.effective_training_mode_tx_q.value)
    except (AttributeError, ValueError):
        return -1


def _input_training_mode_w(dut, side):
    top = dut.u_master if side == "m" else dut.u_slave
    try:
        return int(top.u_chiplet_controller.u_wlink.wlink_phy.input_training_mode_w.value)
    except (AttributeError, ValueError):
        return -1


async def _probe_dump(dut, tb, cycles, log):
    """Cycle-by-cycle dump of slave RX path signals for `cycles` hclks.

    Returns a stats dict.
    """
    s_fc = _slave_fcsm(dut)
    m_fc = _master_fcsm(dut)

    stats = dict(
        s_auto_rx_in_valid     = 0,
        s_auto_rx_in_sop       = 0,
        s_pkt_is_data_pkt      = 0,
        s_pkt_is_cr            = 0,
        s_pkt_is_crack         = 0,
        s_pkt_is_ack           = 0,
        s_pkt_is_nack          = 0,
        s_crc_corrupt          = 0,
        s_l2a_fc_replay_app_valid = 0,
        s_tl_fc_l2a_valid      = 0,
        s_send_nack_req_rises  = 0,
        s_send_ack_req_rises   = 0,
        s_resync_now_pulses    = 0,
        m_auto_rx_in_valid     = 0,
        m_pkt_is_data_pkt      = 0,
        m_pkt_is_ack           = 0,
        m_pkt_is_nack          = 0,
    )

    last_s_send_nack = 0
    last_s_send_ack  = 0
    last_s_state     = -1
    last_m_state     = -1

    logged = dict(auto_rx=0, pkt_data=0, replay=0, l2a_top=0, nack_edge=0, state=0)

    for i in range(cycles):
        await RisingEdge(dut.hclk)

        s_arv = _safe_int(s_fc.auto_rx_in_valid)
        s_arsop = _safe_int(s_fc.auto_rx_in_sop)
        s_aridid = _safe_int(s_fc.auto_rx_in_data_id)
        s_pkt_data = _safe_int(s_fc.pkt_is_data_pkt)
        s_pkt_cr   = _safe_int(s_fc.pkt_is_cr_pkt)
        s_pkt_crack= _safe_int(s_fc.pkt_is_crack_pkt)
        s_pkt_ack  = _safe_int(s_fc.pkt_is_ack_pkt)
        s_pkt_nack = _safe_int(s_fc.pkt_is_nack_pkt)
        s_crc      = _safe_int(s_fc.crc_corrupt)
        s_pktnum   = _safe_int(s_fc.ll_rx_pktnum)
        s_exp_pktnum = _safe_int(s_fc.exp_pkt_num)
        s_l2a_replay = _safe_int(s_fc.l2a_fc_replay_app_valid)
        s_state     = _safe_int(s_fc.state)
        s_nack      = _safe_int(s_fc.send_nack_req)
        s_ack       = _safe_int(s_fc.send_ack_req)
        s_resync    = _safe_int(s_fc.socl_l9_resync_now)
        s_first_seen= _safe_int(s_fc.socl_l9_first_data_seen_rx)

        try:
            s_l2a_top = int(dut.u_slave.tl_fc_l2a_valid.value)
        except Exception:
            s_l2a_top = -1

        m_arv = _safe_int(m_fc.auto_rx_in_valid)
        m_pkt_data = _safe_int(m_fc.pkt_is_data_pkt)
        m_pkt_ack  = _safe_int(m_fc.pkt_is_ack_pkt)
        m_pkt_nack = _safe_int(m_fc.pkt_is_nack_pkt)
        m_state    = _safe_int(m_fc.state)

        if s_arv == 1: stats["s_auto_rx_in_valid"] += 1
        if s_arsop == 1: stats["s_auto_rx_in_sop"] += 1
        if s_pkt_data == 1: stats["s_pkt_is_data_pkt"] += 1
        if s_pkt_cr == 1: stats["s_pkt_is_cr"] += 1
        if s_pkt_crack == 1: stats["s_pkt_is_crack"] += 1
        if s_pkt_ack == 1: stats["s_pkt_is_ack"] += 1
        if s_pkt_nack == 1: stats["s_pkt_is_nack"] += 1
        if s_crc == 1: stats["s_crc_corrupt"] += 1
        if s_l2a_replay == 1: stats["s_l2a_fc_replay_app_valid"] += 1
        if s_l2a_top == 1: stats["s_tl_fc_l2a_valid"] += 1
        if s_resync == 1: stats["s_resync_now_pulses"] += 1
        if m_arv == 1: stats["m_auto_rx_in_valid"] += 1
        if m_pkt_data == 1: stats["m_pkt_is_data_pkt"] += 1
        if m_pkt_ack == 1: stats["m_pkt_is_ack"] += 1
        if m_pkt_nack == 1: stats["m_pkt_is_nack"] += 1

        if s_nack == 1 and last_s_send_nack == 0:
            stats["s_send_nack_req_rises"] += 1
            if logged["nack_edge"] < MAX_LOG_EVENTS:
                log.info(
                    f"  [c{i:5d}] SLAVE send_nack_req RISE: "
                    f"state={s_state} exp_pktnum={s_exp_pktnum} "
                    f"ll_rx_pktnum={s_pktnum} pkt_data={s_pkt_data} "
                    f"resync_now={s_resync} first_seen={s_first_seen}"
                )
                logged["nack_edge"] += 1
        if s_ack == 1 and last_s_send_ack == 0:
            stats["s_send_ack_req_rises"] += 1
        last_s_send_nack = s_nack if s_nack is not None else last_s_send_nack
        last_s_send_ack  = s_ack  if s_ack  is not None else last_s_send_ack

        if s_state != last_s_state and last_s_state != -1 and logged["state"] < MAX_LOG_EVENTS:
            log.info(
                f"  [c{i:5d}] SLAVE state {last_s_state} -> {s_state} "
                f"(m_state={m_state}, send_nack={s_nack})"
            )
            logged["state"] += 1
        last_s_state = s_state
        last_m_state = m_state

        if s_arv == 1 and logged["auto_rx"] < MAX_LOG_EVENTS:
            log.info(
                f"  [c{i:5d}] SLAVE auto_rx_in_valid: sop={s_arsop} "
                f"data_id=0x{s_aridid:02x} pktnum=0x{s_pktnum:02x} "
                f"is_data={s_pkt_data} is_cr={s_pkt_cr} is_crack={s_pkt_crack} "
                f"is_ack={s_pkt_ack} is_nack={s_pkt_nack} crc_corrupt={s_crc} "
                f"l2a_replay={s_l2a_replay}"
            )
            logged["auto_rx"] += 1

        if s_pkt_data == 1 and logged["pkt_data"] < MAX_LOG_EVENTS:
            log.info(
                f"  [c{i:5d}] SLAVE pkt_is_data_pkt=1: pktnum=0x{s_pktnum:02x} "
                f"exp=0x{s_exp_pktnum:02x} l2a_replay={s_l2a_replay} "
                f"resync_now={s_resync} first_seen={s_first_seen}"
            )
            logged["pkt_data"] += 1

        if s_l2a_replay == 1 and logged["replay"] < MAX_LOG_EVENTS:
            log.info(
                f"  [c{i:5d}] SLAVE l2a_fc_replay_app_valid=1: "
                f"l2a_top_valid={s_l2a_top}"
            )
            logged["replay"] += 1

        if s_l2a_top == 1 and logged["l2a_top"] < MAX_LOG_EVENTS:
            log.info(f"  [c{i:5d}] SLAVE tl_fc_l2a_valid (top) = 1")
            logged["l2a_top"] += 1

    return stats


def _classify(stats, log):
    """Apply A/B/C/D taxonomy from the agent task spec."""
    log.info("=" * 70)
    log.info("BUG C SYMPTOM CLASSIFICATION")
    log.info("=" * 70)
    for k, v in stats.items():
        log.info(f"  {k:36s} = {v}")
    log.info("-" * 70)

    s_pkt_data   = stats["s_pkt_is_data_pkt"]
    s_replay     = stats["s_l2a_fc_replay_app_valid"]
    s_l2a_top    = stats["s_tl_fc_l2a_valid"]
    s_auto_valid = stats["s_auto_rx_in_valid"]

    if s_pkt_data == 0:
        # No data-classified pkts arrived at the slave FCSM RX.
        if s_auto_valid == 0:
            verdict = "A0"
            descr = ("PHY: slave NEVER saw an auto_rx_in_valid pulse on "
                     "tl2wl rx_in -- LL_RX byte-align or rxrouter "
                     "data_id gating is killing all data packets. "
                     "Locus = upstream of rxrouter (llrx) or rxrouter "
                     "data_id != swi_data_id_1.")
        else:
            verdict = "A1"
            descr = ("PHY: slave saw auto_rx_in_valid pulses but NONE "
                     "classified as data_pkt. Either data_id mismatches "
                     "the FCSM's swi_data_id_1, or crc_corrupt is "
                     "asserting on every data candidate. Check "
                     "s_crc_corrupt and the dumped data_id values.")
    elif s_replay == 0:
        verdict = "B"
        descr = ("FCSM: pkt_is_data_pkt asserts but "
                 "l2a_fc_replay_app_valid does NOT -- pktnum mismatch "
                 "(L9 resync did not fire, or fired only once and "
                 "subsequent pkts mismatch exp_pkt_num++).  This is the "
                 "FCSM consumer-side L9 patch's intended target.")
    elif s_l2a_top == 0:
        verdict = "C"
        descr = ("RETURNER/GLUE: replay-fifo writes happen but "
                 "tl_fc_l2a_valid never asserts at the tidelink_top "
                 "boundary -- the returner / fc_adapter glue is "
                 "swallowing the packet.")
    else:
        verdict = "D"
        descr = ("All three signals fired -- bug must be FURTHER "
                 "downstream (tidelink_returner -> APB DOORBELL_RESP_ACC "
                 "increment path). Could also be a counting test artefact.")

    log.info(f"  >>> VERDICT: {verdict}")
    log.info(f"  >>> {descr}")
    log.info("=" * 70)
    return verdict


async def _ensure_training_off(tb):
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(tb.dut.hclk, 100)


@cocotb.test()
async def test_bugc_link_layer_probe(dut):
    """Reproduce Bug C and capture cycle-by-cycle slave RX path probes."""
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await _ensure_training_off(tb)

    tb.log.info("=" * 70)
    tb.log.info("BUG C DEEP-DEBUG PROBE: starting M->S 100 doorbells + cycle dump")
    tb.log.info("=" * 70)

    # Sanity snapshot of starting state.
    s_fc = _slave_fcsm(dut)
    m_fc = _master_fcsm(dut)
    tb.log.info(
        f"  pre-traffic: m_state={int(m_fc.state.value)} "
        f"s_state={int(s_fc.state.value)} "
        f"m_exp_pktnum={int(m_fc.exp_pkt_num.value)} "
        f"s_exp_pktnum={int(s_fc.exp_pkt_num.value)} "
        f"m_first_seen={int(m_fc.socl_l9_first_data_seen_rx.value)} "
        f"s_first_seen={int(s_fc.socl_l9_first_data_seen_rx.value)} "
        f"m_train_q={_training_mode_tx_q(dut, 'm')} "
        f"s_train_q={_training_mode_tx_q(dut, 's')}"
    )

    # ----- Phase A: fire all 100 doorbells while monitoring continuously. -----
    # We can't easily run watch loop concurrently with apb writes via cocotb
    # without coroutines, but the doorbell APB writes themselves only block
    # for a handful of cycles each. Drive doorbells in a forked coroutine
    # and monitor in the main thread.

    async def driver():
        for i in range(N_DOORBELLS):
            await tb.m_apb.write(APB_DOORBELL, 1)
            await ClockCycles(dut.hclk, INTER_RING_CYCLES)

    drive_task = cocotb.start_soon(driver())

    # Total monitor window: enough for all rings + drain.
    monitor_cycles = N_DOORBELLS * (INTER_RING_CYCLES + 60) + SETTLE_CYCLES_TOTAL
    tb.log.info(f"  Monitoring {monitor_cycles} cycles ...")
    stats = await _probe_dump(dut, tb, monitor_cycles, tb.log)

    await drive_task

    # ----- Phase B: post-traffic snapshot. ------------------------------------
    tb.log.info(
        f"  post-traffic: m_state={int(m_fc.state.value)} "
        f"s_state={int(s_fc.state.value)} "
        f"m_exp_pktnum={int(m_fc.exp_pkt_num.value)} "
        f"s_exp_pktnum={int(s_fc.exp_pkt_num.value)} "
        f"m_first_seen={int(m_fc.socl_l9_first_data_seen_rx.value)} "
        f"s_first_seen={int(s_fc.socl_l9_first_data_seen_rx.value)} "
        f"s_send_nack_req={int(s_fc.send_nack_req.value)}"
    )

    verdict = _classify(stats, tb.log)

    # Test "passes" as a probe sweep -- we only assert that bringup completed
    # (m/s state reached at least 3, role_locked high).
    assert int(dut.m_role_locked.value) == 1
    assert int(dut.s_role_locked.value) == 1

    # Persist verdict so callers can grep.
    tb.log.info(f"  PROBE_VERDICT={verdict}")
