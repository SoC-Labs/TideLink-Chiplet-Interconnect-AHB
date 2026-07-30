# I1 Training-Arm Root Cause & Fix

Branch: `strategy/i1-training-arm` — ANALYSIS ONLY (no HW, no build, no push).
Date: 2026-07-30. Lens: the training-mode / autoneg arm path.

Silicon symptom (ILA, 07-30, on the I1 override build): the calibrator NEVER
ARMS. Read back on both dies: `swi_training_mode_r = 0` (R8 0x2100 bit[0]),
`role_locked = 0` — despite the PS bring-up writing `ROLE_CFG = 0x02`. The arm
conjunction `nego_en & role_locked & swi_training_mode_r` therefore never fires,
no winscan runs, RX never aligns, so `cr_seen = 0 / cal_done = 0 / fcsm = 0`.

All file:line refs are `src/rtl/local_overrides/` unless noted.

---

## TL;DR

1. The eth-chiplet bring-up arms training/calibration **entirely through the
   autonomous autoneg control plane** (I²C mask-handshake + I²C training-entry).
   `kr260_eth_bringup.py` writes `ROLE_CFG=0x02` and then just *polls* — it never
   SW-writes `SWI_TRAINING_MODE=1` and never force-locks role. There is **no SW
   fallback**.

2. `role_locked=0` and `swi_training_mode_r=0` are both **UPSTREAM** of the
   flow-control state machines. They are caused by the autoneg's I²C transactions
   to the peer not completing (mask handshake never closes → role-lock gate never
   opens; `ST_TRAIN_ENTER` never gets a peer ACK → training never set). This is
   the same "dead/absent peer I²C ⇒ NEGO parks, training never attempted" class
   as the Z2 saga (Option A / `TRAIN_ENTRY_FALLBACK`), now hitting eth-chiplet.

3. **The five overridden FCSMs are NOT in the arm path.** `WlinkGenericFCSM{,_1,
   _2,_3,_4}` are the AXI *channel* FC nodes `wlink_axi{aw,w,b,ar,r}FC` inside
   `AXI4ToWlink` (`deps/.../AXI4ToWlink.v:529,567,605,643,681`). They sit on the
   AXI application data path, DOWNSTREAM of link-up. **No RTL data/control path
   runs from them back to `role_lock`, `swi_training_mode_r`, the autoneg mask
   handshake, or the calibrator arm.** The I1 re-point is therefore not the RTL
   cause of the arm failure — see "Refutation" below.

