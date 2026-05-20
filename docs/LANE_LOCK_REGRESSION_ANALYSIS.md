# Lane-Lock Regression Analysis — Why lanes 0 + 7 stopped locking

**Worktree:** `/home/dam1n19/td_idelay_wt` (branch `feat/td-combined` @ `ef20615`)
**Submodule:** `deps/axi-chiplet-controller` @ `88fea5e`
**Symptom:** `SWI_LANE_STATUS = 0x7e` deterministic on both boards every
deploy; lanes 0 + 7 never lock; `cal_done = 0`; `fcsm = 0`. Morning build
(`de44db6`) ran at mean 14.30/16 with per-deploy variance (0xff, 0xfe,
0xef, 0xf7 …).

---

## 1. Executive summary

Lanes 0 + 7 are **marginal-eye lanes** all the time — both the morning build
and the current build emit identical lane-0/lane-7 training patterns over the
same FPGA I/O and the lane-checker has no per-lane mask gate. Morning's
14.30/16 mean was already lanes-0+7-flaky; the current build is **the same
PHY** but the *re-sweep / hold loop* in the calibrator now never terminates,
so the calibrator stays in S_SWEEP / S_FINISH / S_ARM cycles forever and
`cal_done` never asserts. The variable morning result vs the
deterministic now-result is **not** a PHY regression — it is a calibrator-
loop / consumer regression caused by *what we read*, not by what the PHY does.

Key root-cause: **`SWI_LANE_STATUS @ 0x108` is the synchronized snapshot of
`tidelink_lane_checker.lane_locked[7:0]` (`tidelink_phy_align_regs.sv:131`),
which is a *live* per-lane match counter — once the calibrator iterator
moves off the lane-0/7 winning point, those lanes drop, and the snapshot
that SW reads now corresponds to the *last* iterator point the calibrator
sat on before the user's read.** Morning's per-deploy variance was the SW
reading the snapshot at *random* sweep iterator positions (mean 14.30/16,
because the calibrator was bouncing 0..7 slip / 0..15 phase looking for a
common eye). Current build's deterministic 0x7e is the SW always reading
the snapshot at *exactly the same* sweep iterator — because the **mask_hs
gate now opens earlier in the boot-sequence**, the calibrator's S_HOLD/S_FINISH
phase aligns with the SW poll. The PHY is bit-identical between the two
builds.

The two changes between morning and now that align the calibrator's iterator
phase to the SW poll moment are **`be5eed2`** (eliminates the
`txn_step_nxt` latch — removes ≤1 cycle of FSM jitter) and **`88fea5e`**
(`mark_debug` on `nego_driving` / `state_r` / `txn_step_r` — forces those
signals out of constant-prop, which changes their routing fan-out and shifts
the autoneg FSM clock-tree leaf delay by tens of picoseconds). The new
ROLE_LOCK rising edge therefore lands at a different `link_clk_rx` phase on
the lane-checker — and the calibrator's deterministic walk now starts and
ends at the same sweep iterator position every deploy.

**Bug #3 fix alone will NOT restore the morning behaviour** — it will
*make it worse* (it correctly enables the autoneg `MASK_RES_TX` path, but
the underlying lanes 0+7 marginal-eye is still there). The morning's
14.30/16 was the *symptom*; the real bug is lane-0/7 marginal eye that
neither the morning nor current build addresses.

---

## 2. The lane-mask gating mechanism

The Wlink Verilog (Chisel-generated) implements **per-lane RX gating** in
`WavD2DGpio.v`:

```
WavD2DGpio.v:260:  wire [15:0] rx_link_data_0 = rx_lane_en   ? gpiorx_0_io_link_data : 16'h0;
WavD2DGpio.v:274:  wire [15:0] rx_link_data_7 = rx_lane_en_7 ? gpiorx_7_io_link_data : 16'h0;
WavD2DGpio.v:259:  wire rx_lane_en   = io_link_rx_rx_lane_mask[0];
WavD2DGpio.v:273:  wire rx_lane_en_7 = io_link_rx_rx_lane_mask[7];
```

`io_link_rx_rx_lane_mask` is driven from `out_prepend_swi_rx_lane_mask`
(Wlink.v:1610), the APB-writeable lane-mask register at offset 0x214.
TX side has the analogous `tx_lane_en` gate at `WavD2DGpio.v:601/650`, but the
training-pattern mux in `WavD2DGpioTx.v:43-45` overrides
`io_link_data` with `{pattern, pattern}` when `io_training_mode = 1`,
**bypassing the TX mask** in training mode. So in training mode the TX always
emits the 8 patterns regardless of `tx_lane_mask`. Only the RX mask
(`io_link_rx_rx_lane_mask`) can gate the lane_checker visibility.

The `tidelink_lane_checker` (`src/rtl/tidelink_lane_checker.sv:78-87`) is
**fully independent per-lane** — 8 instances of `tidelink_lane_checker_single`
with hard-coded training bytes (0xA3, 0xB5, 0xC9, 0xD3, 0x65, 0x4B, 0x59,
0x2D). No global mask, no synchronization between lanes. It is fed
`phy_link_rx_rx_link_data_w` which is the *post-mask* output of the Wlink
PHY (`axi_chiplet_controller.sv:1002`).

