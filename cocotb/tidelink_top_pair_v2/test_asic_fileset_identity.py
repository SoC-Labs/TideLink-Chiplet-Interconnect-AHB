"""Runtime proof of WHICH physical file was compiled for each shadowed module.

WHY THIS EXISTS
---------------
`flists/tidelink_top_full_asic_v2.flist` (tapeout) and `flists/tidelink_fpga_v2.flist` (every cocotb suite until
2026-08-26) used to resolve eight modules to DIFFERENT files on disk.  Five were the AXI-path flow-control state
machines WlinkGenericFCSM{,_1.._4}: the FPGA flist took the SoC Labs recovery copies in src/rtl/local_overrides/, the
ASIC flist the recovery-STRIPPED deps/ copies.

TL-018/TL-019 (2026-10, David's decision): the tapeout flist now takes the SAME hardened local_overrides FC nodes as
the FPGA flist, with link CRC ON at reset.  So the expectation is now the SAME on both arms: every AXI FC node carries
all recovery markers AND resets out_prepend_swi_disable_crc to 0.  Only the SRAM wrapper still differs by flist.

A flist line is not evidence, and a VCS "Parsing design file" line is build-time text.  This test asks the ELABORATED
DESIGN ITSELF, at simulation runtime, which variant is present -- so `make ASIC_FLIST=1` cannot silently fall back
to deps (stale simv, a `?=` losing to the environment, a flist edit) without turning this test red.

MARKERS
-------
recovery-present (local_overrides):  socl_l7_wdog_force_clear, socl_l6_cr_emit_count,
                                     socl_l7_crack_emit_count, socl_reack_idle_cnt, socl_l7_bringup_forgive
recovery-absent  (deps):             none of the above exist as handles
CRC: out_prepend_swi_disable_crc == 0 on all 10 nodes right after reset (CRC checking ON).
SRAM: ASIC tidelink_sram instantiates rf_16k as `u_rf`; FPGA tidelink_sram cmsdk_fpga_sram as `u_sram`.

Both arms carry a MUST-BE-PRESENT control (`state`, and the FC node itself), so "marker absent" can never be satisfied
by a mistyped hierarchy path.

RUN (positive, both flists) and the MUTANT (must FAIL -- the gate checks rc != 0 and the message):
    make ASIC_FLIST=1 EPOCH_PROFILE=zero MODULE=test_asic_fileset_identity
    make ASIC_FLIST=0 EPOCH_PROFILE=zero MODULE=test_asic_fileset_identity
    make ASIC_FLIST=1 ASIC_FCSM_DEPS=1 EPOCH_PROFILE=zero MODULE=test_asic_fileset_identity   # expect FAIL
The expectation of the SRAM test comes from ASIC_FLIST; the FC-node test always expects the hardened local file.
"""
import os
import cocotb

from pair_v2_common import PairV2TB

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
    """Every AXI FC node must carry ALL the recovery markers (local_overrides copy), on the ASIC and the FPGA flist
    alike (TL-018/TL-019).  Also asserts the CRC-ON reset value (bit16 of SM_CONTROL = 0)."""
    dut._log.info(f"ASIC_FLIST={os.environ.get('ASIC_FLIST', '0')} ASIC_FCSM_DEPS="
                  f"{os.environ.get('ASIC_FCSM_DEPS', '0')} -> expecting local_overrides FCSM 0-4 on both flists")

    tb = PairV2TB(dut)
    await tb.reset()          # reset values are only defined after the POR (reg is X before it)
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
                if not _has(node, m):
                    bad.append(f"{side}.{inst}.{m} ABSENT -- the recovery-stripped deps/ copy was compiled "
                               f"(TL-019: the tapeout flist must take src/rtl/local_overrides/)")
            # TL-018: CRC ON at reset.  Hierarchy-probed value; a missing handle is itself a failure.
            if not _has(node, "out_prepend_swi_disable_crc"):
                bad.append(f"{side}.{inst}.out_prepend_swi_disable_crc missing (control)")
            else:
                v = int(getattr(node, "out_prepend_swi_disable_crc").value)
                if v != 0:
                    bad.append(f"{side}.{inst}.out_prepend_swi_disable_crc={v} after reset (TL-018: must be 0, CRC ON)")
    assert not bad, "FILE-SET IDENTITY MISMATCH:\n  " + "\n  ".join(bad)

    n = len(AXI_FC_NODES) * 2
    dut._log.info(
        f"PROVEN: all {n} AXI FC node instances carry all {len(RECOVERY_MARKERS)} recovery markers and reset "
        f"CRC ON => src/rtl/local_overrides/WlinkGenericFCSM{{,_1.._4}}.v are compiled "
        f"(ASIC_FLIST={os.environ.get('ASIC_FLIST', '0')}).")


@cocotb.test()
async def test_sram_fileset_identity(dut):
    """The FIFO SRAM wrapper must be the ASIC rf_16k variant iff ASIC_FLIST=1."""
    asic = _expect_asic()
    sram = dut.u_master.u_tidelink_fifo.u_fifo_mem.u_sram
    # asic/tidelink_sram.sv selects the macro from AW (TL-057): rf_16k sits under
    # gen_rf_16k, rf_08k under gen_rf_08k, each as `u_rf`. VCS exposes the
    # generate scope flattened (child key "gen_rf_16k.u_rf"); other simulators
    # nest it. Accept either, never a bare prefix match.
    sram._discover_all()
    kids = set(sram._sub_handles.keys())
    has_rf = any(f"{g}.u_rf" in kids or (_has(sram, g) and _has(getattr(sram, g), "u_rf"))
                 for g in ("gen_rf_16k", "gen_rf_08k"))
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
