# NEGO_TIMEOUT Review — Phase A Hypothesis (c)

> **Worktree:** `/home/dam1n19/td_idelay_wt` (branch `feat/td-combined`, sub `a55d346`)
> **RTL audited (read-only):**
>   - `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv`
>   - `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv`
>   - `src/rtl/fifo/tidelink_apb_regs.sv` (APB decode)
>   - `deps/axi-chiplet-controller/logical/i2c/rtl/i2c_master.v` (prescaler semantics)
>
> **Hypothesis under test (c):** the global negotiation timeout (`NEGO_TIMEOUT`,
> register at Region-4 addr-7 = APB byte offset **0x09C**) is short enough that
> the FSM is silently bailed to `ST_ERROR` (verdict `nego_role=nego_fallback`,
> `nego_error_r=1`) before the mask-handshake states 8 / 9 / 10 ever execute,
> which would manifest on silicon as the master never visiting `MASK_RD_ADDR`
> and `link_lane_mask_hs_result @ 0x21C` staying `0x00000000`.

---

## 1. RTL anatomy of the timeout

### 1.1 Default value
```
tidelink_autoneg.sv:27
  parameter NEGO_TIMEOUT_DEFAULT = 32'd131_082_000;  // ~1.31s @ 100 MHz
axi_chiplet_controller.sv:373
  nego_timeout_reg <= 32'd131_082_000;               // POR default
```

`nego_timeout_reg` is an APB-writable 32-bit register inside
`axi_chiplet_controller.sv`. POR default is **131 082 000** cycles. The
default is identical in both the parameter and the registered POR value.

### 1.2 Clock domain
`tidelink_autoneg` is driven by `clk` (passed in as `apb_clk` from
`axi_chiplet_controller.sv`). On the FPGA bring-up rig that is **50 MHz**
(see also `[v1 ASIC target = 100 MHz GPIO PHY]` in MEMORY); on v1 ASIC it is
~100 MHz.

| Clock | NEGO_TIMEOUT default in seconds |
|-------|---------------------------------|
| 100 MHz (v1 ASIC target) | 1.310 82 s |
| 50 MHz (FPGA bring-up)   | 2.621 64 s |
| 25 MHz (PHY-debug rig)   | 5.243 28 s |

### 1.3 When the counter is loaded
`timeout_ctr_r` is loaded from `nego_timeout_reg` at **only three** points
(grep result on `timeout_ctr_nxt = nego_timeout_reg`):

| Site | Line | Trigger |
|------|------|---------|
| `ST_IDLE → ST_NEGO_INIT` | 481 | the canonical start of negotiation |
| `ST_BYPASS → ST_NEGO_INIT` | 914 | SW arms `nego_en` after BYPASS |
| `ST_NEGO_DONE` slave re-arm | 897 | bounded `SLAVE_REARM_MAX` slave rebound |

The counter is **never** reloaded on entry to `MASK_RD_ADDR`, `MASK_RD_DATA`
or `MASK_RES_TX`. So one budget covers `INIT → WAIT (backoff) → CLAIM (I2C
master setup + 3 AXIL writes) → POLL (status busy-poll, includes 9-bit I2C
write on the wire) → MASK_RD_ADDR → MASK_RD_DATA (×4 bytes) → MASK_RES_TX
(6-byte write)`.

### 1.4 What the counter does
```
tidelink_autoneg.sv:450..458 — decrement
  if (((state_r > ST_IDLE && state_r < ST_NEGO_DONE) ||
        state_r == ST_NEGO_MASK_RES_TX ||
        state_r == ST_NEGO_MASK_RD_ADDR ||
        state_r == ST_NEGO_MASK_RD_DATA) && timeout_ctr_r != '0)
    timeout_ctr_nxt = timeout_ctr_r - 1;

tidelink_autoneg.sv:460..472 — expiry
  if ((same predicate) && timeout_ctr_r == '0) begin
      nego_role_nxt      = nego_fallback;
      nego_error_nxt     = 1'b1;
      nego_set_role_cfg  = 1'b1;
      nego_role_value    = nego_fallback;
      if (nego_force_lock)
          nego_set_role_lock = 1'b1;
      state_nxt = ST_ERROR;
  end
```
Expiry forces the role to `nego_fallback` (`NEGO_CFG[4]`), latches
`nego_error_r=1`, and jumps to `ST_ERROR`. With `nego_force_lock=1`
(`NEGO_CFG[5]`) it also pulses `nego_set_role_lock` — but `role_lock_reg`
won't actually latch unless `mask_hs_gate_open` is true
(`axi_chiplet_controller.sv:399`), so a timeout-then-lock keeps the gate
closed unless `mask_hs_bypass_i` is strapped.

