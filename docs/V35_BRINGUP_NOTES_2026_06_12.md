# TideLink v35 (PHY V2) — bridge1 first-silicon bring-up notes, 2026-06-12 session

**Build:** v35 = `feat/phy-v2-integration` @ `6b8ab00` (FIX-N..R serdes, always-on V2
calibrator, autonomy POR defaults), `pynq-z2-pair-all` / `-flip-all`, staged at
`mapstone-dev:~/tidelink_artefacts/v35` (sha `aa7f9f9a…` non-flip / `72ba6065…` flip).
**Boards:** bridge1 = z2_02 (die_a, 192.168.4.101, non-flip) ↔ z2_03 (die_b,
192.168.6.101, flip). Lease via `fpgahub pair lease acquire bridge1`.
**Outcome: PARTIAL.** First CR/CRACK exchange + unilateral FCSM LINK_IDLE (fcsm=4,
cr=1, ck=1, llv=1 on die_b) on the new PHY — repeatable with the sequence below.
Bilateral LINK_IDLE blocked: the z2_03→z2_02 direction never decodes FCSM short
packets (precise signature in §4). No M→S data word attempted (gate not met).

---

## 1. Working (best-known) sequence — "park-and-freeze"

All registers base 0x44032000 unless noted. `slot0` = 0x44032100
(bit0 = swi_training_mode hold+TX-drive, bit1 = SWI_RECAL). Helper scripts:
`mapstone-dev:~/tl35.py` (staged on both boards at `/home/xilinx/tl35.py`),
`~/tl35.sh`, `~/v35_round2.sh` (full round, exactly this recipe).

1. **Deploy both in parallel** (`deploy_pair.sh`, two backgrounded jobs, `wait`).
   Autonomy runs once at boot and terminal-parks (master: ST_TRAIN_FAIL sticky,
   slave: NEGO_DONE) — it does NOT fight later pokes. NOTE deploy no longer pokes
   ROLE_CFG; roles come from the I²C claim and CAN swap per boot (observed once,
   incl. one boot with nego err=1 on die_a).
2. **Relax the lane-checker lock threshold on BOTH dies:**
   `wr 0x44032160 = 0x55555555` (per-lane 3-bit Hamming thresh, POR=3 → 5).
   **Required.** With POR thresh=3 the marginal die's 128-point sweep never gets
   all 8 lanes past `lane_score >= lock_thresh` in the SAME sweep (M11 class:
   lanes pass only rarely per sweep; union-over-sweeps = 0xff but never jointly).
   With thresh=5 the sweep parks in <2 s. Thresh=5 is still noise-immune
   (random-word 16-consecutive-match probability ≈ 1e-11).
3. **Coordinated arm on BOTH (parallel, ~1 SSH RTT):**
   `slot0=0x1; sleep 10ms; slot0=0x3; sleep 2ms; slot0=0x1`
   (= BIST `arm_one` FIX-F Option-2: force bilateral training carriers via the
   slot0-bit0 OR into the PHY TX drive, then SWI_RECAL falling edge re-arms a
   FRESH sweep against the live peer training; FIX-E catches success in S_HOLD).
   Verify: both `OBS_CAL[3:0]` (0x44032198) = 6 (S_HOLD), 0x108 lk → up to 0xff/0xff.
4. **Freeze BOTH (parallel): `slot0=0x2`** (drop training, HOLD SWI_RECAL high).
   The calibrator parks in S_CANCEL/S_DONE with the latched per-lane (slip,phase)
   applied and training_mode=0 → both carriers switch to FC data; the Wlink FCSMs
   (independent of cal_done) exchange CR/CRACK. This sidesteps S_VALIDATE entirely.
5. **Success criterion:** 0x108 on both → fcsm[19:17]=4 (LINK_IDLE) + cr[23] +
   ck[24] + llv[29]. THEN (and only then) the single-word data test
   (master 0x44000000 ← 0x57A40001; slave read 0x44010000).

Evidence (die_b side reached link-idle, repeatedly — boots of 22:39Z and 23:0xZ):

```
b[cal=0 fcsm=4 llrx=0 cr=1 ck=1 llv=1 a2l=0 full=0 cstate=5]   # LINK_IDLE, decoded a's CR AND CRACK
a[cal=0 fcsm=2 llrx=0 cr=1 ck=0 llv=0 a2l=1 full=0 cstate=5]   # stuck waiting b's CRACK
```

