# R1 residual — FCSM root-cause of the errinject wedge that survived TL-032

Date: 2026-08-09
Env: `cocotb/tidelink_axi_datanode_recovery` (VCS 2022.06-SP2, cocotb 1.7.2),
default (non-ASIC_NEGCTRL) config = FCSM recovery (local) + TL-032 a2l (local) +
ECC restore (local) + CRC, two TIDELINK_PHY_V2 dies at the ~40 ns silicon ratio.
Read-only + sim + `local_overrides` edits only. No board/lease/bitstream/commit.

--------------------------------------------------------------------------------
## BOTTOM LINE

1. **The silicon AW errinject wedge does NOT reproduce in the recovery sim env
   with the current all-fixes overrides.** Every AW error-inject scenario I drove
   RECOVERS byte-exact via the base NACK→replay + TL-032 a2l revert-rewind. This
   holds across FOUR independent configs (all-fixes, ECC-off, FCSM-recovery-
   stripped, persistent injection). TL-032 does **not** regress anything.

2. **The secondary gap the a2l-residuals plan flagged is REAL and confirmed:**
   the state-7 NACK watchdog (Fix D) is *dead code* after the first real CRC
   error — `socl_l7_real_crc_seen` is a sticky latch that pins `socl_l7_wdog_cnt`
   to 0 forever, so `socl_l7_wdog_force_clear` can never assert again. Measured:
   `wdog_cnt_max=0` across 54 state-7 entries with `real_crc_seen=1`.

3. **BUT re-enabling the watchdog (candidate a) is architecturally insufficient
   on its own.** Sim-measured: `force_clear` clears `send_nack_req`, but the
   state-7 EXIT is gated on `auto_tx_out_advance` (`_GEN_115`), which `force_clear`
   does NOT assert. So the backstop cannot break a pure emit-starvation state-7
   stall — exactly the stall type the on-silicon "hard hang" most resembles. This
   matches the HANDOVER doc's own hypothesis ("the stall is upstream of the
   watchdog, or the watchdog trip doesn't unblock the response return").

4. **Conclusion: the wedge is not cleanly reproducible/fixable in this sim env
   because it requires a state the bench cannot create** (TX-arbiter starvation
   from multi-node contention, real PHY/eye timing, and/or accumulated 128-write
   session state), **and/or the converged silicon bits differ from this env**
   (the ECC-restore and/or the full FCSM recovery set may not actually be in the
   shipped bits — see §3-repro). Precise silicon diagnostic in §7.

5. **Delivered fix (TL-033):** a minimal, revert-aware watchdog in all five FCSM
   overrides that (a) closes the confirmed dead-code hole (proven dead→live) and
   (b) does not regress any recovery test. Honest caveat: it is a *defensive
   backstop* for the send_nack_req-stuck case, NOT a proven wedge fix — the emit-
   starvation case additionally needs the state-7 EXIT change specified in §6.

--------------------------------------------------------------------------------
## 1. Topology / which unit wedges (verified)

AW inject: `_arm_injector(side="m", data_id=0x80)` corrupts the AW packet leaving
die_a. Node→module map (verified from the instance→submodule bindings):

| AXI node | data_id | FCSM module | a2l replay (TX) | TL-032? |
|----------|---------|-------------|-----------------|---------|
| AW | 0x80 | `WlinkGenericFCSM.v`   | `WlinkGenericFCReplayV2_1.v` | yes |
| W  | 0x81 | `WlinkGenericFCSM_1.v` | `WlinkGenericFCReplayV2_3.v` | yes |
| B  | 0x82 | `WlinkGenericFCSM_2.v` | `WlinkGenericFCReplayV2_5.v` | yes |
| AR | 0x83 | `WlinkGenericFCSM_3.v` | `WlinkGenericFCReplayV2_7.v` | no  |
| R  | 0x84 | `WlinkGenericFCSM_4.v` | `WlinkGenericFCReplayV2_9.v` | no  |

Flow: die_b's AW-FCSM (`u_slave…wlink_axiawFC`, module `WlinkGenericFCSM.v`)
detects the CRC error → enters **state 7 (SEND_NACK)**, `send_nack_req=1` → NACKs
die_a. die_a receives NACK (`isNackPacket`, ack/nack tag 3) → `a2l_fc_replay_
link_revert` → the AW a2l (`WlinkGenericFCReplayV2_1`, TL-032) rewinds and
replays. The wedge (if any) manifests on die_a as `a2l_full` stuck / `app_ready=0`
→ AHB write never completes → PS-bus hang.

