# Milestone — First V2 A→B Data on Silicon (byte-exact)

**Date:** 2026-06-26
**Platform:** PYNQ-Z2 pair — die_a = z2_02 (master/non-flip, `192.168.4.101`),
die_b = z2_01 (slave/flip, `192.168.2.101`). 8-lane GPIO-style D2D PHY, reduced
mask `0xE4` (active lanes 2/5/6/7), `TIDELINK_PHY_V2=1`.

TideLink V2 delivers data **die_a → die_b, byte-exact**, deterministically (not
the historical credit lottery):

```
sent (die_a txburst):  [0x00240000, 0xCAFE0001, 0xCAFE0002, 0xCAFE0003]
received (die_b GP1 RX aperture 0x84010000):
    0x84010000 = 0x00240000   (header)
    0x84010004 = 0xcafe0001
    0x84010008 = 0xcafe0002
```

## The proven recipe

```
deploy both → rcp (bring-up) → bilateral (fcsm=4)
  → IDELAY winscan (centre per-lane tap → reanchored=1)
  → handoff (FC data-mode entry)
  → SYNC off (R8=0x10)  → FC CTRL 0x44030208=0x00027f07
  → txburst → read GP1 RX aperture 0x84010000  (the committed payload)
```

The L9 first-data-packet resync (`socl_l9_resync_now`) accepts the first packet
deterministically, so the FC packet-number counters need not be pre-aligned.

## The genuine enabling fixes (RTL)

1. **Cross-lane deskew alignment** — the central problem (resisted ~7 attempts).
   - `tidelink_idelay_rx.sv`: full-range per-lane IDELAY tap `{nibble, lsb}`
     (0..31) via a new `SWI_PHASE_LSB` reg (`0x440321B4`), so the winscan can
     reach every sampling phase.
   - `tidelink_lane_deskew.sv` + `axi_chiplet_controller.sv`: a data-mode
     per-lane SYNC-distance obs (`SYNC_DIST_OBS 0x440321AC` / `SEL 0x440321B0`)
     to drive the winscan.
   - **`tidelink_lane_deskew.sv`: removed the `timed_out` veto** on the
     `reanchored` latch. `RTO` (256 beats ≈ 55 µs) expired long before an
     on-silicon winscan (seconds) brings all lanes into SYNC, permanently
     vetoing the latch even after `all_sync_seen` went true. The latch now fires
     whenever `all_sync_seen && sr_rd_safe`, however late. (Safe: when
     `!reanchored` the per-lane read pointer already *is* the common `rd_ptr`;
     poison protection is upstream in `sync_seen`.)

2. **Framer data-mode entry** — after `reanchored=1`, SYNC must be turned off
   (`R8=0x10`) so `sync_resync` does not re-hunt the framer mid-packet; the
   sticky `reanchored` latch keeps the alignment.

## The biggest gotcha (cost most of the debug)

**`RXW` (`0x440320D4`) is the FC-replay pointer, *not* the app RX data counter** —
it reads `0` even when data has been delivered. Chasing it produced a long string
of red-herring theories (marginal eye, /4 link-rate, "systematic dist-5 error",
SYNC-rehunt, FC-pktnum-mismatch). The committed payload was landing in the **GP1
RX aperture `0x84010000`** the whole time. The PHY/eye is, in fact, **perfect**
(received slices dist-0 byte-exact); the `dist=5` obs was a pre-word-pin phantom.

Two further reading traps: the GP1 aperture **pops on read** (read each word
once), and `tl39.py rd` needs a **hex** address string.

## Reverted as unnecessary

The /4 link-rate reduction (BUFGCE_DIV-equivalent divider) was built to "widen the
eye" — but the eye was never the problem (see gotcha). Reverted to 4.6875 MHz.

## Regression protection

`fpga/hw_regression/` — an on-silicon suite (`link_up`, `phy_rx_clean`,
`deskew_align`, `data_a2b`) that asserts this entire path against golden values
and exits non-zero on any regression. Validated 11/11 asserts PASS on the proven
build. Run after any future RTL/build/recipe change:

```bash
fpga/hw_regression/stage_and_run.sh mapstone-dev
```
