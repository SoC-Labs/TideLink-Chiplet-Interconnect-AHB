"""CRC-injection matrix: case lists per tier (data only; see run_crc_matrix.py, crc_matrix_core.py).

A case = dict(name, group, build, env).  group: control | mutant | matrix.  build: zero | silicon | l9
(l9 = compile with +define+SOCL_L9_ALWAYS, the pre-TL-059 sideband RTL).  Order inside a tier:
controls (incl. mutant arms) first -- if any control fails the runner reports HARNESS_BROKEN and does
NOT run the matrix, because a green matrix is only meaningful if the instrument is proven to fire,
count, stay selective and go red on a real bug.

Axes (VERIFICATION.md 2.2):  node {sb 0xA1, AW 0x80, W 0x81, B 0x82, AR 0x83, R 0x84}
  x position {first, second, mid, second_to_last, last} (packet index inside the stream; followers = packets after it)
  x stream size {S: 4 pkts, L: 16 pkts / 8 ops, X: 32 pkts / 16 ops (> replay window)}
  x direction {ab, ba}  (sb only: the slave die's ahb_sub is tied off, so AXI is master-initiated = ab;
                         AW/W/AR transmit m->s, B/R transmit s->m, so both link directions are exercised)
  x spacing {0, 4, 16, 256, 2048 hclk between words/ops}  x profile {zero, silicon (S2M epoch skew, EPOCH_ANCHOR=1)}
Reads (AR/R) are single-outstanding at the AHB master, so they never have followers inside the replay
window: position/size only select which of N sequential reads is hit.
"""

DEFAULT_GAP = 4


def _c(name, group, build, **env):
    env = {k if k.startswith("CM_") else "CM_" + k: str(v) for k, v in env.items()}
    return dict(name=name, group=group, build=build, env=env)


def _shot(node, pos, size="L", gap=DEFAULT_GAP, d="ab", build="zero", byte=5, bit=0, group="matrix", expect="EXACT"):
    n = f"{node}_{d}_{pos}_{size}_g{gap}_{build}" + (f"_b{byte}.{bit}" if (byte, bit) != (5, 0) else "")
    return _c(n, group, build, KIND="shot", NODE=node, DIR=d, POS=pos, SIZE=size, GAP=gap, BYTE=byte, BIT=bit,
              EXPECT=expect, NAME=n)


def controls(mutants=True, axi_mutant=False):
    c = [
        _c("ctl_ship_default", "control", "zero", KIND="ctl_ship_default", NODE="sb", NAME="ctl_ship_default"),
        _c("ctl_readback", "control", "zero", KIND="ctl_readback", NODE="sb", NAME="ctl_readback"),
        _c("ctl_live_sb", "control", "zero", KIND="ctl_live", NODE="sb", SIZE="S", NAME="ctl_live_sb"),
        _c("ctl_live_W", "control", "zero", KIND="ctl_live", NODE="W", SIZE="S", NAME="ctl_live_W"),
        _c("ctl_inert_sb", "control", "zero", KIND="ctl_inert", NODE="sb", SIZE="S", NAME="ctl_inert_sb"),
        _c("ctl_inert_W", "control", "zero", KIND="ctl_inert", NODE="W", SIZE="S", NAME="ctl_inert_W"),
        _c("ctl_detect_sense_sb", "control", "zero", KIND="ctl_detect_sense", NODE="sb", SIZE="L",
           POS="first", NAME="ctl_detect_sense_sb"),
        _c("ctl_detect_sense_W", "control", "zero", KIND="ctl_detect_sense", NODE="W", SIZE="L",
           POS="first", NAME="ctl_detect_sense_W"),
        _c("ctl_counts_sb", "control", "zero", KIND="ctl_counts", NODE="sb", SIZE="L", NAME="ctl_counts_sb"),
    ]
    if mutants:
        # sideband: pre-fix RTL (L9b/L9c live with CRC on).  first/mid have followers inside the NACK window
        # and must go red; 'last' is documented to stay EXACT on the buggy RTL and is not asserted here.
        c += [
            _shot("sb", "first", build="l9", group="mutant", expect="NOT_EXACT"),
            _shot("sb", "mid", build="l9", group="mutant", expect="NOT_EXACT"),
        ]
    if axi_mutant:
        # AXI: pre-Fix-G RTL (socl_l7_reached_link_data forced 0 => forgive armed forever: a detected error
        # never NACKs), applied as a runtime Force inside the zero build.
        for node in ("W", "AW", "B", "AR", "R"):
            x = _shot(node, "first", group="mutant", expect="NOT_EXACT")
            x["name"] = x["env"]["CM_NAME"] = "mut_fixg_" + x["name"]
            x["env"]["CM_MUTANT"] = "fixg_off"
            c.append(x)
    return c


