# TideLink Bring-up Register Map (absolute PS addresses)

This is the **operational** register map used by the host-side bring-up scripts
(`pynq_host/scripts/tidelink_bringup.sh`, `bringup_pair_converge.sh`,
`tl39.py`) on the PYNQ-Z2 `pair-all` / `pair-flip-all` bitstreams. It lists the
registers in the **absolute PS/GP0 addresses** the boards see over `/dev/mem`
(e.g. `0x4403_2090`), not the 13-bit APB offsets.

For the exhaustive, field-by-field register description (all regions, PTP, PHC,
Wlink FC nodes, address translator) see **`docs/REGISTER_MAP.md`**. This file
is the bring-up quick-reference plus the one gotcha that has bitten repeatedly.

> **Address mapping.** The TideLink APB region is exposed on `M_AXI_GP0` at
> base `0x4403_0000`. The APB `0x2xxx` offsets in `docs/REGISTER_MAP.md` appear
> here at `0x4403_2xxx`; the Wlink `0x0xxx` link/PHY registers appear at
> `0x4403_0xxx`. `debug_unlock` lives on its own GPIO at `0x4404_1000`. The
> data apertures are on `M_AXI_GP1`: **AHB_TX `0x8400_0000`**, **RX FIFO
> `0x8401_0000`**.

---

## ⚠️ THE GOTCHA — arm autoneg at 0x44032090, NOT 0x44032110

There are two adjacent, similarly-named autoneg registers. **They are not
interchangeable — one is writable, one is read-only:**

| Address | Name | Access | Purpose |
|---|---|---|---|
| **`0x4403_2090`** | **NEGO_CFG** | **RW — WRITE THIS** | Arms auto-negotiation. `0x61` = `nego_en \| nego_force_lock \| mask_hs_auto_en`. |
| **`0x4403_2110`** | **NEGO_TRAIN_STATUS** | **RO — NEVER WRITE** | Training-handshake **status** mirror. Writing it does nothing. |

**Why this matters:** a prior bring-up tool wrote the arm value to
`0x4403_2110` (NEGO_TRAIN_STATUS). Because that address is a **read-only status
register**, the write was silently discarded, autoneg never armed, the link
never came up — and the failure looked like a silicon/PHY bug. It cost a
multi-session debugging dead-end. **To arm autoneg, write `0x61` to
`0x4403_2090`.** `0x4403_2110` is for reading training status only.

(Do not confuse either of these with `NEGO_TRAIN_CFG` at `0x4403_210C`, which is
the *writable* training-FSM config where `train_auto_en` = bit 0.)

---

## Bring-up register set

### Access / role

| Address | Name | Access | Notes |
|---|---|---|---|
| `0x4404_1000` | DEBUG_UNLOCK | WO | Write `1` **first** to open the APB write path. |
| `0x4403_2080` | ROLE_CFG | RW / W1S | `[0]` role (0=master, 1=slave), `[1]` role_lock (W1S). **master/die_a → `0x2`**, **slave/die_b → `0x3`**. Latches role + releases Wlink POR. Reset only by `poresetn`. |

### Autoneg / training FSM arm

| Address | Name | Access | Notes |
|---|---|---|---|
| `0x4403_2090` | **NEGO_CFG** | **RW** | **Arm autoneg.** `0x61` = `nego_en[0]` + `nego_force_lock[5]` + `mask_hs_auto_en[6]`. |
| `0x4403_210C` | NEGO_TRAIN_CFG | RW | `[0]` `train_auto_en` — write `0x1` to let the training FSM run (autonomous mode). |
| `0x4403_2110` | NEGO_TRAIN_STATUS | **RO** | Read-only training status. **Never write.** |

### PHY static config (manual recipe)

| Address | Name | Value | Notes |
|---|---|---|---|
| `0x4403_0214` | LANE_MASK | `0x0000_e4e4` | Wlink lane mask (8-lane `e4e4` pattern). |
| `0x4403_2128` | SYNC_CFG (SYNCTOL) | `0x0000_05e4` | SYNC detector: `[7:0]` lane-mask (`0xe4`), `[11:8]` tolerance (`5`). tl39.py labels this address `SWI_SYNC_LANE_MASK`. |
| `0x4403_2104` | WORD_PIN (SWI_BIT_SLIP_LO) | `0x0` | `[27:24]` word_pin, `[28]` auto_dis. `0` = per-lane **AUTO** word-pin (proven — NOT a forced global pin). |
| `0x4403_2160` | SCRAMBLE | `0x5555_5555` | PHY scramble / per-lane lock threshold. tl39.py labels this address `LOCKTHR`. |

### R8 control — slot0 (`0x4403_2100`)

`0x4403_2100` is the PHY alignment control ("R8 slot0"). Bit layout:

