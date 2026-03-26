"""Cocotb testbench for tidelink pair doorbell / reset handshake.

Models a paired tidelink's register bank as a Python object. The DUT's
AHB master (returner) writes are intercepted by the pair model, which
then drives back into the DUT's APB slave to simulate the pair's response.

The pair model and DUT can be on independent reset domains.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Timer


# ── Constants ────────────────────────────────────────────────────────────────
CLK_PERIOD_NS = 10
PAIR_BASE     = 0x4000_1000  # Must match tb_top parameter TIDELINK_PAIR_BASE
MAX_TOKENS    = 1 << 12      # (1 << (RAM_ADDR_W - 2)), RAM_ADDR_W=14

# APB offsets
OFF_PAIR_BASE_ADDR   = 0x000
OFF_PKT_WORD_LEN     = 0x008
OFF_TOKEN_COUNT      = 0x00C
OFF_STATUS           = 0x010
OFF_DOORBELL         = 0x014
OFF_RELEASED_TOKENS  = 0x020


# ── Pair Register Bank (Python model) ───────────────────────────────────────

class PairRegisterBank:
    """Models the paired tidelink's APB register bank in Python.

    Monitors the DUT's AHB master outputs for writes, and when a write
    targets an address in this pair's address space, processes it:
    - Write to doorbell (0x014): triggers a response write back to the DUT
    - Write to released tokens accumulator (0x020): accumulates the value

    The pair has its own token count (simulating its own FIFO state) and
    can be independently reset.
    """

    def __init__(self, base_addr, dut_apb_base, max_tokens):
        self.base_addr = base_addr
        self.dut_apb_base = dut_apb_base  # Address of the DUT's APB space
        self.max_tokens = max_tokens
        self.reset()

    def reset(self):
        """Reset the pair's internal state."""
        self.token_count = self.max_tokens  # All tokens free after reset
        self.released_tokens_acc = 0
        self.doorbell_pending = False
        self.log_lines = []

    def log(self, msg):
        self.log_lines.append(msg)

    def handle_ahb_write(self, addr, data):
        """Process an AHB write from the DUT's returner.

        Returns a list of (addr, data) APB writes to perform back to the DUT,
        or an empty list if no response is needed.
        """
        offset = addr - self.base_addr
        responses = []

        if offset == OFF_DOORBELL:
            # Doorbell rung — respond with our total free tokens
            self.doorbell_pending = True
            self.log(f"PAIR: Doorbell rung! Responding with token_count={self.token_count}")
            # Write our total free tokens to the DUT's released tokens accumulator
            responses.append((
                self.dut_apb_base + OFF_RELEASED_TOKENS,
                self.token_count
            ))

        elif offset == OFF_RELEASED_TOKENS:
            # Released tokens received — accumulate
            self.released_tokens_acc += data
            self.log(f"PAIR: Received {data} released tokens "
                     f"(total accumulated: {self.released_tokens_acc})")

        else:
            self.log(f"PAIR: Unknown write to offset 0x{offset:03X} = 0x{data:08X}")

        return responses


# ── AHB Master Monitor ──────────────────────────────────────────────────────

async def ahb_master_monitor(dut, pair_model):
    """Monitor the DUT's AHB master outputs and route writes to the pair model.

    When the pair model generates response writes, drive them into the
    DUT's APB slave interface.
    """
    # AHB master always ready, no errors
    dut.ahbm_hready.value = 1
    dut.ahbm_hresp.value  = 0
    dut.ahbm_hrdata.value = 0

    pending_addr = None

    while True:
        await RisingEdge(dut.hclk)

        # Detect AHB address phase (HTRANS = NONSEQ)
        try:
            htrans = int(dut.ahbm_htrans.value)
            hwrite = int(dut.ahbm_hwrite.value)
        except ValueError:
            continue

        if htrans == 2 and hwrite == 1:
            # Address phase of a write — capture address
            pending_addr = int(dut.ahbm_haddr.value)

        elif pending_addr is not None:
            # Data phase — capture data and process
            try:
                hwdata = int(dut.ahbm_hwdata.value)
            except ValueError:
                hwdata = 0

            dut._log.info(f"AHB Master write: addr=0x{pending_addr:08X} "
                          f"data=0x{hwdata:08X}")

            responses = pair_model.handle_ahb_write(pending_addr, hwdata)

            # Drive response writes back to DUT's APB slave
            for resp_addr, resp_data in responses:
                await apb_write(dut, resp_addr, resp_data)

            pending_addr = None