--------------------------------------------------------------------------------
## 2. Reproduction attempts — ALL RECOVER (the key negative result)

Probe: `cocotb/tidelink_axi_datanode_recovery/test_a2l_r1_probe.py` (new; traces
die_b AW-FCSM state/send_nack_req/real_crc_seen/wdog_cnt/force_clear/crc_errors +
die_a AW a2l a2l_full/app_ready/a2l_link_addr, per inject).

| Config | Scenario | Result | Evidence |
|--------|----------|--------|----------|
| all-fixes (default) | AW pure-CRC payload (byte 5), 4× one-shot sweep | RECOVER ×4 | `wdog_max=0`, `rcrc=1`, `a2l.full=0`, byte-exact |
| all-fixes | AW byte-0 data_id (ECC on) | RECOVER, byte-exact | `crcerr=0` (ECC corrected) |
| ECC **off** (deps EccSyndrome, single-axis flist) | AW byte-0 data_id | RECOVER, byte-exact | `crcerr=0` — byte-0 inject is a no-op on delivery here |
| all-fixes | AW **persistent** payload (`err_inj_smack`) | RECOVER | 54 state-7 entries, `wdog_max=0`, settles |
| **ASIC_MIRROR=1** (deps FCSM = recovery STRIPPED + TL-032 a2l) | AW pure-CRC, 4× | RECOVER ×4 | `rcrc=None` (deps FCSM), byte-exact |

Standard suite also re-run against the TL-033 build (see §5): `gaps_nodes`
(AW/W/AR/R recover + R non-vacuity) all PASS; `test_axi_b_error_recovers`
(FCSM_2) PASS.

**Interpretation.** The base NACK→replay + TL-032 a2l revert recovers every AW
errinject in sim — even with the FCSM recovery set entirely stripped (deps). The
CRC→NACK→replay stall that the a2l-residuals plan traced does **not** stall here.
Notably byte-0 (the *actual silicon byte*) recovers byte-exact regardless of ECC,
so if silicon wedges on byte-0 the shipped bits must differ from this env.

--------------------------------------------------------------------------------
## 3. The dead-watchdog mechanism (confirmed) + why state-7 exits without it

### 3a. State-7 has a natural exit that does not need the watchdog
`_GEN_115 = auto_tx_out_advance ? 3'h4 : state` — state 7 → state 4 when a NACK
word is emitted. In state 4, `send_nack_req` clears via `_GEN_71`
(`send_nack_req ? 1'h0 : …`). So the normal NACK cycle is 7→4→(normal), and the
counter's `state != 3'h7` reset means a legit replay (which cycles through 4)
never accumulates dwell. This is why every scenario in §2 recovers with
`wdog_max=0`.

### 3b. The watchdog is DEAD after any real CRC error
`WlinkGenericFCSM.v` (pre-fix):
```
wire socl_l7_wdog_force_clear = (socl_l7_wdog_cnt == THRESHOLD) & ~socl_l7_real_crc_seen;
…
else if (state != 3'h7)          socl_l7_wdog_cnt <= 0;
else if (socl_l7_real_crc_seen)  socl_l7_wdog_cnt <= 0;   // <-- pins to 0 forever
else if (cnt != THRESHOLD)       socl_l7_wdog_cnt <= cnt+1;
```
`socl_l7_real_crc_seen` latches on the FIRST `crcCorruptSeen` and never clears.
So after any real CRC error the counter is pinned at 0 and `force_clear` can never
assert. Fix D added `~real_crc_seen` to avoid stomping a legit in-progress NACK,
but used a *sticky latch* as the proxy — which disables the backstop precisely
when a real CRC has occurred, i.e. exactly when a stuck state-7 could happen.

**Measured (white-box forced-stall test, LEGACY build):** with die_b AW-FCSM
frozen in state 7 (`auto_tx_out_advance` forced 0) after a real-CRC inject
(`real_crc_seen=1`): `wdog_cnt_max=0`, `force_clear=False`, `send_nack_req` never
cleared. **Backstop confirmed dead.**

### 3c. …but the watchdog is architecturally the wrong lever
Same forced-stall test, TL-033 (fixed) build: `wdog_cnt_max=THRESHOLD`,
`force_clear=True`, `send_nack_req` cleared — **but `state_left_7=False`**: the
state-7 EXIT needs `auto_tx_out_advance` (`_GEN_115`), which `force_clear` does
not provide. So clearing `send_nack_req` alone cannot break a pure emit-
starvation state-7 stall. (Once advance resumes, both builds settle naturally at
state 4 — so the watchdog isn't needed for a *temporary* stall either.)

The watchdog `force_clear` therefore only helps the "post-stall bounce" case
(advance available, `send_nack_req` re-forcing state 7), never the emit-stall
case. The on-silicon hard hang (no Region-F trip, needs JTAG-POR) reads as an
emit-stall, so §6's state-7-exit change is the load-bearing part if silicon
confirms it.

--------------------------------------------------------------------------------
## 4. TL-032 regression check — CLEAN

TL-032 (a2l revert-aware rewind in `WlinkGenericFCReplayV2_{1,3,5}.v`) was NOT
touched. All recovery tests pass with it present, including the FCSM-recovery-
stripped config (ASIC_MIRROR=1) where TL-032 is the *only* recovery override —
and it still recovers. No sign TL-032 interacts badly with the FCSM revert.

--------------------------------------------------------------------------------
## 5. The fix (TL-033) — implemented + sim-proven (arming + non-regression)

Files (local_overrides only): `WlinkGenericFCSM.v`, `_1.v`, `_2.v`, `_3.v`, `_4.v`.
Three changes each, all confined to the Fix-D watchdog block:

1. `SOCL_L7_WDOG_THRESHOLD` made compile-overridable (`SOCL_L7_WDOG_THRESHOLD_VAL`,
   default `16'h4000` — **silicon value UNCHANGED**), mirroring the existing
   `SOCL_L7_MIN_CRACK_EMITS_VAL` pattern, so the white-box arming test can trip
   the backstop in a sim-able window.
2. `socl_l7_wdog_force_clear`: drop the `& ~socl_l7_real_crc_seen` gate.
3. `socl_l7_wdog_cnt`: replace the sticky `else if (socl_l7_real_crc_seen)` reset
   with an INSTANTANEOUS forward-progress reset
   `else if (socl_l7_wdog_progress)`, where
   `socl_l7_wdog_progress = auto_tx_out_advance` (a NACK/word actually emitted).
   A legit replay emits → resets the counter → never stomped; only a state-7
   dwell with ZERO emit for THRESHOLD cycles trips. This is the correct,
   *non-sticky* form of Fix D's intent. (isAckPacket was tried as an extra
   progress term but is too lenient — background ACKs on the shared ack/nack
   fifo kept the counter clear under a genuine emit-stall; dropped it.)

