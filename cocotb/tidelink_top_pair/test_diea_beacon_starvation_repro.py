"""FAIL-FIRST repro — die_a (MASTER) beacon-starvation at winscan FINALIZE.

Silicon failure (3-agent-confirmed, bridge1 zero-poke autonomous bring-up)
-------------------------------------------------------------------------
The MASTER die (die_a) fails to re-anchor ~92% of the time. At its winscan
WS_FINALIZE re-anchor window it F3-clears its OWN sticky SYNC anchor
(sync_obs_clr → deskew sync_seen_l / sync_idx_l / reanchored all drop, see
tidelink_lane_deskew_v2.sv ~L374/L711) and must RE-confirm from the PEER's
(die_b, SLAVE) PERIODIC gap-separated SYNC beacons (SYNC_CONFIRM=2 self-gating,
deskew ~L294). But die_b's slave→master TX idle slots are OCCUPIED by a
CONTINUOUS 0x12 keepalive/FC stream, so die_b's IDLE-GATED SYNC inserter
almost never fires toward die_a.

The PHY SYNC-insert gate is (WavD2DGpio_v2.v L576-577):

    insert = insert_en & (force_always | link_tx_tx_idle)

and at the Wlink port (axi_chiplet_controller.sv L5247):

    force_always = swi_sync_force_always_r(=0 in data mode) | winscan_force_sync

So die_b emits SYNC toward die_a only when EITHER die_b is force-SYNCing
(winscan_force_sync=1, i.e. die_b is itself mid-scan/FINALIZE) OR die_b's TX is
in genuine inter-packet idle (link_tx_tx_idle=1). The keepalive holds
link_tx_tx_idle=0. Result: die_a's RX gets no commit-able beacons →
sync_obs_seen_vec=0x00 → reanchored (ws_anchor_q) never re-latches → the
WS_FINALIZE anchor poll exhausts its FIX-3 retries → ws_anchor_timeout_q=1
(WINSCAN_OBS 0x21B8[2]) → an UNANCHORED fch bootstrap → dead data.

die_a's own TX is quieter (CR spam only), so die_b re-latches fine — the
measured asymmetry (die_b 83% / die_a 8%).

Why sim normally does NOT see it (the discriminator this test pins)
------------------------------------------------------------------
In an ordinary bilateral sim run BOTH dies' WS_FINALIZE windows OVERLAP, so
when die_a re-anchors die_b is STILL force-SYNCing (winscan_force_sync=1),
which drops the idle term in the gate above and delivers beacons to die_a
regardless of keepalive — die_a re-latches first try (test_33d, PROVEN:
m rea=1 anc_to=0 under conditional keepalive). The silicon failure needs
die_a's re-anchor to land AFTER die_b has DROPPED its force (die_b already in
data mode / staggered finalize) into the keepalive-saturated idle-gated era —
an eye/skew-driven stagger that sim does not naturally produce.

This test MODELS that staggered condition deterministically: during die_a's
(master's) WS_FINALIZE window it drives die_b (slave) into the exact
data-mode-with-keepalive gate state, holding the SYNC-insert gate terms:

    die_b winscan_force_sync = 0   (force dropped — no mutual-finalize overlap)
    die_b swi_sync_insert_en = 1   (D2 permanent data-mode beacons enabled)
    die_b link_tx_tx_idle    = K   (TX idle-slot occupancy — THE DISCRIMINATOR)

so the gate collapses to  insert = 1 & (0 | K) = K:  die_b emits periodic SYNC
toward die_a IFF link_tx_tx_idle=1. NOTHING else is touched — die_a's TX,
die_a's re-anchor logic, and both dies' datapaths run stock. die_a's re-anchor
therefore depends purely on K.

  * test_diea_beacon_starvation_keepalive : K=0 (keepalive occupies every idle
      slot) → die_a starves. The healthy-outcome assertion FAILS (die_a rea=0,
      sync_seen=0x00, ws_anchor_timeout_q=1) while die_b re-anchors (rea=1).
      This is the FAIL-FIRST repro on the CURRENT RTL.

  * test_diea_beacon_starvation_baseline  : K=1 (clean inter-packet idle, no
      keepalive) → the SAME harness, die_b's idle-gated beacons flow → die_a
      re-anchors. The healthy-outcome assertion PASSES.

The pair (baseline PASSES / keepalive FAILS) proves keepalive-occupancy of
die_b's TX idle slots is the SOLE discriminator, holding the staggered
force-drop constant across both.

Structured to PASS once a fix lands
-----------------------------------
Both tests assert the HEALTHY end-state (die_a reanchored=1, anchor-timeout=0,
M→S data byte-exact). A fix that guarantees beacon delivery to die_a's
re-anchor when the peer's force has dropped — e.g. a peer-quiesce that kills
die_b's keepalive across die_a's finalize (link_tx_tx_idle returns to idle),
a force-hold rendezvous that keeps die_b's winscan_force_sync high until die_a
confirms, or a re-anchor path not gated on the peer's idle slots — makes die_a
re-latch and both tests pass. (In sim the keepalive occupancy is injected, so
the peer-side of such a fix is validated by RE-RUNNING with the injection
relaxed; the baseline variant already exercises the beacons-flow outcome.)

Run
---
    cd cocotb/tidelink_top_pair
    source ../../set_env.sh
    TIDELINK_PHY_V2=1 BYPASS_AUTONEG=1 TB_TOP_NO_DUMP=1 \
      EXTRA_DEFINES="+define+TB_TOP_SHORT_CAL_HOLD=64" \
      COCOTB_RESOLVE_X=ZEROS SIM_BUILD=sim_build_starve SIM=vcs \
      make MODULE=test_diea_beacon_starvation_repro \
           TESTCASE=test_diea_beacon_starvation_keepalive   # the FAIL-FIRST repro
    # ... TESTCASE=test_diea_beacon_starvation_baseline      # the PASS discriminator
"""
import cocotb
from cocotb.triggers import ClockCycles
from cocotb.handle import Force, Release