4. **Fix** (satisfies "arm training/calibration independent of the FCSM/peer
   handshake, run RX-alignment FIRST"): a default-OFF `SELF_ARM_TRAIN_EN` that
   (a) lets `role_lock_reg` latch on the SW `ROLE_CFG[1]` write WITHOUT
   `mask_hs_gate_open`, and (b) SW-writes `SWI_TRAINING_MODE=1` before polling
   `cal_done`. `mask_hs_verified_reg` (the honest integrity witness) is left
   untouched, so RETIRED-autonomy entry still fails closed.

---

## 1. The training-set state path (file:line)

`swi_training_mode_r` (declared `axi_chiplet_controller.sv:1126`) has exactly two
setters:

- **Autoneg FSM strobe** — `axi_chiplet_controller.sv:2120-2121`
  ```
  if (local_training_mode_set_w)  swi_training_mode_r <= 1'b1;
  else if (local_training_mode_clr_w) swi_training_mode_r <= 1'b0;
  ```
  `local_training_mode_set_w` is wired from `u_autoneg.local_training_mode_set`
  (`axi_chiplet_controller.sv:3428`), which is
  `assign local_training_mode_set = local_train_set_pulse_r;`
  (`tidelink_autoneg.sv:2438`).

  `local_train_set_pulse_r` is asserted in only two places:
  - `tidelink_autoneg.sv:1295` — inside `ST_TRAIN_ENTER`, `TXN_CHECK`, on the
    **peer ACK** of the I²C write of `SWI_TRAINING_MODE=1` to the peer's 0x2100
    (or on a NACK **iff** `TRAIN_ENTRY_FALLBACK=1`, folded in at
    `tidelink_autoneg.sv:1283/1291`).
  - `tidelink_autoneg.sv:891` — the `TRAIN_ENTRY_FALLBACK` global-timeout arm out
    of `ST_TRAIN_ENTER` (start training from the strapped role).

  Reaching `ST_TRAIN_ENTER` requires `ST_NEGO_DONE_PRE` with `train_auto_en=1`
  (`tidelink_autoneg.sv:1219-1243`), which in turn requires the autoneg to have
  resolved the role through the `ST_NEGO_*` I²C states.

- **Direct SW register write** — `axi_chiplet_controller.sv:2144-2147`
  ```
  if (region8_write) case (ctrl_reg_addr[2:0])
      3'h0: swi_training_mode_r <= ctrl_reg_wdata[0];   // 0x2100 bit[0]
  ```
  This is **ungated** — any APB write of `0x2100` bit[0]=1 sets training
  immediately. The bring-up script does NOT exercise it for =1 (only =0, to exit).

`swi_training_mode_w = cal_training_mode_w | swi_training_mode_r`
(`axi_chiplet_controller.sv:6066`) is the live training level fed to the PHY/
lane-checker; the *arm* the ILA reports on uses the register `swi_training_mode_r`.

---

## 2. The exact stall point

The PS bring-up (`nanosoc-ethernet-chiplet/.../pynq_host/scripts/kr260_eth_bringup.py`):

- `:178`  `bd.wr(REG_ROLE_CFG, 0x02)`   — role=0, role_lock (W1S) requested.
- `:191-205` polls `cal_done` — **no** write of `SWI_TRAINING_MODE` here.
- `:209`  `bd.wr(REG_SWI_TRAINING_MODE, 0)` — training=0 (to *exit* to data mode).

So the script relies 100% on the autoneg to raise training. Two independent
gates then fail:

**(a) role_lock never latches.** The `ROLE_CFG=0x02` write only sets
`nego_lock_pending_reg` (`axi_chiplet_controller.sv:795-797`). `role_lock_reg`
latches only when the mask-handshake gate is open
(`axi_chiplet_controller.sv:862-868`):
```
if ((nego_lock_pending_reg && mask_hs_gate_open) ||
    (nego_lock_pending_reg && nego_lost_w))         role_lock_reg <= 1'b1;
else if (ctrl_reg_write && !role_locked && ctrl_reg_addr==5'b01_000) begin
    role_cfg_reg <= ctrl_reg_wdata[0];
    if (ctrl_reg_wdata[1] && mask_hs_gate_open)      role_lock_reg <= 1'b1;   // needs the gate
end
```
with
```
mask_hs_gate_open = mask_hs_match | mask_hs_bypass_i;                 // :711
mask_hs_match     = wlink_mask_hs_result[0] | autoneg_mask_hs_local_match;  // :693
```
On production silicon `mask_hs_bypass_i = 0` (xlconstant). `wlink_mask_hs_result`
comes from the Wlink 0x21C verdict sniffer (`Wlink.v:479-486`, surfaced at
`axi_chiplet_controller.sv:6321`) — set only when the **peer** writes 0x01 over
I²C. `autoneg_mask_hs_local_match` is the master's own I²C mask compare. With no
completing peer I²C handshake, **all three terms stay 0 and `nego_lost_w=0`**, so
`role_lock_reg` never latches ⇒ `role_locked=0`.

**(b) training never set.** The autoneg never reaches `ST_TRAIN_ENTER`'s ACK
(the peer does not answer the I²C training-write), and `TRAIN_ENTRY_FALLBACK=0`
(module/wrapper default — `tidelink_dft_wrapper.sv:161` sets `NEGO_CFG_RESET=0x61`
but leaves `TRAIN_ENTRY_FALLBACK` at its `0` default), so no NACK-fallback set
fires. The SW never writes `0x2100[0]=1`. ⇒ `swi_training_mode_r=0`.

Both symptoms trace to the **autoneg I²C control plane not completing**, i.e. the
peer die not responding on the I²C sideband (or NACKing the mask/training writes).

---

## 3. Does the arm wait on the FCSM? (the hypothesised deadlock — REFUTED)

The task hypothesised a circular deadlock: training-arm → autoneg
`ST_TRAIN_POLL_PEER` → peer/FCSM handshake → calibrator → training. Reading the
RTL, **this loop does not exist for the AXI FC nodes**:

- **The autoneg is I²C-only.** Role resolution, the mask handshake (peer lane-mask
  read + verdict), and the training-entry write all run over the I²C sideband
  (`u_autoneg` ports `i2c_sda_i/i2c_scl_i` and the `m_axil_*` bus to
  `i2c_master_axil`, `axi_chiplet_controller.sv:3354-3373`). None of it reads the
  Wlink link or any FCSM.

- **The calibrator arm is FCSM-independent.**
  `calibrator_role_locked = role_locked & autocal_enable_w`
  (`axi_chiplet_controller.sv:3860`, with
  `autocal_enable_w = AUTOCAL_ENABLE | autocal_force_enable_q`, `:3859`). The V2
  winscan KICK `ws_kick_evt` (`:4811`) is `WINSCAN_FSM_EN & autonomy_armed &
  (training fall)` and references **no** `cr_seen`. RX-alignment can and must run
  before any CR is received.

- **The one real FCSM→calibrator coupling is downstream and correct.** The
  calibrator's `cr_pkt_seen_i / crack_pkt_seen_i` (`axi_chiplet_controller.sv:
  5974,5978` — and the V2 instance `:5866`) gate its **S_VALIDATE / cal_done**,
  not the arm. Those come from the Wlink outputs `obs_cr_pkt_seen_rx_o /
  obs_crack_pkt_seen_rx_o` (`:6382-6383`), which inside Wlink are driven by the
  **TideLink link-layer FCSM `tl2wl` (TideLinkToWlink)** — `Wlink.v:1108-1109`,
  instance `Wlink.v:1845` — **NOT** the overridden AXI channel nodes. Likewise the
  0x2108[19:17] `obs_fcsm_state` (which feeds `autonomy_retire_q` `:4672` and
  `data_mode_o` `:6035`) is `tl2wl`'s state, not the AXI nodes'.

So even the worst case for the AXI FC-node override — a wedged AXI credit node —
could at most stall **`cal_done`** (S_VALIDATE), which requires `role_locked=1`
and training to have already risen. That is the OPPOSITE of the ILA, which shows
the arm itself never firing.

---

## 4. What the I1 override actually changes

`b98b944` ("fix(fcsm): I1"): re-points FCSM 0-4 deps→`local_overrides` in three
flists and lowers `SOCL_L7_MIN_CRACK_EMITS` 32→8 (`local_overrides/
WlinkGenericFCSM{,_1..4}.v`). The deps copies are pristine Wavious nodes
(no `socl_*` logic); the overrides add the SoC-Labs L6 state-1 min-CR-emit gate
(=32), the L7 state-2 min-CRACK-emit gate, and Fix-B/C/D watchdog recovery, while
omitting Fix-F/L9/Bug-C-CDC. **Port list is byte-identical**; the change is purely
behavioural on the AXI aw/w/b/ar/r credit channels. None of these signals leave
`AXI4ToWlink` toward the control plane.

### Refutation of "FCSM → role_lock/training"

There is no RTL path from `WlinkGenericFCSM 0-4` to the arm. The silicon A/B
("revert FCSM 0-4 → deps makes bring-up work") is therefore **not explained by an
RTL data/control dependency** and is most likely confounded — a rebuild / P&R
variance, or a compare in which the two images differed in more than the FCSM
re-point. This matches the standing lab rule ("verify the RTL PRECONDITION; check
what else is dirty before calling an A/B one-variable"). **Recommend re-running
the A/B with the FCSM re-point as the *only* delta and the arm signals
(`role_locked`, `swi_training_mode_r`, `mask_hs_match`) on the ILA** before
attributing anything to the FCSM. Could NOT be resolved by reading: whether the
eth-chiplet actually provides a live inter-die I²C sideband, and whether the two
A/B builds were otherwise identical — both are the crux and need HW/board data.

---

## 5. The fix — arm training + calibration independent of the peer handshake

Goal (from the task): training/calibration must run FIRST (RX alignment enables
CR reception), so the arm must NOT wait on the peer mask-handshake / I²C training
ACK. The RTL already supports SW-set training (`:2147`); the only missing pieces
are (i) a peer-independent way to latch `role_lock`, and (ii) the SW step to raise
training. Both are added default-OFF so every existing build stays bit-identical.

### 5.1 RTL — `SELF_ARM_TRAIN_EN` (default 0)

Add `parameter bit SELF_ARM_TRAIN_EN = 1'b0`, forwarded
`tidelink_top → axi_chiplet_controller` (and set `=1` in the eth-chiplet
`tidelink_dft_wrapper.sv`, exactly the `NEGO_CFG_RESET` plumbing pattern).

- **role_lock self-latch** — in `axi_chiplet_controller.sv:862-868`, allow the SW
  `ROLE_CFG[1]` write to latch `role_lock_reg` when `SELF_ARM_TRAIN_EN` even if
  `mask_hs_gate_open=0`:
  ```
  end else if (ctrl_reg_write && !role_locked && ctrl_reg_addr==5'b01_000) begin
      role_cfg_reg <= ctrl_reg_wdata[0];
      if (ctrl_reg_wdata[1] && (mask_hs_gate_open || SELF_ARM_TRAIN_EN))
          role_lock_reg <= 1'b1;
  end
  ```
  Leave the `mask_hs_verified_reg` block (`:784-785`) untouched — it is driven by
  `mask_hs_match` ALONE and still gates RETIRED-autonomy entry (`:4701`), so a
  self-armed role_lock does NOT forge the integrity witness; autonomous retire
  still fails closed. This is safe because `role_lock` is a **mutual clock
  enable** (`wlink_por_reset = ~poresetn | ~role_locked`, `:2916`): self-latching
  it locally is exactly what the cold-boot bring-up stagger already relies on, and
  it is what lets each die's forwarded `pad_clk_tx` (= the peer's `pad_clk_rx`)
  leave reset so the calibrator can align RX.

