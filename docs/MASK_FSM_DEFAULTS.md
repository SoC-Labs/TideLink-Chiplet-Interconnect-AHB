# MASK-Phase FSM — Class A/B Defaults Audit (Phase A hypothesis (b))

**Scope:** `deps/axi-chiplet-controller/logical/top/tidelink_autoneg.sv` @ `a55d346`
(branch `feat/td-combined`, includes structural Bug #3 fix `6a757e2`).

**Question being answered:** Do `mask_byte_cnt_r`, `mask_retry_r`, and other helpers
on the mask-phase code-path (states 8/9/10 = MASK_RES_TX / MASK_RD_ADDR / MASK_RD_DATA)
exhibit the same Class A (missing comb default → latch) or Class B (missing outer
`default:` arm → optimizer freedom) bug pattern as the three fixes this session:

- Bug #1 — `467b889` nego_driving gating
- Bug #2 — `be5eed2` `txn_step_nxt` latch (Class A)
- Bug #3 — `6a757e2` outer `case (state_r)` missing default (Class B)

**TL;DR:** All mask-phase signals are clean. `mask_byte_cnt_nxt` and `mask_retry_nxt`
both receive an explicit `*_nxt = *_r;` default at the top of the main FSM `always_comb`
(lines 401-402), in the same block hardened by `be5eed2`. The outer `case (state_r)`
already has its `default:` arm (line 937, the `6a757e2` fix). Hypothesis (b) is
**NEGATIVE** — no remaining Class A/B bug on the mask path.

---

## 1. Signals on the mask-phase path

### 1.1 FSM registers (always_ff `posedge clk or negedge poresetn`, lines 1210-1253)

| Signal | Decl | Reset (1211-1229) | Update (1230-1252) | Class |
|---|---|---|---|---|
| `mask_byte_cnt_r[2:0]` | 218 | `<= 3'd0` (1226) | `<= mask_byte_cnt_nxt` (1248) | clean |
| `mask_retry_r[3:0]` | 224 | `<= 4'd0` (1227) | `<= mask_retry_nxt` (1249) | clean |
| `rearm_cnt_r[3:0]` | 228 | `<= 4'd0` (1228) | `<= rearm_cnt_nxt` (1250) | clean |
| `busy_seen_r` | 232 | `<= 1'b0` (1229) | `<= busy_seen_nxt` (1251) | clean |
| `state_r[3:0]` | 216 | `<= ST_IDLE` (1212) | `<= state_nxt` (1231) | clean |
| `txn_step_r[2:0]` | 243 | `<= TXN_PRESCALE` (1217) | `<= txn_step_nxt` (1236) | clean (post-`be5eed2`) |
| `axl_state_r[2:0]` | 239 | `<= AXL_IDLE` (1216) | `<= axl_state_nxt` (1235) | clean |
| `axl_done_r` | 248 | `<= 1'b0` (1218) | edge-clear (1240) | clean |
| `axl_rdata_r[31:0]` | 253 | `<= '0` (1219) | `<= axl_rdata_nxt` (1241) | clean |

### 1.2 Peer-mask capture registers (always_ff, lines 354-379)

| Signal | Decl | Reset (355-359) | Update | Class |
|---|---|---|---|---|
| `peer_tx_lane_mask_r[7:0]` | 261 | `<= 8'h00` | gated by `peer_tx_capture_en` | clean |
| `peer_rx_lane_mask_r[7:0]` | 262 | `<= 8'h00` | gated by `peer_rx_capture_en` | clean |
| `mask_hs_local_match_r` | 263 | `<= 1'b0` | latched on RES_TX→DONE edge | clean |
| `mask_hs_local_fail_r` | 264 | `<= 1'b0` | latched on RES_TX→DONE edge | clean |

### 1.3 Combinational `_nxt` / helper signals

| Signal | always_comb @ | Default at top of block? | Inner case-default? | Class |
|---|---|---|---|---|
| `mask_byte_cnt_nxt` | 389 | YES — line 401 (`= mask_byte_cnt_r`) | outer `case(state_r)` has default @ 937; inner `case(txn_step_r)` arms in states 9/10/8 all have `default: ;` (693, 781, 863) which is safe given top default | clean |
| `mask_retry_nxt` | 389 | YES — line 402 (`= mask_retry_r`) | same as above | clean |
| `txn_step_nxt` | 389 | YES — line 419 (`= txn_step_r`) — added by `be5eed2` | same | clean (post-fix) |
| `state_nxt` | 389 | YES — line 391 | outer default at 937 — added by `6a757e2` | clean (post-fix) |
| `rearm_cnt_nxt` | 389 | YES — line 403 | same | clean |
| `busy_seen_nxt` | 389 | NO top default but fully exhaustive `if/else if/else` chain (425-443) — has final unconditional `else busy_seen_nxt = busy_seen_r;` | n/a | clean (covered by else) |
| `init_wait_nxt` | 389 | YES — line 394 | same | clean |
| `delay_ctr_nxt` | 389 | YES — line 392 | same | clean |
| `timeout_ctr_nxt` | 389 | YES — line 393 | same | clean |
| `nego_done_nxt` | 389 | YES — line 396 | same | clean |
| `nego_won_nxt` | 389 | YES — line 398 | same | clean |
| `nego_lost_nxt` | 389 | YES — line 399 | same | clean |
| `nego_role_nxt` | 389 | YES — line 395 | same | clean |
| `nego_error_nxt` | 389 | YES — line 397 | same | clean |
| `sda_start_seen_nxt` | 389 | YES — line 400 | same | clean |
| `nego_set_role_cfg` / `_lock` / `nego_role_value` | 389 | YES — lines 446-448 (`= 1'b0`) | same | clean |
| `mask_res_byte` / `mask_res_last` | 962 | implicit via case (every 3-bit encoding listed) + explicit `default:` at 970 | n/a | clean |
| `mask_rd_addr_byte` / `mask_rd_addr_last` | 980 | case + explicit `default:` at 984 | n/a | clean |
| `peer_tx_capture_en` | 993 | YES — line 994 (`= 1'b0`) | n/a | clean |
| `peer_rx_capture_en` | 993 | YES — line 995 (`= 1'b0`) | n/a | clean |
| `axl_target_addr` | 1005 | YES — line 1006 (`= 8'd0`) | case has `default: ;` at 1094 — safe via top defaults | clean |
| `axl_target_wdata` | 1005 | YES — line 1007 (`= 32'd0`) | same | clean |
| `axl_is_read` | 1005 | YES — line 1008 (`= 1'b0`) | same | clean |
| `axl_state_nxt` | 1099 | YES — line 1111 (`= axl_state_r`) | inner case has explicit `default: axl_state_nxt = AXL_IDLE;` at 1202 | clean |
| `axl_done_nxt` | 1099 | YES — line 1112 (`= 1'b0`) | n/a | clean |
| `axl_rdata_nxt` | 1099 | YES — line 1113 (`= axl_rdata_r`) | n/a | clean |
| `selected_priority` | 281 | YES — line 289 (`= 16'hFFFF`) + explicit `default:` @ 295 | n/a | clean |

### 1.4 Mask-FSM consumers — where these signals gate transitions

`mask_byte_cnt_r` is READ at:
- 433-434 (`MASK_RES_TX && txn_step==TXN_DATA && mask_byte_cnt_r==0` resets busy_seen)
- 435-436 (same for MASK_RD_ADDR)
- 624 (`MASK_RD_ADDR_BYTES - 1` advance check)
- 627 (increment)
- 649, 674, 684 (resets/increments)
- 767-768 (`MASK_RD_DATA_BYTES - 1` advance check)
- 776 (increment)
- 797 (`MASK_RES_BYTES - 1` advance check)
- 801 (increment)
- 849 (reset on retry)
- 963, 981, 998, 1000, 1062, 1068, 1072 (selector for mask_res_byte, mask_rd_addr_byte, capture_en, cmd-bit selection)

`mask_retry_r` is READ at:
- 662, 673 (MASK_RD_ADDR fail-fast / retry-bump)
- 737, 746 (MASK_RD_DATA fail-fast / retry-bump)
- 839, 848 (MASK_RES_TX fail-fast / retry-bump)

Both registers are 3- and 4-bit respectively; both are reset to 0 at POR and at the
POLL→MASK_RD_ADDR transition (lines 596-597). The fail-fast threshold is
`MASK_MAX_RETRY = 4'd4` (line 37), reachable only after 4 NACKs.

**Could a stale/X value cause the FSM to skip state 8/9/10?** No. The only path
into states 8/9/10 is POLL→MASK_RD_ADDR (line 599) — gated by `mask_hs_auto_en`,
ACK received, and `busy_seen_r`. Neither mask_byte_cnt_r nor mask_retry_r is
in that gate. They are written-before-read on entry (reset to 0 at 596-597),
so even if they held bogus values prior, the entry write overrides.

---

## 2. Severity summary

| Severity | Count | Signals |
|---|---|---|
| HIGH (would unblock Phase A if fixed) | 0 | — |
| MED (latent / portability) | 0 | — |
| LOW (cosmetic / hardening) | 0 | — |
| Clean | 28 | all enumerated above |

**Conclusion for Phase A hypothesis (b):** the mask-phase FSM has no remaining
Class A or Class B defects. Whatever is preventing MASK completion on silicon
is **not** a missing comb default or a missing outer-case default on the helper
regs. Hypothesis (b) is **rejected**.

---

## 3. Where to look next (hypothesis pruning)

Phase A defects must lie outside the audited scope. Candidates:

1. **busy_seen reset coverage** — line 425-443 if/else does not list MASK_RD_ADDR
   TXN_COMMAND start-of-transaction reset (only TXN_DATA is listed at 435).
   For MASK_RD_ADDR, the first transaction is the 2-byte address write — its
   busy_seen reset arm fires only at `txn_step==TXN_DATA && mask_byte_cnt_r==0`,
   which IS the first byte. But the TXN_COMMAND step that pushes the cmd_write
   has no busy_seen reset, so a previous transaction's busy_seen=1 might leak
   into the TXN_CHECK. Not a Class A/B bug; a logic-window concern. Cocotb-
   evidence: `cocotb/tb_tidelink_autoneg/test_autoneg_mask_phase.py` would catch
   this.

2. **`axl_done_r` edge-clear semantics** (line 1240): `axl_done_r <=
   (state_nxt != state_r) ? 1'b0 : axl_done_nxt`. Clears on every state edge.
   But MASK_RD_ADDR → MASK_RD_DATA happens inside `state_nxt!=state_r`, so any
   pending axl_done_r=1 from the MASK_RD_ADDR's last cmd_write is dropped on
   the transition — which is correct for the new MASK_RD_DATA TXN_COMMAND but
   means the MASK_RD_DATA TXN_COMMAND must re-trigger AXL. The AXL drive gate
   (1126-1132) is held while the FSM is in a mask state, so this should be
   fine. Worth a `cocotb` waveform check.

3. **I2C-master DATA register read pathway** in TXN_DATA of MASK_RD_DATA. The
   read uses `axl_target_wdata = 32'd0` + `axl_is_read = 1` (line 1034-1035).
   The I2C master IP's DATA register read is supposed to pop the rd-data FIFO,
   but the rdata bus may carry FIFO meta-bits (data_valid, data_last) in
   bits [9:8] — peer_tx_lane_mask_r captures `axl_rdata_r[7:0]` only (line 362).
   If the FIFO is empty (no byte ready), bit [8] (data_valid) would be 0
   and bits [7:0] would be undefined. There is no `data_valid` check before
   capture, so a read with the byte not yet in the FIFO would latch garbage.
   This is a logic/protocol bug, not Class A/B.

These are **not** in this agent's scope — flagged for the parallel agent
working on hypothesis (a) / (c) / mask-handshake protocol traces.

---

## 4. References

- `be5eed2` — Bug #2 (Class A) — `txn_step_nxt` default
- `6a757e2` — Bug #3 (Class B) — outer `case(state_r)` default
- `467b889` — Bug #1 — nego_driving gating
- `cocotb/lint/sv_anti_pattern_lint.py` — automated Class A/B detector
- `staging/i2c_train/HW_VALIDATION_RESULTS.md §A.10-A.11` — silicon evidence
  for Bug #3
