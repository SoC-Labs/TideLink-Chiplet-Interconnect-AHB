"""TX-gated-by-training hypothesis test.

HW finding (2026-05-24 PHC Phase-1 session): when slot0=1 (swi_training_mode
held high), the FC TX serialisers emit the period-8 training pattern
({pattern,pattern}) instead of LL TX link data. So any cr_pkt / doorbell /
AHB tunnel queued by the FCSM never leaves the wire. When training drops,
lane_locked drops with it because the lane_checker observer expects the
training pattern.

This file exercises the gating point in cocotb sim, with both sides
training-held, and probes:
  1. FCSM parking at SEND_CREDITS1
  2. TX pad emitting training pattern (per-lane gpiotx_<N>._link_data_eff
     = {pattern,pattern})
  3. FC packet attempted during training does NOT cross
  4. lane_locked drop when training released
  5. Brief FC traffic post-drop, FCSM evolution

If sim reproduces all of these the bug is sim-visible (tight debug loop).
If sim doesn't gate, RTL behaves differently on FPGA -> sim/HW divergence.
"""
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from test_link_bringup import (
    setup, lock_master, lock_slave, ctrl_write, ctrl_read,
    apb_read, apb_write,
)

# Region 8 ctrl_reg_addr: bit[3]=1 selects Region 8, bits[2:0]=slot.
R8_SLOT0_TRAIN_RECAL = 0b1000   # slot 0 — SWI_TRAINING_MODE + SWI_RECAL
R8_SLOT2_LANE_STATUS = 0b1010   # slot 2 — SWI_LANE_STATUS + CREDIT_PATH_STATUS

# Region 4 ctrl_reg_addr: bit[3]=0 selects Region 4; slot 0 = ROLE_CFG.
R4_SLOT0_ROLE_CFG = 0b0000

# Wlink APB offsets (also used by test_link_bringup)
WL_LINK_ENABLE_RESET = 0x0208
WL_LANE_MASK         = 0x0214

# Expected training patterns per lane (WavD2DGpio.v:347-349).
TRAINING_PATTERNS = [0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59, 0x2D]


def _chiplet(dut, side):
    return dut.u_master if side == "m" else dut.u_slave


def _fcsm(dut, side):
    return _chiplet(dut, side).u_wlink.tl2wl.wlink_tidelinktl


def _gpio_phy(dut, side):
    return _chiplet(dut, side).u_wlink.phy.gpio


def _gpiotx(dut, side, lane):
    return getattr(_gpio_phy(dut, side), f"gpiotx_{lane}")


async def _set_training_both(dut, on):
    """Write Region 8 slot 0 on both sides: bit[0]=swi_training_mode."""
    val = 0x1 if on else 0x0
    await ctrl_write(dut, 'm', R8_SLOT0_TRAIN_RECAL, val)
    await ctrl_write(dut, 's', R8_SLOT0_TRAIN_RECAL, val)


async def _read_lane_status(dut, side):
    """Read Region 8 slot 2 (SWI_LANE_STATUS + CREDIT_PATH_STATUS)."""
    return await ctrl_read(dut, side, R8_SLOT2_LANE_STATUS)


def _decode_lane_status(w):
    return {
        "lane_locked": w & 0xFF,
        "lane_fault":  (w >> 8)  & 0xFF,
        "cal_done":    (w >> 16) & 0x1,
        "fcsm_state":  (w >> 17) & 0xF,
        "cr_seen":     (w >> 23) & 0x1,
        "crack_seen":  (w >> 24) & 0x1,
        "pkt_cr":      (w >> 27) & 0x1,
        "pkt_crack":   (w >> 28) & 0x1,
    }


