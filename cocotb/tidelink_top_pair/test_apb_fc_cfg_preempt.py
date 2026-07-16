"""FAIL-FIRST regression lock — FC-config-vs-PS APB arbitration at tidelink_top.

Reproduces, in miniature, the silicon Zynq-7000 lockup that hangs die_a the
instant the second die is armed (the `wr 0x4403_210C = 0x1` train_auto_en
write). Root cause (tidelink_top.sv):

    :726   wire fc_cfg_apb_active = fc_cfg_apb_psel;   // bare comb term, NO arbiter
    :738-742 tl_apb_{paddr,pwrite,pwdata,psel,penable} = fc_cfg_apb_active
                                                         ? fc_cfg_* : <external PS APB>
    :1097  tl_regs_prdata  = fc_cfg_apb_active ? '0   : tl_apb_prdata;
    :1098  tl_regs_pready  = fc_cfg_apb_active ? 1'b0 : tl_apb_pready;

`fc_cfg_apb_psel` is driven by the FC adapter (fc_rx_cfg_psel, the peer
credit/doorbell/returner config-write path). It has UNCONDITIONAL priority. If
it is asserted while an external PS access to Region 8 (apb_sel_tidelink,
0x4403_2xxx) is in its ACCESS phase, the mux swaps paddr/pwrite/pwdata out from
under the in-flight access AND forces tl_regs_pready=0 — so the PS access never
completes. The Zynq M_AXI_GP has NO transaction timeout ⇒ the CPU hangs
permanently (Bus error on every later /dev/mem access). This is both an APB
protocol violation (paddr swapped mid-ACCESS) and unbounded starvation.

How fc_cfg_apb_psel is asserted here
------------------------------------
The FC adapter's real RX FSM (tidelink_fc_adapter.sv) always transits back
through RX_IDLE between config writes, so its psel has a 1-cycle gap every
transaction — a *gapless* hold (the worst-case sustained-traffic hazard the
fix must eliminate) is therefore driven by FORCING the internal net
`u_master.fc_cfg_apb_psel` (+ paddr/pwrite/pwdata/penable), NOT via the FSM.
This is the "force the net" option: it models sustained peer FC traffic that
keeps the config port continuously requesting the bus. The separate
`test_apb_fc_cfg_no_fc_starvation` case below drives the REAL FSM (via
tl_fc_l2a_valid) to prove the fix never deadlocks or starves the FC itself.

Fail-first discriminators (on the PRE-FIX RTL)
----------------------------------------------
  * apb_pready never rises while fc_cfg_apb_psel is held  → STARVATION assert fails.
  * tl_apb_paddr is swapped to the FC's addr mid-ACCESS   → PROTOCOL assert fails.

Both PASS once transaction-atomic arbitration lands (the external access owns
the bus until pready; the FC waits on backpressure).

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 TB_TOP_NO_DUMP=1 COCOTB_RESOLVE_X=ZEROS \
      SIM_BUILD=sim_build_fcpreempt SIM=vcs \
      make MODULE=test_apb_fc_cfg_preempt
"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from test_31_autonomous_training_exit import _idle_stimulus, _reset, _si

# ---- Region-8 targets (12-bit APB view; SoC 0x4403_2xxx) --------------------
PADDR_PHY_ALIGN_ID = 0x11C        # RO const 0x5041_0100, pslverr=0 on read
PHY_ALIGN_ID_VAL   = 0x5041_0100
PADDR_BIT_SLIP_LO  = 0x104        # RW, reads back {8'h0, swi_bit_slip_lo_r[23:0]}
BIT_SLIP_MASK      = 0x00FF_FFFF

# APB 15-bit unified addresses (Region 8 = paddr[14:13]=01, i.e. + 0x2000)
APB_PHY_ALIGN_ID = 0x2000 | PADDR_PHY_ALIGN_ID   # 0x211C
APB_BIT_SLIP_LO  = 0x2000 | PADDR_BIT_SLIP_LO    # 0x2104

# A distinct FC-config address + data so any mux swap is unambiguous.
FC_PADDR  = 0x0A8
FC_PWDATA = 0xFCFC_FCFC

# tidelink_fc_adapter RX FSM state encodings (rx_state_t).
RX_IDLE, RX_ADDR_PHASE, RX_DATA_PHASE = 0, 1, 2

# tidelink_fc_adapter packet-type localparams.
PKT_SIDEBAND = 0b01

STALL_BUDGET = 64                 # bounded — a legal ack is 1 cycle


def _fc_sideband_word(addr_offset, payload):
    """Build a 48-bit FC RX word: [47:46]=PKT_SIDEBAND, [45:32]=addr, [31:0]=data."""
    return ((PKT_SIDEBAND & 0x3) << 46) | ((addr_offset & 0x3FFF) << 32) | (payload & 0xFFFFFFFF)


async def _force_fc_cfg_active(top, pwrite, pwdata):
    """Force the FC config port to CONTINUOUSLY request the bus (sustained-traffic
    model). Returns nothing; caller must _release_fc_cfg()."""
    top.fc_cfg_apb_paddr.value   = Force(FC_PADDR)
    top.fc_cfg_apb_pwdata.value  = Force(pwdata)
    top.fc_cfg_apb_pwrite.value  = Force(pwrite)
    top.fc_cfg_apb_penable.value = Force(1)
    top.fc_cfg_apb_psel.value    = Force(1)


def _release_fc_cfg(top):
    top.fc_cfg_apb_psel.value    = Release()
    top.fc_cfg_apb_penable.value = Release()
    top.fc_cfg_apb_pwrite.value  = Release()
    top.fc_cfg_apb_pwdata.value  = Release()
    top.fc_cfg_apb_paddr.value   = Release()


async def _drive_ext_setup_then_access(dut, addr15, pwrite, pwdata):
    """Drive the external (PS) APB into its ACCESS phase (penable=1) and LEAVE it
    there (does not wait for pready). Mirrors APBMaster.write/read timing."""
    dut.m_apb_psel.value    = 1
    dut.m_apb_paddr.value   = addr15 & 0x7FFF
    dut.m_apb_pwrite.value  = 1 if pwrite else 0
    dut.m_apb_pwdata.value  = pwdata & 0xFFFFFFFF
    dut.m_apb_pstrb.value   = 0xF
    dut.m_apb_pprot.value   = 0
    dut.m_apb_penable.value = 0
    await RisingEdge(dut.hclk)          # SETUP phase
    dut.m_apb_penable.value = 1
    await RisingEdge(dut.hclk)          # ACCESS phase established


def _ext_idle(dut):
    dut.m_apb_psel.value    = 0
    dut.m_apb_penable.value = 0
    dut.m_apb_pwrite.value  = 0
    dut.m_apb_paddr.value   = 0
    dut.m_apb_pwdata.value  = 0


async def _boot(dut):
    tb = PairTB(dut)
    await _idle_stimulus(dut)
    await _reset(dut)
    await ClockCycles(dut.hclk, 20)
    return tb


@cocotb.test()
async def test_apb_fc_cfg_preempt_read(dut):
    """External PS READ of Region-8 PHY_ALIGN_ID (0x211C) while the FC config
    port holds the bus. The read MUST still complete with the correct value and
    its address MUST NOT be swapped mid-ACCESS. FAILS on the pre-fix RTL."""
    log = dut._log
    tb  = await _boot(dut)
    top = dut.u_master

    # Golden clean read (no FC contention) — establishes the correct value.
    golden = await tb.m_apb.read(APB_PHY_ALIGN_ID)
    assert golden == PHY_ALIGN_ID_VAL, (
        f"harness sanity: clean read of PHY_ALIGN_ID got 0x{golden:08x}, "
        f"expected 0x{PHY_ALIGN_ID_VAL:08x}")
    await ClockCycles(dut.hclk, 4)

    # FC config port continuously requests the bus (sustained-traffic model).
    await _force_fc_cfg_active(top, pwrite=0, pwdata=FC_PWDATA)
    await ClockCycles(dut.hclk, 2)
    assert _si(top.fc_cfg_apb_active) == 1, (
        "harness sanity: forcing fc_cfg_apb_psel did not make the FC config port "
        "active before the external access started")

    # External PS read into ACCESS phase, held.
    await _drive_ext_setup_then_access(dut, APB_PHY_ALIGN_ID, pwrite=0, pwdata=0)

    ready, prdata, pslverr = False, None, None
    paddr_swapped_to = None
    for _ in range(STALL_BUDGET):
        cur_paddr = _si(top.tl_apb_paddr)
        if cur_paddr != PADDR_PHY_ALIGN_ID and paddr_swapped_to is None:
            paddr_swapped_to = cur_paddr
        if _si(dut.m_apb_pready) == 1:
            ready   = True
            prdata  = _si(dut.m_apb_prdata)
            pslverr = _si(dut.m_apb_pslverr)
            break
        await RisingEdge(dut.hclk)

    _ext_idle(dut)
    _release_fc_cfg(top)
    await ClockCycles(dut.hclk, 4)

    # ---- ASSERT 1: bounded completion (the starvation discriminator) --------
    assert ready, (
        f"STARVATION: external PS read of 0x{APB_PHY_ALIGN_ID:04x} (Region 8) never "
        f"completed (apb_pready stuck 0) within {STALL_BUDGET} cycles while the FC "
        f"config port held the bus — this is the Zynq M_AXI_GP hang: the in-flight "
        f"PS access is preempted and never acked, so /dev/mem Bus-errors for ever.")
    # ---- ASSERT 4: no mid-ACCESS address swap (APB protocol) ----------------
    assert paddr_swapped_to is None, (
        f"APB PROTOCOL VIOLATION: tl_apb_paddr was swapped to 0x{paddr_swapped_to:03x} "
        f"(the FC's addr) during the ACCESS phase of the external read to "
        f"0x{PADDR_PHY_ALIGN_ID:03x} — the FC config mux preempted the in-flight PS "
        f"access instead of waiting for it to complete.")
    # ---- ASSERT 2: correct data, no error -----------------------------------
    assert prdata == golden, (
        f"external read returned 0x{prdata:08x}, expected the ctrl-register value "
        f"0x{golden:08x} (got '0 ⇒ masked FC prdata, or the FC's data ⇒ mux swap)")
    assert pslverr == 0, f"external read raised pslverr={pslverr} unexpectedly"
    log.info("PREEMPT-READ PASS: PS read completed byte-exact (0x%08x), addr never "
             "swapped, no starvation, under sustained FC-config contention", prdata)


@cocotb.test()
async def test_apb_fc_cfg_preempt_write(dut):
    """External PS WRITE of Region-8 SWI_BIT_SLIP_LO (0x2104) while the FC config
    port holds the bus. The PS's pwdata (not the FC's) MUST land, the access MUST
    complete, and paddr/pwdata MUST NOT be swapped mid-ACCESS. FAILS pre-fix."""
    log = dut._log
    tb  = await _boot(dut)
    top = dut.u_master

    PS_VALUE = 0x00A5_A5A5
    FC_VALUE = 0x005A_5A5A          # distinct from PS_VALUE and non-zero

    # FC config port continuously requests the bus, presenting the FC's data.
    await _force_fc_cfg_active(top, pwrite=1, pwdata=FC_VALUE)
    await ClockCycles(dut.hclk, 2)
    assert _si(top.fc_cfg_apb_active) == 1, "harness sanity: FC config port not active"

    # External PS write into ACCESS phase, held.
    await _drive_ext_setup_then_access(dut, APB_BIT_SLIP_LO, pwrite=1, pwdata=PS_VALUE)

    ready = False
    commit_pwdata = commit_paddr = commit_pwrite = None
    paddr_swapped_to = pwdata_swapped_to = None
    for _ in range(STALL_BUDGET):
        cur_paddr  = _si(top.tl_apb_paddr)
        cur_pwdata = _si(top.tl_apb_pwdata)
        if cur_paddr != PADDR_BIT_SLIP_LO and paddr_swapped_to is None:
            paddr_swapped_to = cur_paddr
        if cur_pwdata != PS_VALUE and pwdata_swapped_to is None:
            pwdata_swapped_to = cur_pwdata
        if _si(dut.m_apb_pready) == 1:
            ready         = True
            commit_pwdata = _si(top.tl_apb_pwdata)   # value presented at write-commit
            commit_paddr  = _si(top.tl_apb_paddr)
            commit_pwrite = _si(top.tl_apb_pwrite)
            break
        await RisingEdge(dut.hclk)

    _ext_idle(dut)
    _release_fc_cfg(top)
    await ClockCycles(dut.hclk, 6)

    # ---- ASSERT 1: bounded completion ---------------------------------------
    assert ready, (
        f"STARVATION: external PS write of 0x{APB_BIT_SLIP_LO:04x} never completed "
        f"(apb_pready stuck 0) within {STALL_BUDGET} cycles while the FC config port "
        f"held the bus — the Zynq M_AXI_GP hang.")
    # ---- ASSERT 4: paddr/pwdata not swapped mid-ACCESS ----------------------
    assert paddr_swapped_to is None, (
        f"APB PROTOCOL VIOLATION: tl_apb_paddr swapped to 0x{paddr_swapped_to:03x} "
        f"mid-ACCESS of the external write to 0x{PADDR_BIT_SLIP_LO:03x}.")
    assert pwdata_swapped_to is None, (
        f"APB PROTOCOL VIOLATION: tl_apb_pwdata swapped to 0x{pwdata_swapped_to:08x} "
        f"(the FC's data) mid-ACCESS of the external write.")
    # ---- ASSERT 3: the PS's value is what is committed ----------------------
    assert commit_pwrite == 1 and commit_paddr == PADDR_BIT_SLIP_LO, (
        f"at write-commit the bus did not carry the PS's write "
        f"(pwrite={commit_pwrite}, paddr=0x{commit_paddr:03x})")
    assert commit_pwdata == PS_VALUE, (
        f"at write-commit tl_apb_pwdata=0x{commit_pwdata:08x}, expected the PS's "
        f"0x{PS_VALUE:08x} (0x{FC_VALUE:08x} ⇒ the FC's data won the mux)")
    # ---- ASSERT 3 (corroborate): read the register back ---------------------
    got = await tb.m_apb.read(APB_BIT_SLIP_LO)
    assert (got & BIT_SLIP_MASK) == (PS_VALUE & BIT_SLIP_MASK), (
        f"register readback 0x{got & BIT_SLIP_MASK:06x} != the PS's write "
        f"0x{PS_VALUE & BIT_SLIP_MASK:06x} (the FC's 0x{FC_VALUE & BIT_SLIP_MASK:06x} "
        f"landed instead)")
    log.info("PREEMPT-WRITE PASS: PS pwdata 0x%08x committed & read back, FC data "
             "never won the mux, under sustained FC-config contention", PS_VALUE)


@cocotb.test()
async def test_apb_fc_cfg_no_fc_starvation(dut):
    """The REAL FC RX FSM issues a SIDEBAND config write (0x104 <= 0xA5) while a
    concurrent external PS access holds the bus. BOTH must complete: the PS
    access acks, AND the FC's own transaction returns to RX_IDLE with its write
    committed. Proves the arbitration/backpressure fix never deadlocks or
    starves the FC (task step 2 / point d). Passes pre- and post-fix."""
    log = dut._log
    tb  = await _boot(dut)
    top = dut.u_master
    fca = top.u_fc_adapter

    # Pre-clear the FC's target register so the readback is unambiguous.
    await tb.m_apb.write(APB_BIT_SLIP_LO, 0x000000)
    pre = await tb.m_apb.read(APB_BIT_SLIP_LO)
    assert (pre & BIT_SLIP_MASK) == 0, f"pre-clear failed, 0x{pre:06x}"

    FC_WORD = _fc_sideband_word(PADDR_BIT_SLIP_LO, 0x000000A5)

    # Kick the real FC FSM: hold l2a valid so it issues the config write.
    top.tl_fc_l2a_valid.value = Force(1)
    top.tl_fc_l2a_data.value  = Force(FC_WORD)

    # Concurrent external read of PHY_ALIGN_ID — must complete despite FC traffic.
    got = await tb.m_apb.read(APB_PHY_ALIGN_ID, timeout=STALL_BUDGET)
    assert got == PHY_ALIGN_ID_VAL, (
        f"external read starved/corrupted under FC contention: 0x{got:08x}")

    # Watch the FC FSM run a full transaction: leave IDLE then return to IDLE.
    saw_active = saw_idle_after = False
    for _ in range(200):
        st = _si(fca.rx_state_r)
        if st in (RX_ADDR_PHASE, RX_DATA_PHASE):
            saw_active = True
        elif saw_active and st == RX_IDLE:
            saw_idle_after = True
            break
        await RisingEdge(dut.hclk)

    top.tl_fc_l2a_valid.value = Release()
    top.tl_fc_l2a_data.value  = Release()
    await ClockCycles(dut.hclk, 10)

    assert saw_active, "FC FSM never left RX_IDLE — the config write never started"
    assert saw_idle_after, (
        "FC-STARVATION: the FC config write never completed (rx_state never "
        "returned to RX_IDLE) — the fix deadlocked the FC config path.")

    # The FC's write must actually have committed to the register.
    got = await tb.m_apb.read(APB_BIT_SLIP_LO)
    assert (got & BIT_SLIP_MASK) == 0xA5, (
        f"FC config write did not land: 0x{got & BIT_SLIP_MASK:06x} != 0xA5")
    log.info("NO-FC-STARVATION PASS: FC config write committed (0x%02x) and the "
             "concurrent PS read completed — no deadlock either direction", 0xA5)