# ── APB Helpers ──────────────────────────────────────────────────────────────

async def apb_write(dut, addr, data):
    """Perform an APB write to the DUT's APB slave interface."""
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 1
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 1
    dut.apbs_paddr.value   = addr & 0xFFF  # APB_ADDR_W = 12
    dut.apbs_pwdata.value  = data
    await RisingEdge(dut.hclk)
    dut.apbs_penable.value = 1
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0


async def apb_read(dut, addr):
    """Perform an APB read from the DUT's APB slave interface."""
    await RisingEdge(dut.hclk)
    dut.apbs_psel.value    = 1
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0
    dut.apbs_paddr.value   = addr & 0xFFF
    await RisingEdge(dut.hclk)
    dut.apbs_penable.value = 1
    await RisingEdge(dut.hclk)
    rdata = int(dut.apbs_prdata.value)
    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    return rdata


# ── Setup / Reset ────────────────────────────────────────────────────────────

async def setup(dut):
    """Start clock and initialise all inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.hclk, CLK_PERIOD_NS, units="ns").start())

    # AHB slave defaults (idle)
    dut.ahbs_hsel.value    = 0
    dut.ahbs_hready.value  = 1
    dut.ahbs_htrans.value  = 0
    dut.ahbs_hsize.value   = 2
    dut.ahbs_hwrite.value  = 0
    dut.ahbs_haddr.value   = 0
    dut.ahbs_hwdata.value  = 0

    # AHB master defaults
    dut.ahbm_hready.value  = 1
    dut.ahbm_hresp.value   = 0
    dut.ahbm_hrdata.value  = 0

    # APB defaults
    dut.apbs_psel.value    = 0
    dut.apbs_penable.value = 0
    dut.apbs_pwrite.value  = 0
    dut.apbs_paddr.value   = 0
    dut.apbs_pwdata.value  = 0


async def do_reset(dut, cycles=5):
    """Assert reset for given cycles then deassert."""
    dut.hresetn.value = 0
    await ClockCycles(dut.hclk, cycles)
    dut.hresetn.value = 1
    await ClockCycles(dut.hclk, 2)


# ── AHB Slave (FIFO) Write Helper ────────────────────────────────────────────

async def fifo_write_packet(dut, data_words):
    """Write a packet into the DUT's FIFO via the AHB slave interface.

    Beat 0 (haddr=0): length word
    Beats 1..N (haddr=4,8,...): data words
    """
    pkt_len = len(data_words)

    # Beat 0: write length
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2  # NONSEQ
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2  # WORD
    dut.ahbs_haddr.value  = 0x0000
    dut.ahbs_hready.value = 1
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = pkt_len
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF  # avoid check_addr
    await ClockCycles(dut.hclk, 2)

    # Data beats
    for i, word in enumerate(data_words):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value   = 1
        dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 1
        dut.ahbs_hsize.value  = 2
        dut.ahbs_haddr.value  = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_hwdata.value = word
        dut.ahbs_htrans.value = 0
        dut.ahbs_hsel.value   = 0
        await RisingEdge(dut.hclk)
        dut.ahbs_hwrite.value = 0

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 2)


# ── Tests ────────────────────────────────────────────────────────────────────

@cocotb.test()
async def test_01_reset_doorbell_flow(dut):
    """Test the reset → doorbell → token response flow.

    Flow:
    1. DUT (side A) comes out of reset
    2. Channel 2 fires: writes to pair's doorbell (PAIR_BASE + 0x14)
    3. Pair model sees doorbell, responds by writing its token count
       to DUT's released tokens accumulator (DUT_BASE + 0x20)
    4. DUT's released_tokens_irq asserts
    5. CPU reads accumulator → gets pair's token count, IRQ clears
    """
    await setup(dut)

    # Create pair model (pair has all tokens free)
    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,  # DUT's own APB base (offset 0 in this testbench)
        max_tokens=MAX_TOKENS
    )

    # Start AHB master monitor
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    # Reset the DUT
    await do_reset(dut)

    # Wait for the reset deassertion pulse to propagate and the returner
    # to complete its AHB write cycle (IDLE → ADDR → DATA → IDLE)
    await ClockCycles(dut.hclk, 10)

    # Check that the pair received the doorbell
    assert pair.doorbell_pending, \
        "Pair should have received a doorbell ring after DUT reset"

    # Wait for the APB response write to propagate
    await ClockCycles(dut.hclk, 5)

    # Check IRQ is asserted
    irq = int(dut.released_tokens_irq.value)
    dut._log.info(f"released_tokens_irq = {irq}")
    assert irq == 1, "released_tokens_irq should be asserted after pair responds"

    # CPU reads the accumulator — should get pair's MAX_TOKENS
    acc_value = await apb_read(dut, OFF_RELEASED_TOKENS)
    dut._log.info(f"Released tokens accumulator = {acc_value} "
                  f"(expected {MAX_TOKENS})")
    assert acc_value == MAX_TOKENS, \
        f"Expected {MAX_TOKENS}, got {acc_value}"

    # After read, IRQ should clear
    await ClockCycles(dut.hclk, 1)
    irq = int(dut.released_tokens_irq.value)
    assert irq == 0, "released_tokens_irq should clear after CPU read"

    # Print pair model log
    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_02_software_doorbell(dut):
    """Test the software-triggered doorbell flow.

    1. DUT is out of reset and stable
    2. CPU writes to DUT's doorbell register (0x014)
    3. Channel 1 fires: writes DUT's total free tokens to pair's accumulator
    4. Pair model accumulates the value
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)  # Let reset doorbell complete

    # Clear any state from reset doorbell
    pair.released_tokens_acc = 0
    pair.log_lines.clear()

    # CPU triggers doorbell
    await apb_write(dut, OFF_DOORBELL, 1)

    # Wait for returner to complete
    await ClockCycles(dut.hclk, 10)

    # Pair should have received DUT's total free tokens (MAX_TOKENS)
    dut._log.info(f"Pair received: {pair.released_tokens_acc} tokens")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Pair should have received {MAX_TOKENS} tokens, got {pair.released_tokens_acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_03_independent_resets(dut):
    """Test that each side can reset independently.

    1. Both sides come out of reset together
    2. DUT's reset doorbell rings pair, pair responds
    3. DUT resets again (simulating a soft reset)
    4. DUT's reset doorbell rings pair again, pair responds again
    5. Verify the accumulator gets the pair's tokens each time
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    # ── First reset (both sides together) ────────────────────────
    dut._log.info("=== First reset ===")
    pair.reset()
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    irq = int(dut.released_tokens_irq.value)
    assert irq == 1, "IRQ should be asserted after first reset handshake"

    acc = await apb_read(dut, OFF_RELEASED_TOKENS)
    dut._log.info(f"After first reset: accumulator = {acc}")
    assert acc == MAX_TOKENS, f"Expected {MAX_TOKENS}, got {acc}"

    await ClockCycles(dut.hclk, 2)
    assert int(dut.released_tokens_irq.value) == 0, "IRQ should clear after read"

    # ── Second reset (DUT only, pair stays running) ──────────────
    dut._log.info("=== Second reset (DUT only) ===")
    # Pair keeps running — simulate it having used some tokens
    pair.token_count = MAX_TOKENS - 100
    pair.doorbell_pending = False

    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    assert pair.doorbell_pending, "Pair should see doorbell from DUT's second reset"

    irq = int(dut.released_tokens_irq.value)
    assert irq == 1, "IRQ should be asserted after second reset handshake"

    acc = await apb_read(dut, OFF_RELEASED_TOKENS)
    dut._log.info(f"After second reset: accumulator = {acc} "
                  f"(pair has {pair.token_count} free)")
    assert acc == MAX_TOKENS - 100, \
        f"Expected {MAX_TOKENS - 100} (pair's current free tokens), got {acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_04_pair_resets_while_dut_running(dut):
    """Simulate the pair resetting while the DUT is running.

    When the pair resets, it would ring the DUT's doorbell. We simulate
    this by writing to the DUT's doorbell register (as the pair's reset
    channel 2 would do via the bus fabric).

    The DUT should respond with its total free tokens to the pair's
    accumulator.
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    # Clear reset doorbell state
    pair.released_tokens_acc = 0
    pair.log_lines.clear()
    await apb_read(dut, OFF_RELEASED_TOKENS)  # Clear DUT's accumulator
    await ClockCycles(dut.hclk, 2)

    # Simulate pair resetting: pair's reset channel 2 writes to DUT's doorbell
    dut._log.info("=== Pair resets — ringing DUT's doorbell ===")
    await apb_write(dut, OFF_DOORBELL, 1)

    await ClockCycles(dut.hclk, 10)

    # DUT should have written its total free tokens to pair's accumulator
    dut._log.info(f"Pair received: {pair.released_tokens_acc} tokens from DUT")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Expected DUT to send {MAX_TOKENS} tokens, got {pair.released_tokens_acc}"

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_05_simultaneous_reset(dut):
    """Both sides reset at the same time.

    1. DUT resets and pair resets simultaneously
    2. DUT's reset channel rings pair's doorbell
    3. Pair (modelled) responds with its full token count
    4. Simultaneously, pair would ring DUT's doorbell (simulated via APB write)
    5. Verify both sides receive each other's token counts
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    # Both reset together
    dut._log.info("=== Simultaneous reset ===")
    pair.reset()
    await do_reset(dut)

    # Wait for DUT's reset doorbell to complete
    await ClockCycles(dut.hclk, 15)

    # DUT rang pair's doorbell, pair responded → DUT accumulator has pair's tokens
    acc_from_pair = await apb_read(dut, OFF_RELEASED_TOKENS)
    dut._log.info(f"DUT received from pair: {acc_from_pair}")
    assert acc_from_pair == MAX_TOKENS, \
        f"DUT should receive {MAX_TOKENS} from pair, got {acc_from_pair}"

    # Now simulate pair's reset channel ringing DUT's doorbell
    # (pair would do this via its own returner channel 2)
    pair.released_tokens_acc = 0
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    # DUT should have responded with its total free tokens
    dut._log.info(f"Pair received from DUT: {pair.released_tokens_acc}")
    assert pair.released_tokens_acc == MAX_TOKENS, \
        f"Pair should receive {MAX_TOKENS} from DUT, got {pair.released_tokens_acc}"

    dut._log.info("Both sides received each other's token counts")

    for line in pair.log_lines:
        dut._log.info(line)


@cocotb.test()
async def test_06_write_packets_then_pair_resets(dut):
    """Write several packets into the DUT's FIFO (consuming tokens), then
    simulate the pair resetting. The DUT should respond with the correct
    REDUCED free token count — not MAX_TOKENS.

    Flow:
    1. Both sides come out of reset, exchange initial token counts
    2. Write 3 packets of known sizes into DUT's FIFO (consuming tokens)
    3. Read DUT's token count via APB to confirm it decreased
    4. Pair resets — rings DUT's doorbell
    5. DUT responds with its current (reduced) free token count
    6. Verify pair receives the correct value
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    # ── Initial reset handshake ──────────────────────────────────
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    await apb_read(dut, OFF_RELEASED_TOKENS)  # Clear accumulator/IRQ
    await ClockCycles(dut.hclk, 2)

    # ── Write packets into the FIFO ──────────────────────────────
    packets = [
        [0xAA000001, 0xAA000002, 0xAA000003],           # 3 data words → 4 tokens
        [0xBB000001, 0xBB000002],                        # 2 data words → 3 tokens
        [0xCC000001, 0xCC000002, 0xCC000003, 0xCC000004, # 5 data words → 6 tokens
         0xCC000005],
    ]

    total_tokens_used = 0
    for i, pkt_data in enumerate(packets):
        tokens_for_pkt = len(pkt_data) + 1  # data + length word
        total_tokens_used += tokens_for_pkt
        dut._log.info(f"Writing packet {i+1}: {len(pkt_data)} data words "
                      f"({tokens_for_pkt} tokens)")
        await fifo_write_packet(dut, pkt_data)

    expected_free = MAX_TOKENS - total_tokens_used
    dut._log.info(f"Total tokens used: {total_tokens_used}, "
                  f"expected free: {expected_free}")

    # Wait for any returner activity from write_completes to complete
    await ClockCycles(dut.hclk, 20)

    # ── Verify DUT's token count via APB ─────────────────────────
    hw_token_count = await apb_read(dut, OFF_TOKEN_COUNT)
    dut._log.info(f"DUT token count (APB read): {hw_token_count}")
    assert hw_token_count == expected_free, \
        f"DUT token count: expected {expected_free}, got {hw_token_count}"

    # ── Pair resets — rings DUT's doorbell ───────────────────────
    dut._log.info("=== Pair resets ===")
    pair.reset()  # Pair goes back to MAX_TOKENS
    pair.released_tokens_acc = 0

    # Simulate pair's reset channel 2 ringing DUT's doorbell
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    # DUT should respond with its current free tokens (reduced by writes)
    dut._log.info(f"Pair received from DUT: {pair.released_tokens_acc} tokens "
                  f"(expected {expected_free})")
    assert pair.released_tokens_acc == expected_free, \
        (f"DUT should report {expected_free} free tokens after writing "
         f"{total_tokens_used} tokens, got {pair.released_tokens_acc}")

    for line_out in pair.log_lines:
        dut._log.info(line_out)


