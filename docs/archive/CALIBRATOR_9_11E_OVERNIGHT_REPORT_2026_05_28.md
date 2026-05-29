# Calibrator §9.11e overnight session report — 2026-05-27 evening

**Branch:** `feat/calibrator-eyecenter`
**HEAD at session end:** `4a2156c` (revert of §9.11e {P, ~P})
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter`
**Session window:** 2026-05-27 16:48 → 19:00 (~2h 12m unattended autonomous)
**Mode:** autonomous with explicit user permission for /dev/mem writes,
APB recals, doorbell rings, builds, deploys, commits

## TL;DR

**Honest result: did NOT close the doorbell-crossing gap, and tonight's
runs couldn't reliably reproduce yesterday's bilateral LINK_IDLE.**

What I tried (chronologically):
1. **pair-ila build fix #1** — wired idelay_ref_clk → clk_wiz_0/clk_out1 in
   pair-ila & pair-flip-ila tcl (commit `3598528`). Build still failed.
2. **pair-ila build fix #2** — removed procedural-Tcl line from
   `pynq_z2_tidelink_timing.xdc` (commit `5ebb6a9`). Build STILL failed
   later (DRC errors in impl_1).
3. **§9.11e Layer-2 RTL** — changed training-pattern emission from
   `{P, P}` to `{P, ~P}` in `WavD2DGpioTx.v` + matching `tidelink_lane_checker.sv`
   (commit `9a928b9`). Unit tests + paired-die sim PASS (5/6, same as
   §9.11d). **HW deploy: REGRESSED slave bringup** — 3 deploys + APB
   MIN_LOCK_DWELLS=1 tuning all failed to reach cal_done on slave.
4. **§9.11e revert** — backed out `{P, ~P}` to recover §9.11d state
   (commit `4a2156c`).
5. **§9.11d-equivalent rebuild + redeploy** — 5+ deploys; **could not
   reproduce yesterday's bilateral LINK_IDLE state**. Slave consistently
   stuck at `cal_done=0`, `FCSM=1`, `cr_pkt_seen=0` despite `locked=0xff`
   on multiple deploys.

## What got us to LINK_IDLE yesterday (recap, for the morning)

**Five-step recipe**:
1. §9.11c iter-revert to phase-OUTER/slip-INNER (commit `c3c5bdc`).
   *This is THE structural fix.*
2. §9.11d APB-tunable `SWI_CAL_MIN_DWELLS` (MMIO 0x4403_2100 bits[7:4]).
3. §9.11d S_VALIDATE state added.
4. Fresh `deploy_pair.sh` on master + slave in close succession.
5. Wait ~5 s for natural bringup.

Yesterday: 1st deploy got cal_done=0 → 2nd deploy got bilateral
LINK_IDLE on §9.11d. Reproducibility unknown — tonight's 5+ deploys did
NOT achieve it.

**Honest assessment of whether autonomous overnight work is possible —
see §"Autonomy assessment" below.**

## What I learned tonight (negative results matter)

### Result 1: {P, ~P} training pattern is WORSE, not better

**Hypothesis** (from OVERNIGHT_2026_05_27_FINDINGS): the `{P, P}` same-
byte-repeated training stream had zero byte-boundary transitions for
several per-lane patterns (those with `P[7] == P[0]`). Real data has
random byte-to-byte transitions → real-data eye is narrower → calibrator
locks at training-pattern edge of eye, fails on data.

**Test** (commit `9a928b9`): emit `{P, ~P}` instead. Guaranteed byte-
boundary transition every 16-bit word (~P[7] → P[0] always flips).
Should force calibrator to find a (slip, phase) robust to high-ISI
sequences.

**Sim**: 5/6 PASS, same pattern as §9.11d. No regression in cocotb's
bit-exact model (sim doesn't model analog ISI).

**HW**: REGRESSED. Slave never reached `cal_done=1` across 3 deploys +
recal pulses + APB MIN_LOCK_DWELLS=1 + 1 setting all 16 PHY-CTRL phases.
Master sometimes reached LINK_IDLE-precursor state (cal_done=1, FCSM=2,
cr_pkt_seen=1, locked=0xff) but slave stuck at locked=0x00..0xff
varying, cal_done=0.

**Conclusion**: `{P, ~P}` either makes lane_locked too strict (the lane
checker's 256-consecutive-bit-equality criterion now fails on any
real-silicon timing margin imperfection) OR the byte-boundary transition
ITSELF creates per-lane ISI that the per-lane training-byte set (0xA3,
0xB5, ..., 0x2D) wasn't selected to handle.

**REVERTED at commit `4a2156c`.** Net Layer-2 progress this session: zero.

### Result 2: §9.11d S_VALIDATE has a real chicken-and-egg race

After reverting {P, ~P}, expected to recover yesterday's §9.11d state.
**Could not.** 5+ deploys, multiple recal pulses, APB tuning attempts —
slave consistently stuck. Probe sequence over the night:

```
Deploy 1 (§9.11e):    M cal_done=0 locked=0xff   S cal_done=0 locked=0xc4
Deploy 2 (§9.11e):    M cal_done=1 locked=0xff FCSM=2 cr=1    S cal_done=0 locked=0x00
Deploy 3 (§9.11e):    M cal_done=1 locked=0xff FCSM=2 cr=1    S cal_done=0 locked=0x00
Recal both:           M cal_done=1 FCSM=2 cr=1                S cal_done=0 locked=0xff FCSM=1
SW MIN_DWELLS=1:      M cal_done=1 locked=0xff cr=1           S cal_done=0 locked=0xc6
Revert+rebuild:       (eye7 §9.11d-equiv build started)
Deploy 4 (§9.11d-eq): M cal_done=1 locked=0xff FCSM=2 cr=1    S cal_done=0 locked=0x00
Deploy 5 (§9.11d-eq): M cal_done=0 locked=0x36                S cal_done=0 locked=0xff
Deploy 6 (§9.11d-eq): M cal_done=1 locked=0xff FCSM=2 cr=1    S cal_done=0 locked=0x00
Recal both (final):   M cal_done=1 locked=0xff FCSM=2 cr=1    S cal_done=0 locked=0xff
```

**Diagnosis**: §9.11d's S_VALIDATE state drops `training_mode` on each
side independently while waiting for the LOCAL `cr_pkt_seen` to assert.
Master's FCSM transitions out of state 1 (SEND_CR_PKT) once master sees
slave's CR. If slave isn't yet in S_VALIDATE when master sends CR, slave
misses it. Slave times out (4096 cycles) → re-arm sweep → training_mode
restarts → ...

Yesterday this race resolved (whether by luck or by some specific timing
artefact) on the 2nd deploy. Tonight it didn't, despite many attempts.

### Result 3: pair-ila build has TWO separate problems

1. **`idelay_ref_clk` unconnected** in pair-ila + pair-flip-ila BD tcl.
   Fixed at commit `3598528`. Build then failed differently.
2. **Procedural Tcl in `pynq_z2_tidelink_timing.xdc`** (line 18:
   `set_property USED_IN_SYNTHESIS false [get_files [file normalize
   [info script]]]`). Same bug fixed for pair-all on 2026-05-21
   (fix/xdc-declarative); ILA variants missed. Fixed at commit
   `5ebb6a9`. Build then failed differently — DRC errors during impl_1
   route_design, write_bitstream couldn't run.

   Third failure (DRC) is likely a conflict between the user's
   intentional `create_debug_core u_dbg_int ila` directive in the xdc
   AND the `FPGA_INSERT_DEBUG_CORE=1` Make flag (post-synthesis ILA
   insertion). Likely fix: drop `FPGA_INSERT_DEBUG_CORE=1` from
   pair-ila builds since the xdc already declares the cores. **Not
   tried tonight.**

## Final HW state at session end

| | Master z2_02 | Slave z2_03 |
|---|---|---|
| Bitstream | `calibrator-9_11e-4a2156c` (§9.11d-equiv post-revert) | same |
| ROLE_CFG | 0x02 (lock=1, die_a) | 0x03 (lock=1, die_b) |
| cal_done | 1 | **0** |
| locked | 0xff | 0xff (calibrator finds lock but S_VALIDATE retries) |
| FCSM | 2 (post-CR-sent, waiting for CRACK) | 1 (init / SEND_CRACK_PKT) |
| cr_pkt_seen | 1 | **0** |
| crack_pkt_seen | 0 | 0 |
| DOORBELL_RESP_ACC after 5 master doorbells | 0 | 0 |

**This is not bilateral LINK_IDLE.** Master is ALMOST there (cr_pkt_seen)
but slave hasn't completed calibration. Yesterday's working state would
have shown FCSM=4 + cr=1 + crack=1 on both sides.

## Commits made overnight

```
4a2156c  Revert "calibrator §9.11e: Layer-2 training-pattern ISI fix ({P, ~P})"
5ebb6a9  fpga(pair-ila, pair-flip-ila): remove procedural Tcl from timing XDC
e1c1e27  docs: §9.11e overnight session report skeleton
9a928b9  calibrator §9.11e: Layer-2 training-pattern ISI fix ({P, ~P})  [REVERTED]
3598528  fpga(pair-ila, pair-flip-ila): wire idelay_ref_clk to clk_wiz_0/clk_out1
```

Net code state: identical to last evening's `c5c16a8` (§9.11d + OR-hardening +
loopback). The 5 overnight commits net out to: 2 pair-ila build-system
fixes (still didn't fully solve), 1 Layer-2 attempt that didn't help (reverted).

## Autonomy assessment

**Can autonomous overnight work get this to working?**

Honest answer based on tonight: **partial — and the partial part is
the easier half.**

What worked autonomously:
- **Build orchestration**: 3 separate FPGA builds kicked off, monitored,
  results captured without intervention. `make farm_build` + a Monitor
  on the log file gives clean event-driven loop progression.
- **Sim regression**: cocotb runs auto-trigger, results parse, commits
  follow. No human-in-the-loop needed.
- **RTL design + commit**: I can design, implement, commit, and sim-
  validate small RTL changes autonomously.
- **Deploy + APB poke**: with the explicit chat-text permission, the
  classifier let me do /dev/mem writes, recal pulses, doorbell rings.
  Saves user-in-loop friction.
- **Status logging + branch hygiene**: `/tmp/overnight_status.log`
  captured every transition. Branch state clean, every commit message
  explains rationale.

What did NOT work autonomously:
- **Bug diagnosis under uncertainty**: when {P, ~P} regressed bringup,
  I had no way to ISOLATE which mechanism caused it (the lane_checker
  strictness vs the byte-boundary ISI vs the per-lane pattern
  interaction). Without ILA data I was guessing. **Without you in the
  loop to redirect, I burned ~60 min on the wrong intervention.**
- **HW state recovery from a degraded baseline**: once tonight's runs
  put both boards into a stuck-slave state, I couldn't get back to
  yesterday's working state via deploy iteration alone. A real engineer
  would probably power-cycle the boards or reflash to a known-good
  earlier bitstream — both of which I can't safely do unattended.
- **Build-system debugging beyond the second-level failure**: pair-ila
  needed 3 separate fixes; I made 2 of them and got blocked on the 3rd
  (the create_debug_core xdc directive conflicting with
  FPGA_INSERT_DEBUG_CORE). Without confidence about what the user
  intended with the xdc edit (the system reminder said "intentional, do
  not revert"), I left the build broken rather than risk reverting
  meaningful work.
- **Knowing when to stop**: I followed the stop conditions correctly
  (3 RTL attempts at Layer-2 would have triggered stop, but I only made
  1 attempt before pivoting to revert/recovery). But "fail to recover
  yesterday's state" wasn't in my stop conditions; in hindsight that
  should have triggered earlier abandonment.

**The autonomous overnight loop is genuinely useful for:**
- Long-duration build/sim workflows
- Mechanical refactors with clear sim validation
- Status updates + commit hygiene during waits
- Sequential deploy + probe + commit cycles where the validation step
  is unambiguous (pass/fail bit)

**The autonomous overnight loop is NOT useful for:**
- Open-ended bug diagnosis where the right next experiment depends on
  observing what's actually happening (ILA traces, scope captures,
  judgment about whether a partial result is "good enough")
- HW corner-case recovery where the right action is "power-cycle and
  start over" or "load yesterday's known-good bitstream"
- Choosing between roughly-equivalent design alternatives where the
  user's preference is the deciding factor

## What you should do in the morning

1. **Power-cycle z2_02 and z2_03** (physical access via mapstone-dev hub
   or the board JTAG-reset path). The current FPGA fabric state may be
   in some degraded mode that bitstream reload via fpga_manager isn't
   fully clearing.
2. **Re-deploy the bitstreams** at
   `imp/fpga/output/pynq-z2-pair-all/tidelink.bit` and
   `imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bit`
   (both are the §9.11d-equivalent post-revert build).
3. **If bilateral LINK_IDLE doesn't recover after 2-3 deploys**, the
   issue is the S_VALIDATE chicken-and-egg. Two paths:
   (a) Revert commit `f467ced` (the §9.11d S_VALIDATE addition) so the
       FSM goes S_HOLD → S_DONE without the cr_pkt_seen gate. This
       loses Fix A1 but recovers the §9.11c behaviour that was
       genuinely robust on the previous run.
   (b) Increase the `VALIDATION_TIMEOUT` parameter dramatically (e.g.
       from 4096 to 1_000_000) so slave's S_VALIDATE never times out
       and re-arms during the master's CR send window.
4. **For the actual doorbell-silent Layer-2 issue**: fix pair-ila build
   (likely needs `make build_pair_farmed` WITHOUT
   `FPGA_INSERT_DEBUG_CORE=1` since the xdc now declares the cores),
   then ILA-capture the doorbell-path bytes. See agent-3 assessment in
   yesterday's session notes for which signals to probe.

## End-of-session signature

I delivered:
- ~~Layer-2 fix on HW~~  No.
- Layer-2 design attempt + empirical disproof + clean revert. Yes.
- pair-ila build fixes (2 of probably 3 needed). Partial.
- Honest report. Yes.

Tomorrow's session should not assume tonight's work moved the doorbell
needle — it didn't. The hardware is in a known state (master
near-LINK_IDLE, slave stuck), the branch is clean, and the path forward
is documented above.
