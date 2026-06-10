# Bug N7 silicon status — 2026-06-01

**Branch:** `feat/td-autonomy` HEAD `3fe6a94`
**Build v7:** PASS, both bitstreams flashed to z2_02 / z2_03 at 00:32 BST 2026-06-01.

## RTL + BD fix CONFIRMED on silicon

z2_02 (pair-all, master) and z2_03 (pair-flip-all, slave) post-deploy readback:

```
                    z2_02 (master)      z2_03 (slave)
strap_gpio          0x00                0x01                ← BD: per-target DOUT default ✓
nego_cfg            0x61                0x61                ← Phase 2-bis ✓
nego_priority_reg   0x01                0x02                ← RTL: role_strap-derived ✓ ASYMMETRIC
pair_base_addr      0x44032000          0x44032000          ← Phase 5 ✓
nego_train_cfg      0x0001              0x0001              ← Phase 2 ✓
nego_timeout_reg    0x07d02710 (131M cycles ≈ 2.62s @ 50 MHz)
```

The Bug N7 RTL + BD fix lands on real silicon. Master's `nego_priority_reg` POR-loads to `0x01` because `role_strap_i = strap_gpio[0] = 0`. Slave's POR-loads to `0x02` because `role_strap_i = 1`. The strap-derived asymmetric priority is in place from FPGA POR, before any SW write.

## Behavioural status — autoneg still wedges

Despite asymmetric priorities, both dies still reach `NEGO_STATUS = 0x027` (ST_ERROR with `error=1`) and **`sda_start_seen = 0` on both**. Master's own i2c_slave (same bus as master's i2c_master) never observes an I²C START condition — meaning master's i2c_master never drove START. So master never reached `ST_NEGO_CLAIM`.

Autoneg backoff math (with NEGO_TICK=1000, NEGO_BASE_DELAY=2000, apb_clk=50 MHz):
- Master priority=1: backoff = 1×1000 + 2000 = **3000 cycles ≈ 60 µs** before exiting WAIT → CLAIM
- Slave priority=2:  backoff = 2×1000 + 2000 = **4000 cycles ≈ 80 µs**

Both budgets are TINY compared to `nego_timeout_reg = 131M cycles ≈ 2.62 s`. Master should reach CLAIM long before timeout.

## Hypothesis space

1. **autoneg FSM not actually clocking** — but APB transactions to nego_cfg/pri/timeout DO complete (we can read these regs), and timeout_ctr loading at ST_IDLE→INIT requires the FSM to step at least once. Clocking is probably fine.
2. **`init_wait_r` stuck before CLAIM enter** — at line 625 `init_wait_nxt = NEGO_MST_INIT_WAIT[4:0] = 5'd16`. Only 16 cycles; should not stall.
3. **`axl_state_r` stuck in i2c_master_axil's AXI-Lite handshake** — possible if i2c_master AXIL bus has a hang. Cannot observe from APB without extra debug regs.
4. **`role_is_master` flipping causes `i2c_mst_reset` to assert mid-transaction** — possible if `nego_role_w` toggles between ST_NEGO_WAIT and CLAIM. line 902: `i2c_mst_reset = ~hresetn | (~role_is_master & ~nego_driving)`.
5. **Clock domain / clk_wiz issue** — apb_clk derived from clk_wiz_0. If clk_wiz isn't locked or PLL is mis-configured, autoneg FSM clocking could be subtly off. But that would also break our APB probe reads.
6. **i2c IOBUF mapping inverted** — XDC + BD claim P15=SCL, P16=SDA. Sim confirmed correct connection. But silicon could have a subtle issue (e.g., voltage domain mismatch — although both LVCMOS33).
7. **Dupont harness electrically misconnected** — user confirmed it's installed, but a swap (SDA↔SCL or wrong row of pins) would cause this exact symptom. **The simplest hypothesis to test.**

## Next-step investigation plan

To diagnose without observability rebuild:

1. **Verify Dupont wiring at the boards.** P15 (top board) ↔ P15 (bottom board); P16↔P16; GND↔GND. Confirm no Arduino shield card populated on either board.
2. **Add observability registers** to chiplet APB Region 4 / 8 exposing:
   - `autoneg.delay_ctr_r[31:0]`
   - `autoneg.timeout_ctr_r[31:0]`
   - `autoneg.init_wait_r[4:0]`
   - `autoneg.axl_state_r[2:0]`
   - `autoneg.txn_step_r[2:0]`
   - `autoneg.nego_state_w[3:0]` (already exposed, slot 5)
   - `i2c_master_axil` STATUS register (passthrough)
   This is a wrapper-level edit + rebuild. ~100 min build cycle to get probes.
3. **Then re-deploy** and read the regs to determine which step the FSM is stuck on.

## All Bug N1-N6 fixes still silicon-validated under v7

Per the SW-forced deploy path earlier in this session (commit 3fe6a94 includes all N1-N6 fixes):
- `cal_done=1` both dies ✓
- `cr_pkt_seen / crack_pkt_seen=1` both dies ✓
- `FCSM state=4` both dies ✓
- All POR register defaults match expected (Phase 2/2-bis/5 working)

The only outstanding issue is autoneg actually completing on the I²C wire. That's the LAST blocker for fully autonomous bring-up.

## Recommendation for tomorrow

1. **Verify the Dupont harness wiring visually** (5 min, no code change).
2. If wiring is correct: spawn an agent to add the observability registers (Hypothesis 3 in the list above) → rebuild v8 → re-deploy → probe.
3. Likely candidates from probe data:
   - `axl_state_r` stuck → i2c_master_axil hang → fix i2c IOBUF tristate / pad config
   - `delay_ctr_r` not decrementing → clk_wiz / clock domain → fix clock config
   - `txn_step_r` stuck at TXN_PRESCALE → i2c_master AXI write hang → debug AXIL bus

## Commits in this session

- `3fe6a94` autonomy(bug-n7): role_strap-derived nego_priority POR + per-target strap GPIO DOUT default
- `7d9c7b0` cocotb(bug-n7): test_18 regression + tb RELY_ON_RTL_PRIO_DEFAULTS param — FAILS pre-fix
- `d385349` scripts(deploy_pair): apostrophe fix + Bug N5 diagnosis doc

All 8 commits since `fc2bbb9` form a bisect-clean chain. Build v7 bitstreams at `imp/fpga/output/pynq-z2-pair-{all,flip-all}/tidelink.{bit,bin}`, sha256 `5dc13f98b93d…` / `6bff357f3b4e…`.
