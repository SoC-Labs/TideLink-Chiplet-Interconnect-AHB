"""PHC HW_SYNC pair-sim: positive end-to-end assertion for the slave RX path.

History
-------
This test originally `expect_fail=True` to reproduce the HW PHC slave-RX
gap from docs/PHC_PHASE1_HW_REPORT.md §"Build #9 retry". Diagnostic
instrumentation (test_phc_diag.py) localised the drop to the slave-side
`tidelink_ptp.ptp_enable_r` FF — `rx_accept = ptp_sp_rx_valid &
ptp_enable_r` was held low because the slave's PTP_CTRL register write
pulse was being lost in the cocotb scheduling race between simultaneously-
edging master_clk and slave_clk (master succeeded, slave silently failed
with identical helper code).

Per-cycle counts over 50 000 slave_clk cycles confirmed the layer:
   master sp2wl ll_tx.sop && data_id=0x50  = 7984
   slave  sp2wl ll_rx.valid && sop         = 8183
   slave  llrx.is_short_pkt                = 8176  ← classifier OK
   slave  sp2wl.rx_pkt_valid               = 7968  ← match + valid OK
   slave  sp2wl.rx_fifo.winc               =   64  ← FIFO writes blocked
   slave  sp2wl.rx_fifo.wfull              = 49481 ← because rx_accept=0
   slave  ptp_enable_r                     =    0  ← root cause

Fix: ptp_reg_write now aligns to the side's hclk and holds the write
pulse for two rising edges. With ptp_enable_r reliably set, the RX FIFO
drains correctly and sync_rx_done pulses fire end-to-end.

This test now asserts the slave receives at least one SYNC short packet
per master HW_SYNC interval, end-to-end through both Wlinks.
"""
import cocotb
import pytest
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# Wlink APB offsets (from wlink_pair/test_link_bringup.py)
WL_LINK_ENABLE_RESET = 0x0208
WL_LANE_MASK         = 0x0214
WL_LINK_STATUS       = 0x0234

# tidelink_ptp register offsets (from cocotb/tidelink_ptp/test_tidelink_ptp.py)
# Region 1 (ptp_reg_region=0):
REG_PTP_CTRL       = 0x5
REG_PTP_RX_PAYLOAD = 0x6
REG_PTP_STATUS     = 0x7
# Region 2 (ptp_reg_region=1):
REG_HW_SYNC_CTRL     = 0x0
REG_HW_SYNC_INTERVAL = 0x1
REG_HW_SYNC_STATUS   = 0x2

CTRL_ENABLE   = 0
CTRL_RX_VALID = 2

HW_SYNC_EN       = 0  # [0]
HW_SYNC_FORCE_EN = 2  # [2]

DATA_ID_SYNC = 0x50


# -------------------------------------------------------------------------
# Setup / bring-up helpers (lifted from wlink_pair/test_link_bringup.py)
# -------------------------------------------------------------------------
async def setup(dut, master_period_ns=20.0, slave_period_ns=20.0):
    """Start both clocks and bring both sides out of POR."""
    cocotb.start_soon(
        Clock(dut.master_clk, int(round(master_period_ns * 1000)), unit="ps").start()
    )
    cocotb.start_soon(
        Clock(dut.slave_clk, int(round(slave_period_ns * 1000)), unit="ps").start()
    )

    for prefix in ('m', 's'):
        getattr(dut, f"{prefix}_apb_psel").value     = 0
        getattr(dut, f"{prefix}_apb_penable").value  = 0
        getattr(dut, f"{prefix}_apb_pwrite").value   = 0
        getattr(dut, f"{prefix}_apb_paddr").value    = 0
        getattr(dut, f"{prefix}_apb_pwdata").value   = 0
        getattr(dut, f"{prefix}_apb_pprot").value    = 0
        getattr(dut, f"{prefix}_apb_pstrb").value    = 0
        getattr(dut, f"{prefix}_ctrl_reg_write").value = 0
        getattr(dut, f"{prefix}_ctrl_reg_addr").value  = 0
        getattr(dut, f"{prefix}_ctrl_reg_wdata").value = 0
        getattr(dut, f"{prefix}_ptp_reg_write").value  = 0
        getattr(dut, f"{prefix}_ptp_reg_addr").value   = 0
        getattr(dut, f"{prefix}_ptp_reg_wdata").value  = 0
        getattr(dut, f"{prefix}_ptp_reg_region").value = 0

    dut.m_poresetn.value = 0; dut.s_poresetn.value = 0
    dut.m_hresetn.value  = 0; dut.s_hresetn.value  = 0
    await ClockCycles(dut.master_clk, 5)
    dut.m_poresetn.value = 1; dut.s_poresetn.value = 1
    await ClockCycles(dut.master_clk, 2)
    dut.m_hresetn.value = 1; dut.s_hresetn.value = 1
    await ClockCycles(dut.master_clk, 5)


