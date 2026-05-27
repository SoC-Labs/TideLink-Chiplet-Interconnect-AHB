# Overnight 2026-05-26 → 2026-05-27 — calibrator fix HW validation

## TL;DR

Two independent overnight tracks landed:
1. **HW workaround** — `AUTOCAL_ENABLE(1'b0)` at `tidelink_top.sv:1630` brings up
   the FPGA loopback link end-to-end on real silicon (z2_02 verified).
2. **Calibrator RTL fix** — another session produced
   `feat/calibrator-bug-fix @ f900e07` which adds an `S_PROBE` state that
   biases lane latching to `(slip=0, phase=0)` when natural alignment works.
   Sim PASSES 5/6 including the previously failing test_05 (M→S doorbell).

Both AUTOCAL=0 workaround bitstreams AND the S_PROBE fix bitstreams are
built and staged. Recommendation: **morning's next test is `pynq-z2-pair-all`
+ `pynq-z2-pair-flip-all` with the S_PROBE fix on a real two-board ribbon.**
That is the configuration the S_PROBE fix is designed for; single-die
loopback can't exercise it (see below).

## HW results summary

| Config                                | Deploy on z2_02 loopback                       |
|---------------------------------------|------------------------------------------------|
| AUTOCAL=1, no fix                     | FCSM stuck at LINK_IDLE, no traffic             |
| AUTOCAL=0 (workaround)                | **WORKS** — credits MAX, doorbells cross        |
| AUTOCAL=1 + S_PROBE fix               | Partial — cal_done=1, FCSM cycles 4/5/7, no DB completion |

### AUTOCAL=0 result

- `CURRENT_CREDITS=4096` (MAX), `cr_pkt_seen_rx=1`, `crack_pkt_seen=1`
- `FCSM=4` bilateral LINK_IDLE, ECC clean
- All 7 FC channels show `active=1`
- 5 doorbells → `DOORBELL_RESP_ACC` jumps deterministically by 20480 per ring
- Conclusion: link is genuinely up; FC sideband packets cross end-to-end.

### AUTOCAL=1 + S_PROBE result

