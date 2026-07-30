# I1 eth-chiplet bring-up fix — SELF_ARM_TRAIN_EN (self-arm role-lock)

Branch: `fix/i1-selfarm-rolelock` (RTL + docs; NO push, NO FPGA build, NO HW).
Date: 2026-07-30. Base: `main` @ `18491ef`.
Companion analysis: `strategy/i1-training-arm:docs/I1_TRAINING_ARM_ROOTCAUSE_FIX.md`.

All acc line refs below are the FIXED `src/rtl/local_overrides/axi_chiplet_controller.sv`
in THIS branch (post-edit); the "before" line numbers are called out where they matter.

---

## 1. The bug and the silicon-proven mechanism

On the KR260 eth-chiplet the **deps** FCSM build brings the internal die-to-die
link up to `fcsm=4 / cal_done=1`, but the **I1 recovery-FCSM override** build does
NOT (`fcsm=0 / cal_done=0`). A backdoor arm-chain read on both (same `90fe6cc`
base) proved the ONLY differing signal is **`role_locked`**: deps = **1**,
override = **0**. Everything else was identical (`nego_status=0x06`,
`mask_hs_gate_open=0`, `training=0`, both dies).

`role_locked` is a **MUTUAL CLOCK ENABLE**: `wlink_por_reset = ~poresetn |
~role_locked` (acc). With it stuck 0 it holds every FCSM in reset AND gates this
die's forwarded `pad_clk_tx` (= the peer's `pad_clk_rx`), so the calibrator can
never run ⇒ `cal_done=0 ⇒ fcsm=0`. Fixing `role_locked` to reach 1 is therefore
the whole fix — the rest of the chain is proven to follow (the deps build reaches
`fcsm=4` from `role_locked=1` with the identical bring-up script).

### Why role_locked stays 0 (the latch)

`role_lock_reg` is POR-clear-only and latches at the acc role-lock block. Before
the fix the only latch terms were:

```
if ((nego_lock_pending_reg && mask_hs_gate_open) ||
    (nego_lock_pending_reg && nego_lost_w)) role_lock_reg <= 1'b1;
```

The PS bring-up writes `ROLE_CFG=0x02` (W1S of `ROLE_CFG[1]`), which sets
`nego_lock_pending_reg` — but the gate never opens:

- `mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i` is 0 because the peer-I2C
  mask-handshake control plane never completes (`mask_hs_bypass_i=0` on silicon,
  no peer 0x21C verdict, no local I2C compare).
- `nego_lost_w = 0` (see §2 — on the eth-chiplet the autoneg is in BYPASS).

So `nego_lock_pending_reg` is set but never consumed ⇒ `role_lock_reg` never
latches. This is exactly the anti-pattern the lab rule warns against:
**role-lock must NEVER wait on a protocol event**
(`project_role_lock_is_a_mutual_clock_enable`).

---

## 2. Key finding — the eth-chiplet runs **nego_en = 0** (corrects the training-arm doc)

The training-arm analysis (`strategy/i1-training-arm`) assumed `NEGO_CFG_RESET=0x61`
(nego_en=1) via `tidelink_dft_wrapper.sv:161`. **The eth-chiplet does NOT use that
wrapper.** `nanosoc_eth_chiplet.sv:603` instantiates `tidelink_top` DIRECTLY:

```
tidelink_top #(.NUM_PHY_LANES(NUM_PHY_LANES)) u_tidelink ( ... );
```

and the eth-chiplet's `src/rtl/local_overrides/tidelink_top.sv:123` defaults
`NEGO_CFG_RESET = 7'h00` (my `main` `tidelink_top.sv:141` is also `7'h00`). The
instantiation overrides only `NUM_PHY_LANES`, so **`nego_en = nego_cfg_reg[0] = 0`**.

Consequences (all confirmed by reading the acc + `tidelink_autoneg.sv`):

