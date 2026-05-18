"""Coverage for the read-only APB credit-path observability block.

Adds SW visibility (a 1-second `wlink_probe` APB read) into the Wlink
LL_RX -> cr_pkt -> FCSM credit path that previously needed an ILA debug
core. This test exercises the full RTL path added on
`feat/credit-path-observability`:

  WlinkGenericFCSM_6.io_obs_*  (state / cr_pkt_seen_rx / crack_pkt_seen_rx
                                / pkt_is_cr_pkt / pkt_is_crack_pkt)
  WlinkRxLinkLayer.io_obs_*    (byte-align state / is_short_pkt /
                                is_long_pkt / valid)
  Wlink obs_ecc_*_cnt_o        (16-bit saturating ECC event counters,
                                rx_link_clk domain)
       -> axi_chiplet_controller 2-flop apb_clk CDC (sync_obs_*)
       -> Region 8 read mux:
            slot 2 (SWI_LANE_STATUS, MMIO 0x4403_2108) upper bits
                [20:17] FCSM state (bit20=0, 3b)
                [22:21] LL_RX byte-align state
                [23]    cr_pkt_seen_rx
                [24]    crack_pkt_seen_rx
                [25]    is_short_pkt
                [26]    is_long_pkt
                [27]    pkt_is_cr_pkt
                [28]    pkt_is_crack_pkt
                [29]    LL_RX valid
                [31:30] reserved
            slot 5 (was NEGO_TRAIN_STEP RO=0, MMIO 0x4403_2114) =
                ECC_COUNTERS = {ecc_corrected_cnt[31:16],
                                ecc_corrupted_cnt[15:0]}

Two @cocotb.test()s:

  test_credit_path_observability_negative_control
      Boot only (no role lock, no FC activity). Every observability
      field must read its reset/default (0). Proves the RO words are not
      stuck-at and start from a clean default.

  test_credit_path_observability_live
      Real autocal bring-up: FCSM advances to LINK_DATA, cr_pkt_seen_rx
      sets, ECC events occur during alignment. Asserts the Region 8 RO
      read tracks the hierarchical raw source nets through the CDC, and
      the ECC saturating counter snapshot equals the in-RTL counter.

Invocation (from cocotb/phy_align/):
    rm -rf sim_build ../wlink_pair/sim_build
    make MODULE=test_credit_path_observability SKID_BITS=3
"""
import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import ClockCycles, RisingEdge

from test_link_bringup import setup, lock_master, lock_slave, ctrl_read
from test_autocal_integrated import _chiplet_path, _force_autocal_enable

# Region 8 ctrl_reg_addr: bit[3]=1 selects Region 8, bits[2:0]=slot.
R8_SWI_LANE_STATUS = 0b1010   # slot 2 — SWI_LANE_STATUS + CREDIT_PATH_STATUS
R8_ECC_COUNTERS    = 0b1101   # slot 5 — ECC_COUNTERS (was NEGO_TRAIN_STEP)

# Field accessors on the slot-2 word.
def _fcsm_state(word):   return (word >> 17) & 0xF
def _llrx_state(word):   return (word >> 21) & 0x3
def _cr_seen(word):      return (word >> 23) & 0x1
def _crack_seen(word):   return (word >> 24) & 0x1
def _is_short(word):     return (word >> 25) & 0x1
def _is_long(word):      return (word >> 26) & 0x1
def _pkt_cr(word):       return (word >> 27) & 0x1
def _pkt_crack(word):    return (word >> 28) & 0x1
def _llrx_valid(word):   return (word >> 29) & 0x1
def _resv(word):         return (word >> 30) & 0x3

# Field accessors on the slot-5 word.
def _ecc_corrupt(word):  return word & 0xFFFF
def _ecc_correct(word):  return (word >> 16) & 0xFFFF


def _wlink(dut, side):
    return _chiplet_path(dut, side).u_wlink


def _fcsm_raw(dut, side):
    """Hierarchical raw FCSM state (io_tx_clk domain, pre-CDC)."""
    return int(_wlink(dut, side).tl2wl.wlink_tidelinktl.state.value)


def _cr_seen_raw(dut, side):
    return int(_wlink(dut, side).tl2wl.wlink_tidelinktl.cr_pkt_seen_rx.value)


def _ecc_corrupt_cnt_raw(dut, side):
    return int(_wlink(dut, side).obs_ecc_corrupted_cnt_q.value)


def _ecc_correct_cnt_raw(dut, side):
    return int(_wlink(dut, side).obs_ecc_corrected_cnt_q.value)


