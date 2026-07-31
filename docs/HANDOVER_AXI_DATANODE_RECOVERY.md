# Handover → TideLink dev: AXI data-node error-recovery does NOT work on silicon

**From:** nanoSoC eth-chiplet integration (two-board KR260 FPGA silicon).
**Date:** 2026-07-31. **Status:** reproducible on-silicon failure + a ready acceptance test.

## TL;DR
I1 (SELF_ARM + FIX-E) fixed **link bring-up** — the pair reaches fcsm=4 and carries *clean*
D2D traffic byte-exact. But the **AXI data-node FCSM error-recovery does not work**: a single
injected bit-error on the **B (write-response)** node **hard-wedges the initiator die** (PS
bus + SSH unresponsive, JTAG-POR-only). Critically, the shipped build **already contains the
recovery-capable FCSMs** — so this is not "recovery stripped", it is "**recovery present but
ineffective** for this failure mode". The clean 1000-beat soak passed only because no
bit-errors occurred and ordinary health regs don't observe the AXI nodes.

## What the current build actually ships (verified in the flist)
`flists/tidelink_fpga_v2.flist` sources the 5 AXI FC nodes from `src/rtl/local_overrides/`:
```
src/rtl/local_overrides/WlinkGenericFCSM.v      (AW)
src/rtl/local_overrides/WlinkGenericFCSM_1.v    (W)
src/rtl/local_overrides/WlinkGenericFCSM_2.v    (B)
src/rtl/local_overrides/WlinkGenericFCSM_3.v    (AR)
src/rtl/local_overrides/WlinkGenericFCSM_4.v    (R)
deps/.../WlinkGenericFCSM_5.v                    (sideband, unchanged)
src/rtl/local_overrides/WlinkGenericFCSM_6.v    (sideband recovery)
```
Those local_overrides carry the full recovery set — `SOCL_L7_MIN_CRACK_EMITS=8`,
`socl_reack` (Fix E, receiver-side periodic ACK re-emit), `socl_l7_wdog` (Fix D, state-7
NACK watchdog), `socl_l7_crack_release`, `socl_l7_bringup_forgive` (43 recovery markers in
the B node alone). **They are in the bitstream and still wedge.** NOTE: `CROSS_DIE_WEDGE_
ROOTCAUSE.md` (2026-07-29) says the AXI nodes ship the *stripped* deps copies — that is now
**stale**; I1 re-pointed them to local_overrides. Update that doc.

## The silicon result (2026-07-31, SELF_ARM build `34b006c`, both dies fcsm=4)
Ran `kr260_eth_xfer.py --mode errinject --node B --seed 0xBEEF --stream 32` on die_a.
| Die | Role | Outcome |
|---|---|---|
| **die_a** (initiator, peer-writes) | **HARD WEDGE** — the corrupted write hung the AXI path with no return; PS bus + SSH went unresponsive. A **hard hang**, not a graceful Region-F trip. JTAG-POR required (and recovered cleanly). |
| **die_b** (receiver, local reads) | **HEALTHY** — `SWI_LANE=0x05890000` fcsm=4, Region F `0xAD800000` data_healthy=1, wedge-sticky tgt/ini=0x00. |

The wedge is on the **initiator's** side: its master waits forever for the corrupted B
response. The hang precedes any Region-F read, so the recovery FSM either never fired or fired
too late — that is the thing to diagnose.

---

## HOW TO RECREATE THE BUG (step by step, ~10 min, JTAG-POR staged)
Boards: die_a `ubuntu@10.22.24.159` = fpgahub `kr260_01`; die_b `ubuntu@10.22.24.153` =
`kr260_02`. Board pw `soclabs2026`. PS access = eth_ss_0 backdoor (PS phys 0x4_0000_0000 +
SoC_addr; TideLink APB SoC 0x2E03_0000). NEVER touch bare-link 0x8403/0xA400/0x8000.

```bash
# 0. lease + POR both (fresh dies; role_lock clears only on poresetn)
fpgahub lease acquire kr260_01 ; fpgahub lease acquire kr260_02
for b in kr260_01 kr260_02; do ssh mapstone-dev "curl -s --unix-socket /run/fpgahub/fpgahub.sock \
  -X POST http://localhost/api/v1/targets/$b/reset -H 'Content-Type: application/json' \
  -d '{\"method\":\"default\",\"confirm\":true}'"; done

# 1. deploy the SELF_ARM build to both (auto-skips AFI canaries for eth-chiplet)
export KR260_PASSWORD=soclabs2026
make -C tidelink/fpga deploy_kr260 TARGET=kr260-eth-chiplet      KR260_HOST=ubuntu@10.22.24.159
make -C tidelink/fpga deploy_kr260 TARGET=kr260-eth-chiplet-flip KR260_HOST=ubuntu@10.22.24.153

# 2. bring the link up (FIX-E bilateral orchestrator) -> "LINK UP fcsm=4 BOTH DIES"
DIE_A=ubuntu@10.22.24.159 DIE_B=ubuntu@10.22.24.153 bash tidelink/pynq_host/scripts/bringup_pair_release.sh

# 3. inject one bit-error on the B (write-response) AXI node and resume a write stream
KR260_HOST=ubuntu@10.22.24.159 KR260_XFER_NODE=B KR260_XFER_SEED=0xBEEF \
  bash tidelink/pynq_host/scripts/kr260_eth_run.sh xfer_errinject
#   TODAY'S RESULT: die_a hangs (PS-bus wedge) -> recovery ABSENT.

# 4. recover: JTAG-POR both (step 0), redeploy + bringup -> link returns to fcsm=4.
```

