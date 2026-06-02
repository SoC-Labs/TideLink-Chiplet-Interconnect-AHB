# Overnight Bug A iteration — status as of 2026-06-01 ~02:50 BST

User asked autonomous overnight Bug A correctness work. Real progress made; ILA capture blocked by build-infrastructure issues that need morning attention.

## TL;DR

- **L11 watchdog HW-validated** on Build #8 + reconfirmed Build #9 (1st AHB write succeeds without wedging master; link stays up)
- **Build #9 built + deployed** with L11 + 8 Build #6 RX-wedge probes
- **ILA capture FAILED** due to infrastructure mismatches (not RTL bugs):
  - Slave bitstream has no `dbg_hub` (farm build on srv04936 must be skipping `insert_debug_core.tcl`)
  - Master bitstream has `dbg_hub` but `.ltx` references 71 probes that don't match the hw_ila core on device (synth/impl ILA refresh issue)
- **Bug A correctness still requires ILA evidence** — slave RX framer signals (`pkt_is_data_pkt`, `isExpPacket`, `crcCorruptSeen`, `send_nack_req`, `socl_l7_*`) need silicon capture to diagnose the actual NACK trigger.

## Tonight's iteration arc

| Step | Outcome |
|---|---|
| Apply Build #6 RX probes (8 mark_debug on WlinkGenericFCSM_6.v) | ✅ in tree |
| Launch Build #9 (L11 + RX probes) | ✅ both bits in 66 min |
| Stage + deploy on mapstone-dev | ✅ label `build9-ila-L11-rxprobes` |
| Bringup converge | ✅ 16/16 at iter 1 |
| Run AHB Bug A trigger | ✅ master stays responsive, link stays up |
| Slave APB state read | Bug A symptom confirmed: REG_PKT_LEN=0, RX_FIFO empty |
| ILA capture on slave | ❌ No `dbg_hub` on slave bitstream |
| ILA capture on master | ❌ `.ltx` probes don't match device |
| Repeat AHB write | Wedges master eventually — L11 keeps it auto-recovering via PYNQ watchdog |

## ILA infrastructure issues to fix tomorrow

### Slave bitstream missing debug core

Vivado HW Manager reports:
```
Device xc7z020 (JTAG device index = 1) is programmed with a design that has no supported soft debug core(s) in it.
WARNING: [Labtools 27-3361] The debug hub core was not detected.
WARNING: [Labtools 27-3413] Dropping logic core with cellname:'u_dbg_int' ... since it cannot be found on the programmed device.
```

Likely cause: `FPGA_INSERT_DEBUG_CORE=1` env var isn't being propagated to the srv04936 farm build of `pynq-z2-pair-flip-all`. Two debug paths:

1. Check `fpga/scripts/farm_build.sh` — does it forward the env var via ssh to srv04936?
2. Check `fpga/build_design.tcl` — does it source `insert_debug_core.tcl` only when `FPGA_INSERT_DEBUG_CORE=1`?
3. Re-run slave build LOCALLY (not farm) to confirm `insert_debug_core.tcl` actually fires.

### Master bitstream .ltx mismatch

```
WARNING: [Labtools 27-3222] Mismatch between the design programmed into the device xc7z020 and the probes file(s) /tmp/tidelink_deploy/tidelink.ltx.
The hw_probe in the probes file has port index 71. This port does not exist in the ILA core at location (uuid_8C7A4108CECD5B949181BD3AEA6472BC).
```

Likely cause: `.ltx` is from a different synth run than the `.bit`. Either:
- `tidelink_design_wrapper.ltx` is being copied from a stale stage
- Or `insert_debug_core.tcl` runs after synth but the .ltx that gets written reflects pre-impl ILA state
- Check `fpga/build_design.tcl` for when `write_debug_probes` is called relative to `write_bitstream`

### Workaround for tomorrow

Easier than chasing the build issue:
1. Manually `program_hw_devices` the bitstream from Vivado HW Manager so .ltx + .bit are guaranteed to come from the same project
2. Or rebuild master locally only with `make build_pair MODULE=pynq-z2-pair-all FPGA_INSERT_DEBUG_CORE=1` and verify .ltx mtime ≈ .bit mtime

## What we KNOW about Bug A from HW (without ILA)