from test_tidelink_pair_doorbell import PairTB
from tidelink.packet import encode_word0, PKT_WR_REQ

# Proven helpers (side-effect-free imports — cocotb collects tests only from
# $MODULE, same precedent as test_32/test_33).
from test_31_autonomous_training_exit import _ctrl, _cal, _autoneg, _fcsm, _si
from test_32_die_a_first_zombie_retry import _apb_arm, ST_BYPASS, ST_ERROR
from test_33_arm_stagger_episode_binding import _deposit_hooks, _setup, _obs_snapshot

CLK_PERIOD_NS = 20.0

# Winscan FSM state encodings (axi_chiplet_controller.sv): the WS_FINALIZE(7)
# re-anchor + FIX-3 WS_FIN_CLRLOW(9) clear-low retry hold are the window where
# force-SYNC has been earned, the F3 clear drops die's own sticky anchor, and
# the periodic re-confirm run needs the PEER's beacons.
WS_FINALIZE   = 7
WS_FIN_CLRLOW = 9
DIEA_FINALIZE = {WS_FINALIZE, WS_FIN_CLRLOW}      # {7, 9}


async def _model_keepalive_peer(dut, keepalive, stop, ev):
    """Model die_b (SLAVE) as a data-mode peer whose slave→master TX idle slots
    are (or are not) occupied by a CONTINUOUS 0x12 keepalive/FC stream, from
    die_a's (MASTER's) WS_FINALIZE re-anchor point ONWARD.

    On silicon die_b's keepalive is CONTINUOUS through data mode — so once die_a
    reaches its re-anchor, die_b is already in data mode (force dropped) with the
    keepalive permanently occupying its idle slots. We LATCH the model ON at
    die_a's first WS_FINALIZE/WS_FIN_CLRLOW entry and hold die_b's PHY
    SYNC-insert gate terms so  insert = insert_en & (force_always | link_idle):
        winscan_force_sync = 0   (no mutual-finalize force overlap: staggered)
        swi_sync_insert_en = 1   (D2 data-mode beacons enabled)
        lltx_io_link_idle  : keepalive="on"  -> Force(0): the 0x12 stream
                                 OCCUPIES every idle slot (gate = 1&(0|0) = 0,
                                 die_b emits NO SYNC toward die_a) -> STARVE.
                             keepalive="off" -> NOT forced (natural): die_b is
                                 mostly-idle in data mode, so the idle-gated
                                 inserter fires on the GENUINE idle slots
                                 (gate = 1&(0|natural_idle)) -> beacons flow,
                                 and die_b's real CR/FC still owns its non-idle
                                 slots. (Forcing link_idle=1 would let SYNC
                                 steal CR words and break credit — a FALSE fail.)
    Both variants hold the STAGGERED force-drop constant; keepalive-occupancy of
    die_b's idle slots is the SOLE discriminator. Before die_a's finalize die_b
    runs stock (it brings ITSELF up on die_a's force-beacons — the measured
    asymmetry). Only die_a's TX (never touched) drives die_b's RX, so die_b
    re-anchors either way.

    Records: the latch point + the held die_b gate terms (PROOF die_b's SYNC
    gate toward die_a was CLOSED under keepalive)."""
    sc  = _ctrl(dut, "s")            # die_b / slave controller
    mc  = _ctrl(dut, "m")            # die_a / master controller
    swl = sc.u_wlink
    kp_on = (keepalive == "on")
    latched = False
    while not stop[0]:
        await ClockCycles(dut.hclk, 10)
        if not latched and _si(mc.ws_state_r) in DIEA_FINALIZE:
            latched = True
            ev["latched"] = True
        if latched:
            sc.winscan_force_sync.value   = Force(0)
            sc.swi_sync_insert_en_r.value = Force(1)
            if kp_on:
                swl.lltx_io_link_idle.value = Force(0)
            ev["last_force_sync"] = _si(sc.winscan_force_sync)
            ev["last_insert_en"]  = _si(sc.swi_sync_insert_en_r)
            ev["last_link_idle"]  = _si(swl.lltx_io_link_idle)
    if latched:
        sc.winscan_force_sync.value   = Release()
        sc.swi_sync_insert_en_r.value = Release()
        if kp_on:
            swl.lltx_io_link_idle.value = Release()