A `+define+TL033_LEGACY_WDOG` restores the pre-fix behaviour for the repro.

**Before/after proof** (`test_wdog_arming_forced_stall`, threshold forced to 16):
| build | wdog_cnt_max | force_clear | send_nack_req cleared | state left 7 |
|-------|-------------|-------------|-----------------------|--------------|
| LEGACY (pre-fix) | 0 | False | no | no |
| TL-033 (fix)     | 16 | True | **yes** | no* |

*state stays 7 while `auto_tx_out_advance` is forced 0 — the §3c efficacy limit.

**Non-regression** (default threshold 16'h4000, TL-033 build):
`test_axi_aw_error_recovers`, `test_axi_w_error_recovers`,
`test_axi_ar_error_recovers`, `test_axi_r_error_recovers`,
`test_axi_r_error_wedges_no_fix` (non-vacuity), `test_axi_b_error_recovers`
— all PASS. My probe payload sweep / byte0 / persistent also still recover.

--------------------------------------------------------------------------------
## 6. What a COMPLETE fix needs (specified, NOT yet sim-provable)

If silicon confirms an emit-starvation state-7 stall (see §7), TL-033 alone will
not break it. The additional change is to let the backstop force the state-7 EXIT,
not just clear `send_nack_req`:

- In the state next-state logic, make state 7 leave on `auto_tx_out_advance |
  socl_l7_wdog_force_clear` instead of `auto_tx_out_advance` alone
  (`_GEN_115` in each FCSM). Semantics: after THRESHOLD cycles of zero emit, drop
  the pending NACK and return to state 4. This converts a HARD HANG into a
  bounded lost-NACK (the peer's data is then recovered by the I5 outstanding-
  response backstop / a later re-ACK), i.e. recoverable without JTAG-POR.
- Risk: dropping a legit-but-slow NACK. The THRESHOLD (16384 tx-clk cycles) is
  the guard; must be validated against the real 40 ns-ratio round-trip on silicon
  before shipping. **Do not ship this blind** — it is a state-machine behaviour
  change and cannot be proven without the repro.

Alternative / complementary (higher-confidence, config-level): confirm the
converged silicon bits actually contain the ECC-restore (local `WlinkEccSyndrome`)
AND the full FCSM recovery set — not just TL-032. In sim the ECC-restore makes
byte-0 recover byte-exact; if the shipped bits lack it, byte-0 wedges on silicon
while every sim config here recovers. This is the most likely explanation for a
byte-0 silicon wedge and is a flist/build fix, not new RTL.

--------------------------------------------------------------------------------
## 7. Exact silicon retest / next diagnostic

Rig an ILA (or the existing obs registers) on **die_b's AW-FCSM**
(`u_slave…wlink_axiawFC`) during `cov_errinject_sweep` (op=w byte=0 bit=0), and
capture, at the moment of the hang:

- `state[2:0]` — is it stuck at 7? (confirms state-7 stall vs. something upstream)
- `send_nack_req`, `socl_l7_real_crc_seen`, `socl_l7_wdog_cnt` — is the counter
  pinned at 0 (confirms the dead-watchdog) or counting?
- `auto_tx_out_advance` — is it flat 0 during the dwell (emit-starvation ⇒ §6
  state-exit change needed) or pulsing (bounce ⇒ TL-033 suffices)?
- die_a AW a2l `a2l_full` / `app_ready` — is die_a's stall a consequence of
  die_b's state-7 (chained) or independent?
- `crc_errors` / `io_rx_crc_err` on the AW node — did the byte-0 inject raise a
  CRC error at all (⇒ CRC path), or was it a silent drop (⇒ ECC/data_id path,
  points to the §6 config fix)?

Also confirm the shipped bits' FCSM/ECC provenance (are `WlinkEccSyndrome` and
`WlinkGenericFCSM*` the local overrides or deps in the converged build?).

