# Diagnostic: trace the word-pin enable write path on the SLAVE controller.
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from test_tidelink_pair_doorbell import PairTB, APB_TIDELINK_BASE

APB_WP_VAL = APB_TIDELINK_BASE + 0x148
APB_WP_EN  = APB_TIDELINK_BASE + 0x14C


def _i(s):
    try:
        return int(s.value)
    except Exception:
        return None


async def _probe_write(tb, ctrl, addr, data, label):
    """Drive an APB write and sample the controller decode signals live."""
    apb = tb.s_apb
    clk = apb._clk
    # Manually drive so we can sample mid-access.
    await RisingEdge(clk)
    apb._psel.value = 1; apb._paddr.value = addr & 0x7FFF
    apb._pwrite.value = 1; apb._pwdata.value = data
    apb._pstrb.value = 0xF; apb._pprot.value = 0; apb._penable.value = 0
    await RisingEdge(clk)
    apb._penable.value = 1
    # sample on the cycle penable is high (access phase)
    for _ in range(50):
        await RisingEdge(clk)
        if int(apb._pready.value):
            break
    # Sample the decode signals NOW (just after pready)
    def g(n):
        try:
            return _i(getattr(ctrl, n))
        except Exception:
            return "N/A"
    tb.log.info(f"[diag {label}] addr=0x{addr:04x} data=0x{data:08x} | "
                f"slv_hit={g('slv_apb_ctrl_hit')} "
                f"apb_ctrl_reg_addr={g('apb_ctrl_reg_addr')} "
                f"apb_ctrl_reg_r10={g('apb_ctrl_reg_r10')} "
                f"ctrl_reg_addr={g('ctrl_reg_addr')} "
                f"ctrl_reg_write={g('ctrl_reg_write')} "
                f"region10_write={g('region10_write')} "
                f"wdata={g('ctrl_reg_wdata')}")
    apb.idle()


@cocotb.test()
async def test_diag(dut):
    tb = PairTB(dut)
    await tb.reset()
    ctrl = dut.u_slave.u_chiplet_controller

    await _probe_write(tb, ctrl, APB_WP_VAL, 0x87654321, "VALUE/slot2")
    await ClockCycles(tb.s_apb._clk, 3)
    tb.log.info(f"[diag] after VALUE write: perlane_r=0x{_i(ctrl.swi_word_pin_perlane_r):08x} "
                f"perlane_en_r=0x{_i(ctrl.swi_word_pin_perlane_en_r):02x}")

    await _probe_write(tb, ctrl, APB_WP_EN, 0x55, "ENABLE/slot3")
    await ClockCycles(tb.s_apb._clk, 3)
    tb.log.info(f"[diag] after ENABLE write: perlane_r=0x{_i(ctrl.swi_word_pin_perlane_r):08x} "
                f"perlane_en_r=0x{_i(ctrl.swi_word_pin_perlane_en_r):02x}")

    # also try reading both back via the normal helper
    rb_v = await tb.s_apb.read(APB_WP_VAL)
    rb_e = await tb.s_apb.read(APB_WP_EN)
    tb.log.info(f"[diag] readback value=0x{rb_v:08x} enable=0x{rb_e:08x}")


@cocotb.test()
async def test_diag_rx_reaches(dut):
    """Write value+enable, then peek gpiorx_N.io_word_pin DIRECTLY (the
    silicon-load-bearing path), independent of the shadowed APB readback."""
    tb = PairTB(dut)
    await tb.reset()
    ctrl = dut.u_slave.u_chiplet_controller
    # value: lane nibble = lane#+1 ; enable EVEN lanes only (0x55)
    await tb.s_apb.write(APB_WP_VAL, 0x8765_4321)
    await tb.s_apb.write(APB_WP_EN,  0x55)
    await ClockCycles(tb.s_apb._clk, 12)
    tb.log.info(f"[rx] regs: perlane_r=0x{_i(ctrl.swi_word_pin_perlane_r):08x} "
                f"perlane_en_r=0x{_i(ctrl.swi_word_pin_perlane_en_r):02x}")
    gpio = ctrl.u_wlink.phy.gpio
    seen = []
    for n in range(8):
        wp = _i(getattr(gpio, f"gpiorx_{n}").io_word_pin)
        seen.append(wp)
    tb.log.info(f"[rx] gpiorx io_word_pin per lane = {[hex(x) for x in seen]}")
    # EVEN lanes enabled -> nibble value; ODD lanes disabled -> 0
    exp = [ (0x8765_4321 >> (4*n)) & 0xF if (0x55>>n)&1 else 0 for n in range(8) ]
    tb.log.info(f"[rx] expected per lane              = {[hex(x) for x in exp]}")
    assert seen == exp, f"RX word_pin mismatch: saw {[hex(x) for x in seen]} exp {[hex(x) for x in exp]}"
    tb.log.info("[rx] PASS: word-pin value reaches gpiorx.io_word_pin in V1 (dedicated port path).")
