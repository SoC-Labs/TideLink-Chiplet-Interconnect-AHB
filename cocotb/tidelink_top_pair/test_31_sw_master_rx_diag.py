"""DIAGNOSTIC: does the WORKING SW-bootstrap path deliver packets to the
master FCSM RX? Mirror of test_30 but on the SW path (do_role_lock +
to_data_mode), so we can A/B the master RX packet delivery.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_tidelink_pair_doorbell import (
    PairTB, Clock, CLK_PERIOD_NS, REF_CLK_PERIOD_NS,
    run_bringup_full,
)


def _fcsm(tb, side):
    top = tb.dut.u_master if side == "m" else tb.dut.u_slave
    return top.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl


def _si(sig, d=-1):
    try: return int(sig.value)
    except (ValueError, AttributeError): return d


async def _watch_master_rx(tb, n, label):
    dut = tb.dut
    fc = _fcsm(tb, "m")
    n_cr = n_crack = n_other = n_sop = 0
    ids = {}
    for _ in range(n):
        await RisingEdge(dut.hclk)
        try:
            sop = int(fc.auto_rx_in_sop.value); val = int(fc.auto_rx_in_valid.value)
        except (ValueError, AttributeError):
            continue
        if sop and val:
            n_sop += 1
            did = _si(fc.auto_rx_in_data_id)
            ids[did] = ids.get(did, 0) + 1
            try:
                if int(fc.pkt_is_cr_pkt.value): n_cr += 1
                elif int(fc.pkt_is_crack_pkt.value): n_crack += 1
                else: n_other += 1
            except (ValueError, AttributeError):
                pass
    idstr = " ".join(f"0x{k:02x}:{v}" for k, v in sorted(ids.items()))
    tb.log.info(f"  [{label}] master RX over {n} cy: sop={n_sop} "
                f"cr={n_cr} crack={n_crack} other={n_other} | data_ids: {idstr}")


@cocotb.test()
async def test_sw_master_rx_diag(dut):
    tb = PairTB(dut)
    cocotb.start_soon(Clock(dut.hclk, int(round(CLK_PERIOD_NS*1000)), unit="ps").start())
    cocotb.start_soon(Clock(dut.ref_clk, int(round(REF_CLK_PERIOD_NS*1000)), unit="ps").start())
    for p in ("m", "s"):
        for sig, val in (("apb_psel",0),("apb_penable",0),("apb_pwrite",0),
            ("apb_paddr",0),("apb_pwdata",0),("apb_pstrb",0xF),("apb_pprot",0),
            ("ahb_tx_hsel",0),("ahb_tx_htrans",0),("ahb_tx_hready_in",1),
            ("ahb_fifo_hsel",0),("ahb_fifo_htrans",0),("ahb_fifo_hready_in",1)):
            try: getattr(dut, f"{p}_{sig}").value = val
            except AttributeError: pass
    await run_bringup_full(tb)   # do_role_lock + passive autocal + to_data_mode
    for side in ("m", "s"):
        fc = _fcsm(tb, side)
        tb.log.info(f"  {side}: state={_si(fc.state)} cr={_si(fc.cr_pkt_seen_rx)} "
                    f"crack={_si(fc.crack_pkt_seen_rx)}")
    await _watch_master_rx(tb, 4000, "SW path post to_data_mode")