- The autoneg parks in **BYPASS** (`tidelink_autoneg.sv:1805` "the FSM has sampled
  nego_en=0 and parked in BYPASS"); it never walks the `ST_TRAIN_*` sub-flow, so
  `local_training_mode_set_w` / `local_training_mode_clr_w` **never fire** and
  `nego_lost_w` is 0.
- `autonomy_armed = nego_en & role_locked & nego_train_cfg_r[0] & ~retire = 0`, so
  the **autonomous** winscan, SYNC-config drive and `fch_arm` FC-handoff are all
  DORMANT. `fcsm→4` is reached instead by the bring-up script's **manual LL
  bootstrap** (the three `0x0208` writes — `LL_SWRESET_ON/OFF/ENABLE`), exactly
  like the `test_g2_soc_pair` sim recipe. This is why deps reaches `fcsm=4`
  without any host winscan in the script.
- The **calibrator** arm is NOT nego_en-gated: `calibrator_role_locked =
  role_locked & AUTOCAL_ENABLE`, and `AUTOCAL_ENABLE(1'b1)` is hard-set at the
  eth-chiplet's `tidelink_top`→acc instantiation. So once `role_locked=1` the
  calibrator sweeps — but it needs `swi_training_mode_r` HIGH to decode the peer
  training pattern (the Bug-N3 `swi_training_mode_rise` re-arm). Under nego_en=0
  the autoneg won't raise it, so **the PS must SW-write `SWI_TRAINING_MODE=1`**.

Net: role-lock must self-latch on SW intent, AND training must be SW-raised.

---

## 3. The fix (default-OFF `SELF_ARM_TRAIN_EN`)

### 3a. RTL — `src/rtl/local_overrides/axi_chiplet_controller.sv` (4 edits)

1. **New parameter** (after `TRAIN_ENTRY_FALLBACK`, ~acc:89-90):
   `parameter bit    SELF_ARM_TRAIN_EN    = 1'b0,`  — default OFF, constant-folds
   away for every existing build.

2. **role-lock self-latch** — third OR term at the latch (`if` block, was acc
   `857-859`):
   ```
   if ((nego_lock_pending_reg && mask_hs_gate_open) ||
       (nego_lock_pending_reg && nego_lost_w)      ||
       (nego_lock_pending_reg && SELF_ARM_TRAIN_EN)) begin   // <-- added
       role_lock_reg <= 1'b1;
   ```
   The SW `ROLE_CFG[1]` write sets `nego_lock_pending_reg`; with the param on,
   `role_lock` latches ~2 apb_clk after the write, independent of the peer
   handshake. **`mask_hs_verified_reg` is NOT touched** (it is still driven by
   `mask_hs_match` ALONE at acc:784-785), so RETIRED-autonomy entry (acc:~4701)
   still fails closed — a self-armed role-lock does **not** forge the integrity
   witness.

3. **pending-clear symmetry** (was acc:793) — add `|| SELF_ARM_TRAIN_EN` so
   `nego_lock_pending_reg` clears after the self-arm latch instead of sticking
   (cosmetic; constant-folds away when OFF).

4. **training-clr gate** (was acc:2117):
   ```
   else if (local_training_mode_clr_w && !SELF_ARM_TRAIN_EN)   // <-- gated
       swi_training_mode_r <= 1'b0;
   ```
   Robustness/belt-and-suspenders: if a build ever runs the eth-chiplet with
   nego_en=1, the autoneg's `ST_TRAIN_EXIT` cannot wipe the SW-held training out
   from under the cal_done poll. On the current nego_en=0 eth-chiplet this strobe
   never fires, so it is a no-op there. The **explicit SW slot-0 write** (the
   `region8_write` case, which fires LATER in the same `always_ff` and therefore
   wins) still clears training — that is the recipe's step-3 `SWI_TRAINING_MODE=0`
   that takes the falling edge to data mode.

### 3b. RTL threading (default-OFF everywhere)

- `src/rtl/tidelink_top.sv` — new `parameter bit SELF_ARM_TRAIN_EN = 1'b0` (end of
  the param list, ~:219-227) forwarded `.SELF_ARM_TRAIN_EN (SELF_ARM_TRAIN_EN)`
  at the `axi_chiplet_controller` instantiation (~:2531-2534).
- `src/rtl/asic/tidelink_dft_wrapper.sv` — param + pass-through (default OFF; the
  standalone ASIC path, NOT used by the eth-chiplet, stays byte-identical).
- `fpga/vivado_ip/tidelink_vivado_wrapper.v` — param + pass-through on the IP face
  (default OFF, reaches OOC synth via component.xml exactly like
  `TRAIN_ENTRY_FALLBACK` — a `+define+` would NOT).

Every non-eth-chiplet build keeps `SELF_ARM_TRAIN_EN=0`, so deps / Z2 /
kr260-onchip are byte-behaviour-identical.

### 3c. PS bring-up SW step (eth-chiplet repo — see §5 patch)

`kr260_eth_bringup.py`: raise `SWI_TRAINING_MODE=1` between step 1 (`ROLE_CFG`)
and step 2 (poll `cal_done`). Step 3's existing `SWI_TRAINING_MODE=0` provides the
falling edge to data mode. No change to the LL bootstrap.

---

## 4. Elaborate result (VCS T-2022.06-SP2)

`source ./set_env.sh; export TIDELINK_PHY_V2=1; export PATH=$VCS_HOME/bin:$PATH`,
deps populated by read-only symlink from the shared checkout, then:

```
vcs -full64 -sverilog -f flists/tidelink_fpga_v2.flist -top tidelink_top ...
```

| Config | Exit | Top | simv | Warnings |
| --- | --- | --- | --- | --- |
| `SELF_ARM_TRAIN_EN=0` (default) | **0** | `tidelink_top` (sole) | produced | 29 |
| `SELF_ARM_TRAIN_EN=1` (`-pvalue`, eth cfg) | **0** | `tidelink_top` (sole) | produced | 29 |

Identical 29-warning count (all pre-existing `TFIPC`/`SIOB`, none referencing the
new param) ⇒ the change is **additive**. The `-pvalue+tidelink_top.SELF_ARM_TRAIN_EN=1`
override registered ("assign 1 tidelink_top.SELF_ARM_TRAIN_EN (Command line)").

---

## 5. Applying to the eth-chiplet build (`a87eb93` / `3ab32d6` lineage)

The eth-chiplet vendors tidelink at `nanosoc-ethernet-chiplet/tidelink/` and
shadows `tidelink_top` with `nanosoc-ethernet-chiplet/src/rtl/local_overrides/
tidelink_top.sv`. The vendored acc is close lineage (same latch/clr structure,
line-shifted, no `EPOCH_ANCHOR_EN`), so the acc hunks apply by string anchor.

**(A) `nanosoc-ethernet-chiplet/tidelink/src/rtl/local_overrides/axi_chiplet_controller.sv`**
— apply the SAME 4 edits as §3a (this branch's acc diff is the reference; anchors
are unique strings: the `parameter bit    TRAIN_ENTRY_FALLBACK = 1'b0,` line, the
`(nego_lock_pending_reg && nego_lost_w)) begin` latch, the
`else if (local_training_mode_clr_w)` strobe).

**(B) `nanosoc-ethernet-chiplet/src/rtl/local_overrides/tidelink_top.sv`** — add the
param and thread it (this copy only threads AUTOCAL/USE_IDELAY/NEGO_CFG_RESET):

```
-    parameter [6:0]  NEGO_CFG_RESET       = 7'h00
+    parameter [6:0]  NEGO_CFG_RESET       = 7'h00,
+    // I1 self-arm role-lock (docs/I1_SELFARM_FIX.md). DEFAULT OFF.
+    parameter bit    SELF_ARM_TRAIN_EN    = 1'b0
 )(
```
```
-        .NEGO_CFG_RESET       (NEGO_CFG_RESET)
+        .NEGO_CFG_RESET       (NEGO_CFG_RESET),
+        .SELF_ARM_TRAIN_EN    (SELF_ARM_TRAIN_EN)
     ) u_chiplet_controller (
```

**(C) `nanosoc-ethernet-chiplet/src/rtl/nanosoc_eth_chiplet.sv:603`** — ENABLE it
(the conscious, no-silent-default choice):

```
-    tidelink_top #(.NUM_PHY_LANES(NUM_PHY_LANES)) u_tidelink (
+    tidelink_top #(.NUM_PHY_LANES(NUM_PHY_LANES), .SELF_ARM_TRAIN_EN(1'b1)) u_tidelink (
```

**(D) `nanosoc-ethernet-chiplet/tidelink/pynq_host/scripts/kr260_eth_bringup.py`**
— SW-raise training after step 1, before the cal_done poll (after the
`effective_role` confirm, ~line 185):

```python
    # 1b. hold training HIGH while RX aligns (I1 self-arm: the calibrator needs
    #     SWI_TRAINING_MODE=1 to decode the peer training pattern; on nego_en=0
    #     the autoneg never raises it). Step 3 drops it -> falling edge to data.
    print("--- 1b. SWI_TRAINING_MODE <- 1 (hold training for RX alignment) ---")
    bd.wr(REG_SWI_TRAINING_MODE, 1)
    time.sleep(0.005)
```

The tidelink-side diff (§3a/3b) is on this branch — `git show fix/i1-selfarm-rolelock`.

### Confirming SELF_ARM_TRAIN_EN reaches the eth-chiplet build

The eth-chiplet instantiates `tidelink_top` as **plain RTL** in
`nanosoc_eth_chiplet.sv` (it does NOT go through a packaged Vivado IP for tidelink),
so this is a direct Verilog parameter override — the `+define+`-never-reaches-OOC
trap does NOT apply here. Verify structurally after the change:
`grep -n "SELF_ARM_TRAIN_EN" nanosoc_eth_chiplet.sv` shows `1'b1` at the instance,
and the elaboration/synth log shows the param resolved to 1 on
`u_tidelink.u_chiplet_controller` (e.g. VCS `-pvalue`/`assign` line, or the Vivado
elaborated-parameter report). Do NOT rely on `md5`.

---

## 6. Bench check (on the OVERRIDE + fix `.bit`)

Pair procedure unchanged: POWER-CYCLE both boards → deploy die_a image to one,
die_b(-flip) to the other → run `kr260_eth_bringup.py --bringup --role die_a` (and
`--role die_b` on the peer). Then `arm_read.py` / `--status` must read, on the
OVERRIDE build:

- `ROLE_STATUS 0x2E03_2084[0]` = effective role (0 master / 1 slave) → confirms
  **role_locked=1** (effective role only reflects `role_cfg` once locked);
- `SWI_LANE_STAT 0x2E03_2108[16]` = **cal_done = 1**;
- `SWI_LANE_STAT 0x2E03_2108[19:17]` = **fcsm = 4** (LINK_IDLE).

Falsifiable prediction: with the fix the OVERRIDE build reaches
`role_locked=1 → cal_done=1 → fcsm=4`. If `role_locked` still reads 0 after
`ROLE_CFG=0x02`, the self-arm did not take (re-check that `SELF_ARM_TRAIN_EN`
resolved to 1 on the instance). If `role_locked=1` but `cal_done` stays 0, that is
NOT this bug — it means the peer/ribbon/RX is absent (cal_done legitimately needs
`cr_pkt_seen` from the link-layer `tl2wl` FCSM, i.e. a live peer).

---

## 7. What I am unsure of / caveats

1. **nego_en on the lead's exact `a87eb93` build.** I traced nego_en=0 from
   `NEGO_CFG_RESET=7'h00` in BOTH the eth-chiplet `local_overrides/tidelink_top.sv`
   and my `main` `tidelink_top.sv`, with the instantiation overriding only
   `NUM_PHY_LANES`. The training-arm doc reported nego_en=1 (a different path). If
   the lead's build actually straps/writes `NEGO_CFG` non-zero, nego_en=1 and the
   autonomous fch handoff becomes live and could race the manual LL bootstrap —
   the clr-gate (§3a.4) still protects the SW-held training, but **please read back
   `NEGO_CFG` (0x2E03_2xxx region-4 slot) on the target to confirm nego_en** before
   attributing anything. My fix is correct for either value; the interaction only
   matters if nego_en=1.

2. **The silicon A/B is confounded.** The training-arm doc shows there is no RTL
   path from the overridden `WlinkGenericFCSM 0-4` (AXI channel credit nodes) to
   `role_lock`, so "revert FCSM 0-4 → deps fixes role_locked" is not an RTL
   dependency. My fix sidesteps that entirely by latching role-lock on SW intent,
   so it is robust to whatever the true confound is (rebuild/P&R variance, or an
   otherwise-differing image). The bench check in §6 is the falsifier.

3. **cal_done requires a live peer.** The fix unblocks role-lock and the calibrator
   arm; it does not manufacture a peer. `cal_done` still gates on `cr_pkt_seen`
   from `tl2wl`. A single die with no peer/ribbon will (correctly) not reach
   `cal_done=1` even with the fix.