# -----------------------------------------------------------------------
# TEST 1: FCSM stays parked at SEND_CREDITS1 while training is held.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_01_fcsm_parked_while_training_held(dut):
    """Hold training_mode=1 on both sides after role-lock. FCSM must NOT
    advance past SEND_CREDITS1 (state==1). HW: parked permanently."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Hold training on both sides immediately after lock.
    await _set_training_both(dut, on=True)

    # Watch FCSM state for 2000 cycles.
    m_state = _fcsm(dut, "m").state
    s_state = _fcsm(dut, "s").state
    max_m = 0; max_s = 0
    for _ in range(2000):
        await ClockCycles(dut.master_clk, 1)
        max_m = max(max_m, int(m_state.value))
        max_s = max(max_s, int(s_state.value))

    # Confirm training_mode_r really is 1 inside each chiplet controller.
    m_tr = int(_chiplet(dut, "m").swi_training_mode_r.value)
    s_tr = int(_chiplet(dut, "s").swi_training_mode_r.value)
    dut._log.info(f"  swi_training_mode_r m={m_tr} s={s_tr}")
    dut._log.info(f"  FCSM max_state under training: master={max_m} slave={max_s}")

    assert m_tr == 1, "master swi_training_mode_r failed to latch"
    assert s_tr == 1, "slave  swi_training_mode_r failed to latch"
    # Hypothesis: FCSM cannot leave SEND_CREDITS1 (state==1) because cr_pkts
    # are eaten by the training mux and never reach the peer.
    assert max_m <= 1, f"master FCSM advanced past SEND_CREDITS1: max={max_m}"
    assert max_s <= 1, f"slave  FCSM advanced past SEND_CREDITS1: max={max_s}"


# -----------------------------------------------------------------------
# TEST 2: TX bus emits training pattern under training_mode=1.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_02_tx_emits_training_pattern(dut):
    """While training is held, reconstruct each lane's serialised byte
    from io_pad + count over 16 master_clk cycles, then confirm it
    equals {pattern, pattern} (the doubled training byte).

    This proves the WavD2DGpioTx training mux selects the pattern, not
    io_link_data (which may still carry LL TX content from the FCSM)."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await _set_training_both(dut, on=True)

    # Let the soft-strap inputs propagate.
    await ClockCycles(dut.master_clk, 50)

    # Check the GPIO PHY mux select first.
    m_eff_tm = int(_gpio_phy(dut, "m").effective_training_mode.value)
    s_eff_tm = int(_gpio_phy(dut, "s").effective_training_mode.value)
    dut._log.info(f"  effective_training_mode m={m_eff_tm} s={s_eff_tm}")
    assert m_eff_tm == 1, "master GPIO PHY effective_training_mode != 1"
    assert s_eff_tm == 1, "slave  GPIO PHY effective_training_mode != 1"

    # For each lane, sample (count, io_pad) for ~64 master_clk cycles.
    # Each lane's io_pad emits _link_data_eff[count] every cycle. Build the
    # 16-bit word; with training=1 it must equal {P,P}.
    # io_link_data may be NON-zero — that's exactly the gating evidence:
    # LL TX content is being prepared but masked away.
    mismatches = []
    lltx_observations = []  # (lane, link_data sample)
    for lane in range(8):
        pat = TRAINING_PATTERNS[lane]
        expected = (pat << 8) | pat
        gpiotx = _gpiotx(dut, "m", lane)
        link_data_h = gpiotx.io_link_data
        pad_h       = gpiotx.io_pad
        count_h     = gpiotx.count

        word = [None] * 16
        # Sample for up to 48 cycles; need to see at least one full word.
        for _ in range(48):
            await ClockCycles(dut.master_clk, 1)
            c = int(count_h.value)
            word[c] = int(pad_h.value)
            if None not in word:
                break
        # Snapshot link_data for evidence the LL TX is non-trivial.
        ld = int(link_data_h.value)
        lltx_observations.append((lane, ld))
        if None in word:
            mismatches.append(f"lane{lane}: did not see full count sweep ({word})")
            continue
        reconstructed = 0
        for bit_idx, b in enumerate(word):
            reconstructed |= (b & 1) << bit_idx
        if reconstructed != expected:
            mismatches.append(
                f"lane{lane}: pad reconstructed 0x{reconstructed:04x} != "
                f"expected {{P,P}} 0x{expected:04x} (P=0x{pat:02x})")
        else:
            dut._log.info(
                f"  lane{lane}: pad-reconstructed 0x{reconstructed:04x} "
                f"== {{P,P}} 0x{expected:04x}  io_link_data=0x{ld:04x}")

    if mismatches:
        for m in mismatches:
            dut._log.error("  " + m)
    assert not mismatches, f"TX mux not emitting training pattern: {mismatches}"
    # Diagnostic: surface whether LL TX is carrying non-zero content
    # while training is held (proof that the mux is actively masking).
    nonzero = sum(1 for _, ld in lltx_observations if ld != 0)
    dut._log.info(
        f"  PASS: 8/8 lanes emit {{pattern,pattern}} on io_pad; "
        f"{nonzero}/8 lanes had io_link_data != 0 at sample time "
        "(LL TX carried real content masked by training mux).")


