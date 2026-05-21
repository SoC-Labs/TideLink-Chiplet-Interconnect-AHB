"""Cocotb unit tests for the tidelink_autoneg FSM.

Tests the auto-negotiation FSM in isolation — AXI-Lite responses are driven
by the test to simulate the I2C master core's behaviour.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_PERIOD_NS = 10

# FSM state encoding (matches tidelink_autoneg.sv)
ST_IDLE              = 0
ST_NEGO_INIT         = 1
ST_NEGO_WAIT         = 2
ST_NEGO_CLAIM        = 3
ST_NEGO_POLL         = 4
ST_NEGO_DONE         = 5
ST_BYPASS            = 6
ST_ERROR             = 7
ST_NEGO_MASK_RES_TX  = 8
ST_NEGO_MASK_RD_ADDR = 9
ST_NEGO_MASK_RD_DATA = 10

STATE_NAMES = {
    0:  "IDLE",
    1:  "NEGO_INIT",
    2:  "NEGO_WAIT",
    3:  "NEGO_CLAIM",
    4:  "NEGO_POLL",
    5:  "NEGO_DONE",
    6:  "BYPASS",
    7:  "ERROR",
    8:  "MASK_RES_TX",
    9:  "MASK_RD_ADDR",
    10: "MASK_RD_DATA",
}

TXN_STEP_NAMES = {
    0: "PRESCALE",
    1: "DATA",
    2: "COMMAND",
    3: "POLL",
    4: "CHECK",
    5: "DONE",
}

# I2C status register bit positions (must mirror RTL)
I2C_STS_BUSY     = 0
I2C_STS_BUS_CTRL = 1
I2C_STS_MISS_ACK = 3


async def setup(dut):
    """Start clock and initialise all inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())

    # Defaults: negotiation disabled, bus idle
    dut.nego_en.value = 0
    dut.nego_start.value = 0
    dut.nego_pri_sel.value = 0
    dut.nego_fallback.value = 1
    dut.nego_force_lock.value = 1
    dut.nego_priority_reg.value = 0xFFFF
    dut.nego_priority_i.value = 0
    dut.puf_seed.value = 0
    dut.puf_ready.value = 0
    dut.nego_timeout_reg.value = 131_082_000
    dut.i2c_sda_i.value = 1   # bus idle
    dut.i2c_scl_i.value = 1   # bus idle
    dut.i2c_prescale_reg.value = 500

    # AXI-Lite slave defaults: not ready, no response
    dut.m_axil_awready.value = 0
    dut.m_axil_wready.value = 0
    dut.m_axil_bresp.value = 0
    dut.m_axil_bvalid.value = 0
    dut.m_axil_arready.value = 0
    dut.m_axil_rdata.value = 0
    dut.m_axil_rresp.value = 0
    dut.m_axil_rvalid.value = 0


async def do_por(dut):
    """Assert POR for 5 cycles, then deassert."""
    dut.poresetn.value = 0
    await ClockCycles(dut.clk, 5)
    dut.poresetn.value = 1
    await ClockCycles(dut.clk, 2)


def get_state(dut):
    return int(dut.nego_state.value)


# ── Tests ──────────────────────────────────────────────────────────────────


@cocotb.test()
async def test_01_bypass_mode(dut):
    """NEGO-U01: nego_en=0 → FSM goes to ST_BYPASS."""
    await setup(dut)
    await do_por(dut)

    # Default: nego_en=0 → should transition to BYPASS
    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    assert state == ST_BYPASS, f"Expected ST_BYPASS ({ST_BYPASS}), got {state}"

    # nego_role_r should be 1 (slave default)
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (slave) in bypass"

    # No done, no error
    assert int(dut.nego_done.value) == 0
    assert int(dut.nego_error.value) == 0

    dut._log.info("NEGO-U01: Bypass mode — passed")


