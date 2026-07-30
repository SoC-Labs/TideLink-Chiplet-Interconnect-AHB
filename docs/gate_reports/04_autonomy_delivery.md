# Autonomy / bring-up / delivery (agent #4) — 2026-07-30 — HIGH-VALUE

## Headline (shipping-critical)
- H1 (BIGGEST embedding hazard): link_active = role_locked (tidelink_top.sv:2836), and role_lock is STEP 0 (before cal/anchor/credit/data) + stays HIGH on a wedged link (Fault 2). eth-chiplet gates its whole TX aperture (hsel_tx) on link_active (ETHERNET_CHIPLET_INTEGRATION.md:139,258). => an SoC that opens TX on link_active pushes into a not-yet-live/wedged link -> ahb_tx 1.3ms stall->AHB ERROR, or PS HANG on silicon. NO exported signal proves a byte crossed. tl_local_link_state_o is a CONGESTION EWMA (tidelink_perf.sv:338), not delivery.
- H2: mandated zero-poke autonomy is NOT what embedded consumers get. tidelink_top.sv:131 default NEGO_CFG_RESET=0x00 (autoneg OFF -> parks ST_BYPASS). Every consumer overrides ONLY NUM_PHY_LANES; only FPGA target TCLs bake 0x61. Embedded => firmware APB bring-up. g2_soc_pair reproduces Fault-2 territory (autoneg parks short of LINK_IDLE; manual 4/4, autoneg 1/1).
- H3: flagship gated zeropoke_por PASSES on fcsm=4+cal, moves ZERO bytes (test_zeropoke_por.py:246-279) -> BLIND to Fault 2 (which is exactly fcsm=4 + rxp=0). The gate that certifies the deliverable doesn't test the deliverable.

## CRITICAL new facts
- **0x008 ≡ 0x208 ALIAS ROOT-CAUSED IN RTL:** Wlink.v:1179-1181 truncates paddr[9:0], indexes [7:2] -> [9:8] DROPPED -> 0x008 and 0x208 hit the SAME LL swreset/enable reg. tidelink_top.sv:2454 compares full 13'h208 = decode-WIDTH MISMATCH. Real latent bug; firmware/fabric reading 0x008 can hit LL swreset.
- **BRANCH HAZARD:** fix/v2-sync-clock-gate's unconditional clock-gate fix — the 2026-07-30 ADDENDUM to the sync-clock handover PROVES it BREAKS bring-up (cal=0 fcsm=1, no anchor, on TWO baselines). DO NOT build embedded images from it. The pad_clkgate guard is GREEN-BUT-BLIND to this (forces tx_en=0, can't reach winscan/calibration). Packaged FPGA IP copy still has the OLD gate anyway.
- SWI_RECAL is a no-op after first lock (calibrated_once_q); only SWI_FORCE_RECAL R8[6] or POR re-arms. No software re-anchor; consumers share SoC reset tree, NO link-scoped reset.
- s_i2c_axi CPU->I2C-master port UNCONNECTED in every consumer; I2C is peer-sideband only.

## 12 proposed tests (ranked)
T1 byte-exact BIDIRECTIONAL delivery as SOLE liveness oracle (fuse v2_pair_sustained onto zeropoke_por path; ban status-only PASS; promote hw_regression/zeropoke_proof.sh into a HW gate). T2 in-SoC zero-poke bring-up (elevate g2_soc_pair to autonomous posture, RED if parks short of LINK_IDLE). T3 link_active semantic gate (assert it does NOT mean data-ready; TX-into-not-ready -> clean ERROR not hang). T4 credit soak w/ SoC drain backpressure. T5 re-bring-up-after-drop (needs a link reset leaf). T6 Fault-2 localization ladder (0x2108[31:17] + 0x2114[31:16] sync_detected; first-zero). T7 FC-handoff training-fall-edge robustness. T8 0x008/0x208 alias+width test. T9 dead/absent-I2C embedded bring-up. T10 reset-skew bilateral-clock. T11 strap-polarity/param conformance. T12 idle-link forwarded-clock liveness (the owed sim; deltas not saturating counters; re-run for BRING-UP on silicon since fix breaks it).
Rank: 1) T1/T3/H1 (link_active-trusted bus hang). 2) T2/H2 (embedded non-autonomous). 3) T7+T6 (Fault 2). 4) T5 (no re-bring-up). 5) T4. 6) T10/T9. 7) T8. 8) T12/T11.

## green-but-blind flags
zeropoke_por (status-only), t31 claims bilateral but M->S only, sim can't reach Fault2/idle-clock (g2_soc_pair BYPASSES calibrator test_g2_soc_pair.py:142), test_v2_onchip_pair returns 5 PASS @0ns (false-green). Only zeropoke_proof.sh on real dies reaches silicon-faithful autonomy — in NO mandatory gate.