From Build #5 + #8 + #9 silicon experiments:
- Master can drive `tl_fc_a2l_valid` (T5 force experiment, 2126 cy sustained)
- Slave's `tl_fc_l2a_valid` never asserts
- Slave's REG_PKT_LEN never increments
- Slave's AHB_RX_FIFO stays all-zeros
- Both sides reach FCSM state==4 stably after bringup
- L11 watchdog forces HREADYOUT high after 16 cy stall, dropping the AHB word silently — this is why master doesn't wedge
- 2nd AHB write can still wedge master when the RX backpressure compounds across multiple writes

**Hypothesis preserved from V3 (sim) + Q5 (RTL audit)**:
- Slave RX framer receives master's DATA packet, classifies it as NACK-worthy (`pkt_is_data_pkt=1` but `isExpPacket=0` or `crcCorruptSeen=1`)
- `send_nack_req` latches, slave bounces FCSM state 5→7→4
- Slave never writes the data into RX FIFO

ILA would tell us WHICH of the NACK predicates trips first. Without that, the fix is speculative.

## What CAN we do without ILA tomorrow?

Productive non-ILA paths:

1. **Apply both L9 + L11 in tree, build #10, deploy** — V3's L9 sim test failed, but on HW the dynamics may differ (the BD-tied phc_nanoseconds + the AXI SmartConnect interactions are absent in sim). One real HW data point > many sim points.

2. **Read upstream WlinkRxLinkLayer.v line-by-line** for the slave RX framer path — the actual `pkt_is_data_pkt` decode is `_crc_corrupt_T_2 & ~crc_corrupt` (FCSM_6.v:428). If `crc_corrupt=1` on every master DATA packet, slave correctly NACKs. So the question becomes: is the master's CRC actually wrong? That would be a TX-side bug.

3. **Sim-instrument the FCSM_6 state==5 → state==7 transition** in cocotb to confirm which predicate trips first (sim has the FCSM but no SmartConnect, so the wedge behavior won't reproduce but the NACK condition might).

4. **Re-apply Bug B fix + build #11** so the user can manually fire HW_SYNC and verify slave RX PTP path independently (PTP path is independent of FC path; if PTP works, the link is fundamentally fine — only FC slave RX is broken).

## Recommended morning sequence

1. Fix the `dbg_hub`-missing problem in slave bitstream (15 min — likely a farm_build.sh env var fix)
2. Rebuild slave only (~45 min)
3. Re-attempt ILA capture
4. With evidence in hand, apply the right Bug A correctness fix
5. Build #10 with the fix, verify

## Files

- Build #9 artefacts: `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.bit + .ltx`
- Build #9 staged on mapstone-dev: `/tmp/tidelink_deploy/tidelink{,-flip}.{bin,hwh,ltx,bin.manifest.json}`
- L11 RTL change reverted by user from `src/rtl/tidelink_fc_adapter.sv` (intentional)
- Build #6 RX-wedge probes still in `src/rtl/local_overrides/WlinkGenericFCSM_6.v` (8 mark_debug)
- Predecessor docs:
  - [BUILD8_HW_VALIDATION_2026_05_31_EVENING.md](BUILD8_HW_VALIDATION_2026_05_31_EVENING.md)
  - [BUG_A_WEDGE_INVESTIGATION_2026_05_31.md](BUG_A_WEDGE_INVESTIGATION_2026_05_31.md)
  - [BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md](BUG_A_DEEP_ROOT_CAUSE_2026_05_29.md)
  - [BUG_A_FIX_VERIFICATION_2026_05_29.md](BUG_A_FIX_VERIFICATION_2026_05_29.md) (V1 L8 RED-LIGHT)
  - [BUG_A_L9_VERIFICATION_2026_05_29.md](BUG_A_L9_VERIFICATION_2026_05_29.md) (V3 L9 — was supposed to be at this path; check disk)

## Lease state

bridge1 lease held by mapstone-dev. Released auto-acquire each session. Boards z2_02 + z2_03 attached.

## Honest assessment

Bug A correctness fix requires ILA evidence we couldn't capture tonight due to build infrastructure issues. L11 wedge fix is HW-validated as a stable workaround. The bug is well-bounded — it lives in `WlinkGenericFCSM_6.v` slave RX framer between cycles where master's DATA packet arrives and `send_nack_req` latches — but pinpointing the exact predicate that fires requires JTAG access we don't have working tonight.