async def _diea_finalize_monitor(dut, ev, stop):
    """die_a's (master's) re-anchor evidence. Distinguishes the PRE-CLEAR
    residual sync_seen at FINALIZE entry (carried from the earlier SYNC-detect
    phase, before the F3 clear wipes it) from the POST-CLEAR re-confirm state
    that the starvation actually gates: sync_seen sampled in WS_FIN_CLRLOW
    (state 9 — the retry hold, always after a fresh F3 clear) is the definitive
    'did any beacon re-confirm' metric. Also records the sync_seen at the
    instant the fail-loud anchor timeout (0x21B8[2]) fires."""
    mc = _ctrl(dut, "m")
    while not stop[0]:
        await ClockCycles(dut.hclk, 10)
        st  = _si(mc.ws_state_r)
        ss  = _si(mc.sync_obs_seen_vec_1)
        to  = _si(mc.ws_anchor_timeout_q)
        if st in DIEA_FINALIZE:
            ev["entered_finalize"] = True
        if st == WS_FIN_CLRLOW:               # post-clear retry hold
            ev["retry_samples"] += 1
            if ss > ev["max_sync_seen_post_clear"]:
                ev["max_sync_seen_post_clear"] = ss
        if to == 1 and not ev["timeout_latched"]:
            ev["timeout_latched"] = True
            ev["sync_seen_at_timeout"] = ss