# -----------------------------------------------------------------------
# TEST 3: FC packet attempted during training does not cross to peer.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_03_fc_packet_does_not_cross_under_training(dut):
    """While training is held, monitor:
      - master FCSM's auto_tx_out_advance (FCSM trying to push a packet)
      - master LL_TX phy_link_tx_tx_link_data (LL-layer raw bytes the FCSM
        produced; may carry cr_pkt content)
      - slave pkt_is_cr_pkt / cr_pkt_seen_rx (peer's RX side)
    HW: even though FCSM IS sending cr_pkts at the LL layer, they get
    eaten by the training mux. The peer never decodes them."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await _set_training_both(dut, on=True)

    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")

    tx_advance_pulses = 0
    nonzero_lltx_words = 0
    peer_pkt_cr = False
    peer_cr_seen = False

    m_ll_tx = _chiplet(dut, "m").u_wlink.phy_link_tx_tx_link_data
    for _ in range(2000):
        await ClockCycles(dut.master_clk, 1)
        if int(m.auto_tx_out_advance.value):
            tx_advance_pulses += 1
        if int(m_ll_tx.value):
            nonzero_lltx_words += 1
        if int(s.pkt_is_cr_pkt.value):    peer_pkt_cr = True
        if int(s.cr_pkt_seen_rx.value):   peer_cr_seen = True

    dut._log.info(
        f"  master tx_out_advance pulses    = {tx_advance_pulses}\n"
        f"  master LL_TX non-zero cycles    = {nonzero_lltx_words}\n"
        f"  slave  pkt_is_cr_pkt observed   = {peer_pkt_cr}\n"
        f"  slave  cr_pkt_seen_rx latched   = {peer_cr_seen}")
    # FCSM is alive at the LL layer (cr_pkts being generated) ...
    # ... but absolutely nothing should arrive at the peer RX while training is held.
    assert not peer_pkt_cr,  "TRAINING-MUX LEAK: slave decoded a cr_pkt despite training held"
    assert not peer_cr_seen, "TRAINING-MUX LEAK: slave latched cr_pkt_seen_rx despite training held"


# -----------------------------------------------------------------------
# TEST 4: Lane lock drops when training is released.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_04_lane_lock_drops_when_training_released(dut):
    """1. Bring up link with training held -> lane_checker locks to pattern.
    2. Read SWI_LANE_STATUS lane_locked == 0xff.
    3. Drop training on both sides.
    4. Re-read lane_locked after a few cycles -> drops to 0x00 (matches HW).
    """
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await _set_training_both(dut, on=True)

    # Wait for the lane checkers to lock to the per-lane training byte.
    # They live in the peer's recovered clock domain; give plenty of margin.
    await ClockCycles(dut.master_clk, 500)
    m_lock_h = int(dut.master_lane_locked.value)
    s_lock_h = int(dut.slave_lane_locked.value)
    dut._log.info(f"  TB checker lane_locked m=0x{m_lock_h:02x} s=0x{s_lock_h:02x} (training on)")

    # Sample via APB so we exercise the actual SWI_LANE_STATUS path too.
    m_ls_on = _decode_lane_status(await _read_lane_status(dut, "m"))
    s_ls_on = _decode_lane_status(await _read_lane_status(dut, "s"))
    dut._log.info(f"  SWI_LANE_STATUS m={m_ls_on} s={s_ls_on}")
    assert m_ls_on["lane_locked"] == 0xff, \
        f"master lane_locked not 0xff under training (got 0x{m_ls_on['lane_locked']:02x})"
    assert s_ls_on["lane_locked"] == 0xff, \
        f"slave  lane_locked not 0xff under training (got 0x{s_ls_on['lane_locked']:02x})"

    # Now drop training on both sides simultaneously.
    await _set_training_both(dut, on=False)
    await ClockCycles(dut.master_clk, 200)

    m_ls_off = _decode_lane_status(await _read_lane_status(dut, "m"))
    s_ls_off = _decode_lane_status(await _read_lane_status(dut, "s"))
    dut._log.info(f"  SWI_LANE_STATUS post-drop m={m_ls_off} s={s_ls_off}")

    # The lane_checker is built to lock to the training pattern. Once
    # training stops, the pattern is replaced with arbitrary LL TX bytes;
    # the lock signal SHOULD fall to 0 within a few correlation windows.
    # HW: drops to 0x00.  Pass condition: at least one lane drops.
    dropped = (m_ls_off["lane_locked"] != 0xff) or (s_ls_off["lane_locked"] != 0xff)
    assert dropped, (
        f"lane_locked stayed 0xff after dropping training "
        f"(m=0x{m_ls_off['lane_locked']:02x} s=0x{s_ls_off['lane_locked']:02x}) "
        "-> sim/HW divergence on the lane-checker post-training behaviour")


# -----------------------------------------------------------------------
# TEST 5: Observe the brief FC traffic window during training drop.
# -----------------------------------------------------------------------
@cocotb.test()
async def test_05_brief_fc_traffic_during_drop(dut):
    """Bring up the link with training, then drop on both sides and
    capture state evolution over 1500 cycles.

    Records FCSM state, pkt_is_cr_pkt, cr_pkt_seen_rx, lane_locked at
    several timestamps after the drop. Diagnostic — no hard pass criterion;
    we want to see *whether* the FCSM ever reaches LINK_DATA in sim once
    the mux opens, or whether some other gating point keeps the link
    held. This is the analogue of the HW behaviour where the link briefly
    moves traffic before snapping back."""
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)
    await _set_training_both(dut, on=True)
    await ClockCycles(dut.master_clk, 500)

    # Drop training on both sides synchronously.
    await _set_training_both(dut, on=False)

    m = _fcsm(dut, "m")
    s = _fcsm(dut, "s")

    samples = []
    pkt_cr_m = 0; pkt_cr_s = 0
    cr_seen_m = 0; cr_seen_s = 0
    max_state_m = 0; max_state_s = 0
    for cyc in range(1500):
        await ClockCycles(dut.master_clk, 1)
        ms = int(m.state.value); ss = int(s.state.value)
        max_state_m = max(max_state_m, ms)
        max_state_s = max(max_state_s, ss)
        if int(m.pkt_is_cr_pkt.value):  pkt_cr_m += 1
        if int(s.pkt_is_cr_pkt.value):  pkt_cr_s += 1
        if int(m.cr_pkt_seen_rx.value): cr_seen_m = 1
        if int(s.cr_pkt_seen_rx.value): cr_seen_s = 1
        if cyc in (100, 500, 1000, 1499):
            samples.append((
                cyc,
                ms, ss,
                int(dut.master_lane_locked.value),
                int(dut.slave_lane_locked.value),
                int(m.pkt_is_cr_pkt.value),
                int(s.pkt_is_cr_pkt.value),
            ))
    for cyc, ms, ss, mll, sll, mpc, spc in samples:
        dut._log.info(
            f"  t=+{cyc:4d}  m.state={ms} s.state={ss}  "
            f"m.lane_lock=0x{mll:02x} s.lane_lock=0x{sll:02x}  "
            f"m.pkt_cr={mpc} s.pkt_cr={spc}")
    dut._log.info(
        f"  Window totals: max_state m={max_state_m} s={max_state_s}; "
        f"pkt_cr_m={pkt_cr_m} pkt_cr_s={pkt_cr_s} "
        f"cr_seen_m={cr_seen_m} cr_seen_s={cr_seen_s}")
    # Diagnostic only — record but don't assert.
    dut._log.info("  test_05 is diagnostic; check log for state evolution.")