@cocotb.test()
async def test_07_write_and_read_packets_then_pair_resets(dut):
    """Write packets, read some back (freeing tokens), then pair resets.
    Verify the DUT reports the correct token count reflecting both
    writes and reads.

    1. Write 3 packets (consume 13 tokens)
    2. Read 1 packet back (free 4 tokens)
    3. Pair resets — DUT should report MAX_TOKENS - 13 + 4 = MAX_TOKENS - 9
    """
    await setup(dut)

    pair = PairRegisterBank(
        base_addr=PAIR_BASE,
        dut_apb_base=0,
        max_tokens=MAX_TOKENS
    )
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))

    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)
    pair.released_tokens_acc = 0

    # ── Write 3 packets ──────────────────────────────────────────
    pkt1_data = [0xAA000001, 0xAA000002, 0xAA000003]  # 4 tokens
    pkt2_data = [0xBB000001, 0xBB000002]               # 3 tokens
    pkt3_data = [0xCC000001, 0xCC000002, 0xCC000003,
                 0xCC000004, 0xCC000005]                # 6 tokens

    for pkt_data in [pkt1_data, pkt2_data, pkt3_data]:
        await fifo_write_packet(dut, pkt_data)

    await ClockCycles(dut.hclk, 20)

    tokens_written = (len(pkt1_data)+1) + (len(pkt2_data)+1) + (len(pkt3_data)+1)
    dut._log.info(f"Tokens written: {tokens_written}")

    hw_after_write = await apb_read(dut, OFF_TOKEN_COUNT)
    dut._log.info(f"Token count after writes: {hw_after_write}")
    assert hw_after_write == MAX_TOKENS - tokens_written

    # ── Read back packet 1 (free 4 tokens) ───────────────────────
    # Read length from addr 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
    dut.ahbs_haddr.value = 0x0000; dut.ahbs_hready.value = 1
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    # Read data beats (3 data words for pkt1)
    for i in range(len(pkt1_data)):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
        dut.ahbs_haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)

    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 15)  # Let read hit + returner settle

    tokens_read_back = len(pkt1_data) + 1  # 4 tokens freed
    expected_free = MAX_TOKENS - tokens_written + tokens_read_back
    dut._log.info(f"Tokens read back: {tokens_read_back}, "
                  f"expected free: {expected_free}")

    hw_after_read = await apb_read(dut, OFF_TOKEN_COUNT)
    dut._log.info(f"Token count after read: {hw_after_read}")
    assert hw_after_read == expected_free, \
        f"Expected {expected_free}, got {hw_after_read}"

    # ── Pair resets — rings DUT's doorbell ───────────────────────
    dut._log.info("=== Pair resets ===")
    pair.reset()
    pair.released_tokens_acc = 0

    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 10)

    dut._log.info(f"Pair received from DUT: {pair.released_tokens_acc} tokens "
                  f"(expected {expected_free})")
    assert pair.released_tokens_acc == expected_free, \
        (f"DUT should report {expected_free} free tokens "
         f"(wrote {tokens_written}, read back {tokens_read_back}), "
         f"got {pair.released_tokens_acc}")

    for line_out in pair.log_lines:
        dut._log.info(line_out)