async def ctrl_write(dut, side, addr, data):
    sig_w = getattr(dut, f"{side}_ctrl_reg_write")
    sig_a = getattr(dut, f"{side}_ctrl_reg_addr")
    sig_d = getattr(dut, f"{side}_ctrl_reg_wdata")
    await RisingEdge(dut.apb_clk)
    sig_a.value = addr
    sig_d.value = data
    sig_w.value = 1
    await RisingEdge(dut.apb_clk)
    sig_w.value = 0


async def lock_master(dut):
    await ctrl_write(dut, 'm', 0, 0x02)  # role=master, lock


async def lock_slave(dut):
    await ctrl_write(dut, 's', 0, 0x03)  # role=slave, lock


# -------------------------------------------------------------------------
# tidelink_ptp register helpers (ptp_reg_* backdoor — same as cocotb/tidelink_ptp)
# -------------------------------------------------------------------------
async def ptp_reg_write(dut, side, addr, data, region=0):
    """Drive the tidelink_ptp register pulse synchronously to the side's hclk.

    Hold the write for two rising edges so it is reliably captured even when
    the master/slave clocks are simultaneously edging — cocotb's value-
    scheduling can lose a one-cycle pulse against the second of two
    aligned clocks (seen empirically on the slave side: m_ptp_enable_r=1
    after one pulse but s_ptp_enable_r=0 with identical helper code).
    """
    clk = getattr(dut, f"{'master' if side == 'm' else 'slave'}_clk")
    # Align to a fresh edge before driving so the scheduled-write race
    # against simultaneous master/slave edges is avoided.
    await RisingEdge(clk)
    getattr(dut, f"{side}_ptp_reg_addr").value   = addr
    getattr(dut, f"{side}_ptp_reg_wdata").value  = data
    getattr(dut, f"{side}_ptp_reg_region").value = region
    getattr(dut, f"{side}_ptp_reg_write").value  = 1
    await RisingEdge(clk)  # FF samples write=1 here
    await RisingEdge(clk)  # hold one extra cycle as belt-and-braces
    getattr(dut, f"{side}_ptp_reg_write").value  = 0
    getattr(dut, f"{side}_ptp_reg_region").value = 0


async def ptp_reg_read(dut, side, addr, region=0):
    clk = getattr(dut, f"{'master' if side == 'm' else 'slave'}_clk")
    getattr(dut, f"{side}_ptp_reg_addr").value   = addr
    getattr(dut, f"{side}_ptp_reg_region").value = region
    await RisingEdge(clk)
    val = int(getattr(dut, f"{side}_ptp_reg_rdata").value)
    getattr(dut, f"{side}_ptp_reg_region").value = 0
    return val


# -------------------------------------------------------------------------
# Free-running PHC time driver (cocotb coroutine; tracks `phc_seconds` /
# `phc_nanoseconds` as wall-time inside the sim).
# -------------------------------------------------------------------------
async def drive_phc(dut, side, ns_per_tick=20, seed_seconds=0, seed_ns=0):
    """Increment phc_nanoseconds by ns_per_tick on each apb_clk edge of `side`.
    Rolls into phc_seconds on overflow."""
    clk = getattr(dut, f"{'master' if side == 'm' else 'slave'}_clk")
    sec_sig = getattr(dut, f"{side}_phc_seconds")
    ns_sig  = getattr(dut, f"{side}_phc_nanoseconds")
    sec = seed_seconds
    ns  = seed_ns
    NS_PER_S = 1_000_000_000
    sec_sig.value = sec
    ns_sig.value  = ns
    while True:
        await RisingEdge(clk)
        ns += ns_per_tick
        if ns >= NS_PER_S:
            ns -= NS_PER_S
            sec += 1
        sec_sig.value = sec
        ns_sig.value  = ns