`ST_ERROR` is terminal (line 919-921, no exit transitions). On silicon ILA
this would look like `state_r: POLL (4) → ERROR (7)` — **not** the reported
`POLL → DONE`. See §3.

### 1.5 SW writability
- APB region decode (`tidelink_apb_regs.sv:408-411`): chiplet controller is
  Region 4 (offsets 0x080-0x09C). `ctrl_reg_addr = paddr[4:2]`.
- `NEGO_TIMEOUT` is `ctrl_reg_addr = 3'h7` → **APB byte offset 0x09C** in the
  TideLink region.
- The register file gates writes on `!role_locked` (lines 405, 416), so SW
  must program `NEGO_TIMEOUT` **before** asserting `ROLE_CFG[1]=1`.

---

## 2. Wall-time budget

### 2.1 Available wall time
At the rates above, default `NEGO_TIMEOUT = 131_082_000` cycles is the lifetime
of the entire FSM from `ST_NEGO_INIT` through `MASK_RES_TX → DONE`.

### 2.2 Expected mask-exchange wall time
Each `MASK_RD_ADDR` / `MASK_RD_DATA` / `MASK_RES_TX` AXIL transaction sequences
through `TXN_PRESCALE | TXN_DATA | TXN_COMMAND | TXN_POLL | TXN_CHECK` and
back-pressures on the I2C bus going idle. The dominant cost is the I2C wire
transfer, not the AXIL bookkeeping.

The I2C master uses prescale to time SCL: `prescale = Fclk / (FI2Cclk * 4)`
(`i2c_master.v:139-141`). One byte plus ACK is 9 SCL periods, so:

```
cycles_per_byte_on_wire = 9 * 4 * prescale = 36 * prescale
```

| `I2C_PRESCALE` | cycles/byte | F_SCL @ 50 MHz | F_SCL @ 100 MHz |
|----------------|-------------|----------------|-----------------|
| 128 (POR default) | 4 608  | 97.7 kHz  | 195.3 kHz |
| 200               | 7 200  | 62.5 kHz  | 125.0 kHz |

Mask exchange byte count (off-wire) per the FSM:
- `MASK_RD_ADDR`: 2 address bytes + START + addr-byte + ACK ≈ **4 bytes ≈ 144·prescale**
- `MASK_RD_DATA`: 4 separate cmd_reads, each is repeated-START + addr + read-byte + ACK ≈ 3 bytes × 4 = **12 bytes ≈ 432·prescale**
- `MASK_RES_TX`: 6 bytes + START + addr ≈ **8 bytes ≈ 288·prescale**

Total ≈ **864 · prescale** I2C-wire cycles for the mask round-trip, plus
~5 cycles per AXIL handshake × ~25 AXIL transactions ≈ ~125 AXIL cycles
(negligible). Add the priority-backoff in `ST_NEGO_WAIT`
(`backoff_delay = priority * NEGO_TICK + NEGO_BASE_DELAY`, where
`NEGO_TICK=1000` and `NEGO_BASE_DELAY=2000` — so a `priority=0xFFFF` side
burns 65.54 M cycles in `WAIT` alone before claiming).

| Scenario | Cycles in mask exchange | Cycles in WAIT (pri=0) | Cycles in WAIT (pri=0xFFFF) |
|----------|-------------------------|-------------------------|-------------------------------|
| `prescale=128` | ~ 110 k | 2 000 | 65 537 000 |
| `prescale=200` | ~ 173 k | 2 000 | 65 537 000 |

So even at `prescale=200` and a worst-case priority, total cycles consumed
are bounded by ~65.7 M + (mask + claim/poll) ≈ **66 M cycles** worst-case.
The 131 M budget has roughly **2× headroom** at `prescale=200` and **~1.4 s**
of wall time still left over at 100 MHz.

At `prescale=128` (POR default) the budget has **~10× headroom** for the mask
exchange itself.

---

## 3. Verdict on hypothesis (c)

**REJECTED — NEGO_TIMEOUT is not firing before state 8.**

