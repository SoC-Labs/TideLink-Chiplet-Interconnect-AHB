"""V2 integration gate — a plain external APB write must NOT reach the PTP
servo's cross-die timestamp mailbox (SoC Labs mailbox-RO fix, 2026-07-31).

Background
----------
`tidelink_apb_regs.sv:527` forms `mbox_reg_write = apb_write && (apb_region
== 4'b0011)` with NO source qualifier — it asserts identically for a genuine
FC-sideband (peer) write and for a plain external APB write (CPU/debug).
`cocotb/tidelink_apb_regs/test_mailbox_apb_writeprotect.py` proves that raw
defect at the `tidelink_apb_regs.sv` level (and stays RED there by design —
that module alone cannot distinguish the two sources).

The actual fix lives one level up, in `tidelink_top.sv` (search for
"SoC Labs mailbox-RO fix (2026-07-31)"): it ANDs the raw `mbox_reg_write`
with `fc_cfg_apb_active` — the same 2:1 arbiter signal that already keeps
the peer from writing TXGEN over the link the other direction — and wires
`u_servo.mbox_reg_write` to that gated signal instead of the raw one. Only
writes the arbiter actually granted to the FC RX config path (never an
external/PS/debug access — see `ext_txn`/`ext_lock_q` in tidelink_top.sv)
now reach the servo. This test exercises exactly that integration point,
which the module-level unit test cannot reach.

Observability note: Region 3 (0x2060-0x207C) reads do NOT read back the
mailbox. Per docs/REGISTER_MAP.md and tidelink_apb_regs.sv:523/662-663, ALL
Region-3 reads return `servo_reg_rdata`, and for mbox slot 2 (offset 0x068)
that resolves to `servo_reg_addr = 5+2 = 7` -> `current_frac_r`, a servo
status register, not the mailbox. So there is no clean APB read-back path
for this check; the test observes `mbox_sec_lo_r` directly via a
hierarchical DUT probe (sim-only, fine in cocotb).

No link bring-up is required. `fc_cfg_apb_active` (tidelink_top.sv:907) is
`fc_cfg_apb_psel && !ext_txn && !ext_lock_q`, and `ext_txn` is asserted for
the full duration of our own external APB access — so `fc_cfg_apb_active`
is structurally 0 while our write is in flight, with or without a live FC
link. The only thing under test is whether tidelink_top.sv actually gates
`mbox_reg_write` with that signal before it reaches u_servo.

Run:
    cd cocotb/tidelink_top_pair_v2
    source ../../set_env.sh
    make EPOCH_PROFILE=zero MODULE=test_v2_mbox_apb_writeprotect
"""
import cocotb
from cocotb.triggers import ClockCycles

from pair_v2_common import PairV2TB, APB_TIDELINK_BASE

# Region 3 (Servo status + Timestamp mailbox) base = 3 << 5 = 0x060 within the
# TideLink region. Sub-offset mbox_reg_addr == 2 (paddr[4:2] == 2, i.e. +0x008)
# lands on mbox_sec_lo_r (tidelink_ptp_servo.sv: case 3'h2).
OFF_MBOX_SEC_LO = 0x068
APB_MBOX_SEC_LO = APB_TIDELINK_BASE + OFF_MBOX_SEC_LO   # 0x2068

SENTINEL = 0xDEAD_BEEF


def _mbox_sec_lo(dut, side):
    """Hierarchical probe of the servo's mailbox seconds-low register — the
    only observable path (Region 3 APB reads return servo status, not the
    mailbox; see module docstring).

    ``u_servo`` lives inside a ``generate if (STUB_SERVO == 1'b0)`` block
    named ``gen_servo_real`` (src/rtl/tidelink_top.sv:1907). VCS+cocotb
    expose this as a SINGLE child attribute whose name literally contains a
    dot -- ``"gen_servo_real.u_servo"`` -- so it must be reached with
    ``__getitem__`` (subscript), not dotted ``getattr`` traversal (same
    quirk documented for ``gen_ptp_real.u_ptp`` in
    cocotb/tidelink_top_pair/test_bug_b_phc_saturation.py)."""
    top = dut.u_master if side == "m" else dut.u_slave
    return int(top["gen_servo_real.u_servo"].mbox_sec_lo_r.value)


@cocotb.test()
async def test_external_apb_write_does_not_reach_mailbox(dut):
    """A plain external APB write to the Region-3 mailbox offset (0x2068,
    mbox_reg_addr==2 -> mbox_sec_lo_r) must NOT change the servo's mailbox
    register — only a genuine FC-sideband write (fc_cfg_apb_active=1) may.
    This is the integration-level proof of the mailbox-RO fix applied in
    tidelink_top.sv: the module-level unit test
    (cocotb/tidelink_apb_regs/test_mailbox_apb_writeprotect.py) cannot see
    this fix because it does not instantiate the fc_cfg_apb_active arbiter.
    """
    tb = PairV2TB(dut)
    await tb.reset()
    await ClockCycles(dut.hclk, 20)

    before = _mbox_sec_lo(dut, "m")
    tb.log.info(f"  [mbox] mbox_sec_lo_r before external write = 0x{before:08x}")

    await tb.m_apb.write(APB_MBOX_SEC_LO, SENTINEL)
    await ClockCycles(dut.hclk, 20)

    after = _mbox_sec_lo(dut, "m")
    tb.log.info(f"  [mbox] mbox_sec_lo_r after  external write = 0x{after:08x} "
                f"(external write value was 0x{SENTINEL:08x})")

    assert after == before, (
        f"external APB write to the PTP mailbox (0x{APB_MBOX_SEC_LO:04x}) "
        f"REACHED the servo -- mbox_sec_lo_r changed 0x{before:08x} -> "
        f"0x{after:08x} (wrote 0x{SENTINEL:08x}). This is the mailbox-RO "
        f"defect: an external/debug APB write must never forge the cross-die "
        f"PTP timestamp; only a genuine FC-sideband write "
        f"(fc_cfg_apb_active=1) may update it. If you are seeing this on the "
        f"current tree, the tidelink_top.sv mbox_reg_write_fc_only gate "
        f"(search \"SoC Labs mailbox-RO fix (2026-07-31)\") is missing or "
        f"disconnected from the u_servo instantiation.")
    tb.log.info("  [mbox] PASS: external APB write did NOT reach the PTP "
                "mailbox register (mbox_sec_lo_r unchanged)")