async def _run_starvation(dut, keepalive):
    """Shared body. keepalive ∈ {"on","off"}. Runs the autonomous zero-poke
    role-armed bring-up (BYPASS_AUTONEG=1 + APB role arm — the FSM does the
    whole SYNC-detect → winscan → reanchor → FC-handoff chain with no data
    pokes), models die_b's keepalive occupancy across die_a's FINALIZE, then
    asserts the HEALTHY end-state on die_a. On the CURRENT RTL that assertion
    FAILS for keepalive="on" (die_a starves) and PASSES for keepalive="off"."""
    log = dut._log
    log.info(f"BEACON-STARVATION REPRO — die_b keepalive={keepalive} "
             f"(K={'0 busy' if keepalive=='on' else '1 idle'}) during die_a "
             f"WS_FINALIZE")
    tb = PairTB(dut)
    await _setup(dut, tb)

    stop = [False]
    peer_ev = {"latched": False, "last_force_sync": -1, "last_insert_en": -1,
               "last_link_idle": -1}
    diea_ev = {"entered_finalize": False, "retry_samples": 0,
               "max_sync_seen_post_clear": 0, "timeout_latched": False,
               "sync_seen_at_timeout": -1}
    cocotb.start_soon(_model_keepalive_peer(dut, keepalive, stop, peer_ev))
    cocotb.start_soon(_diea_finalize_monitor(dut, diea_ev, stop))

    # Autonomous zero-poke bring-up: role-arm both dies (master prio 1, slave
    # prio 2). No further pokes — the autoneg/winscan/FC FSMs run to data mode.
    await _apb_arm(tb, "m", priority=1)
    await _apb_arm(tb, "s", priority=2)
    log.info("both dies role-armed; die_b modelled as keepalive peer across "
             "die_a's WS_FINALIZE")

    # Wait for BOTH dies to settle (winscan_done) OR the sim budget. The starved
    # die_a fails open via ws_anchor_timeout_q; die_b re-anchors cleanly.
    poll, waited, last = 200, 0, 0
    MAX = 12_000_000
    while waited < MAX:
        await ClockCycles(dut.hclk, poll)
        waited += poll
        m, s = _obs_snapshot(dut, "m"), _obs_snapshot(dut, "s")
        # Done once both winscans have terminated (die_b anchored, die_a either
        # anchored or failed-open) — early-out to keep the run bounded.
        if m["done"] == 1 and s["done"] == 1:
            log.info(f"both winscans terminated at "
                     f"t={waited*CLK_PERIOD_NS/1000:.0f}us")
            break
        if waited - last >= 500_000:
            last = waited
            log.info(f"t={waited*CLK_PERIOD_NS/1000:.0f}us "
                     f"m(ws={_si(_ctrl(dut,'m').ws_state_r)} "
                     f"seen={_si(_ctrl(dut,'m').sync_obs_seen_vec_1):02x} "
                     f"rea={m['rea']} to={m['anc_to']} done={m['done']}) | "
                     f"s(ws={_si(_ctrl(dut,'s').ws_state_r)} "
                     f"rea={s['rea']} to={s['anc_to']} done={s['done']}) "
                     f"| peer_latched={peer_ev['latched']}")

    # Settling tail: with the peer keepalive LATCHED on (K=0) die_a cannot
    # recover; this dwell proves the starvation is PERMANENT (no late-anchor).
    await ClockCycles(dut.hclk, 50_000)
    m, s = _obs_snapshot(dut, "m"), _obs_snapshot(dut, "s")
    m_seen = _si(_ctrl(dut, "m").sync_obs_seen_vec_1)
    s_seen = _si(_ctrl(dut, "s").sync_obs_seen_vec_1)

    # ---- Evidence dump (the whole point: PROVE why die_a starved) -----------
    gate = peer_ev['last_insert_en'] & (peer_ev['last_force_sync']
                                        | peer_ev['last_link_idle'])
    log.info("================ BEACON-STARVATION EVIDENCE ================")
    log.info(f"die_b (SLAVE) held gate from die_a FINALIZE onward: latched="
             f"{peer_ev['latched']} force_sync={peer_ev['last_force_sync']} "
             f"insert_en={peer_ev['last_insert_en']} "
             f"link_idle={peer_ev['last_link_idle']}  "
             f"=> gate insert=insert_en&(force_sync|link_idle)="
             f"{peer_ev['last_insert_en']}&"
             f"({peer_ev['last_force_sync']}|{peer_ev['last_link_idle']})={gate}"
             f" (die_b emits periodic SYNC toward die_a iff this is 1)")
    log.info(f"die_a (MASTER) re-anchor: entered_finalize="
             f"{diea_ev['entered_finalize']} "
             f"post-clear-retry-samples={diea_ev['retry_samples']} "
             f"max_sync_seen_POST_CLEAR=0x"
             f"{diea_ev['max_sync_seen_post_clear']:02x} "
             f"timeout_latched={diea_ev['timeout_latched']} "
             f"sync_seen_at_timeout=0x"
             f"{diea_ev['sync_seen_at_timeout'] & 0xff:02x}")
    log.info(f"die_a end : sync_seen=0x{m_seen:02x} rea={m['rea']} "
             f"anc_to={m['anc_to']} done={m['done']} fcsm={m['fcsm']} "
             f"credit_max={m['credit_max']}")
    log.info(f"die_b end : sync_seen=0x{s_seen:02x} rea={s['rea']} "
             f"anc_to={s['anc_to']} done={s['done']} fcsm={s['fcsm']} "
             f"credit_max={s['credit_max']}")
    log.info("===========================================================")

    stop[0] = True
    await ClockCycles(dut.hclk, 100)

    # Harness sanity (fail loud on a broken run, not a starvation verdict):
    assert diea_ev["entered_finalize"], (
        "die_a never entered WS_FINALIZE — the winscan did not run; harness/"
        "config issue, not a starvation verdict")
    assert peer_ev["latched"], (
        "die_b keepalive-peer model never latched (die_a FINALIZE never seen) — "
        "harness issue")
    assert _si(_autoneg(dut, "m").state_r) != ST_ERROR, \
        "die_a autoneg parked in terminal ST_ERROR — unrelated crash"
    assert _si(_autoneg(dut, "s").state_r) != ST_ERROR, \
        "die_b autoneg parked in terminal ST_ERROR — unrelated crash"

    # The asymmetry: die_b re-anchors on die_a's force-beacons regardless of K.
    assert s["rea"] == 1, (
        f"die_b (SLAVE) did NOT re-anchor (rea={s['rea']} sync_seen=0x{s_seen:02x})"
        f" — the asymmetric precondition is not established (die_b should latch "
        f"on die_a's force-SYNC beacons)")

    # ---- THE HEALTHY-OUTCOME ASSERTION (fails on current RTL under keepalive) -
    # die_a must re-anchor (reanchored=1), the fail-loud anchor timeout must NOT
    # have fired, and it must have committed its SYNC anchor (sync_seen for the
    # active-lane set). On the CURRENT RTL with keepalive="on" (link_idle forced
    # 0) this FAILS: die_a starves of periodic beacons — sync_seen=0x00, rea=0,
    # timeout=1 — exactly the bridge1 zero-poke signature.  With keepalive="off"
    # (link_idle natural) the SAME harness PASSES, proving keepalive-occupancy of
    # die_b's idle slots is the discriminator.
    assert m["anc_to"] == 0, (
        f"die_a (MASTER) BEACON-STARVATION: ws_anchor_timeout_q=1 "
        f"(WINSCAN_OBS 0x21B8[2]) — die_a's WS_FINALIZE re-anchor exhausted its "
        f"FIX-3 retries with NO commit-able peer beacons. Starvation signature: "
        f"die_a sync_seen=0x{m_seen:02x}, sync_seen_at_timeout=0x"
        f"{diea_ev['sync_seen_at_timeout'] & 0xff:02x}, "
        f"max_sync_seen_POST_CLEAR=0x{diea_ev['max_sync_seen_post_clear']:02x} "
        f"over {diea_ev['retry_samples']} retry samples, rea={m['rea']}; die_b "
        f"was emitting keepalive (force_sync={peer_ev['last_force_sync']} "
        f"link_idle={peer_ev['last_link_idle']} → SYNC-insert gate CLOSED) NOT "
        f"periodic SYNC toward die_a, while die_b itself re-anchored (rea="
        f"{s['rea']}). This is the die_a 8%%/die_b 83%% asymmetry.")
    assert m["rea"] == 1, (
        f"die_a (MASTER) reanchored=0 at end — the deskew never re-latched "
        f"a SYNC anchor (sync_seen=0x{m_seen:02x}); beacon starvation")
    assert m_seen != 0x00, (
        f"die_a (MASTER) sync_obs_seen_vec=0x00 — ZERO lanes committed a SYNC "
        f"anchor: die_a's RX received no commit-able periodic beacons from the "
        f"keepalive-saturated peer (the deskew SYNC_CONFIRM run never fired)")

    # ---- Data must cross M→S once die_a is genuinely anchored ---------------
    payload = [0xC0DE1234, 0xFEED5678]
    word0 = encode_word0(length=len(payload), pkt_type=PKT_WR_REQ,
                         src_id=0, dest_id=0, tag=0)
    await tb.ahb_tx_write_packet("m", [word0, 0x0] + payload)
    await ClockCycles(dut.hclk, 4000)
    s_w2 = await tb.ahb_fifo_read_word("s", 0x08)
    s_w3 = await tb.ahb_fifo_read_word("s", 0x0C)
    log.info(f"M->S data: got 0x{s_w2:08x}/0x{s_w3:08x} "
             f"want 0x{payload[0]:08x}/0x{payload[1]:08x}")
    assert (s_w2, s_w3) == (payload[0], payload[1]), (
        f"M->S data NOT byte-exact (got 0x{s_w2:08x}/0x{s_w3:08x}) — the "
        f"unanchored die_a bootstrap delivers dead data (starvation tail)")

    log.info(f"VERDICT (keepalive={keepalive}): PASS — die_a re-anchored "
             f"(rea=1, anchor-timeout=0, sync_seen=0x{m_seen:02x}) and M->S "
             f"data crossed byte-exact under the modelled peer condition")


@cocotb.test()
async def test_diea_beacon_starvation_keepalive(dut):
    """FAIL-FIRST repro: die_b's TX idle slots are keepalive-occupied (K=0)
    across die_a's WS_FINALIZE → die_a starves of periodic beacons. The
    healthy-outcome assertion FAILS on the current RTL (die_a sync_seen=0x00,
    reanchored=0, ws_anchor_timeout_q=1) while die_b re-anchors."""
    await _run_starvation(dut, keepalive="on")


@cocotb.test()
async def test_diea_beacon_starvation_baseline(dut):
    """DISCRIMINATOR / baseline: the SAME harness, but die_b's TX is clean
    inter-packet idle (K=1, NO keepalive) across die_a's WS_FINALIZE → die_b's
    idle-gated beacons flow → die_a re-anchors. PASSES on the current RTL,
    proving keepalive-occupancy — not the harness — is the discriminator."""
    await _run_starvation(dut, keepalive="off")