- Same baseline (`CURRENT_CREDITS=4096`, `cr_pkt_seen_rx=1`, `crack_pkt_seen=1`, ECC clean)
- **`cal_done=1`** (calibrator ran AND link came up — sim's `cal_state=DONE` mirrored)
- `SWI_BIT_SLIP_LO=0`, `SWI_PHASE_OFFSET=0` (SW side; calibrator output OR-merged in)
- Doorbells DO cause state activity (FCSM cycles 4→5→7→4 within 200ms window;
  state 5 = LINK_DATA, state 7 = SEND_NACK) but `DOORBELL_RESP_ACC` stays at 0
- Inference: the link is sending packets but receiver is NACKing them, not
  completing — suggests a marginal slip/phase pick from the S_SWEEP fallback

### Why S_PROBE doesn't fully exercise on loopback

S_PROBE drives `training_mode=0` (not S_ARM/S_SWEEP/S_HOLD per output driver at
[tidelink_phy_align_calibrator.sv:738](src/rtl/tidelink_phy_align_calibrator.sv#L738)). In a paired sim with two dies,
when one die enters S_PROBE the OTHER die is typically still in S_ARM
emitting the training pattern. The S_PROBE side's RX sees the peer's training
pattern → lane_checker locks → S_PROBE latches (0,0).

**In single-die loopback, local TX = local RX same die.** When the local
calibrator enters S_PROBE and drops training_mode, the loopback wire
carries real data (not training). Lane_checker sees real data, doesn't
match the training pattern, lane_score stays low → `probe_all_locked=0`
→ falls through to the original S_SWEEP path. The original strict-`>`
best-of-sweep then picks the first slip/phase combination that wins by
strict greater-than — which in loopback might be (0,0) initially but
edge-cases produce non-zero picks that mess with framing.

**This means the S_PROBE fix's HW validation must be on a real
two-board pair, not on the internal loopback.**

## Morning verification — recommended sequence

### Step 1: real pair-all with the S_PROBE fix (highest priority)

This is the test the fix was designed for. With AUTOCAL=1 + S_PROBE,
each die's S_PROBE sees the peer's training pattern → lane_checker
locks → both sides latch (0,0) deterministically.

```bash
# Working tree is on feat/sim-tidelink-top-pair-regression with:
#   - src/rtl/tidelink_phy_align_calibrator.sv = f900e07 (S_PROBE fix)
#   - src/rtl/tidelink_top.sv:1630 AUTOCAL_ENABLE(1'b1) (restored)
# Bitstreams already built:
#   - imp/fpga/output/pynq-z2-pair-all/tidelink.{bit,bin,hwh}      (die_a)
#   - imp/fpga/output/pynq-z2-pair-flip-all/tidelink.{bit,bin,hwh} (die_b)

fpgahub pair up bridge1 --ttl 7200 --user dam1n19
mkdir -p /tmp/tidelink_deploy
cp imp/fpga/output/pynq-z2-pair-all/tidelink.{bin,hwh} /tmp/tidelink_deploy/
cp imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin  /tmp/tidelink_deploy/tidelink-flip.bin
cp imp/fpga/output/pynq-z2-pair-flip-all/tidelink.hwh  /tmp/tidelink_deploy/tidelink-flip.hwh

# Deploy via mapstone-dev (deploy_pair.sh runs there per its header docs)
ssh david@mapstone-dev "cd ~/tidelink && pynq_host/scripts/deploy_pair.sh 192.168.4.101 z2_02 die_a --no-verify"
ssh david@mapstone-dev "cd ~/tidelink && pynq_host/scripts/deploy_pair.sh 192.168.6.101 z2_03 die_b --no-verify"
# Then bringup convergence
ssh david@mapstone-dev "cd ~/tidelink && pynq_host/scripts/bringup_pair_converge.sh"
```

Expected outcomes:
- **If link comes up bilaterally with FC traffic** → S_PROBE fix is HW-confirmed.
  Restore `AUTOCAL_ENABLE(1'b1)` as the production setting, merge fix.
- **If pair-all link stays down** → there is a pad/IDELAY-specific residual
  the S_PROBE fix doesn't address. Fall back to AUTOCAL=0 workaround (also
  built — see backup bitstreams in Step 3).

### Step 2: re-verify internal loopback (AUTOCAL=0) as the known-good

Sanity check that the workaround still works.

```bash
fpgahub lease acquire pynq_z2_02_pl --ttl 3600 --user dam1n19 --solo
# To switch to AUTOCAL=0 bitstream, restore src/rtl/tidelink_top.sv:1630 to
#   .AUTOCAL_ENABLE(1'b0) AND rebuild ('make farm_build FARM_JOBS=...').
# Or rerun the deploy with one of the backup bitstreams (see below).
```

### Step 3: backup AUTOCAL=0 bitstreams

If the S_PROBE pair-all test fails, the AUTOCAL=0 workaround built earlier in
the session is still a complete deploy-ready fallback. To rebuild AUTOCAL=0:

```bash
# Flip src/rtl/tidelink_top.sv:1630 to .AUTOCAL_ENABLE(1'b0), then
FPGA_USE_IDELAY=1 make -C fpga farm_build FARM_JOBS="pynq-z2-pair-all@local pynq-z2-pair-flip-all@local pynq-z2-loopback@local"
# (~60 min wall)
```

## Files touched

- `src/rtl/tidelink_top.sv:1630` — restored to `.AUTOCAL_ENABLE(1'b1)` (S_PROBE fix doesn't need the flip)
- `src/rtl/tidelink_phy_align_calibrator.sv` — pulled from f900e07 (S_PROBE state added)
- `fpga/targets/pynq-z2-loopback/tidelink_design.tcl` — USE_IDELAY=0, idelay_ref_clk wiring, mask_hs_bypass HIGH
- `fpga/targets/pynq-z2-loopback-ext/` — new target dir cloned from pair-all
- `fpga/Makefile` — pynq-z2-loopback-ext added
- `pynq_host/scripts/deploy_loopback.sh` — single-board deploy, LOOPBACK_KIND={internal,external}
- `docs/AUTOCAL0_HW_REPRO_2026_05_27.md` — detailed AUTOCAL=0 HW repro
- (this file) — overnight session brief

## What's NOT done

- **S_PROBE fix HW validation on real pair-all** — bitstreams built, deploy
  is the morning's job (needs a pair lease).
- **AUTOCAL_ENABLE setting in trunk** — currently `1'b1` with the S_PROBE
  fix loaded. If pair-all validates, that's correct for merge. If not,
  flip to `1'b0` as the diagnostic-flip workaround until a deeper fix.

## Don't merge yet

The S_PROBE fix needs HW validation on the pair-all flow before merging.
The handoff doc's expected outcome is the calibrator-fix RTL change + a
restored `AUTOCAL_ENABLE(1'b1)`. We have the second; the first is on disk
from f900e07 but needs the pair-all HW pass to confirm it's the right fix.