# ══════════════════════════════════════════════════════════════════════════════
# Bug Regression Tests
# ══════════════════════════════════════════════════════════════════════════════

@cocotb.test()
async def test_bug1_metadata_capture_without_valid_transfer(dut):
    """BUG: packet_word_length captured on idle bus when haddr is 0.

    The metadata capture logic fires on haddr==0 without checking
    hsel or htrans. During idle cycles where haddr is 0 and hwrite=0,
    check_addr gets set, which then captures rdata (0 from inactive
    SRAM) into packet_word_length, zeroing it out.
    """
    await setup(dut)
    pair = PairRegisterBank(PAIR_BASE, 0, MAX_TOKENS)
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)

    # Write a packet to set packet_word_length = 3
    await fifo_write_packet(dut, [0x11, 0x22, 0x33])
    await ClockCycles(dut.hclk, 5)

    pkt_len_before = await apb_read(dut, OFF_PKT_WORD_LEN)
    dut._log.info(f"packet_word_length after write: {pkt_len_before}")
    assert pkt_len_before == 3, f"Expected 3, got {pkt_len_before}"

    # Leave haddr=0, hwrite=0, hsel=0, htrans=IDLE (idle bus at addr 0)
    # The check_addr path triggers on haddr==0 && ~hwrite (no hsel/htrans check)
    # Then next cycle, check_addr_r=1 captures rdata (0 from inactive cs) into pkt_len
    dut.ahbs_haddr.value  = 0
    dut.ahbs_hwrite.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_htrans.value = 0
    # Wait enough cycles for check_addr to set and rdata to be captured
    await ClockCycles(dut.hclk, 10)

    pkt_len_after = await apb_read(dut, OFF_PKT_WORD_LEN)
    dut._log.info(f"packet_word_length after idle at addr 0: {pkt_len_after}")

    if pkt_len_after == 0:
        dut._log.error("BUG CONFIRMED: packet_word_length zeroed by idle bus "
                       "at haddr=0. Metadata capture not gated on valid_transfer.")
    assert pkt_len_after == 3, \
        (f"BUG: packet_word_length corrupted from 3 to {pkt_len_after}. "
         f"Capture fires on haddr==0 without checking hsel/htrans.")