--------------------------------------------------------------------------------
## 8. Suggested BUG_REGISTRY entry (do NOT edit the registry — concurrent hot file)

```yaml
- id: TL-033
  title: State-7 NACK watchdog (Fix D) is dead code after the first real CRC error
  severity: medium            # latent backstop hole; not the sole wedge cause
  status: fix-in-local-overrides (sim-proven arming + non-regression); silicon-unconfirmed
  area: axi-chiplet-controller/wlink FCSM (WlinkGenericFCSM{,_1,_2,_3,_4}.v)
  found: 2026-08-09 (R1 residual after TL-032)
  detail: >
    socl_l7_real_crc_seen is a sticky latch; it pins socl_l7_wdog_cnt=0 and gates
    off socl_l7_wdog_force_clear, so the state-7 backstop is permanently disabled
    after the first crcCorruptSeen — exactly when a stuck state-7 could occur.
    Sim-measured wdog_cnt_max=0 across 54 state-7 entries. Fix (TL-033): replace
    the sticky real_crc_seen proxy with an instantaneous forward-progress proxy
    (auto_tx_out_advance); drop the real_crc_seen gate on force_clear. Proven
    dead->live + non-regressing.
  caveat: >
    force_clear clears send_nack_req but the state-7 EXIT is gated on
    auto_tx_out_advance (_GEN_115), so TL-033 alone does NOT break an emit-
    starvation state-7 stall. A complete fix additionally needs state-7 to exit on
    (auto_tx_out_advance | socl_l7_wdog_force_clear) — a state-machine behaviour
    change requiring silicon repro to validate. The reproducible AW errinject
    wedge does NOT occur in the recovery sim env (all configs recover via base
    NACK->replay + TL-032); confirm shipped-bits ECC/FCSM provenance.
  repro: cocotb/tidelink_axi_datanode_recovery test_a2l_r1_probe.py
         (test_wdog_arming_forced_stall, +define+TL033_LEGACY_WDOG for pre-fix)
```

--------------------------------------------------------------------------------
## 9. Artifacts

- RTL (local_overrides, uncommitted): `WlinkGenericFCSM.v`, `_1.v`, `_2.v`,
  `_3.v`, `_4.v` — TL-033 revert-aware watchdog (+ `TL033_LEGACY_WDOG` toggle,
  `SOCL_L7_WDOG_THRESHOLD_VAL` override). a2l TL-032 files untouched.
- Test: `cocotb/tidelink_axi_datanode_recovery/test_a2l_r1_probe.py`
  (payload sweep / byte0 / persistent / forced-stall arming).
- Single-axis flist: `cocotb/tidelink_axi_datanode_recovery/tidelink_fpga_v2_eccoff.flist`
  (ECC→deps, FCSM+a2l local) for the ECC-off experiment.
- Logs: scratchpad/{aw_recover,r1_probe,r1_byte0,r1_persist,eccoff_*,mirror_*,
  wdog_fix3,wdog_legacy3,regress_gaps_nodes,regress_b}.log