## THE TEST (already written; this is your acceptance gate)
`kr260_eth_xfer.py --mode errinject` (+ `xfer_corners_lib.py`) does, on die_a:
1. `_require_link()` (fcsm=4) + baseline the target node's CRC (`0x2E03_1200+0x20` for B).
2. Inject via the **Wlink error injector `0x2E03_003C`** — `[7:0]DataID` (B=0x82, R=0x84,
   W=0x81, AW/AR similar), `[15:8]Byte`, `[18:16]Bit`, `[24]Enable`. One corrupted peer-write.
3. Confirm the node CRC **rose** (inject took effect; else exit 2 = injector not in bitstream).
4. Injector OFF; resume a short deterministic write stream, sampling **Region F `0x2E03_21E0`**
   (data_healthy[23], wedge-sticky tgt[14:10]/ini[19:15] per {r,ar,b,w,aw}) each beat.

**Exit contract:** `0` recovery-present (stream healthy → confirm byte-exact with
`errinject_verify` on die_b); `1` recovery-absent (graceful Region-F wedge trip);
**hard hang/timeout = recovery-absent (hard wedge)** — today's outcome; `2` inconclusive.

**The gate for a fix:** run `errinject` per node ∈ {AW, W, B, AR, R} × several `--inj-bit`/
`--inj-byte`, and **expect exit 0 on every one** (traffic resumes byte-exact, Region F
healthy, no hang). A fix is done when no node/bit hard-wedges. Wire it into the weekend
campaign (`pynq_host/scripts/weekend/`) so it sweeps all nodes/bits and tallies
recover-vs-wedge autonomously, snapshotting Region F and JTAG-POR-recovering each wedge.

## HOW TO PRODUCE A MATCHING SIM TEST (close the blind spot that hid this)
The `sim[silicon_data]` gap is why a clean soak "passed" while an injected error wedges. Build
a cocotb error-injection sim (extend `cocotb/tidelink_error_injection/`) that, at the **40 ns
silicon ratio** with two dies, on **each** AXI FC node: brings the FC up to LINK_DATA, drives a
sustained write stream, injects a single CRC/ACK error (mirroring the `0x2E03_003C` model), and
**asserts the node re-syncs and delivery resumes byte-exact within N cycles** — i.e. the
watchdog/`socl_reack` path fires. Default PASS; an `INJECT_NO_RECOVER=1` variant that disables
the recovery must FAIL exactly like silicon. This sim is the fast triage loop (a HW errinject
is a ~1.5 h build + bench cycle per hypothesis).

## What to diagnose / where to look
The recovery logic is present but does not save this case. Determine, in
`local_overrides/WlinkGenericFCSM{,_1..4}.v`:
- Does the corrupted **write-response (B)** hang the AXI master **before** any recovery state
  (state ≥4 `socl_reack`/`socl_l7_wdog`) can fire? The hard hang (no Region-F trip) suggests the
  stall is upstream of the watchdog, or the watchdog trip doesn't unblock the response return.
- Does the `0x2E03_003C` injection model the natural failure (dropped ACK / CRC error) the
  recovery was designed for, or a different corruption the recovery ignores? (Try each byte/bit
  and the sideband CR id 0x44 vs a data id to compare.)
- The `SOCL_L7_MIN_CRACK_EMITS=8` interaction and the state-7 watchdog threshold at silicon ratio.

## References
- Test: `pynq_host/scripts/kr260_eth_xfer.py` (`do_errinject`/`do_errinject_verify`),
  `pynq_host/scripts/xfer_corners_lib.py` (`error_inject`, `snap_health`, `classify_wedge`),
  dispatch `pynq_host/scripts/kr260_eth_run.sh` mode `xfer_errinject`.
- Injector `0x2E03_003C`, Region F `0x2E03_21E0`, per-node FC `0x2E03_{1000..1400}`+0x20 CRC —
  `docs/reference/REGISTER_MAP.md` (~:393, :455).
- Shipped FCSMs: `src/rtl/local_overrides/WlinkGenericFCSM{,_1..4,_6}.v`; flist
  `flists/tidelink_fpga_v2.flist` (FCSM region ~292-304).
- Eth-chiplet-side write-ups: `docs/AXI_DATANODE_RECOVERY_GAP_2026_07_31.md`,
  `docs/CROSS_DIE_WEDGE_ROOTCAUSE.md` (stale on the flist — see above),
  `docs/I1_RESOLVED_HANDOVER_2026_07_31.md` (bring-up resolution).
- Sim to extend: `cocotb/tidelink_error_injection/`.

**Boards:** restored to the working SELF_ARM link (fcsm=4 both), leases released.