@cocotb.test()
async def test_bug2_doorbell_lost_when_returner_busy(dut):
    """BUG: Doorbell pulse lost if returner is busy with another channel.

    doorbell_trigger is a 1-cycle self-clearing pulse. The returner only
    captures interrupts in ST_IDLE. If channel 0 (read completion) is
    mid-transfer when the doorbell fires, the pulse is gone before the
    returner can service it.
    """
    await setup(dut)
    pair = PairRegisterBank(PAIR_BASE, 0, MAX_TOKENS)
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)
    pair.released_tokens_acc = 0
    pair.log_lines.clear()

    # Write a packet
    await fifo_write_packet(dut, [0xAA, 0xBB, 0xCC])
    await ClockCycles(dut.hclk, 10)

    # Read the packet back — last beat triggers read_complete → channel 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
    dut.ahbs_haddr.value = 0x0000; dut.ahbs_hready.value = 1
    await RisingEdge(dut.hclk)
    dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 3)

    for i in range(3):
        addr = (i + 1) * 4
        await RisingEdge(dut.hclk)
        dut.ahbs_hsel.value = 1; dut.ahbs_htrans.value = 2
        dut.ahbs_hwrite.value = 0; dut.ahbs_hsize.value = 2
        dut.ahbs_haddr.value = addr
        await RisingEdge(dut.hclk)
        dut.ahbs_htrans.value = 0; dut.ahbs_hsel.value = 0
        dut.ahbs_haddr.value = 0x3FFF
        await RisingEdge(dut.hclk)

    # Channel 0 now active — IMMEDIATELY ring doorbell while busy
    await apb_write(dut, OFF_DOORBELL, 1)
    await ClockCycles(dut.hclk, 20)

    # Check what the pair received
    dut._log.info(f"Pair accumulated: {pair.released_tokens_acc}")
    for line_out in pair.log_lines:
        dut._log.info(line_out)

    # If doorbell was serviced, pair should have received the total free
    # tokens (MAX_TOKENS) in addition to any channel 0 deltas.
    # If the doorbell was lost, pair only gets channel 0 deltas.
    received_total = pair.released_tokens_acc > MAX_TOKENS or \
                     any("4096" in l for l in pair.log_lines)
    received_doorbell = any("4096" in l for l in pair.log_lines)

    dut._log.info(f"Doorbell response received by pair: {received_doorbell}")

    if not received_doorbell:
        dut._log.error("BUG CONFIRMED: Doorbell pulse was lost because "
                       "returner was busy with channel 0.")
    assert received_doorbell, \
        (f"BUG: Pair received {pair.released_tokens_acc} tokens but "
         f"no doorbell response (MAX_TOKENS={MAX_TOKENS}) was seen. "
         f"Doorbell pulse lost while returner was busy.")