def quick():
    """~5 matrix cases (+ controls & the sideband mutant arm); budget < 6 min incl. both compiles."""
    return controls(mutants=True, axi_mutant=False) + [
        _shot("sb", "first"),                       # THE TL-059 case: corrupted packet with followers
        _shot("sb", "mid", d="ba"),
        _shot("sb", "last"),
        _shot("W", "first"),                        # AXI write data, posted-write followers
        _shot("R", "mid"),                          # AXI read return path
    ]


def gate():
    """~24 matrix cases + controls (all five AXI mutants + the sideband mutant arm)."""
    m = []
    for d in ("ab", "ba"):
        for pos in ("first", "mid", "second_to_last", "last"):
            m.append(_shot("sb", pos, d=d))
    m += [_shot("sb", "first", gap=0), _shot("sb", "first", gap=256),
          _shot("sb", "first", d="ab", build="silicon"), _shot("sb", "first", d="ba", build="silicon")]
    m += [_shot("AW", "first"), _shot("W", "first"), _shot("W", "mid"), _shot("W", "last"),
          _shot("B", "first"), _shot("B", "mid"),
          _shot("AR", "first", size="S"), _shot("R", "first", size="S"), _shot("R", "last", size="S"),
          _shot("W", "first", build="silicon"), _shot("B", "first", build="silicon")]
    return controls(mutants=True, axi_mutant=True) + m


def nightly():
    """Larger set (~220): full cross on sideband (dirs x 5 pos x 3 sizes x gaps), AW/W (5 pos x gaps), B, reads,
    plus the silicon profile and byte/bit variants."""
    m = []
    for d in ("ab", "ba"):
        for pos in ("first", "second", "mid", "second_to_last", "last"):
            for gap in (0, 16, 256, 2048):
                m.append(_shot("sb", pos, size="L", gap=gap, d=d))
            for size in ("S", "X"):
                m.append(_shot("sb", pos, size=size, gap=DEFAULT_GAP, d=d))
            m.append(_shot("sb", pos, size="L", d=d, build="silicon"))
            m.append(_shot("sb", pos, size="L", gap=256, d=d, build="silicon"))
    for node in ("W", "AW"):
        for pos in ("first", "second", "mid", "second_to_last", "last"):
            for gap in (0, 16, 256, 2048):
                m.append(_shot(node, pos, size="L", gap=gap))
    for pos in ("first", "second", "mid", "second_to_last", "last"):
        for gap in (0, 256):
            m.append(_shot("B", pos, size="L", gap=gap))
        m.append(_shot("W", pos, size="X"))
    for node in ("AR", "R"):
        for pos in ("first", "mid", "last"):
            for size in ("S", "L"):
                m.append(_shot(node, pos, size=size))
    for node in ("W", "B", "R"):
        for pos in ("first", "mid", "last"):
            m.append(_shot(node, pos, build="silicon"))
    for byte, bit in ((4, 0), (8, 3), (11, 7)):
        m.append(_shot("sb", "first", byte=byte, bit=bit))
        m.append(_shot("W", "first", byte=byte, bit=bit))
    return controls(mutants=True, axi_mutant=True) + m


TIERS = dict(quick=quick, gate=gate, nightly=nightly)