- **training** — cleanest is to raise it from SW (5.2). If a pure-RTL raise is
  preferred, gate `TRAIN_ENTRY_FALLBACK` on `SELF_ARM_TRAIN_EN` for the eth-chiplet
  wrapper so the autoneg self-sets training from the strapped role on the peer
  NACK (`tidelink_autoneg.sv:1283/1291`), rather than parking in `ST_TRAIN_FAIL`.

### 5.2 SW — bring-up writes training directly, before polling cal_done

In `kr260_eth_bringup.py`, between step 1 (`ROLE_CFG`) and step 2 (poll
`cal_done`):
```
bd.wr(REG_SWI_TRAINING_MODE, 1)   # 0x2100 bit[0]=1 — hold training while RX aligns
time.sleep(0.005)
```
Step 3 already writes `SWI_TRAINING_MODE=0` (`:209`) to drop training and take the
falling edge into the winscan/FC handoff. With role_lock self-armed (5.1) and
`AUTOCAL_ENABLE=1`, `calibrator_role_locked` asserts, the calibrator/winscan sweep
aligns RX, `cr_pkt_seen` then arrives from `tl2wl`, S_VALIDATE completes, and
`cal_done` rises — with no dependency on a peer I²C handshake.

### 5.3 Interaction note (nego_en=1)