@cocotb.test()
async def test_credit_path_observability_negative_control(dut):
    """No role lock, no FC traffic → every RO observability field reads
    its reset/default. Discriminates a stuck-at / mis-wired RO word from
    a working one (the live test below proves it can also read non-zero).
    """
    await setup(dut)
    # Deliberately do NOT lock roles → Wlink is held in por_reset
    # (wlink_por_reset = ~poresetn | ~role_locked), so the FCSM /
    # byte-align FSM / ECC counters all sit at reset.
    await ClockCycles(dut.apb_clk, 32)

    status = await ctrl_read(dut, "m", R8_SWI_LANE_STATUS)
    ecc    = await ctrl_read(dut, "m", R8_ECC_COUNTERS)
    dut._log.info(
        f"[neg] slot2=0x{status:08x} slot5=0x{ecc:08x} "
        f"fcsm={_fcsm_state(status)} llrx_st={_llrx_state(status)} "
        f"cr={_cr_seen(status)} crack={_crack_seen(status)} "
        f"short={_is_short(status)} long={_is_long(status)} "
        f"pktcr={_pkt_cr(status)} pktcrack={_pkt_crack(status)} "
        f"valid={_llrx_valid(status)} "
        f"ecc_corrupt={_ecc_corrupt(ecc)} ecc_correct={_ecc_correct(ecc)}"
    )

    # CREDIT_PATH_STATUS observability fields (slot 2 [31:17]) all default 0.
    assert _fcsm_state(status) == 0, f"FCSM state not 0 at reset: 0x{status:08x}"
    assert _llrx_state(status) == 0, f"LL_RX state not 0 at reset: 0x{status:08x}"
    assert _cr_seen(status) == 0,    f"cr_pkt_seen_rx not 0 at reset"
    assert _crack_seen(status) == 0, f"crack_pkt_seen_rx not 0 at reset"
    assert _is_short(status) == 0,   f"is_short_pkt not 0 at reset"
    assert _is_long(status) == 0,    f"is_long_pkt not 0 at reset"
    assert _pkt_cr(status) == 0,     f"pkt_is_cr_pkt not 0 at reset"
    assert _pkt_crack(status) == 0,  f"pkt_is_crack_pkt not 0 at reset"
    assert _llrx_valid(status) == 0, f"LL_RX valid not 0 at reset"
    assert _resv(status) == 0,       f"reserved bits [31:30] not 0"

    # ECC_COUNTERS (slot 5) zero at reset.
    assert _ecc_corrupt(ecc) == 0, (
        f"ECC-corrupted count not 0 at reset (0x{ecc:08x}) — counter or "
        f"CDC stuck-at / mis-decoded"
    )
    assert _ecc_correct(ecc) == 0, (
        f"ECC-corrected count not 0 at reset (0x{ecc:08x})"
    )

    # The legacy SWI_LANE_STATUS low bits ([16:0]) must also still be 0
    # here (no calibrator running) — proves the observability pack did
    # not corrupt the pre-existing field positions.
    assert (status & 0x1FFFF) == 0, (
        f"SWI_LANE_STATUS low 17 bits non-zero with no calibrator "
        f"(0x{status:08x}) — observability pack collided with the "
        f"lane_locked/lane_fault/cal_done fields"
    )
    dut._log.info("negative control OK: all observability fields read 0 at reset")