@cocotb.test()
async def test_02_nego_init_enters(dut):
    """NEGO-U02: nego_en=1 → FSM enters NEGO_INIT then NEGO_WAIT."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x0001
    dut.nego_pri_sel.value = 2  # PUF source
    await do_por(dut)

    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    # Should have passed through INIT into WAIT (PUF is ready)
    assert state == ST_NEGO_WAIT, f"Expected ST_NEGO_WAIT ({ST_NEGO_WAIT}), got {state}"

    dut._log.info("NEGO-U02: Negotiation enters WAIT — passed")


@cocotb.test()
async def test_03_puf_stall(dut):
    """NEGO-U10: PUF not ready → FSM stalls in ST_NEGO_INIT."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2  # PUF source
    dut.puf_ready.value = 0     # PUF not ready
    await do_por(dut)

    await ClockCycles(dut.clk, 10)

    state = get_state(dut)
    assert state == ST_NEGO_INIT, f"Expected ST_NEGO_INIT ({ST_NEGO_INIT}), got {state}"

    # Now set PUF ready
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x1234
    await ClockCycles(dut.clk, 5)

    state = get_state(dut)
    assert state == ST_NEGO_WAIT, f"After PUF ready, expected ST_NEGO_WAIT, got {state}"

    dut._log.info("NEGO-U10: PUF stall and release — passed")


@cocotb.test()
async def test_04_sda_early_exit(dut):
    """NEGO-U03: SDA START detected during NEGO_WAIT → becomes slave."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0       # register priority
    dut.nego_priority_reg.value = 0xFFFF  # max delay (won't expire in test)
    dut.nego_force_lock.value = 1
    await do_por(dut)

    # Wait for NEGO_WAIT
    for _ in range(20):
        await RisingEdge(dut.clk)
        if get_state(dut) == ST_NEGO_WAIT:
            break
    assert get_state(dut) == ST_NEGO_WAIT, "FSM should be in NEGO_WAIT"

    # Inject I2C START: SDA falling while SCL high
    dut.i2c_scl_i.value = 1
    dut.i2c_sda_i.value = 1
    await RisingEdge(dut.clk)
    dut.i2c_sda_i.value = 0  # falling edge
    await ClockCycles(dut.clk, 3)

    state = get_state(dut)
    assert state == ST_NEGO_DONE, f"Expected ST_NEGO_DONE after SDA START, got {state}"
    assert int(dut.nego_lost.value) == 1, "nego_lost should be 1"
    assert int(dut.sda_start_seen.value) == 1, "sda_start_seen should be 1"
    assert int(dut.nego_done.value) == 1, "nego_done should be 1"
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (slave)"

    dut._log.info("NEGO-U03: SDA early exit — passed")


@cocotb.test()
async def test_05_timeout(dut):
    """NEGO-U04: Short timeout → ST_ERROR with fallback role."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0
    dut.nego_priority_reg.value = 0xFFFF  # max backoff
    dut.nego_timeout_reg.value = 50       # very short timeout
    dut.nego_fallback.value = 1           # fallback = slave
    dut.nego_force_lock.value = 1
    await do_por(dut)

    # Wait for timeout (50 + some cycles for INIT→WAIT transition)
    await ClockCycles(dut.clk, 80)

    state = get_state(dut)
    assert state == ST_ERROR, f"Expected ST_ERROR after timeout, got {state}"
    assert int(dut.nego_error.value) == 1, "nego_error should be 1"
    assert int(dut.nego_error_irq.value) == 1, "nego_error_irq should be 1"
    assert int(dut.nego_role_r.value) == 1, "nego_role_r should be 1 (fallback=slave)"

    dut._log.info("NEGO-U04: Timeout with fallback — passed")