@cocotb.test()
async def test_bug3_stale_packet_length_causes_spurious_hit(dut):
    """BUG: packet_word_length not cleared after packet completion.

    After a packet completes, the old packet_word_length persists and
    write_target_addr remains at old_length * 4. A subsequent AHB write
    to that stale address triggers a spurious completion, advancing the
    pointer and decrementing the token count incorrectly.
    """
    await setup(dut)
    pair = PairRegisterBank(PAIR_BASE, 0, MAX_TOKENS)
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Write a packet with length=3. Target addr = 3*4 = 0xC
    await fifo_write_packet(dut, [0x11, 0x22, 0x33])
    await ClockCycles(dut.hclk, 10)

    tokens_after_pkt = await apb_read(dut, OFF_TOKEN_COUNT)
    dut._log.info(f"Token count after packet: {tokens_after_pkt}")

    # Now do a raw AHB write to haddr=0xC (stale target address)
    # This is NOT a new packet — just a random write
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 1
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x000C
    await RisingEdge(dut.hclk)
    dut.ahbs_hwdata.value = 0xDEAD
    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    await RisingEdge(dut.hclk)
    dut.ahbs_hwrite.value = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await ClockCycles(dut.hclk, 10)

    tokens_after_spurious = await apb_read(dut, OFF_TOKEN_COUNT)
    dut._log.info(f"Token count after spurious write to 0xC: {tokens_after_spurious}")

    if tokens_after_spurious != tokens_after_pkt:
        dut._log.error(f"BUG CONFIRMED: Stale packet_word_length caused "
                       f"spurious hit. Tokens {tokens_after_pkt} -> "
                       f"{tokens_after_spurious}.")
    assert tokens_after_spurious == tokens_after_pkt, \
        (f"BUG: Token count changed from {tokens_after_pkt} to "
         f"{tokens_after_spurious}. packet_word_length should be "
         f"cleared after packet completion.")


