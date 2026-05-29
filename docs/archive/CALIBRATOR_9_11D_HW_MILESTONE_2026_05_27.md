# Calibrator §9.11d HW milestone — 2026-05-27

**Branch:** `feat/calibrator-eyecenter` HEAD `c5c16a8`
**Worktree:** `/home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter`
**HW pair:** z2_02 (master die_a, 192.168.4.101) + z2_03 (slave die_b, 192.168.6.101)
**Bitstream label:** `calibrator-9_11d-f467ced`

## Headline result

**Bilateral LINK_IDLE achieved on real silicon for the first time on §9.11d.**

Both calibrators converge to `cal_done=1`, both Wlinks reach FCSM=4 (LINK_IDLE),
both observe each other's CR + CRACK packets. This resolves the original
Symptom A (calibrator stuck at `cal_done=0` on §9.11 / earlier RTL).

**Residual: doorbell M→S does not cross** — exactly the Layer-2 prediction from
`docs/OVERNIGHT_2026_05_27_FINDINGS.md`. SW sweep of all 16 PHY-CTRL global
phase values confirmed 0/16 cross the doorbell. The calibrator's chosen
(slip, phase) per lane passes the lane_checker's 256-consecutive-bits
training criterion AND lets CR/CRACK exchange, but real-data packet bytes
fail to decode at the slave.

## State snapshot at milestone (M and S both at LINK_IDLE)

| | Master z2_02 | Slave z2_03 |
|---|---|---|
| ROLE_CFG | 0x02 (lock=1, die_a) | 0x03 (lock=1, die_b) |
| **cal_done** | **1** | **1** |
| FCSM | 4 (LINK_IDLE) | 4 (LINK_IDLE) |
| cr_pkt_seen_rx | 1 (sticky) | 1 (sticky) |
| crack_pkt_seen_rx | 1 (sticky) | 1 (sticky) |
| SWI_LANE_STATUS | 0x23890000 | 0x01890000 |
| PHY_CTRL global phase | 0 | 3 (bitstream default — does NOT corrupt under §9.11c+d) |
| DOORBELL_RESP_ACC after 5×M doorbells | 0 | 0 (Layer-2 blocker) |

## How we got here (RTL chronology)

| Version | Commit | Change | Effect |
|---|---|---|---|
| §9.11 | 52ac307 | Eye-CENTRE via MIN_LOCK_DWELLS, slip-OUTER iter, S_PROBE advisory, S_FINALIZE | Sim 5/6 PASS; HW `cal_done=0` stuck (M/S sweep-overlap killed by slip-OUTER) |
| §9.11b | 34e9797 | `any_pass_valid` first-passing-point fallback | Helped cocotb skewed but didn't fix HW (would have hit same M/S race) |
| **§9.11c** | **c3c5bdc** | **Revert iter-order to phase-OUTER, slip-INNER (§9.7/§9.9 order)** | **THE FIX** — restores frequent M/S sweep-window crossings (~512 cy vs ~16k cy under slip-OUTER) |
| §9.11d | f467ced | APB-tunable `SWI_CAL_MIN_DWELLS` + S_VALIDATE state + cr_pkt_seen_i input | In-system tune knob; S_VALIDATE not needed in this run but available |
| (hardening) | c5c16a8 | WavD2DGpio AND-clamp on effective_phase_offset OR-merge | Latent fix; not deployed in this bitstream; PHY_CTRL global was 3 on slave but didn't cause corruption (calibrator picked compatible values) |
| (loopback) | 7eae0ea | pynq-z2-loopback BD edits (USE_IDELAY=0, mask_hs_bypass=1) | Loopback bitstream available; deploy needs role_lock investigation |

## Key intervention sequence on HW (replicable)

Initial deploy showed `cal_done=0` on slave (Symptom A residue from
pre-deploy state — calibrator was in a stuck state). Resolved via:

1. **Re-deploy both bitstreams cleanly** — `deploy_pair.sh 192.168.4.101 z2_02 die_a` then `deploy_pair.sh 192.168.6.101 z2_03 die_b`
2. Wait ~5 s for natural bringup
3. Both sides automatically converge: cal_done=1, FCSM=4, cr+crack=1