## 2. What does NOT work (tried, with evidence)

* **Zero-poke / plain deploy:** both calibrators loop failing sweeps forever
  (cstate=2 at every 1 Hz sample); autonomy master times out POLL_PEER →
  ST_TRAIN_FAIL (tst=6 sticky). lk flickers 0–8/8.
* **slot0=1 hold alone (the earlier tonight attempt):** the V2 arm DISCONNECTED the
  Bug-N3 re-arm (`training_mode_set_swreset_w` is defined but unconsumed in the
  `TIDELINK_PHY_V2` branch of `axi_chiplet_controller.sv`), so setting bit0 never
  re-sweeps; the FSM gets caught in S_HOLD with a STALE garbage latch → lk=0/8.
  The SWI_RECAL pulse (step 3) is mandatory.
* **Coordinated release (slot0 1→0 on both, the BIST coord-hold release):** both
  drop into S_VALIDATE but v35 instantiates the V2 calibrator with ALL DEFAULTS →
  `VALIDATION_TIMEOUT=4096` link-cycles (~655 µs @6.25 MHz) vs the V1 port's
  2,000,000 (320 ms). The 12 ms re-arm loops' 655 µs windows are near-periodic
  and never rendezvous (M8-class carrier starvation). Observed: 10 s of cstate=2
  bilaterally, cr/ck never latch.
* **Staggered release (slave loops, master held listening):** master (parked
  8/8, lk=0xff steady) never latched sticky cr in 12 s of slave windows.
* **Wlink CTRL toggles (0x44030208 FULL→DIS→FULL) to restart a wedged FCSM:** no
  effect (bit[3] swreset is Tier-2 AND-masked; enable-bit cycling does not clear
  the exchange state). After failed exchanges die_a latches fe_rx_is_full=1
  (Bug-A wedge fingerprint).
* **LL_RX framer re-hunt retries** (slot0 0x2→0x3→0x2, pulses llrx_reset via the
  local-training-high gate): 0/8 retries produced a decode on the dead direction.
* **SWI_BIT_SLIP OR-nudges** (0x44032104 = 0x249249/0x492492/…/0xFFFFFF): llv
  responds (datapath moves) but cr/ck never latch → the missing alignment is
  OUTSIDE the 3-bit slip range.
* **Redeploy lottery:** 8+ whole-pair boots; the dead direction never flipped.

## 3. v35 RTL findings (build-level, for the next spin)

1. **V2 calibrator instantiated with all defaults** (`axi_chiplet_controller.sv`
   `TIDELINK_PHY_V2` arm, no `#(...)`): `VALIDATION_TIMEOUT=4096` (~655 µs) — far
   below the CR/CRACK oracle latency budget the V1 port used (2M ≈ 320 ms), and
   `MAX_RESWEEPS=0` + `VAL_TIMEOUT_TO_DONE=0` → infinite S_VALIDATE→S_ARM thrash.
2. **Bug-N3 re-arm disconnected in V2** (`training_mode_set_swreset_w` unconsumed)
   → SWI_TRAINING_MODE rise no longer re-arms; only SWI_RECAL falling edge does.
3. **M11b `min_lock_dwells_r` is V1-only** (V2 calibrator has no such port); the
   live SW knob for marginal eyes is the lane-checker LOCK_THRESH APB reg
   (`tidelink_gpio_phy_apb_regs` ADDR_THRESH → MMIO **0x44032160**, POR 3/lane).
   POR=3 is too strict for this board pair; consider POR=5 or script the write.
4. **USE_IDELAY=1 in the FPGA wrapper** (`fpga/vivado_ip/tidelink_vivado_wrapper.v`,
   enforced by `check_wrapper_params.sh`) — but the silicon-validated BIST config
   of this exact PHY bypassed IDELAY (tidelink-gpio-phy-deskew
   `docs/archive/DECISION_F1_IDELAY.md`, Option A: ≤2.34 ns tap is ~1.5% of the
   160 ns bit cell; uncalibrated bank-35 IDELAYE2 is a drift liability).
   Deviation to reconcile (likely flip the FPGA packaged-IP default to 0).