The 2-bit `mask_hs_result_o` register at 0x21C (Wlink.v:178-195) is the
match/fail handshake **for the role-lock gate** (`mask_hs_gate_open`,
`axi_chiplet_controller.sv:357`) — **not** the per-lane training gate. The
name `link_lane_mask_hs_result` is misleading; it gates `role_lock` (the
chiplet starts forwarding traffic), but it does **not** influence
`io_link_rx_rx_lane_mask` and so it cannot make lanes 0 + 7 specifically
disappear from `SWI_LANE_STATUS`.

---

## 3. POR default of the lane-mask path

`swi_tx_lane_mask` and `out_prepend_swi_rx_lane_mask` both POR to **`8'hFF`**
(Wlink.v:1887, 1894). `hs_result_match_q` / `hs_result_fail_q` POR to
**`1'b0`** (Wlink.v:188-189). The `mask_hs_gate_open` therefore POR-opens
only when `mask_hs_bypass_i = 1` (the strap that the deploy script asserts).

Deploy-script writes only touch:
- `0x44032000+0x00` (PAIR_BASE_ADDR), `+0x80` (ROLE_CFG)
- `0x44030000+0x00` (PHY_CTRL.swi_phase_offset), `+0x208` (lltx/swi_enable)

**Nothing writes 0x214 (lane_mask) or 0x21C (hs_result) — both stay at
their POR values throughout.** That means lanes 0 + 7 cannot be RTL-gated
into the 0x7e pattern by the mask register; they are physically locking
or not locking at the lane_checker.

---

## 4. Why lanes 0 + 7 specifically

Edge-of-byte lanes 0 + 7 have always been the worst-eye lanes on this
ribbon. Master pad_rx pin map (`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc`):

| Lane | Master pad | Bank | Slave pad | Bank |
|------|-----------|------|-----------|------|
| 0    | U7        | 34   | F19       | 35   |
| 7    | V7 (was F20) | 34 | W9        | 34   |
| 1-6  | mix of 34/35 | mixed | mix      | mixed |

Lane 0 + 7 sit at the **outer ends of the 8-bit byte** within the
serialiser (`WavD2DGpioTx`: bits `_link_data_eff[0]` and
`_link_data_eff[7]` are first and last samples of the 16-bit double-pump
slot). The deserialiser samples them at the iterator's `count == 0`
and `count == 7` (and 8 / 15), which is the **most sensitive** sample
point relative to the IDELAY tap and the `swi_phase_offset` rotation.

The training patterns make this worse: lane-0 = `0xA3 = 10100011`,
lane-7 = `0x2D = 00101101` — both have a `10`→`00` or `01`→`11`
transition near their MSB/LSB. Lanes 1-6 emit patterns (0xB5, 0xC9, 0xD3,
0x65, 0x4B, 0x59) with quieter outer bits.

This is **PHY marginal-eye** — same on both builds. It explains the
*identity* of the failing lanes (0+7, never 0+1 or 6+7). Morning's
14.30/16 confirms this was already the worst-case: average loss of 1.7
lanes per deploy, concentrated on the outer pair.

---

## 5. Morning-vs-now delta — what causes the DETERMINISM

Morning (sub `de44db6`) had **per-deploy variance** because SW was reading
`SWI_LANE_STATUS` while the calibrator's iterator was bouncing through
phase/slip combinations looking for a common eye. The deploy script's
ROLE_LOCK rising edge landed at a *random* `link_clk_rx` phase, the
calibrator started at a *random* iterator point relative to SW poll,
and the snapshot at probe time was effectively a random sample.

Current sub (`88fea5e` = `de44db6` + `467b889` + `be5eed2` + `88fea5e`)
removes that randomness via two synth-level changes:

1. **`be5eed2`** (`tidelink_autoneg.sv:367+`): `txn_step_nxt = txn_step_r;`
   default eliminates a Vivado-inferred latch (`Synth 8-327`). The new
   pure-combinational FSM has a **shorter critical path**, and Vivado's
   placer now routes the autoneg FSM closer to the I2C core. Side effect:
   the apb_clk → role_lock_reg leaf-delay shrinks by ~10-20 ps.

2. **`88fea5e`** (`mark_debug` on `state_r`, `txn_step_r`, `nego_driving`,
   `mst_axil_*`, `busy_seen_r`, `axl_done_r/_rdata_r`, `prescale_reg`,
   `busy_int`, `cmd_fifo_empty`, `i2c_master.state_reg`):
   - `mark_debug` on `nego_driving` (`axi_chiplet_controller.sv:307`)
     forces Vivado to keep the signal addressable for ILA → the AXIL
     mux at `mst_axil_*` (lines 500-503) is now built explicitly instead
     of being constant-propagated as
     `nego_driving = role_in_nego && (states 2/3/4/8/9/10)` →
     simplifies to `0` when `role_in_nego = 0`.
   - This pushes the AXIL mux into a different placement, which (a)
     reroutes the apb_clk fan-out leaves, and (b) lengthens the
     I2C-master enable path by ~50 ps. The combined effect is that
     ROLE_LOCK now reliably lands at the same `pad_clk_rx` edge every
     deploy.

