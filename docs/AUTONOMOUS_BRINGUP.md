# TideLink — Autonomous ("zero-poke") Bring-Up: How It Works

> **✅ UPDATE 2026-07-16 — the autonomy CHANNEL gap is CLOSED.** Zero-poke all channels
> now deliver byte-exact on silicon (N=10/10, N=40 certifying). See
> `AUTONOMY_STATUS_2026_07_14.md §0`. The delivered blocker was NOT the §3 anchor gate — it
> was the master die_a's **winscan FSM livelocking in data mode** (churns FINALIZE, tears
> down its own FC, disrupts RX-commit). Fix = event-gated retire-autonomy on
> `wip/b2a-fix` @ cd2db38 (latch `reanchored && fcsm==4` → DISARM-PARK the FSM). The
> `autonomy_armed` / commit-gate mechanics below remain accurate as the bring-up chain.


**Audience:** an analyst with no prior context on this project.
**Scope:** the V2 PHY autonomous bring-up chain only. Written 2026-07-14.
**Repo:** branch `wip/phase2-pblock`. All file:line refs verified on that branch.

---

## 1. What "autonomous bring-up" means here

Two dies (die_a = master, die_b = slave) are wired together over an 8-lane
source-synchronous GPIO PHY (a forwarded-clock D2D link — **no CDR, no DLL**).
Only 4 lanes are active: **{2,5,6,7}**, i.e. lane mask **0xE4**.

**Autonomous** = from power-on-reset, with **zero software pokes**, the two dies
must negotiate roles, calibrate the channel, align the lanes, and reach a state
where data flows. The requirement is explicit: *a firmware recipe is not a
deliverable.* Today we also have a **manual recipe** (`rcp()`) that pokes the same
registers by hand; that path is deterministic and works, but it is NOT the goal.

Autonomy is gated by one bit:

```
axi_chiplet_controller.sv:1143
    wire autonomy_armed = nego_en & role_locked & nego_train_cfg_r[0];
```

If `autonomy_armed == 0`, the whole winscan FSM never runs. (Historically this
silently masked months of debugging: `NEGO_CFG`'s POR value was `0x00`, so nothing
was ever armed. A wrapper parameter now forces `NEGO_CFG_RESET = 7'h61` at POR, which
is what makes zero-poke possible at all.)

---

## 2. The bring-up chain (in order)

```
POR
 └─ role_strap (bond pad / GPIO)         -> role_locked
 └─ NEGO_CFG = 0x61 at POR (parameter)   -> nego_en, force_lock, mask_hs_auto_en
 └─ NEGO_TRAIN_CFG[0] = 1 at POR         -> train_auto_en
        ==> autonomy_armed = 1
 1. autoneg handshake (roles, lane mask exchange)
 2. calibration          -> cal_done          (per-lane eye/tap search)
 3. SYNC insert + detect -> sync_seen_vec     (per-lane STICKY bit)
 4. deskew + ANCHOR      -> reanchored        (THE COMMIT GATE — see §3)
 5. anchor verify        -> zero-tolerance
 6. FCSM + credits       -> fcsm = 4 (bilateral)
 7. data mode            -> packets flow
```

Steps 1–3 are per-lane and tolerant. **Step 4 is the choke point** and is where
autonomy fails.

---

## 3. The commit gate — the single most important fact

`reanchored` (deskew aligned, sticky) latches **iff every active lane has set its
sticky `sync_seen` bit within ONE clear-to-clear window**:

```
tidelink_lane_deskew_v2.sv:1350
    wire all_sync_seen = &(sync_seen_sync1 | ~lane_mask);

tidelink_lane_deskew_v2.sv:1016
    assign sync_seen_vec_o = sync_seen_sync1;      // the same net, exported
```

This is an **AND across all 4 active lanes**. Consequences:

- **`FAILOPEN  <=>  sync_seen_vec != 0xE4`** — this is an RTL identity, not a heuristic.
  If bring-up fails, read `sync_seen_vec` (0x4403_215C) and the failing lane is
  named for you.
- A lane's sticky bit sets only after **`SYNC_CONFIRM = 2` consecutive** periodic
  beacon matches (`tidelink_lane_deskew_v2.sv:272`).
