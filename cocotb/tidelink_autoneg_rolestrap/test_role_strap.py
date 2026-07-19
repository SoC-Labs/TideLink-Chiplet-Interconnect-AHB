"""PENDING-DECISION #5 — role from STRAP, not the I2C-NACK constant.

Both dies are driven to the I2C-NACK terminal path. A minimal AXI-Lite
"I2C-master" model accepts the FSM's writes (PRESCALE/DATA/COMMAND) and answers
the status-register polls: BUSY=1 on the first read (so busy_seen latches), then
BUSY=0 | MISS_ACK on the next (the NACK), driving the FSM into its terminal role
decision.

  MODE=trap (ROLE_FROM_STRAP=0): die_a -> slave, die_b -> slave  (both slave = trap)
  MODE=fix  (ROLE_FROM_STRAP=1): die_a -> master, die_b -> slave  (strap honoured)
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE = os.environ.get("ROLE_FROM_STRAP_MODE", "trap")

I2C_STS_BUSY = 1 << 0
I2C_STS_MISS_ACK = 1 << 3


class I2CMasterModel:
    """Drives one die's AXI-Lite response channels to emulate the I2C master:
    all writes accepted; status reads return BUSY then a NACK (MISS_ACK)."""

    def __init__(self, dut, p):
        self.dut = dut
        self.p = p          # prefix "a" or "b"
        self.read_count = 0

    def g(self, s):
        return getattr(self.dut, f"{self.p}_{s}")

    def init(self):
        for s in ("awready", "wready", "bvalid", "arready", "rvalid"):
            self.g(s).value = 0
        self.g("rdata").value = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
            # ---- write channel: accept AW+W together, then B --------------
            if int(self.g("awvalid").value) and int(self.g("wvalid").value):
                self.g("awready").value = 1
                self.g("wready").value = 1
                await RisingEdge(self.dut.clk)
                self.g("awready").value = 0
                self.g("wready").value = 0
                self.g("bvalid").value = 1
                while not int(self.g("bready").value):
                    await RisingEdge(self.dut.clk)
                self.g("bvalid").value = 0
                continue
            # ---- read channel: status polls -------------------------------
            if int(self.g("arvalid").value):
                self.g("arready").value = 1
                await RisingEdge(self.dut.clk)
                self.g("arready").value = 0
                # First status read: BUSY (arms busy_seen). Later: NACK.
                if self.read_count == 0:
                    self.g("rdata").value = I2C_STS_BUSY
                else:
                    self.g("rdata").value = I2C_STS_MISS_ACK  # busy=0, miss_ack=1
                self.read_count += 1
                self.g("rvalid").value = 1
                while not int(self.g("rready").value):
                    await RisingEdge(self.dut.clk)
                self.g("rvalid").value = 0
                continue


@cocotb.test()
async def test_nack_terminal_role_from_strap(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    model_a = I2CMasterModel(dut, "a")
    model_b = I2CMasterModel(dut, "b")
    model_a.init()
    model_b.init()

    dut.nego_en.value = 0
    dut.nego_start.value = 0
    dut.poresetn.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.poresetn.value = 1
    await RisingEdge(dut.clk)

    cocotb.start_soon(model_a.run())
    cocotb.start_soon(model_b.run())

    # Kick off negotiation on both dies
    dut.nego_en.value = 1
    dut.nego_start.value = 1

    # Run until both dies latch a terminal role (nego_done), bounded
    done = False
    for _ in range(4000):
        await RisingEdge(dut.clk)
        if int(dut.a_done.value) and int(dut.b_done.value):
            done = True
            break
    assert done, (
        f"[{MODE}] dies did not reach a terminal role: "
        f"a_state={int(dut.a_state.value)} a_done={int(dut.a_done.value)} "
        f"b_state={int(dut.b_state.value)} b_done={int(dut.b_done.value)}")

    # nego_role_value is a pulse (valid only when set_role_cfg=1); the LATCHED
    # terminal role is nego_role_r.
    a_role = int(dut.a_role_r.value)
    b_role = int(dut.b_role_r.value)
    a_lost = int(dut.a_lost.value)
    b_lost = int(dut.b_lost.value)
    dut._log.info(f"[{MODE}] NACK terminal roles: die_a={a_role} (strap=master=0), "
                  f"die_b={b_role} (strap=slave=1); a_lost={a_lost} b_lost={b_lost}")

    # Both took the NACK path (nego_lost set)
    assert a_lost == 1 and b_lost == 1, (
        f"[{MODE}] expected both dies on the NACK path (nego_lost=1); "
        f"got a_lost={a_lost} b_lost={b_lost} — instrument did not reach NACK.")

    if MODE == "fix":
        assert a_role == 0, f"FIX: die_a (master strap) must be MASTER (0), got {a_role}"
        assert b_role == 1, f"FIX: die_b (slave strap) must be SLAVE (1), got {b_role}"
        dut._log.info("FIX confirmed: NACK honours the strap -> (master, slave). "
                      "A master exists; autonomy can proceed.")
    else:  # trap
        assert a_role == 1 and b_role == 1, (
            f"TRAP: today's RTL forces both dies SLAVE on NACK; "
            f"got a_role={a_role} b_role={b_role}. Instrument broken if not (1,1).")
        dut._log.info("TRAP confirmed: NACK forces (slave, slave) -> NO master, "
                      "winscan never retires, autonomy structurally dead.")