Three independent lines of evidence:

1. **Wall-time math (§2):** 131 M cycles is ~2× the worst-case total of the
   most pessimistic legitimate path (`priority=0xFFFF` + `prescale=200`).
   For a `priority=0` master with default `prescale=128` the budget is ~1200×
   the mask exchange itself.

2. **Wrong terminal state.** The ILA symptom is `POLL → DONE`, NOT
   `POLL → ERROR`. A timeout fires `state_nxt = ST_ERROR` (line 472) and
   sets `nego_error_r=1`. There is **no** code path that takes a timeout
   into `ST_NEGO_DONE`; ST_ERROR is sticky terminal (line 919). If timeout
   were the culprit, the ILA would show state 7 with `nego_error=1`, and
   `nego_status[4]` (the `nego_error_r` sticky) would be set on the
   silicon-readable status register.

3. **Wrong direct-cause for the symptom.** Looking at `ST_NEGO_POLL` TXN_CHECK
   (`tidelink_autoneg.sv:595-602`), `POLL → DONE` direct transition is the
   intended behaviour when `mask_hs_auto_en == 0` (i.e. `NEGO_CFG[6] == 0`).
   The branch is:
   ```
   if (mask_hs_auto_en) begin
       state_nxt = ST_NEGO_MASK_RD_ADDR;
   end else begin
       state_nxt = ST_NEGO_DONE;
   end
   ```
   The ILA showing `POLL → DONE` is consistent with `NEGO_CFG[6]` being
   **clear** on silicon — not with the timeout firing. This is the mask-FSM
   agents' territory (see `docs/MASK_FSM_DEFAULTS.md` and
   `docs/MASK_FSM_REVIEW.md`), not the timeout's.

---

## 4. Recommendation

Although hypothesis (c) is rejected, two minor robustness items dropped out of
the audit and are worth noting:

### 4.1 Belt-and-braces: per-MASK-phase timeout reload
The current implementation gives one global budget covering both the backoff
(`WAIT`) and the mask exchange. A future v2 design point would reload
`timeout_ctr_r` on entry to `MASK_RD_ADDR` so the mask phases get a fresh,
narrower budget independent of `priority`-driven backoff. **Not needed for
Phase A** — current headroom is fine.

### 4.2 SW write knob for shorter-budget bench debug
For bench bring-up where the operator wants quick "timed-out vs gated"
discrimination, write a smaller `NEGO_TIMEOUT` (e.g. 5 000 000 cycles = 100 ms
@ 50 MHz) through APB offset **0x09C** before clearing the lock. This makes a
mask-exchange-stall fail fast into `ST_ERROR` (visible via `nego_status[4]`
on the status register) instead of looking like a benign `DONE`.

```
# Pseudocode — APB write to TideLink Region 4 (paddr[14:13]=01) addr 7
write32(TIDELINK_BASE + 0x09C, 5_000_000)     # 100 ms @ 50 MHz, 50 ms @ 100 MHz
write32(TIDELINK_BASE + 0x094, 0x41)          # NEGO_CFG: en=1, auto_en=1 (bit 6)
```

This is a **debug aid only**, not a fix for the Phase A symptom.

### 4.3 No code change for Phase A
Pursue mask-FSM hypotheses (see `MASK_FSM_REVIEW.md` /
`MASK_FSM_DEFAULTS.md` / `LANE_TRAIN_FLOW.md`) instead. Most likely is
`NEGO_CFG[6]` (mask_hs_auto_en) being clear on silicon — the bring-up script
must program `NEGO_CFG = 7'b1?????1` (bit 6 set, bit 0 set) **before** lock.

---

## 5. Cross-references
- ILA-instrumented signals (mark_debug): `state_r`, `txn_step_r`,
  `axl_done_r`, `axl_rdata_r`, `nego_driving`, `busy_seen_r` —
  `tidelink_autoneg.sv:213-253`.
- Sister-agent docs (do not edit from this agent):
  - `docs/MASK_FSM_REVIEW.md` (FSM-trace) — owns POLL→DONE root-cause
  - `docs/MASK_FSM_DEFAULTS.md` — owns `mask_hs_auto_en` strap defaults
  - `docs/LANE_TRAIN_FLOW.md` — owns lane-train sequencing
  - `docs/SV_ANTIPATTERN_SWEEP_REPORT.md` — owns SV-lint sweep