5. **V2 word-disambiguation surface is tied off at the calibrator**
   (`lane_pin_converge_en_i=1'b0`, `sync_seen_i=1'b0`, PRBS_EYESCAN off);
   `swi_word_pin_auto_en` is hardwired 1'b1 (WORD_PIN_AUTO comma re-pin on),
   `swi_word_pin_in=4'h0`. There is NO runtime override of the word pin in the
   tidelink register surface (the BIST had BIT_SLIP_OVR[28] + winscan).
6. Lane-checker readback (0x108 lk) quality does NOT track data-path health:
   die_b completed CR/CRACK to LINK_IDLE on a boot where its checker read 0x00.

## 4. THE BLOCKER — precise signature

**Direction z2_03→z2_02 (flip-image TX → non-flip RX) never decodes FCSM short
packets, deterministically, across ≥8 independent boots, both freeze orders,
either role assignment, 8 framer-reset retries and 8 slip-nudge values.**

* z2_02→z2_03 works fully and repeatedly: die_b decodes die_a's CR and CRACK,
  reaches fcsm=4 LINK_IDLE, llv=1 continuous.
* z2_03→z2_02: die_a holds solid 8/8 training lock (lk=0xff sustained in S_HOLD)
  and llv=1 (the LL_RX sees valid-shaped traffic), but cr/ck NEVER latch (single
  transient cr=1 sticky observed once at 22:39Z; never again). The FCSM then
  wedges (fcsm=1/2, later fe_rx_is_full=1) and, with 0x208[3] masked, cannot be
  restarted from SW.
* Consequence chain: cr|crack oracle can never fire on die_a → S_VALIDATE can
  never confirm → cal_done unreachable → autonomy ST_TRAIN_FAIL. The "M8
  chicken-egg" called out in tonight's earlier findings is real but one level
  shallower than the root cause: even with carriers held up and the LL out of
  reset, the dead direction does not deliver shorts.
* Classification: 8-bit-periodic training pattern locks blind to the mod-16
  word/byte phase; the 3-bit slip cannot reach it; immune to LL re-hunt; ⇒
  word/byte-phase (FIX-R WORD_PIN_AUTO domain) or flip-image TX launch-path
  effect, in the one direction. WORD_PIN_AUTO is compiled+enabled but evidently
  not correcting this direction in-system — first suspects: the un-ported
  "CDC F2" item from the PHY integration-readiness blocker list, and the
  flip-target TX clock/launch differences vs the (validated, two-bitstream
  straight-ribbon) BIST harness.

## 5. Next steps

1. ILA on z2_02: post-deskew 128-bit bus + per-lane `word_pin` /
   comma-matcher activity in WavD2DGpioRx while z2_03 retries CR (the frozen
   park state makes this a stable, repeatable capture).
2. Port/verify the CDC F2 fix from the PHY repo finalization list; diff the
   flip-all target's TX clocking vs the BIST flip image.
3. Build spin (v36) with: `VALIDATION_TIMEOUT` ≥ 2M (or M9 retry budget),
   Bug-N3 re-arm consumed in the V2 branch, LOCK_THRESH POR=5 (or deploy-script
   write), runtime word-pin override exposed (BIT_SLIP_OVR[28]-equivalent),
   and the DECISION_F1 IDELAY-bypass decision reconciled for FPGA targets.
4. Keep `~/v35_round2.sh` as the bring-up driver; success gate = bilateral
   fcsm=4 + cr + ck, then the single-word M→S test (do NOT storm; credits-full
   single word per runbook §9).

## 6. Session ledger

* Cycle 0–1: baseline (autonomy terminal; both calibrators thrash; lk flicker).
* Cycle 2–4: ported BIST arm; discovered single-side park anti-pattern; learned
  peer redeploy invalidates the partner's latched alignment (pair-mutual skew).
* Cycle 5–7: whole-pair lottery rounds — exactly one side parks per boot at
  thresh=3.
* Cycle 8: **LOCK_THRESH 3→5 ⇒ instant bilateral S_HOLD park (lk 0xff/0xff).**
* Cycle 9: release rendezvous starvation confirmed (both thrash, no stickies).
* Cycle 10–12: **freeze-in-S_CANCEL recipe ⇒ first CR/CRACK on the new PHY;
  die_b fcsm=4 LINK_IDLE; dead direction isolated (order-independent).**
* Cycle 13–14: framer-retry + FCSM-restart + slip-nudge falsifications.
* Boards left frozen (slot0=0x2 both) on the last lottery boot; helpers staged;
  pair lease released at session end.