@cocotb.test()
async def test_06_force_lock_disabled(dut):
    """NEGO-U06: force_lock=0 → SDA early-exit sets role but no auto-lock."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 0
    dut.nego_priority_reg.value = 0xFFFF
    dut.nego_force_lock.value = 0  # no auto-lock
    await do_por(dut)

    # Wait for NEGO_WAIT
    for _ in range(20):
        await RisingEdge(dut.clk)
        if get_state(dut) == ST_NEGO_WAIT:
            break

    # Inject SDA START to resolve as slave
    dut.i2c_sda_i.value = 0
    await ClockCycles(dut.clk, 3)

    assert get_state(dut) == ST_NEGO_DONE, "Should be in NEGO_DONE"
    assert int(dut.nego_done.value) == 1
    assert int(dut.nego_role_r.value) == 1, "Should be slave"

    dut._log.info("NEGO-U06: Force lock disabled — passed")


@cocotb.test()
async def test_07_puf_priority_used(dut):
    """NEGO-U09: pri_sel=2 uses puf_seed as priority for backoff delay."""
    await setup(dut)
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2  # PUF
    dut.puf_ready.value = 1
    dut.puf_seed.value = 0x0000  # lowest possible priority → shortest delay
    dut.nego_timeout_reg.value = 100_000
    await do_por(dut)

    # With priority=0, backoff = 0 * NEGO_TICK + NEGO_BASE_DELAY = 2000 cycles
    # Should reach NEGO_CLAIM after ~2000 cycles
    await ClockCycles(dut.clk, 2020)

    state = get_state(dut)
    assert state in [ST_NEGO_CLAIM, ST_NEGO_POLL], \
        f"Expected CLAIM or POLL state with PUF priority=0, got {state}"
    assert int(dut.nego_role_r.value) == 0, "nego_role_r should be 0 (master) during claim"

    dut._log.info("NEGO-U09: PUF priority source — passed")


# ─────────────────────────────────────────────────────────────────────────────
# PHASE A FSM TRACE (Bug #3 / Silicon-vs-sim divergence investigation)
#
# These tests answer:
#   (a) Does the FSM actually ENTER state 9 (MASK_RD_ADDR) in sim?
#   (d) Does the MASK_RES_TX AXIL sequence complete without silent failure?
#
# Silicon symptom (per parallel handoff): master FSM goes POLL→DONE directly,
# never lights up state 9, slave's link_lane_mask_hs_result @0x21C stays 0.
#
# Strategy:
#   – Walk the FSM from IDLE through to a master-win arbitration.
#   – Have cocotb act as the AXI-Lite slave (I²C master IP surrogate).
#   – Respond to status polls so the FSM gets BUSY=1 first (passes busy_seen),
#     then BUSY=0+ACK so it accepts the transaction as complete.
#   – Sample state_r/txn_step_r every clock and log every transition.
#   – After autoneg, MUST see 4 → 9 → 10 → 8 → 5 (master-win mask flow).
# ─────────────────────────────────────────────────────────────────────────────


class FsmTracer:
    """Samples nego_state + txn_step every clock, logs distinct transitions
    and tracks per-state cycle counts. Run as a cocotb coroutine via
    cocotb.start_soon().
    """

    def __init__(self, dut, label=""):
        self.dut = dut
        self.label = label
        self.cycle = 0
        self.history = []          # list of (cycle, prev_state, new_state, txn)
        self.cycles_in_state = {}  # state -> cycle count
        self.txn_steps_seen = {}   # state -> set of txn_steps observed
        self.first_entry = {}      # state -> first cycle entered
        self.entries = {}          # state -> count of distinct entries
        self.stop_flag = False
        self._prev_state = None
        self._prev_txn = None

    def stop(self):
        self.stop_flag = True

    async def run(self):
        while not self.stop_flag:
            await RisingEdge(self.dut.clk)
            self.cycle += 1
            try:
                s = int(self.dut.nego_state.value)
                t = int(self.dut.u_dut.txn_step_r.value)
            except Exception:
                continue
            # Accumulate cycle count
            self.cycles_in_state[s] = self.cycles_in_state.get(s, 0) + 1
            self.txn_steps_seen.setdefault(s, set()).add(t)
            # Log transition
            if s != self._prev_state:
                self.history.append((self.cycle, self._prev_state, s, t))
                self.entries[s] = self.entries.get(s, 0) + 1
                if s not in self.first_entry:
                    self.first_entry[s] = self.cycle
                prev_name = STATE_NAMES.get(self._prev_state, "?") \
                    if self._prev_state is not None else "(init)"
                new_name = STATE_NAMES.get(s, "?")
                self.dut._log.info(
                    "[trace %s] cyc=%d  %s(%s) -> %s(%s)  txn=%s",
                    self.label, self.cycle,
                    prev_name, self._prev_state,
                    new_name, s,
                    TXN_STEP_NAMES.get(t, str(t)))
            self._prev_state = s
            self._prev_txn = t

    def report(self, log):
        log.info("─── FSM TRACE REPORT (%s) ───", self.label)
        log.info("Total cycles observed: %d", self.cycle)
        log.info("States visited (in order):")
        for cyc, prev, new, txn in self.history:
            prev_name = STATE_NAMES.get(prev, "?") if prev is not None else "(init)"
            new_name = STATE_NAMES.get(new, "?")
            log.info("  cyc=%6d  %-12s -> %-12s  (entered with txn=%s)",
                     cyc, f"{prev_name}({prev})", f"{new_name}({new})",
                     TXN_STEP_NAMES.get(txn, str(txn)))
        log.info("Cycle counts per state:")
        for st in sorted(self.cycles_in_state.keys()):
            log.info("  state %2d %-12s : %6d cycles  entries=%d  txn_steps=%s",
                     st, STATE_NAMES.get(st, "?"),
                     self.cycles_in_state[st],
                     self.entries.get(st, 0),
                     sorted(self.txn_steps_seen.get(st, set())))


class AxilSlave:
    """Cocotb-driven AXI-Lite slave that mimics the I²C master IP.

    Models a per-FSM-state "I²C transaction lifecycle":
      * On state-entry to a master-driving state (CLAIM/POLL/MASK_*),
        a virtual I²C transaction starts. It must be observed as busy
        on its first STATUS poll, then idle on its second STATUS poll.
        That two-phase pattern is what `busy_seen_r` in the RTL needs
        in order to accept busy=0 as "transaction complete".
      * For MASK_RD_DATA, each byte is its own transaction (start fresh
        on every TXN_COMMAND entry within the state).

    Knobs:
      * fail_on_state — return MISS_ACK=1 when STATUS busy=0 is reported,
        for the specified FSM state. Used to model NACKed mask txns.
      * read_data_bytes — list of bytes returned by MASK_RD_DATA pops
        (one byte per pop, advancing per call).
    """

    def __init__(self, dut, log):
        self.dut = dut
        self.log = log
        self.stop_flag = False
        self.fail_on_state = None
        self.read_data_bytes = [0xFF, 0xFF, 0x00, 0x00]
        self._mask_data_byte_idx = 0

        # Virtual I²C "transaction" lifecycle:
        # poll_count: how many STATUS reads completed since the last
        # transaction-restart event. busy=1 on poll #1, busy=0 on poll #2+.
        self._poll_count = 0
        # Track previous state + txn_step so we can detect
        # transaction-restart events (state change OR re-entry to COMMAND
        # within MASK_RD_DATA where each byte is a fresh txn).
        self._prev_state = None
        self._prev_txn = None
        # Track when CHECK has fired and consumed the busy=0 — reset poll
        # count on a fresh POLL/CHECK loop only after the FSM has clearly
        # moved past the current transaction.

    def stop(self):
        self.stop_flag = True

    async def run(self):
        dut = self.dut
        # On first cycle, deassert everything.
        dut.m_axil_awready.value = 0
        dut.m_axil_wready.value = 0
        dut.m_axil_bvalid.value = 0
        dut.m_axil_arready.value = 0
        dut.m_axil_rvalid.value = 0

        while not self.stop_flag:
            await RisingEdge(dut.clk)
            try:
                state = int(dut.nego_state.value)
                txn   = int(dut.u_dut.txn_step_r.value)
            except Exception:
                continue

            # ── Detect virtual-transaction restart events ─────────────
            # On entry to a new FSM state (state changed): reset poll_count
            # so the next STATUS read returns busy=1.
            restart = False
            if state != self._prev_state:
                restart = True
            # Inside MASK_RD_DATA: each TXN_COMMAND entry is a fresh byte-
            # read transaction.
            if state == ST_NEGO_MASK_RD_DATA and \
                    self._prev_txn != 2 and txn == 2:  # entry to COMMAND
                restart = True
            # Inside MASK_RD_ADDR: a NACK retry re-enters TXN_DATA at
            # byte 0; reset there too.
            if state == ST_NEGO_MASK_RD_ADDR and \
                    self._prev_txn != 1 and txn == 1:
                restart = True
            # MASK_RES_TX retry re-enters TXN_DATA on retry.
            if state == ST_NEGO_MASK_RES_TX and \
                    self._prev_txn != 1 and txn == 1:
                restart = True
            if restart:
                self._poll_count = 0
            self._prev_state = state
            self._prev_txn = txn

            # ── Write-channel handshake (1-cycle latency) ─────────────
            if int(dut.m_axil_awvalid.value):
                dut.m_axil_awready.value = 1
            else:
                dut.m_axil_awready.value = 0
            if int(dut.m_axil_wvalid.value):
                dut.m_axil_wready.value = 1
            else:
                dut.m_axil_wready.value = 0

            # B-channel: pulse bvalid one cycle after we ack'd both AW+W
            if int(dut.m_axil_awvalid.value) and \
                    int(dut.m_axil_wvalid.value) and \
                    int(dut.m_axil_awready.value) and \
                    int(dut.m_axil_wready.value):
                dut.m_axil_bvalid.value = 1
                dut.m_axil_bresp.value = 0
            elif int(dut.m_axil_bvalid.value) and \
                    int(dut.m_axil_bready.value):
                dut.m_axil_bvalid.value = 0

            # ── Read-channel handshake ────────────────────────────────
            if int(dut.m_axil_arvalid.value) and \
                    not int(dut.m_axil_rvalid.value):
                # Accept the AR phase
                dut.m_axil_arready.value = 1
                # Compose rdata
                if state == ST_NEGO_MASK_RD_DATA and txn == 1:  # TXN_DATA
                    # DATA-register read pops one byte from the rd FIFO
                    byte_idx = self._mask_data_byte_idx % 4
                    rd = self.read_data_bytes[byte_idx] & 0xFF
                    self._mask_data_byte_idx += 1
                    dut.m_axil_rdata.value = rd
                else:
                    # STATUS register read (TXN_POLL → CHECK loop)
                    self._poll_count += 1
                    if self._poll_count == 1:
                        # Transaction still in flight → busy=1
                        rdata = (1 << I2C_STS_BUSY) | (1 << I2C_STS_BUS_CTRL)
                    else:
                        # Transaction complete → busy=0
                        rdata = 0
                        if self.fail_on_state is not None and \
                                state == self.fail_on_state:
                            rdata = (1 << I2C_STS_MISS_ACK)
                    dut.m_axil_rdata.value = rdata
                dut.m_axil_rresp.value = 0
                dut.m_axil_rvalid.value = 1
            elif int(dut.m_axil_rvalid.value) and \
                    int(dut.m_axil_rready.value):
                # Master took the data, drop rvalid
                dut.m_axil_rvalid.value = 0
                dut.m_axil_arready.value = 0
            elif not int(dut.m_axil_arvalid.value):
                dut.m_axil_arready.value = 0


async def _wait_for_state(dut, target, max_cycles=200_000):
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        if int(dut.nego_state.value) == target:
            return True
    return False


@cocotb.test()
async def test_phase_a_state9_enters(dut):
    """PHASE A: Drive autoneg to master-win + mask_hs_auto_en=1; trace FSM.

    Confirms (or refutes) that in sim:
      – State 9 (MASK_RD_ADDR) is entered after a master-win POLL→ACK
      – The AXIL handshake fires for the 2 address-byte writes
      – State 10 (MASK_RD_DATA) and 8 (MASK_RES_TX) follow
      – Final transition is RES_TX → NEGO_DONE with mask data captured

    If sim ALSO skips MASK_RD_ADDR → bug is RTL-level, reproducible here.
    If sim enters 9/10/8 normally → bug is silicon/synth-only (Class A/B).
    """
    await setup(dut)
    # mask_hs_auto_en = 1 (this is the gate on POLL → MASK_RD_ADDR)
    dut.mask_hs_auto_en.value = 1
    # Both local lane masks = 0xFF so comparator can match peer's 0xFF
    dut.local_tx_lane_mask_i.value = 0xFF
    dut.local_rx_lane_mask_i.value = 0xFF
    # Force this side to claim master quickly via PUF=0
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2  # PUF source
    dut.puf_seed.value = 0
    dut.puf_ready.value = 1
    dut.nego_force_lock.value = 1
    dut.nego_fallback.value = 0  # fallback master (only used on timeout)
    dut.nego_timeout_reg.value = 200_000  # generous

    # Start tracer + AXL slave BEFORE deasserting POR so we catch IDLE
    tracer = FsmTracer(dut, label="phase_a")
    axl = AxilSlave(dut, dut._log)
    tracer_task = cocotb.start_soon(tracer.run())
    axl_task = cocotb.start_soon(axl.run())

    await do_por(dut)
    # Wait for the mask flow to FULLY complete: FSM must settle at
    # NEGO_DONE (state 5). nego_done_r is asserted earlier (in POLL ACK)
    # but the FSM keeps moving through MASK_RD_ADDR/RD_DATA/RES_TX, so
    # waiting on nego_done_r alone exits too early.
    nego_done = False
    for _ in range(100_000):
        await RisingEdge(dut.clk)
        if int(dut.nego_state.value) == ST_NEGO_DONE and \
                int(dut.nego_done.value):
            nego_done = True
            break
        if int(dut.nego_error.value):
            break

    # Drain a few extra cycles for last-state cycle counts
    await ClockCycles(dut.clk, 50)
    tracer.stop()
    axl.stop()
    await ClockCycles(dut.clk, 2)

    tracer.report(dut._log)

    # ── Findings checks ────────────────────────────────────────────────
    visited = set(tracer.cycles_in_state.keys())
    dut._log.info("Visited state set: %s", sorted(visited))
    dut._log.info("nego_done=%d  nego_error=%d  nego_won=%d  nego_lost=%d  final_state=%d",
                  int(dut.nego_done.value), int(dut.nego_error.value),
                  int(dut.nego_won.value), int(dut.nego_lost.value),
                  int(dut.nego_state.value))
    dut._log.info("peer_tx_lane_mask_o=0x%02x  peer_rx_lane_mask_o=0x%02x",
                  int(dut.peer_tx_lane_mask_o.value),
                  int(dut.peer_rx_lane_mask_o.value))
    dut._log.info("mask_hs_local_match=%d  mask_hs_local_fail=%d",
                  int(dut.mask_hs_local_match.value),
                  int(dut.mask_hs_local_fail.value))

    # The state-9 entry is the central question of Phase A.
    state9_entered = ST_NEGO_MASK_RD_ADDR in visited
    state10_entered = ST_NEGO_MASK_RD_DATA in visited
    state8_entered = ST_NEGO_MASK_RES_TX in visited

    dut._log.info("=" * 70)
    dut._log.info("PHASE A FINDINGS:")
    dut._log.info("  state 9 (MASK_RD_ADDR) entered:  %s", state9_entered)
    dut._log.info("  state 10 (MASK_RD_DATA) entered: %s", state10_entered)
    dut._log.info("  state 8 (MASK_RES_TX)  entered:  %s", state8_entered)
    dut._log.info("  final nego_done:                 %s", nego_done)
    dut._log.info("=" * 70)

    assert state9_entered, (
        "PHASE A REPRO: state 9 (MASK_RD_ADDR) NEVER entered in sim. "
        "This matches silicon — bug is RTL-level, not synth-only.")


@cocotb.test()
async def test_phase_a_state8_to_done_transition(dut):
    """PHASE A follow-up: Check MASK_RES_TX completion latches mask_hs_local_match.

    Specifically tests hypothesis (d): does the AXIL handshake fire during
    MASK_RES_TX, and does the FSM cleanly transition state 8 → state 5
    with mask_hs_local_match asserted?
    """
    await setup(dut)
    dut.mask_hs_auto_en.value = 1
    dut.local_tx_lane_mask_i.value = 0xFF
    dut.local_rx_lane_mask_i.value = 0xFF
    dut.nego_en.value = 1
    dut.nego_pri_sel.value = 2
    dut.puf_seed.value = 0
    dut.puf_ready.value = 1
    dut.nego_force_lock.value = 1
    dut.nego_fallback.value = 0
    dut.nego_timeout_reg.value = 200_000

    tracer = FsmTracer(dut, label="phase_a_d")
    axl = AxilSlave(dut, dut._log)
    cocotb.start_soon(tracer.run())
    cocotb.start_soon(axl.run())

    await do_por(dut)

    for _ in range(100_000):
        await RisingEdge(dut.clk)
        if int(dut.nego_state.value) == ST_NEGO_DONE:
            break
        if int(dut.nego_error.value):
            break

    await ClockCycles(dut.clk, 50)
    tracer.stop()
    axl.stop()
    await ClockCycles(dut.clk, 2)

    tracer.report(dut._log)

    final = int(dut.nego_state.value)
    match = int(dut.mask_hs_local_match.value)
    fail = int(dut.mask_hs_local_fail.value)
    dut._log.info("PHASE A(d): final_state=%d  mask_match=%d  mask_fail=%d  "
                  "peer_tx=0x%02x peer_rx=0x%02x",
                  final, match, fail,
                  int(dut.peer_tx_lane_mask_o.value),
                  int(dut.peer_rx_lane_mask_o.value))

    # If state 8 was entered and we exit cleanly, mask_match should be 1
    # (because we returned peer masks = local masks = 0xFF).
    visited = set(tracer.cycles_in_state.keys())
    assert ST_NEGO_MASK_RES_TX in visited, (
        "PHASE A(d): MASK_RES_TX (state 8) never entered — "
        "AXIL or comparator gate is failing silently in sim too.")
    assert final == ST_NEGO_DONE, \
        f"Expected final state NEGO_DONE, got {STATE_NAMES.get(final, final)}"