- One marginal lane fails the whole AND. There is **no partial credit and no
  per-lane retry** — it is all-4-or-nothing.

### The retry that doesn't accumulate

The winscan FSM gives the anchor a retry budget:

```
axi_chiplet_controller.sv:3951   WS_ANCHOR_TIMEOUT  = 15_000_000   (~0.3 s @ 50 MHz)
axi_chiplet_controller.sv:3971   WS_ANCHOR_RETRIES  = 5
axi_chiplet_controller.sv:4005   WS_ANCHOR_EXTEND   = 7            (0 = baseline)
```

**Each retry RE-PULSES the observation clear**, which wipes the per-lane sticky
vector. So a marginal lane faces a *fresh* `p^2` lottery on every retry instead of
accumulating evidence across them — which is why `retry_cnt` saturates at the budget
without ever helping. `WS_ANCHOR_EXTEND` was added to reload the window *without*
re-pulsing the clear (so accumulation is continuous for ~8 x 0.3 s). **Its benefit is
UNPROVEN** — see the status doc.

---

## 4. Registers you need (APB base 0x4403_2000)

| Address | Name | Notes |
|---|---|---|
| `0x4403_2090` | **NEGO_CFG** (RW) | Arm autoneg. `0x61` = nego_en\|force_lock\|mask_hs_auto_en. **NOT** the RO alias at `0x110`. POR is now 0x61 by parameter. |
| `0x4403_210C` | NEGO_TRAIN_CFG | `[0]` = train_auto_en. POR = 0x1. Manual recipe writes **0** here (autonomy OFF). |
| `0x4403_2080` | role_lock | W1S bit[1] |
| `0x4403_2100` | **R8** PHY ctrl | `[0]`train `[1]`recal `[2]`SYNC_EN `[3]`force_always `[4]`robust. `0x1C`=sync, `0x1E`=recal, **`0x10`=data (SYNC stripped)**. |
| `0x4403_2108` | STATUS | `[16]`cal `[19:17]`fcsm (4 = bilateral) `[23]`cr `[31]`fe_full |
| `0x4403_2140` | **REANCHORED** | `[0]` = epoch_anchored (sticky). The success bit. |
| `0x4403_215C` | **sync_seen_vec** | `[7:0]`. **Golden = 0xE4.** Anything else ⇒ FAILOPEN, and names the bad lane. |
| `0x4403_2150/54` | calibrator eye | sel lane via `2154`; `2150`: `[5:0]`best_run (0..16), `[13]`lane_passed, `[31:24]`=0xE7 marker. **Measures BIT-capture margin, NOT cross-lane SYNC-detect margin.** |
| `0x4403_21B8` | winscan obs | `[31:24]`=0x57 marker, `[23:20]`ws_state, `[2]`anchor_timeout, `[0]`winscan_done |
| `0x4403_0214` | LANEMASK | `0x0000_E4E4` |
| `0x4403_0208` | FC CTRL | bootstrap triplet `0x27F09, 0x27F01, 0x27F07` |
| `0x8400_0000` / `0x8401_0000` | GP1 TX / RX data apertures | (GP0 `0x44xx_xxxx` for data **hangs**) |

**Do NOT read `0x1AC` / `0x1B0` / `0x1B4`** — they hard-stall the Zynq PS (uninterruptible
AXI hang; needs a power-cycle).

---

## 5. How to observe a failed autonomous bring-up

In order — the first one that is wrong tells you where it died:

1. `0x21B8` — if the word reads `0x57000000` with `winscan_done=0`, check
   `autonomy_armed` first: **the FSM may never have run.**
2. `0x2108` — `cal` bit, then `fcsm`.
3. **`0x215C` — `sync_seen_vec`. Must be `0xE4`.** This is the money read.
4. `0x2140` — `reanchored`.
5. `0x2150/54` — per-lane eye. NOTE: a **wide** eye here does **not** mean the lane is
   healthy for SYNC-detect (see status doc §Root cause).

`cal` and `fcsm` read healthy even on a marginal link; `lane_locked` reads `0x00`
even on a *good* link. Do not trust them as health indicators.
