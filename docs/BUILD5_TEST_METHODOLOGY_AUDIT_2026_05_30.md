# Build #5 HW Test Methodology Audit

Date: 2026-05-30 — Independent (no consult of BUILD4/BUILD5/FCSM_L7 priors).
Subject: `/tmp/multi_deploy_test.sh` (mapstone-dev) — 5-iter doorbell probe with `SWI_TRAINING_MODE=1` held throughout.

## 1. Address-map verification

Source of truth: `src/rtl/fifo/tidelink_apb_regs.sv` (live per `git status`; instantiated by `src/rtl/fifo/tidelink_fifo.sv`).

| Reg | APB offset | Test addr | Decode | Verdict |
|---|---|---|---|---|
| REG_DOORBELL | 0x014 | 0x44032014 | region 0000 / slot 5 (line 210) | CORRECT |
| REG_STATUS | 0x010 | 0x44032010 | region 0000 / slot 4 (line 470) | CORRECT |
| REG_DOORBELL_RESP_ACC | 0x024 | 0x44032024 | region 0001 / slot 1 (line 491) | CORRECT |
| SWI_TRAINING_MODE | 0x100 | 0x44032100 | region 1000 / slot 0 → ctrl_reg_addr=8 (line 447), routed to `axi_chiplet_controller.swi_training_mode_r` | CORRECT |
| SWI_LANE_STATUS | 0x108 | 0x44032108 | region 1000 / slot 2 RO | CORRECT |

`PAIR_BASE_ADDR` is written to 0x44032000 by `deploy_pair.sh:329`, so the master returner targets the slave's APB at `0x44032000 + REG_OFFSET`. Slave REG_DOORBELL_RESP_ACC at 0x44032024 is the correct observation point (master sends via `PAIR_DOORBELL_RESPONSE_ADDR = pair_base_addr + 0x024`, `tidelink_fifo.sv:180`).

**Address map is sound.**

## 2. Read/write semantics

- **REG_DOORBELL (0x014)** — write of any value pulses `doorbell_trigger` for one `hclk` cycle (`apb_regs.sv:210`); `pwdata` ignored. Reads return peripheral ID `0x544C_0100`, not status. Test only writes — fine.
- **REG_STATUS (0x010) RO** — bit[0]=`returner_busy`=`state_r!=ST_IDLE` direct from returner (`tidelink_returner.sv:96`). bit[1] overrun, bit[2] underrun, bit[3] master_error (sticky), bit[4] packet_committed. No read-side effect.
- **REG_DOORBELL_RESP_ACC (0x024) — read-to-clear, write-add (16-bit saturating)** (`apb_regs.sv:297-311`). A read zeroes it next cycle. The peer returner writes here with `write_data_1 = credit_count_data` (`tidelink_fifo.sv:321`) — NOT a "+1". One delivered doorbell adds the master's current free credit count, typically 4096 (0x1000) given the 4096-deep FIFO. ~16 deliveries saturate to 0xFFFF.
- **SWI_TRAINING_MODE (0x100)** — RW bit[0] = `swi_training_mode_r` (`axi_chiplet_controller.sv:579`); OR-merges with `cal_training_mode_w` (`acc.sv:1474`) and feeds `Wlink.swi_training_mode_in` (`acc.sv:1712`). POR-only reset on the register.

The test's `read_state()` reads RESP_ACC and so clears it; the bracketing call before `ring_master()` is benign as written but easy to break.

## 3. Race conditions and timing

- 2 s after `SWI_TRAINING_MODE:=1` — APB→link CDC is 2 FFs; `post_train_hold_ctr_r` is 64 link-word cycles. Massive overkill. Not a race.
- 0.5 s after 100 rings — returner is a few hclk per AHB txn; even single-digit ms covers 100. Not a race.
- 100 PS `struct.pack_into` writes — each is a separate AXI write through SmartConnect→`xhb500_axi_to_ahb_bridge`→APB; no coalescing in the bridge.
- Returner `interrupt_1_rising = interrupt_1 & ~interrupt_1_r` (`returner.sv:89`) detects each one-cycle pulse as its own edge. BUT `pending_1` is one bit (line 93): if a second rising edge arrives while the first hasn't been dispatched, it is coalesced. With back-to-back PS writes at sub-µs rate vs. tens-to-hundred-ns drain, you should expect 1–few actual dispatches per 100 rings, NOT 100. This is an architectural property, not a test bug — but means the test's pass criterion must be "non-zero" not "100×N".

## 4. AHB / SmartConnect coalescing

SmartConnect is a transaction-level switch — same-address back-to-back writes are NOT collapsed. The xhb500 bridge serialises AXI→AHB one-for-one. Each PS write produces one APB transaction → one `doorbell_trigger` pulse → at most one `pending_1` set in the returner (per §3). The visible bound is the returner drain rate, NOT bridge coalescing.

## 5. The killer: doorbells with SWI_TRAINING_MODE=1 cannot deliver

`local_overrides/WavD2DGpioTx.v:252-256`:

```
wire [15:0] _link_data_eff = io_training_mode_mux ? {pattern,pattern} : io_link_data;
```

`local_overrides/Wlink.v:1952`:

```
assign llrx_reset = rx_link_clk_reset | swi_training_mode_rxsync_1;
```

When SW asserts `SWI_TRAINING_MODE=1`:
- **TX**: every WavD2DGpioTx mux replaces `io_link_data` with the per-lane training pattern. The FCSM-emitted doorbell FC packet is substituted out before leaving the die.
- **RX on the peer**: LL_RX is forced into reset, cannot receive ANY FC packet.

