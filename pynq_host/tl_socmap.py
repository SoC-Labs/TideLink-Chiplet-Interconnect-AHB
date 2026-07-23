#!/usr/bin/env python3
# =============================================================================
# tl_socmap.py — single source of truth for TideLink host-side address
#                relocation across SoC targets. NO pynq dependency (importable
#                on a dev box, on a board, and from a unit test).
#
# WHY THIS EXISTS (hardware-safety, 2026-07-16)
# ---------------------------------------------
# fpga/docs/KR260_PORT.md told operators they could bring up a KR260 by
# exporting the DATA-plane overrides:
#
#     TIDELINK_TX_BASE=0xA4000000 TIDELINK_RXFIFO_BASE=0xA4010000
#
# That is a TRAP. Those two vars only move the data plane. Every CONTROL-plane
# literal (tl39.py alone carries ~30 of them at 0x4403_xxxx) stayed pointed at
# the Z2 map. On the KR260 (Zynq UltraScale+) 0x0000_0000..0x7FFF_FFFF is DDR
# and 0x4403_xxxx is UNDECODED — an access there is an AXI transaction with no
# responder and NO TIMEOUT: the PS hangs hard and needs a power-cycle. Same
# failure class as the documented bootpy/base.bit incident.
#
# So the control plane, not the data plane, is the thing that MUST relocate.
# `TIDELINK_SOC` (already implemented in overlay.py / bare_overlay.py /
# tl_poke.py) is the only mechanism that can move it, and is therefore the
# authoritative one. TIDELINK_TX_BASE / TIDELINK_RXFIFO_BASE remain honoured as
# NARROW data-plane overrides (five existing tools read them and live runbooks
# set them), but they are cross-checked against TIDELINK_SOC and can never be a
# substitute for it.
#
# Z2 IS BYTE-IDENTICAL BY CONSTRUCTION
# ------------------------------------
# On z2 (the default, and the certified platform) `remap()` is a literal
# identity — `return addr`, no table lookup, no validation, no env read. There
# is no code path by which selecting the default can change a Z2 address. Only
# a non-default TIDELINK_SOC engages the table.
#
# FAIL LOUD
# ---------
# * unknown TIDELINK_SOC value            -> SocMapError (never silently z2)
# * address outside every known aperture, on a relocating SoC -> SocMapError
# * TIDELINK_TX_BASE/RXFIFO_BASE disagreeing with TIDELINK_SOC -> SocMapError
# A wrong address on ZynqMP is an unrecoverable bus hang; a loud error is free.
# =============================================================================

import os

__all__ = ["SocMapError", "resolve_soc", "remap", "tx_base", "rxfifo_base",
           "APERTURES", "KR260_ALIASES", "Z2_ALIASES", "describe"]


class SocMapError(RuntimeError):
    """Raised on any missing/ambiguous/inconsistent SoC address config.

    NEVER catch this and fall back to a default map — the whole point is to
    stop before an undecoded access hangs the bus.
    """


# TIDELINK_SOC accepted values. Kept in step with pynq_host/overlay.py.
KR260_ALIASES = ("kr260", "kria", "mpsoc", "zynqmp", "kv260")
Z2_ALIASES = ("z2", "pynq-z2", "pynq_z2", "zynq7", "zynq")

# ---------------------------------------------------------------------------
# Aperture table — Z2 base -> KR260 base. From fpga/docs/KR260_PORT.md and
# fpga/targets/kr260-pair-*/tidelink_design.tcl.
#
# Sizes are the DOC's aperture sizes, deliberately: ahb_sub is 64 MB, so it
# spans 0x4000_0000..0x43FF_FFFF and does NOT swallow the 0x4403_xxxx APB
# aperture. The table is therefore unambiguous — no address matches two rows.
#
# The `*_legacy` rows are the pre-GP1-split (2026-06-12) data apertures that
# overlay.py still uses as its z2 defaults; they collapse onto the same KR260
# data windows, matching overlay.py's KR260 map exactly.
#
#          name              z2_base       kr260_base    size
# ---------------------------------------------------------------------------
APERTURES = (
    ("ahb_sub",          0x4000_0000, 0x8000_0000, 0x0400_0000),  # 64 MB, HPM0_LPD
    ("ahb_tx_legacy",    0x4400_0000, 0xA400_0000, 0x0001_0000),  # pre-GP1-split
    ("ahb_fifo_legacy",  0x4401_0000, 0xA401_0000, 0x0001_0000),  # pre-GP1-split
    ("ahb_ptp",          0x4402_0000, 0x8402_0000, 0x0000_1000),
    ("apb",              0x4403_0000, 0x8403_0000, 0x0000_8000),  # unified config
    ("strap_gpio",       0x4404_0000, 0x8404_0000, 0x0000_1000),
    ("debug_unlock_gpio", 0x4404_1000, 0x8404_1000, 0x0000_1000),
    ("phc_apb",          0x4405_0000, 0x8405_0000, 0x0000_1000),  # -ptp only
    ("ahb_tx",           0x8400_0000, 0xA400_0000, 0x0001_0000),  # GP1 data
    ("ahb_fifo",         0x8401_0000, 0xA401_0000, 0x0001_0000),  # GP1 data
)

