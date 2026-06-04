"""Probe master FC-adapter TX internals during one compliant AHB write.

Compliant driver holds hwdata across the data phase, yet the payload still
ships as 0. This captures, per cycle, the master adapter's input hwdata, the
latched addr/data-phase flags, and what the skid actually registers -- to see
exactly where DEADBEEF is lost.
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from test_tidelink_pair_doorbell import (
    PairTB, run_bringup_full, APB_R8_SLOT0, R8_SLOT0_OFF,
)
from test_data_path_compliant import ahb_tx_write_compliant


def _i(sig):
    try:
        return int(sig.value)
    except Exception:
        return None


@cocotb.test()
async def test_master_tx_probe(dut):
    tb = PairTB(dut)
    await run_bringup_full(tb)
    await tb.m_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await tb.s_apb.write(APB_R8_SLOT0, R8_SLOT0_OFF)
    await ClockCycles(dut.hclk, 200)

    fa = dut.u_master.u_fc_adapter

    async def watch(n, label):
        for cyc in range(n):
            await RisingEdge(dut.hclk)
            hw   = _i(fa.ahb_tx_hwdata)
            ha   = _i(fa.ahb_tx_haddr)
            ar   = _i(fa.tx_addr_r)
            dph  = _i(fa.tx_data_phase_r)
            fv   = _i(fa.tx_fc_valid)
            sv   = _i(fa.skid_valid_r)
            sd   = _i(fa.skid_data_r)
            av   = _i(fa.tl_fc_a2l_valid)
            ard  = _i(fa.tl_fc_a2l_ready)
            hro  = _i(fa.ahb_tx_hreadyout)
            if dph or fv or sv or av or (hw not in (0, None)):
                sdt = "----" if sd is None else f"0x{sd:012x}"
                tb.log.info(
                    f"[mtx:{label}] cyc={cyc:3d} hwdata={hw} haddr={ha} "
                    f"tx_addr_r={ar} dphase={dph} fc_valid={fv} hro={hro} | "
                    f"skid_v={sv} skid_d={sdt} a2l_v={av} a2l_rdy={ard}")

    # Drive a single known word; run watcher concurrently.
    w = cocotb.start_soon(watch(40, "w8"))
    await ahb_tx_write_compliant(tb, "m", 0x8, 0xDEADBEEF)
    await w