@cocotb.test()
async def test_bug4_hit_fires_on_wrong_direction(dut):
    """BUG: write_complete fires during read operations.

    The hit signals are not gated on hwrite direction. write_complete
    can fire during a READ if haddr matches the write target address.
    """
    await setup(dut)
    pair = PairRegisterBank(PAIR_BASE, 0, MAX_TOKENS)
    monitor = cocotb.start_soon(ahb_master_monitor(dut, pair))
    await do_reset(dut)
    await ClockCycles(dut.hclk, 15)
    await apb_read(dut, OFF_RELEASED_TOKENS)
    await ClockCycles(dut.hclk, 2)

    # Write a packet with length=2. Target = 2*4 = 0x8
    await fifo_write_packet(dut, [0xAA, 0xBB])
    dut.ahbs_haddr.value = 0x3FFF
    await ClockCycles(dut.hclk, 10)

    # Now do an AHB READ at haddr=0x8 (the write target address)
    await RisingEdge(dut.hclk)
    dut.ahbs_hsel.value   = 1
    dut.ahbs_htrans.value = 2
    dut.ahbs_hwrite.value = 0  # READ
    dut.ahbs_hsize.value  = 2
    dut.ahbs_haddr.value  = 0x0008

    await RisingEdge(dut.hclk)
    await FallingEdge(dut.hclk)
    try:
        w_hit = int(dut.u_dut.u_tidelink_ahb.u_fifo_ctrl.write_complete.value)
    except ValueError:
        w_hit = 0

    dut.ahbs_htrans.value = 0
    dut.ahbs_hsel.value   = 0
    dut.ahbs_haddr.value  = 0x3FFF
    await RisingEdge(dut.hclk)

    dut._log.info(f"write_complete during READ at 0x8: {w_hit}")

    if w_hit == 1:
        dut._log.error("BUG CONFIRMED: write_complete fired during a READ. "
                       "Hit signal is not gated on hwrite direction.")
    assert w_hit == 0, \
        ("BUG: write_complete fired during a READ at the write target "
         "address. Hit signals should be gated on transfer direction.")