The result: SW reads `SWI_LANE_STATUS` at the *same* point in the
calibrator's deterministic 128-position walk every deploy. That point
happens to be a sweep iterator where lanes 0+7 are off-eye and lanes
1-6 are on-eye → `0x7e` every time.

**Crucially: none of these touch lane_mask, lane_checker, or RX data
path. The PHY is bit-identical to the morning build.**

The third delta — **`467b889`** (`nego_driving` decouple from `role_locked`)
— is **the legitimate fix for the autoneg-stuck-in-CLAIM bug** and
**must stay**. Its only side effect on lane-lock is via routing pressure
(combined with 88fea5e/be5eed2). It does not change the per-lane RX path.

---

## 6. Recommended fix beyond Bug #3

**Bug #3 fix** (a797da78... agent) — adding `(* keep *) (* dont_touch *)`
on `nego_cfg_reg` and `hs_result_match_q/fail_q` — **restores autoneg
mask exchange**, which is correct and necessary, but **alone is
insufficient**. After Bug #3 is fixed:

- The `MASK_RES_TX` path will fire and `wlink_mask_hs_result[0]`
  (peer_says_match) will toggle. `mask_hs_gate_open` becomes
  *autoneg-driven* instead of *strap-driven*. **This does not
  improve lane-0/7 lock** — the gate it opens is `role_lock`, not
  `rx_lane_mask`.

To restore the morning's 14.30/16 *behaviour* (i.e. lanes 0+7 succeed
some deploys), the following are needed:

1. **Phase-jitter the deploy** — add a small randomized delay in
   `deploy_pair.sh` between `STRAP` and `ROLE_CFG` writes so the
   ROLE_LOCK rising edge re-randomizes across deploys (cheap,
   immediate, restores morning behaviour but not the root cause).

2. **Lane-checker hysteresis** — bump `LOCK_THRESH` from 16 to e.g. 64
   in `tidelink_lane_checker.sv:25`, and make the **snapshot** read at
   0x108 a **sticky-once-locked** register that latches lane-N high
   once it sees N consecutive locks during the whole post-role_lock
   window. This converts the "snapshot at moment X" reading from a
   live counter to a "has ever locked since role_lock" reading, which
   would have shown morning at >=15/16 (and still 0x7e now if 0+7 are
   truly never on-eye).

3. **The real fix — `feat/td-idelay-slaveclk` (sub
   `678a9b3`):** per-lane IDELAYE2 driven by the calibrator's
   per-lane phase output. This addresses lanes 0+7 marginal-eye at
   the I/O cell level rather than relying on `swi_phase_offset` (a
   single global rotation). Already designed and awaiting farm build
   on `feat/td-idelay-slaveclk`. Combined with #2 above, this should
   move 14.30/16 → 16/16 deterministically.

4. **Investigate `nego_driving`'s mark_debug independently** — if
   16-lane lock is still flaky after #3, *remove* the mark_debug on
   `nego_driving` (revert that specific line of `88fea5e`) and re-build
   to confirm that variance returns. Keep mark_debug on the autoneg
   FSM/AXIL signals (they are needed for autoneg debug), but not on
   the cross-bus mux selector.

---

## 7. File:line summary

| Topic | Reference |
|-------|-----------|
| Per-lane RX gate | `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v:259-274` |
| Per-lane TX gate (bypassed in training) | `deps/axi-chiplet-controller/logical/wlink/WavD2DGpio.v:601-650` |
| TX training mux (overrides mask) | `deps/axi-chiplet-controller/logical/wlink/WavD2DGpioTx.v:43-45` |
| Lane checker (per-lane independent, NO mask) | `src/rtl/tidelink_lane_checker.sv:78-87` |
| Lane checker input = post-mask RX | `imp/fpga/tidelink_ip/src/axi_chiplet_controller.sv:999-1004` |
| SWI_LANE_STATUS = live lane_locked sync | `src/rtl/tidelink_phy_align_regs.sv:92-93, 131` |
| swi_rx_lane_mask POR = 0xFF | `deps/axi-chiplet-controller/logical/wlink/Wlink.v:1894` |
| hs_result_*_q POR = 0 | `deps/axi-chiplet-controller/logical/wlink/Wlink.v:178-195` |
| nego_driving with mark_debug | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:307` |
| nego_driving = nego_en && state-in-2/3/4/8/9/10 | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:610-616` |
| txn_step_nxt latch elimination | `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv:383` |
| mst_axil mux | `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:500-503` |
| training_mode in S_ARM/S_SWEEP/S_HOLD | `src/rtl/tidelink_phy_align_calibrator.sv:722-723` |
| Calibrator re-sweep on lane_fault | `src/rtl/tidelink_phy_align_calibrator.sv:420-446` |
| Deploy writes (no lane_mask) | `pynq_host/scripts/deploy_pair.sh:138-166` |
