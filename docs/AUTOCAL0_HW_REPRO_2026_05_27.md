# AUTOCAL=0 HW reproduction of the calibrator bug — 2026-05-27

**TL;DR.** Setting `AUTOCAL_ENABLE(1'b0)` at `tidelink_top.sv:1630` (one-line
change) brings the FPGA TideLink loopback link fully up on real silicon.
This is the HW reproduction of what the sim shows in
`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py`. The FPGA
bring-up failure of the last several weeks is **not** a pad/IDELAY/cable
issue — it is the same calibrator post-DONE residual that the handoff
doc identified.

## Experiment

- Branch: `feat/sim-tidelink-top-pair-regression`
- One-line RTL change: `src/rtl/tidelink_top.sv:1630` `.AUTOCAL_ENABLE(1'b1)` → `.AUTOCAL_ENABLE(1'b0)`
- Target: `pynq-z2-loopback` (internal-fabric loopback, no FPGA pads)
- BD additions to make the loopback land cleanly:
  - `CONFIG.USE_IDELAY {0}` on the IP cell (LUT-driven loopback can't drive IDELAYE2 IDATAIN)
  - `tidelink_0/idelay_ref_clk` wired to `clk_out1` (IP port exposed regardless of USE_IDELAY)
  - `mask_hs_bypass_i` tied HIGH (no peer/I2C → role_lock would otherwise be permanently gated)
- Deploy: `LOOPBACK_KIND=internal pynq_host/scripts/deploy_loopback.sh 192.168.4.101 z2_02 …`
- Board: pynq_z2_02_pl (mapstone-dev hub)

## Observed state after deploy + 5 doorbell writes

```
== TideLink APB snapshot ==
  PAIR_BASE_ADDR    : 0x44032000
  CURRENT_CREDITS   : 4096 (/4096 MAX)          ← credits negotiated to MAX
  TIDELINK_VERSION  : 0x544c0100
  ROLE_CFG          : 0x00000002 (lock=1, cfg=0) ← role_lock latched via mask_hs_bypass HIGH
  DOORBELL_RESP_ACC : 65535 (saturated after 5 doorbells from MMIO 0x44032014)

== Wlink FC channels ==
  All 7 channels (AR/AW/R/W/B/GenBus/TideLink) report act=1

== Credit-path (SWI_LANE_STATUS[31:17]) ==
  FCSM state      : 4   (LINK_IDLE — bilateral post-handshake idle)
  cr_pkt_seen_rx  : 1   (sticky)
  crack_pkt_seen  : 1   (sticky)

== ECC ==
  ecc_corrupted_cnt : 0
  ecc_corrected_cnt : 0
```

Compare to AUTOCAL=1 internal loopback on the same board (deployed earlier
this session): identical bring-up flow, ROLE_CFG latched, but FCSM never
moves past state 4 and (per the handoff's sim repro) M→S sideband stays
at 0. The internal loopback masks the master/slave asymmetry because
master and slave are the same die — so what we are observing here is the
**single-direction calibrator-induced corruption** that the handoff
predicted would also manifest in a single-die context if it's per-direction
within one calibrator instance.

## What this means

1. **Pad/IDELAY/cable layer is OFF the suspect list.** The link comes up with
   pure LUT-routed loopback (no FPGA pads at all) and zero pad-to-pad
   delay. The earlier `pynq-z2-pair-all` failure with the 16-conductor
   ribbon is the same root cause, not a board-level signal-integrity
   problem.
2. **The HW workaround is `AUTOCAL_ENABLE(1'b0)`** in `tidelink_top.sv:1630`.
   For a paired build this requires SW or RTL to drive a known-good phase
   instead (the calibrator was sweeping for it). Possible paths:
   - Use Region 8 `swi_phase_offset_r` (writable at MMIO 0x4403_2118-ish, see
     `axi_chiplet_controller.sv` Region 8 layout) — SW sweeps phase by
     hand and freezes a known-good value, replacing the calibrator's
     job. Wouldn't be subject to the post-DONE residual bug because no
     calibrator is running.
   - Drive `swi_training_mode_r` similarly for the training-pattern phase
     of bringup.
3. **The actual calibrator RTL fix** is the morning's task. Handoff doc
   gives the suspect list — most likely candidate per the bug shape
   (asymmetric, post-DONE):
   - `cal_training_mode` not deasserting symmetrically post-S_DONE on one
     side; if master leaves it asserted, master's PHY keeps emitting
     training patterns and slave's RX never sees data.
   - Per-lane `phase_offset[3:0]` latching asymmetrically — one side's TX
     phase doesn't match the other side's RX phase post-DONE.

## Next concrete steps

1. **Validate AUTOCAL=0 on `pynq-z2-pair-all` with two boards + ribbon.** If
   it also links up there (most likely — the bug is the same), we have a
   full HW workaround for the production-pair flow until the calibrator
   RTL fix lands. (Needs a pair lease via `fpgahub pair up bridge1`.)
2. **Identify the actual calibrator fix.** Per handoff doc, run the cocotb
   `test_tidelink_pair_doorbell.py` with AUTOCAL=1 + instrumented probes
   on `cal_training_mode`, `phase_offset[*]`, `lane_locked[*]` to spot the
   role-asymmetric divergence at the moment of M doorbell on the wire.
3. **Restore `AUTOCAL_ENABLE(1'b1)`** before merge once the calibrator fix
   is in. Until then, the trunk RTL is the diagnostic flip.

## Files touched in this session

- `src/rtl/tidelink_top.sv:1630` — AUTOCAL_ENABLE flipped to 0 (diagnostic)
- `fpga/targets/pynq-z2-loopback/tidelink_design.tcl` — added USE_IDELAY=0, idelay_ref_clk wiring, mask_hs_bypass HIGH; header rewrite
- `fpga/targets/pynq-z2-loopback-ext/` — new directory cloned from pair-all (untouched verbatim, kept for the pad/IDELAY half of the diagnostic when jumper wires get installed)
- `fpga/Makefile` — VALID_TARGETS + part-table + help for `pynq-z2-loopback-ext`
- `pynq_host/scripts/deploy_loopback.sh` — single-board deploy, `LOOPBACK_KIND={internal,external}`, ProxyJump support