The eth-chiplet POR is `NEGO_CFG_RESET=0x61` (nego_en=1). With the autoneg live,
its `ST_TRAIN_EXIT` could drive `local_training_mode_clr_w` and fight the SW-held
training. Two clean options: (a) for the pure-SW bring-up, set the eth-chiplet
`NEGO_CFG_RESET` with nego_en=0 (the KR260-proven "SW role-lock / host-winscan"
path) and rely on 5.1+5.2 only; or (b) keep nego_en=1 and instead use the
`TRAIN_ENTRY_FALLBACK`/`SELF_ARM_TRAIN_EN` RTL raise (5.1) so the autoneg itself
owns training and never clears it out from under the SW. Option (a) is the lowest
risk and matches the existing proven manual recipe. Do NOT open the role_lock gate
by SW-writing the 0x21C verdict (`Wlink.v:479-486`): a local write would set
`mask_hs_verified_reg`, forging the integrity witness — the exact sham F2b removed.

---

## 6. Cited signal map

| Signal | Where | Role |
| --- | --- | --- |
| `swi_training_mode_r` | acc.sv:1126,2120-2121,2147 | the arm's training bit; set by autoneg strobe or SW 0x2100[0] |
| `local_training_mode_set_w` | acc.sv:3428 ← autoneg:2438 ← :1295/:891 | autoneg training-set strobe |
| `ST_NEGO_DONE_PRE→ST_TRAIN_ENTER` | autoneg:1219-1243 | gate to training sub-flow (`train_auto_en`) |
| `role_lock_reg` latch | acc.sv:862-868 | needs `mask_hs_gate_open` (the stall) |
| `nego_lock_pending_reg` | acc.sv:795-797 | set by SW ROLE_CFG[1]; waits for the gate |
| `mask_hs_gate_open` | acc.sv:711 (`mask_hs_match`\|bypass) | autoneg/I²C-only; 0 on eth-chiplet |
| `wlink_mask_hs_result` | acc.sv:6321 ← Wlink.v:479-486 | peer 0x21C I²C verdict sniffer |
| `calibrator_role_locked` | acc.sv:3860 | calibrator arm = `role_locked & autocal_enable_w`; FCSM-independent |
| `cr_pkt_seen_i` (S_VALIDATE) | acc.sv:5974/5866 ← :6382 ← Wlink.v:1108 (`tl2wl`) | gates cal_done, from the LINK-LAYER FCSM, not the AXI nodes |
| `WlinkGenericFCSM{,_1..4}` | AXI4ToWlink.v:529-681 | the I1-overridden AXI aw/w/b/ar/r credit nodes (data path) |

acc.sv = `src/rtl/local_overrides/axi_chiplet_controller.sv`; autoneg =
`src/rtl/local_overrides/tidelink_autoneg.sv`; Wlink.v / AXI4ToWlink.v as noted.
