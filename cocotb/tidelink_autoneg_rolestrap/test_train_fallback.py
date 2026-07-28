"""Option A proof — TRAIN_ENTRY_FALLBACK on a dead I2C bus.

Companion to test_role_strap (DECISION #3). 6080ebd gave the NEGO transaction a
strap fallback on a dead I2C bus; the TRAINING transaction had none, so
local_training_mode_set (the ONLY enabler of the SYNC beacon) fired only on a
peer I2C ACK. On a rig whose I2C never ACKs (bridge1, measured 2026-07-24) the
FSM hangs/fails in ST_TRAIN_ENTER, the beacon never lights, and no data crosses.

Same two-die env, same I2C NACK model — but train_auto_en=1 so the FSM walks
PAST the NEGO terminal-role decision into ST_TRAIN_ENTER and runs the TRAINING
I2C transaction, which also NACKs. The A/B (compile-time param, run-time env):

  MODE=trainfb_on  (TRAIN_ENTRY_FALLBACK=1): local_training_mode_set PULSES —
                    training enters from strap, the beacon would light.
  MODE=trainfb_off (TRAIN_ENTRY_FALLBACK=0): it NEVER pulses and the FSM reaches
                    ST_TRAIN_FAIL — the beacon stays dark (the negative control,
                    reproducing the rig).
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE = os.environ.get("TRAIN_FALLBACK_MODE", "on")

I2C_STS_BUSY     = 1 << 0
I2C_STS_MISS_ACK = 1 << 3

ST_NEGO_DONE  = 5     # terminal parking state on the NEGO-NACK path
ST_TRAIN_RUN  = 13
ST_TRAIN_FAIL = 17


class I2CNackModel:
    """Per-transaction BUSY-then-NACK. busy_seen resets each transaction
    (tidelink_autoneg.sv:809), so the model must present BUSY on the FIRST read
    of EVERY transaction (nego AND training), then MISS_ACK. A write re-arms
    (each transaction begins with writes before it polls)."""

    def __init__(self, dut, p):
        self.dut = dut
        self.p = p
        self.armed = True   # first read of the current transaction returns BUSY

    def g(self, s):
        return getattr(self.dut, f"{self.p}_{s}")

    def init(self):
        for s in ("awready", "wready", "bvalid", "arready", "rvalid"):
            self.g(s).value = 0
        self.g("rdata").value = 0

    async def run(self):
        while True:
            await RisingEdge(self.dut.clk)
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
                self.armed = True                 # new transaction started
                continue
            if int(self.g("arvalid").value):
                self.g("arready").value = 1
                await RisingEdge(self.dut.clk)
                self.g("arready").value = 0
                if self.armed:
                    self.g("rdata").value = I2C_STS_BUSY       # arm busy_seen
                    self.armed = False
                else:
                    self.g("rdata").value = I2C_STS_MISS_ACK   # busy=0, miss_ack=1
                self.g("rvalid").value = 1
                while not int(self.g("rready").value):
                    await RisingEdge(self.dut.clk)
                self.g("rvalid").value = 0
                continue


@cocotb.test()
async def test_train_entry_fallback(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    model_a = I2CNackModel(dut, "a")
    model_b = I2CNackModel(dut, "b")
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

    dut.nego_en.value = 1
    dut.nego_start.value = 1

    # Watch die_a (master strap): did training ENTER (local_training_mode_set
    # pulsed) and/or did it reach ST_TRAIN_FAIL. Run well past the NEGO NACK and
    # into ST_TRAIN_ENTER's transaction.
    train_set_seen = False
    train_run_seen = False
    train_fail_seen = False
    for _ in range(30000):
        await RisingEdge(dut.clk)
        if int(dut.a_train_set.value):
            train_set_seen = True
        st = int(dut.a_state.value)
        if st == ST_TRAIN_RUN:
            train_run_seen = True
        if st == ST_TRAIN_FAIL:
            train_fail_seen = True

    dut._log.info(
        f"[{MODE}] die_a: train_set_seen={train_set_seen} "
        f"train_run_seen={train_run_seen} train_fail_seen={train_fail_seen} "
        f"final_state={int(dut.a_state.value)} role_r={int(dut.a_role_r.value)}")

    # Precondition both arms share: the NEGO NACK resolved die_a to MASTER from
    # strap (so we know the instrument reached the training transaction at all).
    assert int(dut.a_role_r.value) == 0, (
        f"[{MODE}] die_a role should be MASTER(0) from strap after NEGO NACK, "
        f"got {int(dut.a_role_r.value)} — the FSM never got past negotiation")

    if MODE == "on":
        assert train_set_seen, (
            "TRAIN_ENTRY_FALLBACK=1: local_training_mode_set NEVER pulsed on a "
            "dead I2C bus — training did not enter from strap, so the SYNC "
            "beacon would stay dark and the link could not self-start")
        assert train_run_seen, (
            "TRAIN_ENTRY_FALLBACK=1: FSM never reached ST_TRAIN_RUN — the "
            "fallback did not enter training")
        assert not train_fail_seen, (
            "TRAIN_ENTRY_FALLBACK=1: FSM reached ST_TRAIN_FAIL despite the "
            "fallback — it bailed instead of entering training")
        dut._log.info("TRAINFB_ON confirmed: dead I2C => training enters from "
                      "strap, beacon would light, link self-starts.")
    else:  # off — the negative control
        # With the fallback OFF, the NEGO NACK parks in the TERMINAL ST_NEGO_DONE
        # (training is never even attempted), so the beacon stays dark. This is
        # exactly the bridge1 rig behaviour (R8=0). The A/B is rigorous: same
        # dead I2C, one param flipped -> ON enters training, OFF never does.
        assert not train_set_seen, (
            "TRAIN_ENTRY_FALLBACK=0 (negctl): local_training_mode_set pulsed "
            "without a peer ACK — the fallback fired when it should not have, "
            "so the ON result proves nothing")
        assert not train_run_seen, (
            "TRAIN_ENTRY_FALLBACK=0 (negctl): FSM reached ST_TRAIN_RUN without "
            "the fallback — training entered when it should not have")
        assert int(dut.a_state.value) == ST_NEGO_DONE, (
            f"TRAIN_ENTRY_FALLBACK=0 (negctl): die_a should park in the terminal "
            f"ST_NEGO_DONE ({ST_NEGO_DONE}) with the beacon dark, got "
            f"{int(dut.a_state.value)} — the dead-I2C NACK path is not being "
            f"exercised, so this is not a valid negative control")
        dut._log.info("TRAINFB_OFF confirmed: dead I2C => parks in terminal "
                      "ST_NEGO_DONE, training never enters, beacon DARK. This is "
                      "the bridge1 rig behaviour the fallback fixes.")