_TRUE_DEFAULT_SOC = "z2"


def resolve_soc(env=None):
    """Return 'z2' or 'kr260'. Raise SocMapError on an unrecognised value.

    Unset -> 'z2', preserving today's behaviour exactly.
    """
    env = os.environ if env is None else env
    raw = env.get("TIDELINK_SOC")
    if raw is None or raw == "":
        return _TRUE_DEFAULT_SOC
    v = raw.strip().lower()
    if v in KR260_ALIASES:
        return "kr260"
    if v in Z2_ALIASES:
        return "z2"
    raise SocMapError(
        "TIDELINK_SOC=%r is not a recognised SoC.\n"
        "  KR260 aliases: %s\n"
        "  Z2 aliases   : %s\n"
        "Refusing to guess an address map: a wrong base on ZynqMP is an\n"
        "unrecoverable AXI hang (power-cycle to recover)."
        % (raw, ", ".join(KR260_ALIASES), ", ".join(Z2_ALIASES))
    )


def remap(addr, env=None, what="address"):
    """Relocate a Z2 address literal onto the selected SoC.

    On z2 (default) this is a pure identity: the argument is returned
    unchanged, with no table lookup and no validation. Z2 CANNOT regress.

    On a relocating SoC, `addr` must fall inside a known Z2 aperture or
    SocMapError is raised — an unrelocated literal would be an undecoded
    access, i.e. a bus hang.
    """
    soc = resolve_soc(env)
    if soc == "z2":
        return addr                      # identity — byte-identical to pre-2026-07-16

    for name, z2b, socb, size in APERTURES:
        if z2b <= addr < z2b + size:
            return socb + (addr - z2b)

    raise SocMapError(
        "TIDELINK_SOC=%s but %s 0x%08X is not inside any known Z2 aperture,\n"
        "so it cannot be relocated. On the KR260 an unrelocated Z2 literal is\n"
        "UNDECODED -> AXI hang with no timeout (power-cycle to recover).\n"
        "Known Z2 apertures:\n%s"
        % (soc, what, addr,
           "\n".join("  %-18s 0x%08X..0x%08X" % (n, b, b + s - 1)
                     for n, b, _, s in APERTURES))
    )


def _data_base(env, var, z2_default, what):
    """Resolve a data-plane base honouring the legacy TIDELINK_*_BASE override.

    Precedence and safety:
      * override unset -> remap(z2_default): TIDELINK_SOC alone does the right
        thing on every target.
      * override set   -> it wins, but MUST agree with what TIDELINK_SOC
        implies, otherwise SocMapError. This is what stops the documented
        "just export TIDELINK_TX_BASE" recipe from half-configuring a KR260.
    """
    env = os.environ if env is None else env
    expected = remap(z2_default, env, what)
    raw = env.get(var)
    if raw is None or raw == "":
        return expected
    try:
        val = int(raw, 0) if not raw.strip().lower().startswith("0x") \
            else int(raw, 16)
    except ValueError:
        raise SocMapError("%s=%r is not a parseable integer address." % (var, raw))
    if val != expected:
        raise SocMapError(
            "%s=0x%08X contradicts TIDELINK_SOC=%s, which puts %s at 0x%08X.\n"
            "Refusing to run half-configured: mixing a hand-set data base with a\n"
            "control plane resolved from TIDELINK_SOC is exactly how an operator\n"
            "ends up poking Z2 control addresses on a KR260 (AXI hang).\n"
            "Fix: unset %s and let TIDELINK_SOC drive the whole map."
            % (var, val, resolve_soc(env), what, expected, var)
        )
    return val


def tx_base(z2_default=0x8400_0000, env=None):
    """AHB_TX data aperture base for the selected SoC."""
    return _data_base(env, "TIDELINK_TX_BASE", z2_default, "ahb_tx")


def rxfifo_base(z2_default=0x8401_0000, env=None):
    """RX FIFO data aperture base for the selected SoC."""
    return _data_base(env, "TIDELINK_RXFIFO_BASE", z2_default, "ahb_fifo")


def describe(env=None):
    """One-line human summary — for tool banners."""
    return "TIDELINK_SOC=%s" % resolve_soc(env)


if __name__ == "__main__":
    # Self-describing dump: `python3 tl_socmap.py` prints the resolved map.
    import sys
    try:
        soc = resolve_soc()
    except SocMapError as e:
        print("ERROR: %s" % e, file=sys.stderr)
        sys.exit(2)
    print("TIDELINK_SOC=%s" % soc)
    for name, z2b, _socb, size in APERTURES:
        print("  %-18s z2 0x%08X -> 0x%08X  (%d KB)"
              % (name, z2b, remap(z2b), size // 1024))
