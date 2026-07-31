# KR260 compute-chiplet-flip (die_b) target — build notes

This is the **die_b / FLIP** half of the KR260 compute-chiplet pair. See the die_a
target `../kr260-compute-chiplet/BUILD_NOTES.md` for the full port map, the
compute-vs-eth deltas, the build order, and the complete `SCOPING-TODO` list — all
of which apply here unchanged.

> **FIRST-CUT SCAFFOLD** — not yet through a Vivado build. Same status as die_a.

## What differs from die_a

The flip target is a **true mirror** of die_a, differing in exactly TWO places:

1. **XDC — TX/RX ball swap.** `kr260_compute_chiplet_tidelink.xdc` (the constraints
   agent's deliverable) swaps the J21 ribbon TX and RX ball-sets so that die_b's TX
   lands on die_a's RX balls and vice-versa (straight-through ribbon between the two
   boards). The timing and drc XDC are identical to die_a.
2. **Role strap default = 1.** `tidelink_design.tcl` here sets the link-0 role-strap
   xlconstant `CONFIG.CONST_VAL {1}` (die_a uses `0`), so die_b comes up as the
   opposite role. This pins the pair's roles deterministically while finding G1
   (per-die DEVICE_CLASS strapping) is still open — do not rely on auto-election.

`tidelink_design_wrapper.v` and `tidelink_phy_clk_div2.v` are **byte-identical** to
die_a (the BD tcl is shared-style; the flip is selected by the target dir the
Makefile picks).

**Pair the die_a image with this die_b image** — the same image on both boards
shorts every ribbon lane.

## Build

```
make -C ../.. build_design TARGET=kr260-compute-chiplet-flip
```

(from `fpga/`: `make build_design TARGET=kr260-compute-chiplet-flip`)