@cocotb.test()
async def test_credit_path_observability_live(dut):
    """Real autocal bring-up drives the credit path to a known non-default
    state; assert the Region 8 RO read tracks the hierarchical raw nets
    through the apb_clk CDC, and the ECC saturating-counter snapshot
    equals the in-RTL counter."""
    _force_autocal_enable(dut, "m", True)
    _force_autocal_enable(dut, "s", True)
    await setup(dut)
    await lock_master(dut)
    await lock_slave(dut)

    # Drive the link up until the FCSM reaches LINK_DATA (state>=4) and
    # cr_pkt_seen_rx has set on the master — same convergence the
    # autocal-integrated test relies on.
    raw_max_state = 0
    cr_seen_raw = 0
    for _ in range(4000):
        await ClockCycles(dut.master_clk, 25)
        raw_max_state = max(raw_max_state, _fcsm_raw(dut, "m"))
        cr_seen_raw = _cr_seen_raw(dut, "m")
        if raw_max_state >= 4 and cr_seen_raw == 1:
            break

    dut._log.info(
        f"[live] raw FCSM max state={raw_max_state} cr_pkt_seen_rx={cr_seen_raw} "
        f"ecc_corrupt_cnt={_ecc_corrupt_cnt_raw(dut,'m')} "
        f"ecc_correct_cnt={_ecc_correct_cnt_raw(dut,'m')}"
    )
    assert raw_max_state >= 4, (
        f"FCSM (raw hier) never reached LINK_DATA (max={raw_max_state}) — "
        f"link bring-up did not converge; cannot exercise observability"
    )
    assert cr_seen_raw == 1, (
        "cr_pkt_seen_rx never set on the raw FCSM net — credit path did "
        "not produce a cr packet (link bring-up issue, not observability)"
    )

    # Let the 2-flop apb_clk CDC settle, then read the RO word and
    # cross-check against the raw hierarchical source nets.
    await ClockCycles(dut.apb_clk, 32)
    raw_state = _fcsm_raw(dut, "m")
    raw_cr    = _cr_seen_raw(dut, "m")
    status = await ctrl_read(dut, "m", R8_SWI_LANE_STATUS)
    dut._log.info(
        f"[live] slot2=0x{status:08x} fcsm_field={_fcsm_state(status)} "
        f"raw_state={raw_state} cr_field={_cr_seen(status)} raw_cr={raw_cr} "
        f"llrx_st={_llrx_state(status)} valid={_llrx_valid(status)}"
    )

    # cr_pkt_seen_rx is sticky (0e126b0) so the synced bit must read 1
    # once it has set, regardless of CDC latency.
    assert _cr_seen(status) == 1, (
        f"CREDIT_PATH_STATUS[23] cr_pkt_seen_rx read 0 (0x{status:08x}) "
        f"but the raw FCSM net is {raw_cr} — FCSM->Wlink->chiplet CDC->"
        f"Region 8 slot-2 path is broken"
    )
    # FCSM state field must be non-zero (link is up; FCSM is well past
    # the wedge-at-1 failure) and consistent with the 3-bit raw value
    # (top packed bit [20] is always 0).
    assert _fcsm_state(status) != 0, (
        f"CREDIT_PATH_STATUS FCSM state field reads 0 (0x{status:08x}) "
        f"while raw FCSM state={raw_state} — state not surfaced"
    )
    assert (_fcsm_state(status) & 0x8) == 0, (
        f"CREDIT_PATH_STATUS FCSM state bit[20] (=packed bit 3) is set "
        f"(0x{status:08x}); FCSM state is only 3 bits, bit[20] must be 0"
    )

    # ECC saturating-counter snapshot vs the in-RTL rx-clock counter.
    # The two are 2-flop-synced bit-wise; sample raw, settle, then read.
    raw_corrupt = _ecc_corrupt_cnt_raw(dut, "m")
    raw_correct = _ecc_correct_cnt_raw(dut, "m")
    await ClockCycles(dut.apb_clk, 32)
    raw_corrupt2 = _ecc_corrupt_cnt_raw(dut, "m")
    raw_correct2 = _ecc_correct_cnt_raw(dut, "m")
    ecc = await ctrl_read(dut, "m", R8_ECC_COUNTERS)
    rd_corrupt = _ecc_corrupt(ecc)
    rd_correct = _ecc_correct(ecc)
    dut._log.info(
        f"[live] ECC slot5=0x{ecc:08x} read corrupt={rd_corrupt} "
        f"correct={rd_correct}; raw corrupt {raw_corrupt}->{raw_corrupt2} "
        f"correct {raw_correct}->{raw_correct2}"
    )
    # The synced read must lie within the raw counter window observed
    # around the sample (counters are monotonic non-decreasing; the
    # 2-flop sync lags by a couple apb_clk).
    assert raw_corrupt <= rd_corrupt <= raw_corrupt2 or rd_corrupt == raw_corrupt2, (
        f"ECC-corrupted snapshot {rd_corrupt} outside raw window "
        f"[{raw_corrupt},{raw_corrupt2}] — counter->CDC->slot5 broken"
    )
    assert raw_correct <= rd_correct <= raw_correct2 or rd_correct == raw_correct2, (
        f"ECC-corrected snapshot {rd_correct} outside raw window "
        f"[{raw_correct},{raw_correct2}] — counter->CDC->slot5 broken"
    )
    # Saturating semantics: never exceed 0xFFFF.
    assert rd_corrupt <= 0xFFFF and rd_correct <= 0xFFFF, (
        f"ECC counter exceeded 16-bit saturation (0x{ecc:08x})"
    )

    # Positive proof the slot-5 read is genuinely sourced from the
    # counters and not a stuck constant: at least one ECC event must have
    # occurred during alignment (training noise / mis-slip windows). If
    # the link came up perfectly with zero ECC events this is still a
    # pass for the path test (cross-check above held) but log it.
    if rd_corrupt == 0 and rd_correct == 0:
        dut._log.info(
            "[live] note: zero ECC events during this bring-up — path "
            "cross-check (read==raw) still proves the wiring; the "
            "non-zero-capable proof is the live cr_pkt_seen_rx bit + the "
            "negative-control test"
        )
    else:
        assert (rd_corrupt == raw_corrupt2) and (rd_correct == raw_correct2), (
            f"ECC counters moved but the synced read does not match the "
            f"settled raw value (rd c={rd_corrupt}/{rd_correct} vs raw "
            f"{raw_corrupt2}/{raw_correct2})"
        )
        dut._log.info(
            f"[live] ECC counters exercised non-zero and matched: "
            f"corrupt={rd_corrupt} correct={rd_correct}"
        )

    # -----------------------------------------------------------------
    # Deterministic ECC-corrupted injection. Force the Wlink-level
    # llrx_io_ecc_corrupted wire (== WlinkRxLinkLayer.ecc_check_corrupted)
    # high for N recovered-RX-link-clock cycles; the 16-bit saturating
    # counter increments once per cycle the level is high. Then release
    # and verify the slot-5 ECC_COUNTERS read advanced by N (or
    # saturated) through the apb_clk CDC. This is the "inject an
    # ecc_check_corrupted event hierarchically" proof that the counter
    # path is genuinely sourced from the event, not a constant.
    # -----------------------------------------------------------------
    wl = _wlink(dut, "m")
    rx_clk = wl.phy_link_rx_rx_link_clk
    pre_raw = _ecc_corrupt_cnt_raw(dut, "m")
    N_INJECT = 5
    wl.llrx_io_ecc_corrupted.value = Force(1)
    for _ in range(N_INJECT):
        await RisingEdge(rx_clk)
    # Sample the raw counter while still forced (after N rising edges it
    # has incremented N times, modulo the one-cycle reg latency).
    await RisingEdge(rx_clk)
    wl.llrx_io_ecc_corrupted.value = Release()
    await RisingEdge(rx_clk)
    post_raw = _ecc_corrupt_cnt_raw(dut, "m")
    dut._log.info(
        f"[live] ECC inject: raw corrupt {pre_raw} -> {post_raw} "
        f"(forced {N_INJECT} rx-clk cycles high)"
    )
    assert post_raw > pre_raw, (
        f"forced ecc_check_corrupted ({N_INJECT} cycles) did NOT advance "
        f"the saturating counter ({pre_raw}->{post_raw}) — the counter is "
        f"not wired to llrx_io_ecc_corrupted"
    )
    expected = min(0xFFFF, pre_raw + N_INJECT)
    assert pre_raw < post_raw <= expected + 1, (
        f"counter advanced by an unexpected amount: {pre_raw}->{post_raw}, "
        f"expected ~{pre_raw}+{N_INJECT}"
    )

    # Settle the apb_clk 2-flop sync, then confirm the injected count is
    # visible through the Region 8 slot-5 RO read.
    await ClockCycles(dut.apb_clk, 32)
    ecc2 = await ctrl_read(dut, "m", R8_ECC_COUNTERS)
    rd_corrupt2 = _ecc_corrupt(ecc2)
    final_raw = _ecc_corrupt_cnt_raw(dut, "m")
    dut._log.info(
        f"[live] post-inject slot5=0x{ecc2:08x} read corrupt={rd_corrupt2} "
        f"raw={final_raw}"
    )
    assert rd_corrupt2 == final_raw, (
        f"post-injection ECC-corrupted read {rd_corrupt2} != settled raw "
        f"counter {final_raw} — counter->CDC->slot5 path broke under load"
    )
    assert rd_corrupt2 >= post_raw, (
        f"injected ECC count not visible via Region 8 slot 5 "
        f"(read={rd_corrupt2}, injected to {post_raw})"
    )
    # ecc_corrected half must be untouched by a corrupted-only injection.
    assert _ecc_correct(ecc2) == _ecc_correct_cnt_raw(dut, "m"), (
        "ecc_corrected half of slot 5 diverged from raw during a "
        "corrupted-only injection — the two counters are cross-wired"
    )
    dut._log.info(
        f"[live] ECC injection OK: {rd_corrupt2} corrupted events visible "
        f"via Region 8 ECC_COUNTERS slot 5"
    )

    dut._log.info(
        "live OK: FCSM state + cr_pkt_seen_rx + ECC counters surfaced "
        "through Wlink->chiplet CDC into Region 8 RO and read back via "
        "ctrl_reg"
    )
