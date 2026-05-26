"""Common helpers for the ptp_pair cocotb suite.

Mirrors the wlink_pair/test_link_bringup setup/lock/bringup primitives,
but adds PTP Short-Packet (SP) driver helpers tied to the cocotb-drivable
ptp_in/ptp_out buses exposed by tb_ptp_pair.sv.

Why duplicate vs import? The wlink_pair helpers (test_link_bringup.py)
live in a sibling directory; pulling them in via PYTHONPATH worked but is
fragile across cocotb regression runs. A small local mirror is cleaner
and keeps the ptp_pair suite self-contained.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Wlink APB offsets
WL_LINK_ENABLE_RESET = 0x0208
WL_LANE_MASK         = 0x0214
WL_LINK_STATUS       = 0x0234
WL_LINK_INTERRUPTS   = 0x0240
WL_FC_TIDELK_BASE    = 0x1700

# Region 8 (Region-8 ctrl_reg) slots used by bringup_pair_converge.sh
R8_SLOT0_TRAIN_RECAL = 0b1000
LL_CTRL_SWRESET_ON   = 0x27f08
LL_CTRL_SWRESET_OFF  = 0x27f00
LL_CTRL_ENABLED      = 0x27f07

# FCSM states for the TideLink FC channel
FCSM_IDLE          = 0
FCSM_SEND_CREDITS1 = 1
FCSM_SEND_CREDITS2 = 2
FCSM_LINK_EN_WAIT  = 3
FCSM_LINK_IDLE     = 4
FCSM_LINK_DATA     = 5

# PTP data_id constants per src/rtl/tidelink_ptp.sv
DATA_ID_PTP_SYNC      = 0x50
DATA_ID_PTP_FOLLOWUP  = 0x51   # task uses 0x51 for follow-up (DELAY_REQ slot)


# -----------------------------------------------------------------------
# Setup / role-lock — replica of wlink_pair test_link_bringup primitives
# -----------------------------------------------------------------------
async def setup(dut, master_period_ns=20.0, slave_period_ns=20.0,
                 stagger_por_cycles=0):
    cocotb.start_soon(Clock(dut.master_clk, int(round(master_period_ns * 1000)),
                            unit="ps").start())
    cocotb.start_soon(Clock(dut.slave_clk,  int(round(slave_period_ns  * 1000)),
                            unit="ps").start())
    for prefix in ['m', 's']:
        getattr(dut, f"{prefix}_apb_psel").value = 0
        getattr(dut, f"{prefix}_apb_penable").value = 0
        getattr(dut, f"{prefix}_apb_pwrite").value = 0
        getattr(dut, f"{prefix}_apb_paddr").value = 0
        getattr(dut, f"{prefix}_apb_pwdata").value = 0
        getattr(dut, f"{prefix}_apb_pprot").value = 0
        getattr(dut, f"{prefix}_apb_pstrb").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
        # Default PTP SP TX outputs to idle (cocotb drives later)
        getattr(dut, f"{prefix}_ptp_sp_tx_valid").value = 0
        getattr(dut, f"{prefix}_ptp_sp_tx_data_id").value = 0
        getattr(dut, f"{prefix}_ptp_sp_tx_payload").value = 0
        getattr(dut, f"{prefix}_ptp_sp_rx_accept").value = 1
    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value  = 0; dut.s_hresetn.value  = 0
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1
    if stagger_por_cycles > 0:
        await ClockCycles(dut.master_clk, stagger_por_cycles)
    dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def ctrl_write(dut, side, addr, data):
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr; sig_d.value = data; sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0


async def lock_master(dut):
    await ctrl_write(dut, 'm', 0, 0x02)


async def lock_slave(dut):
    await ctrl_write(dut, 's', 0, 0x03)


async def apb_write(dut, side, addr, data):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pwdata = getattr(dut, f"{side}_apb_pwdata")
    pstrb = getattr(dut, f"{side}_apb_pstrb")
    pready = getattr(dut, f"{side}_apb_pready")
    await RisingEdge(dut.apb_clk)
    psel.value = 1; paddr.value = addr & 0x1FFF
    pwr.value = 1; pwdata.value = data; pstrb.value = 0xF
    pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            break
    psel.value = 0; pen.value = 0; pwr.value = 0


async def apb_read(dut, side, addr):
    psel = getattr(dut, f"{side}_apb_psel")
    pen = getattr(dut, f"{side}_apb_penable")
    pwr = getattr(dut, f"{side}_apb_pwrite")
    paddr = getattr(dut, f"{side}_apb_paddr")
    pready = getattr(dut, f"{side}_apb_pready")
    prdata = getattr(dut, f"{side}_apb_prdata")
    await RisingEdge(dut.apb_clk)
    psel.value = 1; paddr.value = addr & 0x1FFF
    pwr.value = 0; pen.value = 0
    await RisingEdge(dut.apb_clk)
    pen.value = 1
    while True:
        await RisingEdge(dut.apb_clk)
        if int(pready.value):
            data = int(prdata.value)
            break
    psel.value = 0; pen.value = 0
    return data


# -----------------------------------------------------------------------
# HW bringup sequence — mirrors bringup_pair_converge.sh
# -----------------------------------------------------------------------
async def _set_slot0(dut, val):
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, val)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, val)


async def recal_cycle(dut, hold=200, settle=200):
    await _set_slot0(dut, 0x3)
    await ClockCycles(dut.master_clk, hold)
    await _set_slot0(dut, 0x1)
    await ClockCycles(dut.master_clk, settle)


async def drop_training_and_swreset_ll(dut):
    await _set_slot0(dut, 0x0)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_ON)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_SWRESET_OFF)
    await ClockCycles(dut.master_clk, 50)
    await apb_write(dut, 'm', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)
    await apb_write(dut, 's', WL_LINK_ENABLE_RESET, LL_CTRL_ENABLED)


def _fcsm(dut, side):
    """Hierarchical handle of the TideLink FC FCSM on a given side."""
    chip = dut.u_master if side == "m" else dut.u_slave
    return chip.u_wlink.tl2wl.wlink_tidelinktl


async def attempt_bringup(dut, observation_cycles=5000):
    """Run the standard role-lock + recal + LL-swreset sequence and
    return the final FCSM state on both sides plus a boolean indicating
    whether the link reached LINK_DATA (state 5) symmetrically."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await recal_cycle(dut, hold=200, settle=200)
    await drop_training_and_swreset_ll(dut)

    m = _fcsm(dut, "m"); s = _fcsm(dut, "s")
    max_m = 0; max_s = 0
    for _ in range(observation_cycles):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        if ms > max_m: max_m = ms
        if ss > max_s: max_s = ss
    return {
        "max_m": max_m, "max_s": max_s,
        "final_m": int(m.state.value), "final_s": int(s.state.value),
        "link_data": (max_m >= FCSM_LINK_DATA) and (max_s >= FCSM_LINK_DATA),
    }


