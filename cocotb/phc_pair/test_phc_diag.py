"""PHC pair-sim diagnostic — instrument the slave RX path to localise
the layer at which master→slave SYNC short packets are dropped.

Probes (slave hierarchy):
  - dut.u_slave.u_wlink.llrx.is_short_pkt / is_long_pkt — RX classifier
  - dut.u_slave.u_wlink.sp2wl.dataIdMatch              — data_id match
  - dut.u_slave.u_wlink.sp2wl.rx_pkt_valid             — adapter accepted
  - dut.u_slave.u_wlink.sp2wl.rx_fifo_io_wfull         — FIFO full backpressure
  - dut.u_slave_ptp.ptp_enable_r                       — RX-accept gate
  - dut.s_ptp_sp_rx_valid (tb wire)                    — pin-level RX valid

Reports per-layer event counts so the boundary where the count drops to
zero IS the root cause layer.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

from test_phc_hw_sync_pair import (
    setup, lock_master, lock_slave, ptp_reg_write,
    REG_PTP_CTRL, REG_HW_SYNC_CTRL, REG_HW_SYNC_INTERVAL, REG_HW_SYNC_STATUS,
    CTRL_ENABLE, HW_SYNC_EN, HW_SYNC_FORCE_EN, drive_phc,
)


async def _safe_probe(dut, attr_path):
    """Best-effort read of dotted attribute path; return None on miss."""
    try:
        obj = dut
        for part in attr_path.split('.'):
            obj = getattr(obj, part)
        return obj
    except Exception:
        return None


@cocotb.test()
async def test_phc_diag(dut):
    await setup(dut)

    cocotb.start_soon(drive_phc(dut, 'm', ns_per_tick=20, seed_seconds=0, seed_ns=1_000))
    cocotb.start_soon(drive_phc(dut, 's', ns_per_tick=20, seed_seconds=100, seed_ns=1_000))

    await lock_master(dut)
    await lock_slave(dut)
    await ClockCycles(dut.master_clk, 500)

    # Probe handles (after elab so hierarchy exists)
    s_is_short_pkt  = await _safe_probe(dut, 'u_slave.u_wlink.llrx.is_short_pkt')
    s_is_long_pkt   = await _safe_probe(dut, 'u_slave.u_wlink.llrx.is_long_pkt')
    s_dataIdMatch   = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.dataIdMatch')
    s_rx_pkt_valid  = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.rx_pkt_valid')
    s_rx_wfull      = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.rx_fifo_io_wfull')
    s_rx_winc       = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.rx_fifo_io_winc')
    s_ll_rx_valid   = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.auto_rx_in_valid')
    s_ll_rx_sop     = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.auto_rx_in_sop')
    s_ll_rx_dataid  = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.auto_rx_in_data_id')
    s_ll_rx_wc      = await _safe_probe(dut, 'u_slave.u_wlink.sp2wl.auto_rx_in_word_count')
    s_ptp_enable_r  = await _safe_probe(dut, 'u_slave_ptp.ptp_enable_r')
    m_ptp_enable_r  = await _safe_probe(dut, 'u_master_ptp.ptp_enable_r')

    # Master-side too, for sanity
    m_is_short_pkt  = await _safe_probe(dut, 'u_master.u_wlink.llrx.is_short_pkt')
    m_ll_tx_sop     = await _safe_probe(dut, 'u_master.u_wlink.sp2wl.auto_tx_out_sop')
    m_ll_tx_dataid  = await _safe_probe(dut, 'u_master.u_wlink.sp2wl.auto_tx_out_data_id')

    found = {
        's_is_short_pkt':  s_is_short_pkt is not None,
        's_is_long_pkt':   s_is_long_pkt is not None,
        's_dataIdMatch':   s_dataIdMatch is not None,
        's_rx_pkt_valid':  s_rx_pkt_valid is not None,
        's_rx_wfull':      s_rx_wfull is not None,
        's_rx_winc':       s_rx_winc is not None,
        's_ll_rx_valid':   s_ll_rx_valid is not None,
        's_ll_rx_sop':     s_ll_rx_sop is not None,
        's_ll_rx_dataid':  s_ll_rx_dataid is not None,
        's_ll_rx_wc':      s_ll_rx_wc is not None,
        's_ptp_enable_r':  s_ptp_enable_r is not None,
        'm_is_short_pkt':  m_is_short_pkt is not None,
        'm_ll_tx_sop':     m_ll_tx_sop is not None,
        'm_ll_tx_dataid':  m_ll_tx_dataid is not None,
    }
    dut._log.info(f"probe availability: {found}")

    # Enable PTP both sides — uses fixed helper (2-edge hold) in
    # test_phc_hw_sync_pair.py. Pre-fix, this was a single-edge pulse and
    # the slave-side write was silently lost.
    await ptp_reg_write(dut, 'm', REG_PTP_CTRL, 1 << CTRL_ENABLE, region=0)
    await ptp_reg_write(dut, 's', REG_PTP_CTRL, 1 << CTRL_ENABLE, region=0)
    await ClockCycles(dut.master_clk, 4)
    dut._log.info(
        f"after PTP enable: s_ptp_enable_r={int(s_ptp_enable_r.value)} "
        f"m_ptp_enable_r={int(m_ptp_enable_r.value)}")

    interval_ns = 2_000
    await ptp_reg_write(dut, 'm', REG_HW_SYNC_INTERVAL, interval_ns, region=1)
    await ptp_reg_write(dut, 'm', REG_HW_SYNC_CTRL,
                        (1 << HW_SYNC_FORCE_EN) | (1 << HW_SYNC_EN), region=1)

    # --------- Counters ---------
    # Master-side
    m_tx_sop_pulses = 0      # master ll_tx.sop high (per-cycle count of sop=1)
    m_tx_sync_pulses = 0     # ditto AND data_id==0x50
    # Slave-side - per-cycle counts on slave_clk
    s_ll_valid_cnt = 0       # slave RX router presented valid
    s_ll_valid_sop_cnt = 0   # slave RX router valid && sop
    s_is_short_cnt = 0       # is_short_pkt high (any cycle)
    s_is_long_cnt = 0
    s_dataIdMatch_cnt = 0
    s_rx_pkt_valid_cnt = 0   # post-classifier
    s_rx_winc_cnt = 0        # actually written to RX FIFO
    s_rx_wfull_cnt = 0
    last_dataid_seen = None
    distinct_dataids_seen = set()

    POLL_CYCLES = 50_000

    # Cycle-by-cycle sampling on slave_clk
    for i in range(POLL_CYCLES):
        await RisingEdge(dut.slave_clk)
        if s_ll_rx_valid is not None and int(s_ll_rx_valid.value):
            s_ll_valid_cnt += 1
            if s_ll_rx_sop is not None and int(s_ll_rx_sop.value):
                s_ll_valid_sop_cnt += 1
                if s_ll_rx_dataid is not None:
                    did = int(s_ll_rx_dataid.value)
                    last_dataid_seen = did
                    distinct_dataids_seen.add(did)
        if s_is_short_pkt is not None and int(s_is_short_pkt.value):
            s_is_short_cnt += 1
        if s_is_long_pkt is not None and int(s_is_long_pkt.value):
            s_is_long_cnt += 1
        if s_dataIdMatch is not None and int(s_dataIdMatch.value):
            s_dataIdMatch_cnt += 1
        if s_rx_pkt_valid is not None and int(s_rx_pkt_valid.value):
            s_rx_pkt_valid_cnt += 1
        if s_rx_winc is not None and int(s_rx_winc.value):
            s_rx_winc_cnt += 1
        if s_rx_wfull is not None and int(s_rx_wfull.value):
            s_rx_wfull_cnt += 1
        # master tx sample
        if m_ll_tx_sop is not None and int(m_ll_tx_sop.value):
            m_tx_sop_pulses += 1
            if m_ll_tx_dataid is not None and int(m_ll_tx_dataid.value) == 0x50:
                m_tx_sync_pulses += 1

    # Final readbacks
    if s_ptp_enable_r is not None:
        dut._log.info(f"final s_ptp_enable_r={int(s_ptp_enable_r.value)}")

    dut._log.info("===== Per-cycle counts over %d slave_clk cycles =====" % POLL_CYCLES)
    dut._log.info(f"  master sp2wl ll_tx.sop high cycles      = {m_tx_sop_pulses}")
    dut._log.info(f"  master sp2wl ll_tx.sop && data_id=0x50  = {m_tx_sync_pulses}")
    dut._log.info(f"  slave  sp2wl ll_rx.valid                = {s_ll_valid_cnt}")
    dut._log.info(f"  slave  sp2wl ll_rx.valid && sop         = {s_ll_valid_sop_cnt}")
    dut._log.info(f"  slave  llrx.is_short_pkt                = {s_is_short_cnt}")
    dut._log.info(f"  slave  llrx.is_long_pkt                 = {s_is_long_cnt}")
    dut._log.info(f"  slave  sp2wl.dataIdMatch                = {s_dataIdMatch_cnt}")
    dut._log.info(f"  slave  sp2wl.rx_pkt_valid               = {s_rx_pkt_valid_cnt}")
    dut._log.info(f"  slave  sp2wl.rx_fifo.winc               = {s_rx_winc_cnt}")
    dut._log.info(f"  slave  sp2wl.rx_fifo.wfull              = {s_rx_wfull_cnt}")
    dut._log.info(f"  slave  distinct data_ids seen on rx     = {sorted(distinct_dataids_seen)}")
    dut._log.info(f"  slave  last data_id seen                = {last_dataid_seen}")
