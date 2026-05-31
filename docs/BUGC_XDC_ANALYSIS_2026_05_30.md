# Bug C — XDC / Physical-pin Asymmetry Audit (2026-05-30)

Audit of FPGA-target XDC + tidelink_design.tcl files for `pynq-z2-pair-all`
(master / die_a / non-flip) vs `pynq-z2-pair-flip-all` (slave / die_b /
flip) to look for pin, bank, I/O-standard, pull, clock-routing, IDELAY or
timing-constraint asymmetry that could explain the S->M doorbell-delivery
bug (master `REG_DOORBELL_RESP_ACC` stays 0 while M->S saturates).

Files audited:
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc`
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_timing.xdc`
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_drc.xdc`
- `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink_idelay.xdc`
- `fpga/targets/pynq-z2-pair-all/tidelink_design.tcl`
- `fpga/targets/pynq-z2-pair-all/tidelink_design_wrapper.v`
- `fpga/targets/pynq-z2-pair-flip-all/` — same five
- `fpga/targets/pynq-z2-pair-{,flip-}all/ribbon_wiring.md` (FYI)

---

## 1. Executive summary

XDC asymmetry between the two paired targets is small and well-explained
by the flip convention. All 18 link lanes, 4 LEDs and the PMOD-B trigger
live on bank 35 + bank 13 LVCMOS33 on BOTH bitstreams; every port shares
the same IOSTANDARD/SLEW/DRIVE/PULLTYPE attribute set, with the same
LVCMOS33 / SLEW=FAST / DRIVE=8 on every TX pin and bare LVCMOS33 (no
explicit drive / pull) on every RX pin. The forwarded-clock topology is
intentionally mirrored: pair-all uses `pad_clk_tx=Y9 SRCC` /
`pad_clk_rx=Y7 MRCC`, the flip target uses `pad_clk_tx=Y7 MRCC` /
`pad_clk_rx=Y9 SRCC`, so end-to-end the master->slave forwarded clock
travels MRCC->SRCC and the slave->master forwarded clock travels MRCC->SRCC.
That gives BOTH receivers an SRCC-rooted input clock. SRCC has weaker
clock distribution than MRCC and the timing-XDC header explicitly calls
this out ("slave is always the unlucky side"), bounded by `set_bus_skew
2.0 ns`. Source-sync constraints, IDELAY group, false-path on
CNTVALUEIN, IOB rules, clock-group async cut, AHB-loop waiver, and PMOD-B
IOBUF wrapper are bit-identical (modulo formatting + comments). No
asymmetric pull, no asymmetric drive, no missing constraint, no
asymmetric Pmod conflict (all 18 lanes are off Pmod-A-shared balls in BOTH
bitstreams). XDC is NOT a plausible root cause of bug C — the bug is in
the RTL doorbell/credit/FCSM path, not the pin map.

---

## 2. XDC diff matrix

| Category                            | pair-all (master) | pair-flip-all (slave) | Functional difference? |
|-------------------------------------|-------------------|-----------------------|------------------------|
| `pad_clk_tx` PACKAGE_PIN            | Y9 (SRCC, P)      | Y7 (MRCC, P)          | NO — pad swap for 1:1 ribbon |
| `pad_clk_rx` PACKAGE_PIN            | Y7 (MRCC, P)      | Y9 (SRCC, P)          | NO — pad swap for 1:1 ribbon |
| `pad_tx[0..7]` PACKAGE_PIN          | F19,V10,V8,W10,B20,W8,V6,W9 | U7,C20,Y8,A20,U8,W6,Y6,V7 | NO — pad swap for 1:1 ribbon |
| `pad_rx[0..7]` PACKAGE_PIN          | U7,C20,Y8,A20,U8,W6,Y6,V7   | F19,V10,V8,W10,B20,W8,V6,W9 | NO — pad swap for 1:1 ribbon |
| TX IOSTANDARD / SLEW / DRIVE        | LVCMOS33 FAST 8   | LVCMOS33 FAST 8       | identical |
| RX IOSTANDARD                       | LVCMOS33          | LVCMOS33              | identical |
| RX SLEW / DRIVE / pull              | (default)         | (default)             | identical (no pull on either side) |
| `pmod_b_trig` ball / IOSTANDARD / pull | Y16 / LVCMOS33 / PULLDOWN | Y16 / LVCMOS33 / PULLDOWN | identical |
| `led{0,1,2,3}` ball / IOSTANDARD    | R14,P14,N16,M14 / LVCMOS33 | identical | identical |
| `set_output_delay` window (TX eye)  | +/-5 ns vs `pad_clk_tx_fwd` | +/-5 ns vs `pad_clk_tx_fwd` | identical |
| `set_input_delay` (RX)              | -4..+4 ns vs `pad_clk_rx`   | -4..+4 ns vs `pad_clk_rx`   | identical |
| `set_max_delay -datapath_only` (RX) | 8.000 ns          | 8.000 ns              | identical |
| `set_bus_skew` (RX)                 | 2.000 ns          | 2.000 ns              | identical |
| `set_clock_groups -async` hclk/rx   | yes               | yes                   | identical |
| AHB combinatorial-loop waiver       | u_xhb_sub/u_resp/* | u_xhb_sub/u_resp/*   | identical |
| IDELAY xdc (idelay_group, false_path on CNTVALUEIN, IOB FALSE on pad_rx) | full file | full file | byte-identical except header `pair-all` -> `pair-flip-all` |
| `pad_clk_tx_fwd` generated clock    | sourced from `tidelink_design_i/clk_wiz_0/clk_out1`, /1 | identical | identical |
| `CFGBVS` / `CONFIG_VOLTAGE`         | set                | NOT set in flip XDC   | (cosmetic — bitstream defaults handle it; both boards configure successfully) |
| `set_property IOB TRUE` on pad_rx[*] (timing XDC) | yes | yes  | identical |
| DRC XDC                             | 25 lines core + ~290 lines of debug-core connect_debug_port (PHC ILA) | 25 lines core only — NO debug-core stanza | **Difference: only the master target has the PHC ILA wired in; flip has none.** Both targets DO have the same `ALLOW_COMBINATORIAL_LOOPS` waiver. |

The DRC-file size delta is the only non-trivial diff: the master's
`pynq_z2_tidelink_drc.xdc` carries the ILA probe stanza for PHC debug.
That ILA does not touch the doorbell datapath and is read-only telemetry;
its presence cannot alter functional behaviour and certainly cannot
asymmetrically break the slave->master direction (the ILA is on the
master, the one direction that supposedly works).

---

## 3. Pin-bank / I/O-standard / pull analysis

All 18 link lanes on BOTH targets live in **bank 35 (3.3 V, LVCMOS33)** on
Zynq Z-7020 CLG400; PMOD-B Y16 and the four LEDs live in bank 13 (also
3.3 V LVCMOS33). No bank-voltage mismatch is possible.

Both targets carefully avoid the Pmod-A-shared, I2C-pulled-up balls
(W18/W19/Y18/Y19/U18/U19) that the 2026-04-29 base.xdc rebase moved off
of. Verified — the master pin list (F19/V10/V8/W10/B20/W8/V6/W9 + Y9) and
the slave pin list (U7/C20/Y8/A20/U8/W6/Y6/V7 + Y7) are exactly the two
halves of the verified "RPi-only, no Pmod-A, no I2C pull-up" set in
`ribbon_wiring.md`. Both halves are pull-up-clean.

No explicit PULLUP/PULLDOWN/PULLTYPE on any pad_tx[*] or pad_rx[*] on
either side. Drive/slew is symmetric (FAST/8 on TX, default on RX). There
is no asymmetric pull resistor or asymmetric drive strength that could
make one direction work and the other fail.

PMOD-B trigger: bidirectional via IOBUF (one IO ball Y16, identical
PULLDOWN on both sides). Symmetric. Not relevant to doorbell delivery
(doorbells are link-layer, the trigger is the out-of-band PHC capture
strobe).

---

## 4. Clock + IDELAY + timing constraint comparison

- `pad_clk_tx` is defined identically as a 1:1 generated clock from
  `clk_wiz_0/clk_out1` on both sides. Period/duty/edges identical.
- `pad_clk_rx` is a primary clock on a P-side clock-capable input pin on
  both sides (MRCC on master, SRCC on slave). The flip target's timing
  XDC header explicitly documents this asymmetry and points at
  `set_bus_skew 2.0 ns` as the construction-time equaliser. Skew bound
  applies symmetrically.
- `set_input_delay` / `set_output_delay` / `set_max_delay` /
  `set_bus_skew` values are bit-identical (-4..+4 ns; 8 ns max; 2 ns
  bus-skew; +/-5 ns TX eye).
- Clock-groups async cut between `pad_clk_rx` and the hclk MMCM output
  is identical on both sides.
- No `set_false_path` other than the IDELAY CNTVALUEIN one (identical).
- No `CLOCK_DEDICATED_ROUTE` override on either side — both rely on the
  default routing rules. The flip-side SRCC root infers a BUFG
  automatically; pair-all's MRCC root does the same. No
  `BACKBONE`/`ANY_CMT_COLUMN` override on either.
- IDELAYE2 group binding (`IODELAY_GROUP tidelink_rx_idelay`),
  IDELAYCTRL placement, IOB FALSE on pad_rx[*] — byte-identical (only
  the header comment differs: pair-all vs pair-flip-all).
- IDELAYCTRL reference clock (200 MHz `clk_out3`) is auto-defined by
  the clk_wiz MMCM in the BD; same MMCM config on both sides.

There is no clock-domain or delay-line asymmetry that could let one
direction's 8-bit GPIO eye close while the other stays open. The
calibrator handles dynamic phase per lane; static skew is bounded
symmetrically.

---

## 5. `tidelink_design.tcl` differences

Diff is 100 % cosmetic — the flip target's design.tcl has shorter
comments (cross-references to pair-all instead of duplicating the
rationale). Functional BD topology is identical:

- Same IP set: ZYNQ7 PS, AXI SmartConnect, AXI APB bridge,
  TideLink IP, PHC IP, 3x AXI GPIO (`axi_gpio_strap`,
  `axi_gpio_debug_unlock`, `axi_gpio_pmod_trig`), 2x xlconstant
  (puf_seed, mask_hs_bypass).
- Same AXI address map (0x4404_0000 strap, 0x4404_1000 debug-unlock,
  0x4404_2000 pmod-trig GPIO, 0x4405_0000 PHC).
- Same `xlconst_mask_hs_bypass` value (LOW — driven via the
  autoneg-driven peer-mask path).
- Same clk_wiz config (hclk + 50 MHz PHC clock + 200 MHz IDELAY ref).
- Same PMOD-B handling: `axi_gpio_pmod_trig` ch1 -> `pmod_b_trig_o`
  (driven), ch2 <- `pmod_b_trig_i` (sensed); `pmod_b_trig_i` OR'd
  into PHC `hw_capture_0_i` alongside `tidelink_0/phc_hw_capture`.
- IOBUF wrapper in `tidelink_design_wrapper.v` is BYTE-IDENTICAL
  between the two targets (`diff` returns empty); same active-low
  T-control, same Y16 pin map.

PMOD-B is wired bidirectionally and symmetrically on both bitstreams.

The only non-cosmetic difference in the entire pair is the master's PHC
ILA in `pynq_z2_tidelink_drc.xdc` — read-only debug, cannot cause bug C.

---

## 6. Verdict

**XDC / pin-mapping / clock-routing asymmetry is NOT a plausible root
cause of bug C.**

Evidence:
1. Every pad shares the same IOSTANDARD/SLEW/DRIVE/PULL on both sides.
2. Pins are swapped en bloc TX<->RX so that, end-to-end across the
   ribbon, the M->S link and the S->M link are physically and
   electrically the same channel — both directions ride 9 traces (1
   clk + 8 data) on the same J13 ribbon with no per-direction pull or
   drive bias.
3. Both receivers root on a P-side clock-capable input pin; the
   MRCC-vs-SRCC asymmetry is exactly the one the timing XDC's
   `set_bus_skew 2 ns` was added to neutralise, and HW build #8 has
   already demonstrated 16/16 link lock through this very topology.
4. All source-sync timing constraints (input/output delay, max delay,
   bus skew, async groups) are byte-identical.
5. IDELAYE2 / IDELAYCTRL group and false-path are byte-identical.
6. PMOD-B trigger is bidirectional and symmetric on both sides.
7. The only non-cosmetic XDC diff is the master's read-only PHC ILA,
   which cannot break a datapath.
8. M->S doorbells DO deliver — so the GPIO PHY in the "harder" SRCC
   direction is working. If anything, that's the direction XDC
   asymmetry would have hit first.

The bug is in RTL (most likely the doorbell counter / credit-return /
FC adapter / Wlink RX accept path on the master). It is NOT in the
constraints, pin map, or BD topology of either FPGA target.

## 7. Proposed XDC fix

None. No XDC change is warranted. Hunt for bug C in the RTL doorbell /
credit-return / FC-adapter / FCSM path on the master receive side (the
parallel BUGC_RTL_ANALYSIS_2026_05_30.md investigation), not in the
constraints.