| Bit | Name | Meaning |
|---|---|---|
| `[0]` | `swi_training_mode` | **⚠ NEVER SET — bit0 traps the calibrator in `S_HOLD`.** |
| `[1]` | `swi_recal` | Recalibration strobe. |
| `[2]` | `sync_insert_en` | Insert SYNC beacons on TX. |
| `[3]` | `sync_force_always` | Force SYNC on every word (bring-up only). |
| `[4]` | `sync_robust_detect` | Robust RX SYNC detector. |

Composite values the recipe uses (all keep bit0 = 0):

| Value | Bits | Meaning |
|---|---|---|
| `0x1C` | `[4\|3\|2]` | **SYNC-config** — insert + force + robust, no train, no recal. |
| `0x1E` | `0x1C \| [1]` | **recal pulse** — pulse recal while holding SYNC-config, then drop back to `0x1C`. |
| `0x14` | `[4\|2]` | **data-enable** — SYNC insert + robust, force **OFF** → normal data flow. |

### Status / observability (read-only)

| Address | Name | Fields |
|---|---|---|
| `0x4403_2108` | STATUS (SWI_LANE_STATUS + credit-path obs) | `[7:0]` lane_locked, `[15:8]` lane_fault, **`[16]` cal_done**, **`[19:17]` fcsm** (4 = LINK_IDLE), **`[23]` cr_seen**. |
| `0x4403_2140` | REANCHOR (SWI_EPOCH_STATUS) | **`[0]` reanchored (RA)**, `[6:1]` epoch_span. |

### LL (link-layer) bootstrap — Wlink Enable/Reset (`0x4403_0208`)

`0x4403_0208` is the Wlink Enable/Reset register:
`[0]` swi_enable, `[1]` lltx_enable, `[2]` llrx_enable, `[3]` sw_reset. The high
bits `0x0002_7f00` carry the constant Max-Short-Pkt-ID (`0x7f`) + PREQ-Data-ID
(`0x02`).

| Address | Value | Meaning |
|---|---|---|
| `0x4403_0230` | `0x0` | P-State Control — clear to `0` **first**. |
| `0x4403_0208` | `0x0002_7f09` | swi_enable + **sw_reset** (assert reset). |
| `0x4403_0208` | `0x0002_7f01` | swi_enable only (release reset, LL still disabled). |
| `0x4403_0208` | `0x0002_7f07` | swi_enable + lltx + llrx (**full enable** — also the final re-assert). |

---

## Recipes

Both are implemented in `pynq_host/scripts/tidelink_bringup.sh`. All coordinated
writes are applied to **both dies within ~1 SSH RTT** (the SYNC/recal/enable
edges must re-arm close together). All MMIO goes through `tl39.py rd/wr`, i.e.
the single-u32 ctypes store (never `struct.pack_into`, which over-advances 5×
and starves the credit loop — SoC Labs 2026-07-03).

### Manual (full deterministic recipe)

1. `DEBUG_UNLOCK` (`0x4404_1000`) = `1`.
2. Static config: `LANE_MASK`=`0xe4e4`, `SYNC_CFG`=`0x5e4`, `WORD_PIN`=`0`,
   `SCRAMBLE`=`0x55555555`.
3. `R8` (`0x4403_2100`) = `0x1C` (SYNC-config).
4. Role W1S (`0x4403_2080`): master=`0x2`, slave=`0x3`.
5. Recal pulse: `R8`=`0x1E` → settle → `R8`=`0x1C`.
6. Poll `cal_done` (`0x4403_2108[16]`) on both dies.
7. LL bootstrap: `0x4403_0230`=`0`, then `0x4403_0208` triplet
   `0x0002_7f09` → `0x0002_7f01` → `0x0002_7f07`.
8. `R8` = `0x14` (data-enable).
9. Wait for reanchor `RA` (`0x4403_2140[0]`) on both dies.
10. Final `0x4403_0208` = `0x0002_7f07`.
11. Poll `fcsm` (`0x4403_2108[19:17]`) == `4` on both dies.

### Autonomous (arm-and-wait)

1. `DEBUG_UNLOCK` (`0x4404_1000`) = `1` on both dies.
2. `NEGO_TRAIN_CFG` (`0x4403_210C`) = `0x1` (`train_auto_en`) on both.
3. `NEGO_CFG` (**`0x4403_2090`**) = `0x61` on both — **arm autoneg (NOT
   `0x2110`)**.
4. Poll `fcsm` (`0x4403_2108[19:17]`) == `4` on both dies with **zero further
   bring-up pokes** — the on-chip autoneg / training / calibrator FSMs drive
   role-lock, SYNC, reanchor and the credit handshake themselves.
5. Then do the LL bootstrap (step 7 + final of the manual recipe) to enable the
   data path.

---

## See also

- `docs/REGISTER_MAP.md` — full field-level register description (APB offsets).
- `pynq_host/scripts/tidelink_bringup.sh` — canonical bring-up (both modes).
- `pynq_host/scripts/tl39.py` — `/dev/mem` rd/wr helper (single-u32 ctypes store).