A fresh deploy gives both sides simultaneous role_lock; the §9.11c
phase-OUTER iter then provides enough M/S sweep-window overlap for both
calibrators to find compatible per-lane (slip, phase) tuples.

## Why doorbells don't cross — the Layer-2 confirmation

The OVERNIGHT_2026_05_27_FINDINGS prediction was: training-pattern lock
passes at points where real-data decode fails. Empirical evidence on
§9.11d:

* Independent Agent 2 assessment: lane_checker enforces 256 consecutive
  16-bit equality matches = strictly stricter than CRC at the symbol
  level. Therefore if lane locks but data CRC fails, the corruption is
  downstream of the lane_checker's `word_in` tap.

* SW sweep tonight: 16 PHY-CTRL global phase settings, doorbell rung
  after each. **0/16 crossed.** No single global phase override unblocks
  the data path even though all 16 reach LINK_IDLE.

* Master's `cr_pkt_seen=1` and `crack_pkt_seen=1` mean the bytes for
  short fixed-form packets (CR/CRACK headers) decode correctly. The
  doorbell packet has different framing (longer, different transition
  density) and fails at the same (slip, phase).

Agent 2's three downstream suspects (from earlier in this session):
1. **Tx-side mid-word disturbance at training→data handoff** — ruled out
   by code inspection (`WavD2DGpioTx.v` `WORD_ALIGN_MUX` latches at
   `count==4'hf`; mux flip lands at next `count==0`)