The 64-cycle `post_train_hold_ctr_r` extends the RX hold past the falling edge of training_mode, but the test keeps the input HIGH throughout, so both gates are permanently asserted.

**Doorbell delivery is physically impossible in this configuration. `DB_RESP=0` is the expected outcome, not evidence of a wedge.**

## 6. `REG_STATUS[0]` ("returner_busy") ambiguity

Bit[0] = state != ST_IDLE. Under training_mode=1 the FC credit-replenishment loop is dead (cr_pkts cannot return from the peer whose RX is in reset). Once pair credits exhaust, the local FC node refuses new returner writes; the returner stalls in ADDR/DATA phase waiting for `hready`. **Busy=1 under training_mode is the design's expected behaviour, not a wedge signature.** Longer sleeps would not change this — the path will not drain until training_mode drops on both sides.

## 7. APB-vs-FCSM race

Not the dominant effect. `deploy_pair.sh` ends with the swreset toggle and LL re-enable; the AUTOCAL path (`AUTOCAL_ENABLE=1` at `tidelink_top.sv:1812`) runs internally and a 2 s settle is generous. The test is not "too fast"; it is "in a mode that disables real traffic".

## 8. Cross-channel observability

The only delivery observable on the slave is `doorbell_response_acc` and the level signal `doorbell_irq = (acc != 0)` — same information. No separate counter, no LED, no IRQ count. Test has no orthogonal cross-check. ILA on the slave APB write port or on returner `pending_1` would be needed.

## Per-question verdicts

| # | Verdict |
|---|---|
| 1 | TEST VALID |
| 2 | TEST VALID |
| 3 | TEST VALID (as written; fragile to extra probes) |
| 4 | QUESTIONABLE — no AHB coalescing, but returner `pending_1` is one bit → 100 rings ≈ 1–few dispatches even on healthy link. Pass criterion should be "non-zero", not "100×N" |
| 5 | **TEST WRONG.** TX is substituted with training pattern; peer RX held in reset. Delivery impossible by design under SWI_TRAINING_MODE=1 |
| 6 | QUESTIONABLE — `busy=1` is the expected behaviour under training_mode=1 (FC credit loop dies); not diagnostic of any wedge |
| 7 | VALID (timing is generous) |
| 8 | QUESTIONABLE — no orthogonal observable |

## Refined recipe

1. `deploy_pair.sh` for both boards.
2. **Do NOT write SWI_TRAINING_MODE.** Poll `SWI_LANE_STATUS` until `lock==0xFF` and `cal_done` bit set (5 s timeout); fail iteration if it doesn't converge.
3. Read REG_DOORBELL_RESP_ACC on slave once to clear any autoneg-induced deposit.
4. Read REG_STATUS on master; require bit[0]=0 before ringing.
5. Ring **1** doorbell from master (one is informative because each delivery adds `credit_count_data ≈ 4096`).
6. Sleep 100 ms.
7. Read REG_DOORBELL_RESP_ACC on slave: PASS = non-zero (~4096); FAIL = 0.
8. Read REG_STATUS on master: PASS = bit[0] back to 0; FAIL = 1.
9. Optionally repeat 5–10 rings with 50 ms gaps; expect growing or saturated 0xFFFF, not 0.

A separate test should exercise SWI_TRAINING_MODE=1 and assert the *expected* hold semantics (training bytes on wire, peer RX in reset, doorbells DO NOT deliver) — not conflate it with a delivery healthcheck.

## Could the "downstream wedge" be a test artefact? — YES, partially (probably wholly)

The test writes `SWI_TRAINING_MODE=1` on both boards then probes doorbell delivery. By the RTL of `local_overrides/WavD2DGpioTx.v:252-256` (TX mux replaces FC bytes) and `local_overrides/Wlink.v:1952` (peer LL_RX held in reset), delivery is impossible by design while training_mode is asserted. The observed `DB_RESP=0` and master `REG_STATUS[0]=1` (returner stalled on dead FC credit loop) are EXACTLY the symptoms this mode produces. The build #3 baseline that "worked" (`/tmp/doorbell_test.sh`) never writes 0x100 — its 4096 reading is consistent with autoneg leaving training_mode=0 and a healthy link.

A real downstream wedge — if one exists — cannot be confirmed or refuted by this test until SWI_TRAINING_MODE is removed from the loop or the test asserts it back to 0 before ringing. Re-run the refined recipe before committing to another build cycle. If the refined recipe also shows `DB_RESP=0` and `returner_busy=1` on build #5 but works on build #3, THAT is the wedge evidence; the current data is not.

**Key files**
- `src/rtl/fifo/tidelink_apb_regs.sv` (regs, decoding, accumulator semantics)
- `src/rtl/fifo/tidelink_fifo.sv:180,321` (returner ch1; `write_data_1=credit_count_data`, target=`pair_base_addr+0x024`)
- `src/rtl/fifo/tidelink_returner.sv:89-127` (single-bit `pending_1`, busy = state != IDLE)
- `src/rtl/local_overrides/WavD2DGpioTx.v:252-256` (TX mux on training_mode)
- `src/rtl/local_overrides/Wlink.v:1952` (peer LL_RX reset on training_mode)
- `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv:1474,1712` (training_mode OR-merge + Wlink wiring)
- `pynq_host/scripts/deploy_pair.sh:303-367` (deploy does NOT touch SWI_TRAINING_MODE)
- `/tmp/multi_deploy_test.sh` + `/tmp/td_set_train.py` (the audited test)
- `/tmp/doorbell_test.sh` (build-#3 baseline that does NOT touch SWI_TRAINING_MODE)
