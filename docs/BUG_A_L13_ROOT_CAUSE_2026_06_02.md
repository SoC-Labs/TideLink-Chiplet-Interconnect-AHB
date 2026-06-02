# Bug A — L13 root cause and fix (2026-06-02)

After a clean Build #12c HW test pivoted the diagnosis ("R-1 regression" was
falsified; payload-zeroing was confirmed), a focused code audit found the
root cause was an unfinished RTL fix.

## Root cause

`src/rtl/tidelink_fc_adapter.sv:179-187` carries a comment block describing
the **L13 fix** ("Register hwdata into tx_data_r at the data phase") but
the register `tx_data_r` was declared and never assigned. The combinational
formulation `tx_fc_word = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata}` (line 252
of the pre-fix tree) samples hwdata directly from the AHB bus. On
`axi_ahblite_bridge` + SmartConnect (the Xilinx AXI→AHB pipeline used in
the PYNQ-Z2 BD), hwdata is released on the hreadyout=1 ack edge — the
same edge as the skid load — so the skid latches zero.

The first FC word of a packet carries the **packet length** in its wdata
(captured at slave `fc_wr_addr == 0` per `tidelink_fifo_ctrl.sv:157`).
hwdata-zero therefore captured length=0 on the slave side, which kept
`write_target_addr_r` pinned at 0 and prevented `write_complete` from
ever firing. That cascades to:

- slave `packet_committed_irq` never asserts → `REG_STATUS bit[4] = 0`
- slave RX FIFO contents stay zero (the wdata that was lifted is 0)
- master credit accounting / framing still works (boundary signals OK)
- every payload pattern — including 0xFFFFFFFF and 0x55555555 — arrives
  as zero on the slave

## HW evidence (Build #12c, 2026-06-02 ~10:30 BST)

After 6 patterns of length=1 sent from master (0xFFFFFFFF, 0x55555555,
0xAAAAAAAA, 0x00000001, 0x80000000, 0xDEADBEEF), then 16 sequential
length=1 packets:

| signal | master | slave | meaning |
|---|---|---|---|
| `REG_STATUS bit[0]` returner_busy | 0 | 0 | no R-1 regression |
| `REG_STATUS bit[4]` PKT_COMMITTED | 0 | 0 | slave never sees commit |
| `REG_STATUS bit[2]` underrun | 1 | 1 | sticky from FIFO read of empty |
| `REG_RELEASED_ACC` | 6 | 6 | credit accounting OK |
| `AHB_RX_FIFO[0..63]` | 0 | 0 | payload lost entirely |
| `SWI_LANE_STATUS` | 0x018900ff | 0x018900ff | 16/16 link UP |

The master never overruns (TX FIFO never fills) → packets ARE leaving
master AHB → wlink. The slave acks credit boundaries (RELEASED_ACC ticks
as the master fc_adapter consumes TX-FIFO entries). But payload words
arrive zeroed.

This is the same failure mode as the cocotb 2.x BFM bug found yesterday
(`test_buga_addr_aliasing` `_ahb_tx_write_word_fixed`), but on the HW
side of the AHB bus rather than the testbench side.

## Fix

`src/rtl/tidelink_fc_adapter.sv` — split the data phase into two cycles:

- Cycle 1 (`tx_data_phase_first_r == 1`): capture `ahb_tx_hwdata` into
  `tx_data_r`. AHB master must still hold hwdata in this cycle because
  hreadyout is forced low.
- Cycle 2 (`tx_data_phase_r == 1 && tx_data_phase_first_r == 0`): skid
  load fires using the registered `tx_data_r`, hreadyout=1 acks the
  transfer. The bridge releasing hwdata on this edge no longer matters
  because `tx_fc_word` is fed from `tx_data_r`, not combinational
  `ahb_tx_hwdata`.

Throughput: minimum data phase grows from 1 cycle to 2 cycles. Worst
case 50% reduction in single-burst throughput. At 25 MHz FPGA clock,
that's a 12.5 MHz word rate ceiling — well above the credit-limited
steady-state throughput, so no end-to-end impact.

Wedge watchdog (L10/L11) updated to skip the first capture cycle when
counting back-pressure — otherwise it would trip every transfer.

## Sim validation

`test_buga_addr_aliasing.test_buga_addr_aliasing` PASS in 205s with the
L13 fix in place:

```
master tl_fc_a2l data: ['0x240000', '0x0', '0xdeadbeef', '0xcafebabe']
slave fc_rx_fifo wdat: ['0x240000', '0x0', '0xdeadbeef', '0xcafebabe']
SLAVE packet_committed_irq_r transitions: cy=77 0 → 1
```

The fixed BFM (`_ahb_tx_write_word_fixed`, holds hwdata an extra cycle)
plus the L13 RTL fix produces correct end-to-end commit. The sim doesn't
exactly emulate the SmartConnect "release-too-early" symptom, so HW
validation is what proves the fix.

## HW validation plan

Build #13 (in flight at 11:00 BST on `srv04936` farm host) carries:
- L13 fix in `tidelink_fc_adapter.sv`
- mark_debug on `tx_fc_word`, `tx_fc_valid`, `fc_rx_fifo_wdata`
- Same ODDR / IDELAYE2 / calibrator config as Build #11/12 (no other
  RTL changes that could mask the fix)

Expected HW result after deploy:
- master REG_STATUS unchanged at 0x00000000 (no regressions)
- slave REG_STATUS bit[4] should pulse 1 per packet (then self-clear)
- slave AHB_RX_FIFO[0..N] should contain the actual payload words sent
- master REG_RELEASED_ACC should advance correctly with consumed credits
- link should still report 16/16 lanes locked

## Related artefacts

- `docs/BUG_A_PIVOT_2026_06_01.md` — yesterday's pivot doc
- `docs/BUG_A_ADDR_COLLAPSE_SIM_2026_06_01.md` — the original sim trace
  that motivated the L13 fix comment block
- `cocotb/tidelink_top_pair/test_buga_addr_aliasing.py` — the cocotb
  BFM-fix test that catches this class of failure
