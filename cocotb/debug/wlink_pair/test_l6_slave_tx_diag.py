"""L6 diagnostic — observe slave-side FCSM TX path during recal-failed scenario.

Goal: capture exact sequence of slave FCSM state, sop, data_id, auto_tx_out_advance,
en_ff2_tx_demet_io_out, cr_pkt_seen_tx_demet_io_out, crack_pkt_seen_tx_demet_io_out
during the failing paired_recal scenario where slave never emits CR (0x44).
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write,
    apb_read, apb_write,
)
from test_paired_recal_to_link_data import (
    recal_cycle, drop_training_and_swreset_ll, STATE_NAME,
)


def _fcsm(dut, side):
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


# Background coroutine: trace FCSM state changes
TRACE = []  # list of dicts {cyc, side, ev}


async def trace_loop(dut, s, m, n_cycles):
    prev_state_s = -1
    prev_state_m = -1
    prev_data_id_s = -1
    prev_data_id_m = -1
    prev_m_rx_data_id = -1
    prev_m_rx_valid = -1
    prev_m_rx_sop = -1
    prev_m_cr_seen_rx = -1
    for cyc in range(n_cycles):
        await ClockCycles(dut.master_clk, 1)
        try:
            ss = int(s.state.value)
            ms = int(m.state.value)
            sop_s = int(s.sop.value)
            data_id_s = int(s.data_id.value)
            data_id_m = int(m.data_id.value)
            en_ff2_tx_s = int(s.en_ff2_tx_demet_io_out.value)
            cr_seen_tx_s = int(s.cr_pkt_seen_tx_demet_io_out.value)
            crack_seen_tx_s = int(s.crack_pkt_seen_tx_demet_io_out.value)
            cr_seen_rx_s = int(s.cr_pkt_seen_rx.value)
            advance_s = int(s.auto_tx_out_advance.value)
            # master RX side — what does master actually receive?
            m_rx_data_id = int(m.auto_rx_in_data_id.value)
            m_rx_valid = int(m.auto_rx_in_valid.value)
            m_rx_sop = int(m.auto_rx_in_sop.value)
            m_pkt_is_cr = int(m.pkt_is_cr_pkt.value)
            m_pkt_is_crack = int(m.pkt_is_crack_pkt.value)
            m_cr_seen_rx = int(m.cr_pkt_seen_rx.value)
            # slave's TX-router output (post-arbitration) — what actually goes on the wire
            try:
                s_txrt_out_sop  = int(dut.u_slave.u_wlink.txrouter.auto_out_sop.value)
                s_txrt_out_did  = int(dut.u_slave.u_wlink.txrouter.auto_out_data_id.value)
                s_txrt_out_adv  = int(dut.u_slave.u_wlink.txrouter.auto_out_advance.value)
            except Exception:
                s_txrt_out_sop = 0
                s_txrt_out_did = 0
                s_txrt_out_adv = 0
        except Exception as e:
            TRACE.append({"cyc": cyc, "side": "?", "ev": f"signal err: {e}"})
            return

        if ss != prev_state_s:
            TRACE.append({"cyc": cyc, "side": "s",
                "ev": f"STATE {prev_state_s}->{ss} ({STATE_NAME.get(ss,'?')}) "
                      f"data_id=0x{data_id_s:02x} sop={sop_s} "
                      f"en_ff2_tx={en_ff2_tx_s} cr_seen_tx={cr_seen_tx_s} "
                      f"crack_seen_tx={crack_seen_tx_s} cr_seen_rx={cr_seen_rx_s} "
                      f"advance={advance_s}"})
            prev_state_s = ss
        if ms != prev_state_m:
            TRACE.append({"cyc": cyc, "side": "m",
                "ev": f"STATE {prev_state_m}->{ms} ({STATE_NAME.get(ms,'?')}) "
                      f"data_id=0x{data_id_m:02x}"})
            prev_state_m = ms
        if data_id_s != prev_data_id_s:
            TRACE.append({"cyc": cyc, "side": "s",
                "ev": f"DATA_ID 0x{prev_data_id_s & 0xff:02x}->0x{data_id_s:02x} "
                      f"state={ss} sop={sop_s} advance={advance_s} "
                      f"cr_rx={cr_seen_rx_s} cr_tx={cr_seen_tx_s} crack_tx={crack_seen_tx_s}"})
            prev_data_id_s = data_id_s
        if data_id_m != prev_data_id_m:
            TRACE.append({"cyc": cyc, "side": "m",
                "ev": f"DATA_ID 0x{prev_data_id_m & 0xff:02x}->0x{data_id_m:02x} "
                      f"state={ms}"})
            prev_data_id_m = data_id_m
        if advance_s == 1 and sop_s == 1:
            TRACE.append({"cyc": cyc, "side": "s",
                "ev": f"EMIT data_id=0x{data_id_s:02x} state={ss} cr_rx={cr_seen_rx_s}"})
        # Slave's TX router output (this is what actually goes on the wire to master)
        if s_txrt_out_sop == 1 and s_txrt_out_adv == 1:
            TRACE.append({"cyc": cyc, "side": "s",
                "ev": f"TXRT_OUT data_id=0x{s_txrt_out_did:02x}"})
        # Master RX-side observations
        if m_rx_sop == 1 and m_rx_valid == 1:
            TRACE.append({"cyc": cyc, "side": "m",
                "ev": f"RX_SOP data_id=0x{m_rx_data_id:02x} is_cr={m_pkt_is_cr} is_crack={m_pkt_is_crack}"})
        if m_cr_seen_rx != prev_m_cr_seen_rx and m_cr_seen_rx == 1:
            TRACE.append({"cyc": cyc, "side": "m",
                "ev": f"CR_PKT_SEEN_RX LATCH (first time)"})
            prev_m_cr_seen_rx = m_cr_seen_rx


@cocotb.test()
async def test_01_slave_tx_path_trace(dut):
    """Cycle-by-cycle trace of slave FCSM TX path across the failing scenario."""
    TRACE.clear()
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    s = _fcsm(dut, "s")
    m = _fcsm(dut, "m")

    # Fork the tracer for full window
    tracer = cocotb.start_soon(trace_loop(dut, s, m, 8000))

    # Use the FAILING fuzz scenario: hold=300, settle=100, nrec=1 (mid-range scenario)
    await recal_cycle(dut, hold_cycles=300, settle_cycles=100)
    await drop_training_and_swreset_ll(dut)

    # Wait for tracer to collect ~3000-window observation
    await ClockCycles(dut.master_clk, 4000)

    dut._log.info("=" * 90)
    dut._log.info(f"TRACE EVENTS (total: {len(TRACE)})")
    dut._log.info("=" * 90)

    # ALL state transitions on each side
    all_state_s = [e for e in TRACE if e["side"] == "s" and "STATE" in e["ev"]]
    all_state_m = [e for e in TRACE if e["side"] == "m" and "STATE" in e["ev"]]
    dut._log.info(f"ALL slave  state transitions ({len(all_state_s)}):")
    for e in all_state_s:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")
    dut._log.info(f"ALL master state transitions ({len(all_state_m)}):")
    for e in all_state_m:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")

    # First state==1 entries on each side (master + slave)
    s1_events_s = [e for e in TRACE if e["side"] == "s" and "STATE" in e["ev"] and "->1" in e["ev"]]
    s1_events_m = [e for e in TRACE if e["side"] == "m" and "STATE" in e["ev"] and "->1" in e["ev"]]
    s12_events_s = [e for e in TRACE if e["side"] == "s" and "STATE" in e["ev"] and "1->2" in e["ev"]]

    dut._log.info(f"Slave  state==1 entries: {len(s1_events_s)}")
    for e in s1_events_s[:10]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")
    dut._log.info(f"Slave  state 1->2 exits: {len(s12_events_s)}")
    for e in s12_events_s[:10]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")
    dut._log.info(f"Master state==1 entries: {len(s1_events_m)}")
    for e in s1_events_m[:10]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")

    # Find slave data_id transitions
    did_events_s = [e for e in TRACE if e["side"] == "s" and "DATA_ID" in e["ev"]]
    dut._log.info(f"Slave  DATA_ID transitions: {len(did_events_s)}")
    for e in did_events_s[:20]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")

    # All emissions (advance+sop)
    emit_events_s = [e for e in TRACE if e["side"] == "s" and "EMIT" in e["ev"]]
    cr_emits = [e for e in emit_events_s if "0x44" in e["ev"]]
    crack_emits = [e for e in emit_events_s if "0x45" in e["ev"]]
    dut._log.info(f"Slave  TX emissions: total={len(emit_events_s)} CR(0x44)={len(cr_emits)} CRACK(0x45)={len(crack_emits)}")
    if cr_emits:
        for e in cr_emits[:3]:
            dut._log.info(f"  CR cyc {e['cyc']}: {e['ev']}")
    if crack_emits:
        dut._log.info(f"  first CRACK cyc {crack_emits[0]['cyc']}: {crack_emits[0]['ev']}")

    # Slave TX router output
    s_txrt_events = [e for e in TRACE if e["side"] == "s" and "TXRT_OUT" in e["ev"]]
    s_txrt_cr = [e for e in s_txrt_events if "0x44" in e["ev"]]
    s_txrt_crack = [e for e in s_txrt_events if "0x45" in e["ev"]]
    dut._log.info(f"Slave TX-router OUT advanced packets: total={len(s_txrt_events)} CR(0x44)={len(s_txrt_cr)} CRACK(0x45)={len(s_txrt_crack)}")
    for e in s_txrt_events[:20]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")

    # Master RX side analysis
    m_rx_sop_events = [e for e in TRACE if e["side"] == "m" and "RX_SOP" in e["ev"]]
    m_cr_rx_events = [e for e in TRACE if e["side"] == "m" and "CR_PKT_SEEN_RX" in e["ev"]]
    dut._log.info(f"Master RX SOP packets received: {len(m_rx_sop_events)}")
    for e in m_rx_sop_events[:20]:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")
    dut._log.info(f"Master CR_PKT_SEEN_RX latch events: {len(m_cr_rx_events)}")
    for e in m_cr_rx_events:
        dut._log.info(f"  cyc {e['cyc']}: {e['ev']}")