2. **IDELAYE2 tap not held stable post-S_DONE** — code inspection shows
   tap is stable (`LD=1'b1` reloads CNTVALUEIN every IDELAYCTRL refclk;
   calibrator's `phase_offset` held stable after `lane_done[i]=1`)
3. **Rx bit_slip update on training_mode falling edge** — code inspection
   shows pure combinational rotation, no edge-triggered update

Agent 3's "OR-merge corruption" was a real-but-not-active hazard on this
deploy (slave's PHY_CTRL=3 + slave's per-lane reg=0 → no corruption).

**Net Layer-2 hypothesis**: the training pattern (per-lane single byte
0xA3/0xB5/0xC9/0xD3/0x65/0x4B/0x59/0x2D, period-8 repeated `{P,P}`) has
predictable transition density that gives a "wide-eye" training lock,
but real-data packet bytes have transitions at arbitrary positions and
the same (slip, phase) lands on an eye edge for those.

## What the §9.11d work delivered

* **Symptom A FIXED**: §9.11c iter-revert proven on real silicon.
  Calibrator completes bilaterally; both sides reach LINK_IDLE
  reproducibly via fresh deploy.
* **APB tuning capability**: SW can now write `SWI_CAL_MIN_DWELLS[3:0]`
  via MMIO `0x4403_2100` bits[7:4] to tune the eye-centre policy at
  runtime. Verified via readback.
* **S_VALIDATE state**: in place. Not exercised in this run because
  cr_pkt_seen asserted via natural bringup; would activate if a future
  deploy needed retry-on-no-CR.
* **OR-merge hardening (c5c16a8)**: committed but not in the deployed
  bitstream. Available for next rebuild if HW evidence ever shows the
  OR-corruption signature.

## What §9.11d did NOT fix

* **Doorbell crossing (Symptom B)**: requires Layer-2 work — either a
  richer training pattern (PRBS / multi-byte) in `WavD2DGpio.v` +
  `tidelink_lane_checker.sv`, or an alternative post-cal validation
  using real packet patterns. Multi-hour RTL design, separate effort.

## Open follow-ups

1. **Layer-2 fix** — design richer training pattern OR multi-pattern
   lane_checker. Scope: ~3-5 hours RTL + sim regression + rebuild + HW.

2. **ILA capture pipeline for doorbell path** — current pair-ila /
   pair-flip-ila build failed on missing `idelay_ref_clk` connection
   in target tcl. Port the loopback tcl's xlconstant clock wiring to
   the pair-ila targets, rebuild, capture master's `tl_fc_a2l_valid`
   transitions and slave's pad RX byte stream during doorbell. Would
   give direct evidence of where the byte-stream corruption happens.

3. **Loopback target role_lock** — single-board loopback bitstream
   deployed but `ROLE_CFG=0x0` (lock didn't latch). `mask_hs_bypass`
   xlconstant in the loopback tcl may not be wired through correctly.
   Worth a 30-min debug session.

4. **Combined OR-merge hardening rebuild** — when next rebuilding,
   include `c5c16a8` for defence-in-depth even though current state is
   benign.

## Replication recipe

```bash
# On dev box:
cd /home/dam1n19/SoCLabs/td-bisect/td-calibrator-eyecenter
git checkout feat/calibrator-eyecenter  # HEAD c5c16a8

# Bitstreams already built; .bin files at:
#   imp/fpga/output/pynq-z2-pair-all/tidelink.bin       (master die_a)
#   imp/fpga/output/pynq-z2-pair-flip-all/tidelink.bin  (slave die_b)
# .bin sha256:
#   master: f0a9633fb06676c42fa1cf94b55761c2fc6d6a6b8ef7536880c96c91d455aa87
#   slave:  90bfad7c0986adccfd021bce1a9b93057c12cbfb8c5639b794671b9606b71a23

# Acquire lease and deploy:
ssh mapstone-dev "/opt/fpgahub/bin/fpgahub pair lease acquire bridge1 \
    --user \$(whoami) --ttl 3600"
# (stage bitstreams to /tmp/tidelink_deploy on mapstone-dev — see
#  CALIBRATOR_BUG_HANDOFF_2026_05_26.md staging procedure)

ssh mapstone-dev "cd /tmp/tidelink_deploy && \
    bash deploy_pair.sh 192.168.4.101 z2_02 die_a && \
    bash deploy_pair.sh 192.168.6.101 z2_03 die_b"

# Probe (expect bilateral LINK_IDLE):
ssh mapstone-dev "cd /tmp/tidelink_deploy && \
    bash wlink_probe.sh 192.168.4.101 master && \
    bash wlink_probe.sh 192.168.6.101 slave"
# Expected: both cal_done=1, FCSM=4, cr+crack=1, locked=0x00 (post-cal)

# Ring doorbell:
# ... see /tmp/loopback_deploy.log for the MMIO write sequence ...
# Result: DOORBELL_RESP_ACC stays 0 — Layer-2 issue, NOT in scope here
```

## Branch state (clean, all committed)

```
c5c16a8 WavD2DGpio: AND-clamp effective_phase_offset OR-merge (latent fix)
7eae0ea fpga: loopback target USE_IDELAY=0 + mask_hs_bypass=1 (single-board diag)
f467ced calibrator §9.11d: APB-tunable MIN_LOCK_DWELLS + S_VALIDATE Fix A1
c3c5bdc calibrator §9.11c: revert iter order to phase-OUTER, slip-INNER (THE FIX)
3fadb60 calibrator §9.11 validation: doorbell sim 5/6 PASS (test_05 M→S resolved)
c26f738 calibrator §9.11: design doc + eyemap dump diagnostic helper
52ac307 calibrator §9.11: eye-CENTRE via MIN_LOCK_DWELLS contiguity (Agent O)
```

(Plus the original 3 cherry-picked sim env commits at the base.)

## Related memory entries

* [[project-tidelink-calibrator-fix-2026-05-27]] — Agent F's S_PROBE baseline
* [[project-autocal0-hw-workaround-2026-05-27]] — original AUTOCAL=0 diagnostic
* [[project-tidelink-sim-repro-2026-05-26]] — sim repro from which §9.11d
  ultimately worked

## End-of-day signature

**§9.11c iter-revert is the headline fix.** Phase-OUTER iteration restores
sufficient M/S sweep-window overlap on real silicon to let independent
calibrators on independently-triggered chiplets converge to compatible
per-lane (slip, phase) tuples. §9.11d's APB knob + S_VALIDATE add
tooling and fallback paths but did not bind in this run.

The residual doorbell-silent state is a fundamentally different bug
(Layer 2, training-pattern vs real-data eye divergence) and is the
subject of the next session's work.