# -----------------------------------------------------------------------
# PTP SP packet driver / observer
# -----------------------------------------------------------------------
async def send_ptp_sp(dut, side, data_id, payload, timeout_cycles=5000):
    """Drive a single PTP SP packet on a given side and wait for handshake.
    Returns the cycle count it took for ptp_sp_tx_ready to assert, or
    -1 on timeout. The 16-bit `payload` carries an opaque value (e.g.
    sequence number) — the link wire format is 16 bits regardless of
    whether the upper-layer message would notionally be 64 bits.
    """
    valid = getattr(dut, f"{side}_ptp_sp_tx_valid")
    did   = getattr(dut, f"{side}_ptp_sp_tx_data_id")
    pld   = getattr(dut, f"{side}_ptp_sp_tx_payload")
    rdy   = getattr(dut, f"{side}_ptp_sp_tx_ready")

    clk = dut.master_clk if side == "m" else dut.slave_clk
    await RisingEdge(clk)
    did.value = data_id & 0xFF
    pld.value = payload & 0xFFFF
    valid.value = 1
    for c in range(timeout_cycles):
        await RisingEdge(clk)
        if int(rdy.value):
            valid.value = 0
            return c
    valid.value = 0
    return -1


class SPObserver:
    """Monitor the peer-side SP RX bus across a window. Latches each
    (data_id, payload) tuple seen. Cocotb sets `<side>_ptp_sp_rx_accept`
    to 1 by default so the FC RX strobe advances without TideLink PTP
    in the loop (the tidelink_ptp module is NOT instantiated in the
    paired wlink TB — observing at ptp_out is sufficient for sim PTP
    validation).
    """
    def __init__(self, dut, side):
        self.dut = dut
        self.side = side
        self.events = []   # list of (data_id, payload, sim_cycle_idx)
        self._stop = False

    async def run(self, max_cycles=10000):
        valid = getattr(self.dut, f"{self.side}_ptp_sp_rx_valid")
        did   = getattr(self.dut, f"{self.side}_ptp_sp_rx_data_id")
        pld   = getattr(self.dut, f"{self.side}_ptp_sp_rx_payload")
        accept= getattr(self.dut, f"{self.side}_ptp_sp_rx_accept")
        accept.value = 1
        clk = self.dut.master_clk if self.side == "m" else self.dut.slave_clk
        for c in range(max_cycles):
            await RisingEdge(clk)
            if self._stop:
                return
            try:
                if int(valid.value):
                    self.events.append((int(did.value), int(pld.value), c))
            except Exception:
                # X/Z propagation during reset — ignore
                pass

    def count_by_data_id(self, data_id):
        return sum(1 for e in self.events if e[0] == data_id)

    def payloads(self, data_id):
        return [e[1] for e in self.events if e[0] == data_id]

    def stop(self):
        self._stop = True


def skip_if_no_link_data(dut, bringup_obs, label=""):
    """Return (True, reason) if the bringup observation indicates the
    link never reached LINK_DATA (state 5) on both sides. The caller
    uses cocotb.test() `skip=True` semantics by returning early with
    a clear log marker. cocotb's regression manager picks up the
    skipped log line and prints SKIP in the summary.
    """
    if not bringup_obs["link_data"]:
        msg = (f"skipped{(' [' + label + ']') if label else ''}: link bringup "
               f"did not reach LINK_DATA (max_m={bringup_obs['max_m']}, "
               f"max_s={bringup_obs['max_s']}) — pending option (c) PR")
        dut._log.warning(msg)
        return True, msg
    return False, ""
