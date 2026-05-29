# TideLink slave-side "demux" issue — detailed report

**Date:** 2026-05-29 13:20 BST
**Build:** #3 (dda0a0e, Fix A2+B + AUTOCAL_ENABLE=1)
**Lease:** bridge1 held until 16:09 BST

## TL;DR

The headline phrase "slave-side demux issue" is **two separate issues that initially looked like one**:

1. **AHB packet RX**: `PAIR_CREDIT_COUNTER = 0x00` on both sides. FCSM CR/CRACK credit handshake never completes; AHB-class FC application traffic is starved. This is the **shared FC node** for AHB packets at [tidelink_top.sv:1951-1953](src/rtl/tidelink_top.sv#L1951-L1953).

2. **PTP HW_SYNC RX**: A **different** failure. The PTP short-packet path uses a **dedicated port** on the chiplet controller ([tidelink_top.sv:1955-1956](src/rtl/tidelink_top.sv#L1955-L1956)) wired through [ShortPacketToWlink.v](deps/axi-chiplet-controller/logical/wlink/ShortPacketToWlink.v) — which has NO credit gating, just TX/RX FIFOs + valid/ready handshakes. So this isn't credit starvation. The likely cause is in the PHC Phase-1 family of bugs (master TX never asserts, or slave consumer-replica drops packets at [tidelink_ptp.sv:288](src/rtl/tidelink_ptp.sv#L288)).

The doorbell channel works because it rides on a **sideband path** that doesn't require credits.

**Empirical confirmation (2026-05-29 13:30 BST):** Setting slave `PTP_CTRL=0x01` (ptp_enable=1) and triggering master HW_SYNC still leaves slave `HW_SYNC_STATUS=0x00`. So `ptp_enable_r` gate at slave isn't the cause either.

## Direct HW evidence (build #3, post-deploy + bringup, lease held)

```
LANE_STATUS         = 0x018900ff   (locked=0xff cal_done=1)  -- both sides
PAIR_CREDIT_COUNTER = 0x00000000   -- both sides   ← THIS IS THE BUG
CRED                = 0x00001000   -- both sides   -- initial credit allocation; non-zero, OK
PTP_CTRL            = 0x00000000   -- both sides   -- SW has not touched these yet
HW_SYNC_CTRL        = 0x00000000   -- both sides
HW_SYNC_STATUS      = 0x00000000   -- both sides
SERVO_STATUS        = 0x00000000   -- both sides
```

Note: the earlier sandwich run showed master `HW_SYNC_STATUS=0x1e0d` because `bringup_ptp_sync.sh` had explicitly written `PTP_CTRL=0x0d` and `HW_SYNC_CTRL` to start the initiator. The slave's `HW_SYNC_STATUS=0` is the same problem in the same family: no application traffic flows because of `PAIR_CREDIT_COUNTER=0`.

## Mapping symptoms to layers

| Symptom | Layer | Build #3 status |
|---|---|---|
| 16/16 lane lock | PHY (Wlink + new GPIO PHY) | ✅ |
| cal_done both sides | PHY (calibrator FSM) | ✅ |
| Doorbell M↔S | FC sideband (counter at REG_DOORBELL_RESP_ACC bumps freely) | ✅ |
| AHB packet RX at slave | FC application traffic (needs PAIR_CREDIT) | ❌ |
| PTP HW_SYNC reaches slave | FC application traffic (needs PAIR_CREDIT) | ❌ |
| AHB_TX wedge | PS-visible side-effect of dead application queue | ✅ no wedge now (returner self-drains on TX side) |

So the picture is consistent: **everything that requires the FC credit handshake fails; everything that bypasses it works**.

## Why the credit handshake doesn't complete

Three live hypotheses from the 2026-05-24 observation doc, none yet ruled out for build #3:

| Hyp | Where the CR packet stops | What would confirm |
|---|---|---|
| Alt-1 | Master sends CR, but slave's `sp2wl` byte-aligner doesn't decode it | Master TX counter shows CR sent; slave RX byte-counter shows nothing |
| Alt-2 | PHY reports 8/8 locked but recovered clock is wrong-phase for credit-class traffic specifically | Per-channel BER asymmetric: doorbells (sideband) clean, application channel corrupt |
| Alt-3 | Master's TX FCSM never **sends** CR | Master TX counter for CR=0 |

Note: build #3's calibrator fix specifically addressed eye selection. The "wrong-phase for application class" Alt-2 is now much less likely because the calibrator is correctly locking to per-lane eye centers. Alt-1 and Alt-3 are the more probable survivors.

## Crucial side findings from this run

### Autocal works from pure deploy (answer to Q4)

This was tested and confirmed in this session:

1. **Fresh deploy with no SW intervention**: cal_done=1 on both sides, lock=0x00 (because no training pattern yet)
2. **One APB write to set `SWI_TRAINING_MODE=1` on each side**: lock=0xff on both within 2 seconds
3. **bringup_pair_converge.sh's elaborate re-deploy loop is no longer needed** for build #3

This means deploy + training-mode = link up. It's a one-step bring-up now, not the historic retry sweep.

### Agent A's PTP_CTRL bit-2 hypothesis was wrong but informative

Agent A suggested `slave's PTP_CTRL bit 0 = 0 at POR is the bug`. On inspection that's true at POR, BUT `bringup_ptp_sync.sh` does write slave `PTP_CTRL=0x05` (bit 0 set) before running the convergence loop. So slave's `ptp_enable_r` IS 1 by the time the master fires HW_SYNC. The PTP RX rejection isn't at the `ptp_sp_rx_accept` gate — it's that nothing arrives to be accepted.

That said, Agent A's static-analysis finding stands as a regression watch: **`ptp_sp_rx_accept = ptp_sp_rx_valid & ptp_enable_r`** at [tidelink_ptp.sv:288](src/rtl/tidelink_ptp.sv#L288) means any future build that forgets to write slave PTP_CTRL bit 0 will silently lose all HW_SYNC packets. Worth a deploy-time init.

### Agent B's coverage gap is the path forward

Existing paired-die cocotb tests do NOT assert:
- AHB packet RX at slave (the file explicitly comments "we don't drive packets in this test")
- `PAIR_CREDIT_COUNTER != 0` post-bringup (this is exactly the regression gate the 2026-05-24 doc called for)
- Slave's `HW_SYNC_STATUS` register updates (the one paired PTP test verifies RX FIFO but not the APB-readable status)

So the sim **cannot currently catch this bug** — which is why it surfaced on silicon.

## Sim replication plan

Per Agent B's report, the closest existing test is [verif/cocotb/test_tidelink_pair_doorbell.py](verif/cocotb/test_tidelink_pair_doorbell.py) for the paired-die env. Extend it with three new tests:

```python
# Test 1 — regression gate for the actual bug
@cocotb.test()
async def test_paircredit_nonzero_after_bringup(dut):
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await ClockCycles(dut.clk, 2000)
    m_pcc = await pair.master_apb_read(0x2028)
    s_pcc = await pair.slave_apb_read(0x2028)
    assert m_pcc != 0, f"master PAIR_CREDIT_COUNTER stuck at {m_pcc:#x}"
    assert s_pcc != 0, f"slave  PAIR_CREDIT_COUNTER stuck at {s_pcc:#x}"
```

```python
# Test 2 — AHB packet M→S end-to-end
@cocotb.test()
async def test_ahb_packet_master_to_slave(dut):
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await pair.set_training_mode(both=False)         # data mode
    pkt = [2, 0xDEADBEEF, 0xCAFEBABE]
    await pair.master_ahb_tx_packet(pkt)
    await ClockCycles(dut.clk, 2000)
    n = await pair.slave_apb_read(0x008)             # REG_PKT_LEN
    assert n == 2, f"slave REG_PKT_LEN={n}, expected 2"
    rx = await pair.slave_ahb_fifo_read(2)
    assert rx == pkt[1:], f"slave FIFO contents {rx}"
```

```python
# Test 3 — PTP HW_SYNC reaches slave's status
@cocotb.test()
async def test_ptp_hw_sync_slave_status(dut):
    pair = await setup_wlink_pair(dut)
    await pair.bringup_links_and_calibrate()
    await pair.master_apb_write(0x2034, 0x0d)        # master PTP_CTRL
    await pair.slave_apb_write (0x2034, 0x05)        # slave  PTP_CTRL
    await pair.master_apb_write(0x2040, 0x05)        # HW_SYNC_CTRL enable+force_en
    await ClockCycles(dut.clk, 5000)
    s_status = await pair.slave_apb_read(0x2048)
    assert s_status != 0, f"slave HW_SYNC_STATUS stuck at 0"
```

Predicted outcome: all three FAIL in sim — they would reproduce the silicon symptom. With them as regression gates, the fix can be developed against the sim and re-validated on HW.

## Resolution path (no code changes yet — needs user authorization)

**Stage 1 — confirm sim reproduces (~1 day)**

- Add the three tests above to the paired-die cocotb env
- Run; expect at least the PAIR_CREDIT and AHB tests to FAIL

**Stage 2 — instrument FCSM (~½ day)**

- Add VCD probes for: `master.fc_tx_cr_valid`, `master.fc_tx_cr_data`, `slave.fc_rx_cr_valid`, `slave.fc_rx_cr_decoded`, `slave.fcsm_cr_received_q`
- Rerun PAIR_CREDIT test, observe which signal first fails to assert

**Stage 3 — fix and re-validate**

- Localize root cause in `tidelink_fc_adapter.sv` or in the `axi-chiplet-controller` Scala-generated Verilog
- Patch
- Sim regression
- HW redeploy
- Sandwich loop should show pass=N (not pass=1 + ahb_fail=5)

**Stage 4 — defensive init**

- Patch deploy_pair.sh / overlay.py to set TRAIN_MODE=1, PTP_CTRL bit 0=1, HW_SYNC_CTRL=1 at deploy time so user SW doesn't have to remember
- Documents the now-validated finding: build #3 is one-step deploy + 3 APB pokes, not iterative bringup

## Concrete action requested from user

If you authorize it, dispatch:
- **Agent C**: write and run the three new cocotb tests against current `feat/td-gpio-phy-integration` sim, report results
- **Agent D** (gated on Agent C result): if PAIR_CREDIT test FAILS in sim, instrument FCSM and root-cause the CR packet path

Alternatively, **release the lease** while we set up Stage 1-2 offline.
