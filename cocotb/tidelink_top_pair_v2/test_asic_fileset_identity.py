"""Runtime proof of WHICH physical file was compiled for each shadowed module.

WHY THIS EXISTS
---------------
`flists/tidelink_top_full_asic_v2.flist` (tapeout) and
`flists/tidelink_fpga_v2.flist` (every cocotb suite until 2026-08-26) resolve
eight modules to DIFFERENT files on disk.  Five are the AXI-path flow-control
state machines WlinkGenericFCSM{,_1.._4}: the FPGA flist takes the SoC Labs
recovery copies in src/rtl/local_overrides/, the ASIC flist takes the
recovery-STRIPPED deps/ copies.

A flist line is not evidence.  A VCS "Parsing design file" line is better but
is still build-time text.  This test asks the ELABORATED DESIGN ITSELF, at
simulation runtime, which variant is present -- so `make ASIC_FLIST=1` cannot
silently fall back to the FPGA twin (stale simv, a `?=` losing to the
environment, a flist edit) without turning this test red.

MARKERS
-------
recovery-present (local_overrides):  socl_l7_wdog_force_clear, socl_l6_cr_emit_count,
                                     socl_l7_crack_emit_count, socl_reack_idle_cnt
recovery-absent  (deps, ASIC):       none of the above exist as handles
SRAM: ASIC tidelink_sram instantiates rf_16k as `u_rf`;
      FPGA tidelink_sram instantiates cmsdk_fpga_sram as `u_sram`.

Both arms carry a MUST-BE-PRESENT control (`state`, and the FC node itself),
so "marker absent" can never be satisfied by a mistyped hierarchy path.

RUN BOTH WAYS:
    make ASIC_FLIST=1 EPOCH_PROFILE=zero MODULE=test_asic_fileset_identity
    make ASIC_FLIST=0 EPOCH_PROFILE=zero MODULE=test_asic_fileset_identity
The expectation is taken from the ASIC_FLIST environment variable, so the two
runs assert OPPOSITE things and a build that ignored the knob fails one of them.
"""
import os
import cocotb

AXI_FC_NODES = [
    "wlink_axiawFC",   # WlinkGenericFCSM    (AW)
    "wlink_axiwFC",    # WlinkGenericFCSM_1  (W)
    "wlink_axibFC",    # WlinkGenericFCSM_2  (B)
    "wlink_axiarFC",   # WlinkGenericFCSM_3  (AR)
    "wlink_axirFC",    # WlinkGenericFCSM_4  (R)
]

# Present ONLY in src/rtl/local_overrides/WlinkGenericFCSM*.v (16 socl_ signals);
# `grep -c socl_` on the deps/ copies is 0.
RECOVERY_MARKERS = [
    "socl_l6_cr_emit_count",      # Fix B  min CR-emit gate, state-1 exit
    "socl_l7_crack_emit_count",   # Fix C  min CRACK-emit gate, state-2 exit
    "socl_l7_bringup_forgive",    # Fix A  sticky-NACK bring-up forgive
    "socl_l7_wdog_force_clear",   # Fix D / TL-033 state-7 emit-starvation watchdog
    "socl_reack_idle_cnt",        # Fix E  periodic cumulative-ACK re-emit
]


def _expect_asic():
    return os.environ.get("ASIC_FLIST", "0") == "1"


def _node(dut, side, inst):
    top = dut.u_master if side == "m" else dut.u_slave
    return getattr(top.u_chiplet_controller.u_wlink.axi2wl, inst)


def _has(handle, attr):
    try:
        getattr(handle, attr)
        return True
    except AttributeError:
        return False


@cocotb.test()
async def test_fcsm_fileset_identity(dut):
    """Every AXI FC node must carry the recovery markers iff the FPGA flist was
    compiled, and must lack ALL of them iff the ASIC (tapeout) flist was."""
    asic = _expect_asic()
    dut._log.info(f"ASIC_FLIST={os.environ.get('ASIC_FLIST', '0')} -> expecting "
                  f"{'deps/ RECOVERY-STRIPPED' if asic else 'local_overrides RECOVERY'} FCSM 0-4")

    bad = []
    for side in ("m", "s"):
        for inst in AXI_FC_NODES:
            node = _node(dut, side, inst)
            # MUST-BE-PRESENT CONTROL: if `state` is missing the path is wrong
            # and every "marker absent" result below would be vacuous.
            assert _has(node, "state"), (
                f"CONTROL FAILED: {side}.{inst}.state not found -- hierarchy path "
                f"is wrong, so this test proves nothing. Fix the path.")
            for m in RECOVERY_MARKERS:
                present = _has(node, m)
                if asic and present:
                    bad.append(f"{side}.{inst}.{m} PRESENT but ASIC flist was requested "
                               f"(the deps/ copy has no socl_ signals) -> the FPGA twin "
                               f"was compiled")
                if (not asic) and (not present):
                    bad.append(f"{side}.{inst}.{m} ABSENT but FPGA flist was requested "
                               f"-> the deps/ copy was compiled")
    assert not bad, "FILE-SET IDENTITY MISMATCH:\n  " + "\n  ".join(bad)

    n = len(AXI_FC_NODES) * 2
    if asic:
        dut._log.info(
            f"PROVEN: all {n} AXI FC node instances lack all {len(RECOVERY_MARKERS)} "
            f"recovery markers => deps/axi-chiplet-controller/logical/wlink/"
            f"WlinkGenericFCSM{{,_1.._4}}.v (the files that tape out) are compiled.")
    else:
        dut._log.info(
            f"PROVEN: all {n} AXI FC node instances carry all {len(RECOVERY_MARKERS)} "
            f"recovery markers => src/rtl/local_overrides/WlinkGenericFCSM{{,_1.._4}}.v "
            f"(the FPGA twins) are compiled -- this is what every other suite runs.")


@cocotb.test()
async def test_sram_fileset_identity(dut):
    """The FIFO SRAM wrapper must be the ASIC rf_16k variant iff ASIC_FLIST=1."""
    asic = _expect_asic()
    sram = dut.u_master.u_tidelink_fifo.u_fifo_mem.u_sram
    has_rf = _has(sram, "u_rf")        # asic/tidelink_sram.sv  -> rf_16k u_rf
    has_bram = _has(sram, "u_sram")    # fpga/tidelink_sram.sv  -> cmsdk_fpga_sram u_sram
    # MUST-BE-PRESENT CONTROL: exactly one of the two must exist; if neither
    # does, the hierarchy path is wrong and the assertion below is vacuous.
    assert has_rf != has_bram, (
        f"CONTROL FAILED: rf_16k present={has_rf}, cmsdk_fpga_sram present={has_bram} "
        f"-- expected exactly one. Hierarchy path is wrong.")
    if asic:
        assert has_rf, "ASIC flist requested but the cmsdk_fpga_sram (FPGA) wrapper compiled"
        dut._log.info("PROVEN: src/rtl/fifo/asic/tidelink_sram.sv (rf_16k) compiled.")
    else:
        assert has_bram, "FPGA flist requested but the rf_16k (ASIC) wrapper compiled"
        dut._log.info("PROVEN: src/rtl/fifo/fpga/tidelink_sram.sv (cmsdk_fpga_sram) compiled.")