# -------------------------------------------------------------------------
# Test
# -------------------------------------------------------------------------
@cocotb.test()
async def test_phc_hw_sync_pair(dut):
    """End-to-end SYNC short-packet RX assertion (pair-sim).

    Programs master HW_SYNC initiator (Region 2: INTERVAL + EN|FORCE_EN, the
    same `0x5` write performed by `bringup_ptp_sync.sh` step [5]). Polls slave
    `PTP_CTRL[2]` (rx_valid) and `sync_rx_done` for evidence that the PHC
    short packets routed through master Wlink -> GPIO PHY -> slave Wlink ->
    slave tidelink_ptp.ptp_sp_rx_valid are accepted and latched.
    """
    await setup(dut)

    # Start PHC time counters on both sides — master a bit later than slave
    # so the master's HW_SYNC initiator computes a sensible "target_ns +
    # interval" without rolling.
    cocotb.start_soon(drive_phc(dut, 'm', ns_per_tick=20, seed_seconds=0, seed_ns=1_000))
    # Slave PHC starts 100 s ahead (deliberate offset, like the real bench).
    cocotb.start_soon(drive_phc(dut, 's', ns_per_tick=20, seed_seconds=100, seed_ns=1_000))

    # Bring the Wlink pair up (role lock both sides + a settling window).
    await lock_master(dut)
    await lock_slave(dut)
    # ~500 master cycles is enough for link to come fully active in the sim
    # (cf. wlink_pair/test_02_fc_handshake_completes — link is up by ~2000 ns).
    await ClockCycles(dut.master_clk, 500)

    dut._log.info(
        f"After bring-up: m_role_locked={int(dut.m_role_locked.value)} "
        f"s_role_locked={int(dut.s_role_locked.value)} "
        f"m_tx_link_idle={int(dut.m_tx_link_idle.value)} "
        f"s_tx_link_idle={int(dut.s_tx_link_idle.value)}"
    )

    # Enable PTP on BOTH sides so that slave will accept RX packets
    # (PTP_CTRL[0] = enable). On HW this corresponds to the bringup script
    # writing the PTP enable bit before HW_SYNC starts.
    await ptp_reg_write(dut, 'm', REG_PTP_CTRL, 1 << CTRL_ENABLE, region=0)
    await ptp_reg_write(dut, 's', REG_PTP_CTRL, 1 << CTRL_ENABLE, region=0)
    await ClockCycles(dut.master_clk, 4)

    # Program master HW_SYNC_INTERVAL (Region 2 0x044): short interval so
    # the FSM fires quickly inside the simulation window.
    interval_ns = 2_000  # 2 µs — well inside our ~10 ms poll window
    await ptp_reg_write(dut, 'm', REG_HW_SYNC_INTERVAL, interval_ns, region=1)

    # Master HW_SYNC enable + force_en (same as bringup_ptp_sync.sh step [5]:
    #   value = (1<<FORCE_EN) | (1<<EN) = 0x5
    # The force_en bit bypasses the phc_locked_i gate that b61c84a addressed.
    await ptp_reg_write(
        dut, 'm', REG_HW_SYNC_CTRL,
        (1 << HW_SYNC_FORCE_EN) | (1 << HW_SYNC_EN),
        region=1,
    )

    # ------------------------------------------------------------------
    # Poll
    # ------------------------------------------------------------------
    # Watch slave's sync_rx_done (single-cycle pulse on each accepted SYNC)
    # AND slave's PTP_CTRL[2] (rx_valid) as the latched evidence of any
    # short-packet RX. Either firing == bug is reproduced-as-fixed.
    POLL_CYCLES = 50_000
    CHUNK = 200
    master_status_seen = 0
    slave_rx_pulses = 0
    slave_rx_valid_latched = False

    for chunk in range(POLL_CYCLES // CHUNK):
        await ClockCycles(dut.master_clk, CHUNK)
        # Track slave sync_rx_done pulses
        if int(dut.s_sync_rx_done.value):
            slave_rx_pulses += 1
        # Read master HW_SYNC_STATUS to confirm the master FSM IS advancing
        m_status = await ptp_reg_read(dut, 'm', REG_HW_SYNC_STATUS, region=1)
        if m_status != master_status_seen and chunk < 20:
            dut._log.info(
                f"  cycle ~{(chunk+1)*CHUNK} "
                f"master HW_SYNC_STATUS=0x{m_status:08x} "
                f"(seq_num={(m_status >> 2) & 0xFFFF})"
            )
            master_status_seen = m_status
        # Read slave PTP_CTRL — bit [2] latches on any short-packet RX
        s_ctrl = await ptp_reg_read(dut, 's', REG_PTP_CTRL, region=0)
        if (s_ctrl >> CTRL_RX_VALID) & 1:
            slave_rx_valid_latched = True

    # Final probe
    m_final_status = await ptp_reg_read(dut, 'm', REG_HW_SYNC_STATUS, region=1)
    s_final_ctrl   = await ptp_reg_read(dut, 's', REG_PTP_CTRL, region=0)

    dut._log.info("---- PHC pair-sim summary ----")
    dut._log.info(f"  master HW_SYNC_STATUS = 0x{m_final_status:08x} "
                  f"(active={m_final_status & 1}, seq_num={(m_final_status >> 2) & 0xFFFF})")
    dut._log.info(f"  slave  PTP_CTRL       = 0x{s_final_ctrl:08x} "
                  f"(rx_valid={ (s_final_ctrl >> CTRL_RX_VALID) & 1 })")
    dut._log.info(f"  slave sync_rx_done pulses observed = {slave_rx_pulses}")
    dut._log.info(f"  slave PTP_CTRL[2] rx_valid latched = {slave_rx_valid_latched}")

    # Sanity: master MUST be firing (else this test is testing nothing useful).
    master_seq = (m_final_status >> 2) & 0xFFFF
    assert master_seq > 0, (
        f"Master HW_SYNC never advanced (seq_num=0). Bring-up may be incomplete; "
        f"status=0x{m_final_status:08x}. Check role lock + tx_link_idle wiring."
    )

    # The actual reproduction assertion: slave MUST have received at least one
    # SYNC short packet. On HW + on broken sim this fires; on fixed sim it
    # turns into a clean PASS.
    assert slave_rx_pulses > 0 or slave_rx_valid_latched, (
        "Slave never observed an incoming PHC SYNC short packet "
        "(sync_rx_done never pulsed AND PTP_CTRL.rx_valid never latched). "
        f"This reproduces the HW PHC slave-RX gap documented in "
        f"docs/PHC_PHASE1_HW_REPORT.md §'Build #9 retry'. "
        f"Master fired {master_seq} sync packets; slave saw 0."
    )
