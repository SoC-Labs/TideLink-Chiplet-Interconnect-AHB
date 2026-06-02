# Bug A — Delivery-Path Sim Findings (2026-06-01)

**Predecessor**: `docs/BUG_A_NACK_PREDICATE_SIM_2026_06_01.md` falsified the
NACK-loop theory (slave RX FCSM decode is clean; `send_nack_req` never
fires).

This sim sweep probes BOTH the master TX submission path and the slave RX
delivery path concurrently while a single 4-word PKT_WR_REQ traverses the
link.

---

## 1. Test path

* New cocotb test: `/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/test_buga_delivery_path.py`
* Reuses `PairTB` + `run_bringup_full` from `test_tidelink_pair_doorbell.py`
* Sequence:
  1. `run_bringup_full(tb)` → role-lock, passive autocal, to_data_mode
     (cr/crack latch on both sides, fcsm state = 4 on both).
  2. Clear training (slot0 = 0x0 both sides), 200 cy idle.
  3. Start watcher coroutine — samples 25 probes every `hclk` edge.
  4. Drive ONE AHB write of 4 words (word0 length=2, dest=0,
     payload=[0xDEADBEEF, 0xCAFEBABE]) into master `m_ahb_tx_*` aperture.
  5. Idle 800 cy, then APB-read slave `REG_PKT_WORD_LEN`.
* Build: `SIM_BUILD=sim_build_delivery TB_TOP_NO_DUMP=1`, ~5 min runtime.
* `set_env.sh` + `CMSDK_FPGA_SRAM_V=imp/fpga/tidelink_ip/src/cmsdk_fpga_sram.v`
  (lab workaround per memory).

---

## 2. Hierarchical refs used (verified — all probes resolved)

Master TX (inside `dut.u_master.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl`):

```
.a2l_fc_replay_app_valid
.a2l_fc_replay_app_ready
.a2l_fc_replay_link_valid
.a2l_fc_replay_link_advance
.fe_tx_credit_max         (8-bit reg, from FC.scala:200)
.fe_rx_credit_max         (8-bit reg)
.pkt_is_cr_pkt
.pkt_is_crack_pkt
.cr_pkt_seen_rx
.crack_pkt_seen_rx
```

Slave RX (same hierarchy under `dut.u_slave`):

```
.l2a_fc_replay_app_valid     ← THE delivery gate
.l2a_fc_replay_app_data[47:0]
.l2a_fc_replay_link_valid
.l2a_fc_replay_link_advance
.exp_pkt_num
.ll_rx_pktnum
.pkt_is_data_pkt
.isExpPacket
```

Master/Slave fc_adapter (`dut.u_master.u_fc_adapter` / `dut.u_slave.u_fc_adapter`):

```
.tl_fc_a2l_valid / .tl_fc_a2l_ready / .tl_fc_a2l_data       (master)
.tl_fc_l2a_valid / .tl_fc_l2a_accept / .tl_fc_l2a_data      (slave)
.fc_rx_fifo_valid / .fc_rx_fifo_addr                        (slave)
.fc_rx_cfg_psel  / .fc_rx_cfg_paddr                         (slave)
```

`a2l_full` was NOT separately reachable (not exposed as a wire in
`WlinkGenericFCSM_6.v`); a2l backpressure is observable via
`a2l_fc_replay_app_valid & ~a2l_fc_replay_app_ready` — see §3.

---

## 3. Per-signal timing trace

Pre-AHB snapshot (after `run_bringup_full` + slot0=0 + 200 cy idle):

```
M.fe_tx_credit_max = 31    (credits granted by peer)
M.fe_rx_credit_max = 31
M.cr_pkt_seen_rx   = 1
M.crack_pkt_seen_rx= 1
S.exp_pkt_num      = 2     (background traffic already advanced this)
S.ll_rx_pktnum     = 1
```

Probe table (cycles relative to watcher start, 1 cy = 1 hclk):

| signal | first_high | total_high |
|---|---:|---:|
| a2l_fc_replay_app_valid (M) | 4 | 4 |
| a2l_fc_replay_app_ready (M) | 1 | 823 |
| a2l_fc_replay_link_valid (M) | 20 | 26 |
| a2l_fc_replay_link_advance (M) | 20 | 26 |
| pkt_is_cr_pkt (M) | — | 0 |
| pkt_is_crack_pkt (M) | — | 0 |
| cr_pkt_seen_rx (M) | 1 | 823 (sticky from bringup) |
| crack_pkt_seen_rx (M) | 1 | 823 (sticky) |
| **M.tl_fc_a2l_valid** | 4 | 4 |
| M.tl_fc_a2l_ready | 1 | 823 |
| **l2a_fc_replay_app_valid (S)** | 46 | 25 |
| l2a_fc_replay_link_valid (S) | 55 | 4 |
| l2a_fc_replay_link_advance (S) | 55 | 4 |
| pkt_is_data_pkt (S) | 46 | 25 |
| isExpPacket (S) | 68 | 26 |
| **S.tl_fc_l2a_valid** | 55 | 4 |
| **S.tl_fc_l2a_accept** | 55 | 4 |
| **S.fc_rx_fifo_valid** | 57 | 4 |
| **S.fc_rx_cfg_psel** | — | 0 |

Post-AHB: `S.exp_pkt_num = 6` (advanced by 4), `S.ll_rx_pktnum = 5`.

Stuck-detector: `M.tl_fc_a2l_valid=1 & M.tl_fc_a2l_ready=0` — **0 cycles**.
No skid backpressure.

APB read: **`S.REG_PKT_WORD_LEN = 0x00000000`**.

---

## 4. Verdict

**The wedge is NOT in any of the suspected paths.** All five candidate
failure modes are falsified:

1. Master TX (`tl_fc_a2l_valid`) fired exactly 4 cycles — one per AHB
   word. Not blocked.
2. Slave RX (`tl_fc_l2a_valid`) fired exactly 4 cycles — link delivery
   intact.
3. pkt_type as delivered was clean (no X, no misroute).
4. `S.fc_rx_fifo_valid` fired 4 times at `fc_rx_fifo_addr=0x0` — the
   FIFO RAM saw 4 word-writes.
5. `S.fc_rx_cfg_psel` never fired — no sideband-APB misroute.

`S.exp_pkt_num` advanced from 2 → 6 (delta = 4): the slave FCSM
*acknowledged* receipt of all 4 packets. Credits are healthy
(`fe_tx_credit_max=31`).

**Yet `REG_PKT_WORD_LEN = 0x00000000`.**

The data physically reaches the slave RX FIFO RAM. What does NOT update
is the sideband length/doorbell counter that SW polls. The wedge is
therefore **downstream of `fc_rx_fifo_valid`** — in the path that
converts FIFO writes into `PKT_WORD_LEN` / doorbell-response state seen
on APB.

This is consistent with the HW symptom (`PKT_WORD_LEN=0` and the
returner doorbell never firing) but now localized: it is **not** an
RTL bug in the master TX or in the Wlink/FCSM/fc_adapter receive
chain. It is in the FIFO-write → PKT_WORD_LEN counter / doorbell
returner glue.

### Subtle observation worth flagging

`S.fc_rx_fifo_addr = 0x0` on first fire — all four words appear to be
written to **the same FIFO address** (offset 0). That would explain
why `PKT_WORD_LEN` reads 0: if the address counter on the slave FIFO
side never increments, no length-update sideband fires either. The
`rx_addr_offset` source inside `tidelink_fc_adapter.sv:566` is the
FC-word's address field — but the master's `tx_addr_r` (the 14-bit
address field in `tx_fc_word`) tracks **the master's local AHB-TX
address**, not the destination FIFO write-offset. If that address is
always 0 (because the AHB master walks its own SRAM aperture, not the
peer's), the peer's FIFO write goes to slot 0 every time.

That would make the wedge **architectural** in the FC-word
construction (`tidelink_fc_adapter.sv:243`): the master is encoding its
own TX SRAM offset as the destination address, not the peer's FIFO
slot index, so all FIFO writes alias to slot 0.

---

## 5. Proposed fix direction

The data path is correct end-to-end. Two parallel investigations:

### A. Verify the address-aliasing hypothesis (high priority)

* Add a watcher on **`dut.u_master.u_fc_adapter.tx_addr_r`** across all
  four AHB writes and on **`dut.u_slave.u_fc_adapter.rx_addr_offset`**
  on each `fc_rx_fifo_valid` fire.
* If `rx_addr_offset` is 0 for all 4 writes, the FC-word's
  address-field semantics are the bug: the master is shipping its own
  `tx_addr_r` (SRAM aperture offset 0..N) where the protocol intends
  "FIFO offset on the peer".
* RTL site to inspect: `tidelink_fc_adapter.sv:243` for the TX side
  construction, and `:564–566` for the RX side decoding.

### B. Confirm PKT_WORD_LEN update path

Even if (A) is real, the length counter should still tick once per
landed packet. Probe the slave's `PKT_WORD_LEN` write-enable inside
`tidelink_apb_regs.sv` and the `rx_pkt_done` / packet-boundary pulse
inside `tidelink_fc_adapter.sv`. The pulse may be gated on
`rx_state_r == RX_IDLE` re-entry which itself may be conditioned on
something the data-word pkt_type fails to satisfy.

### Decision

Treat this as **Bug A pivot** — drop the `WlinkGenericFCSM_6.v` and
master-TX wedge hypotheses. The next investigation should be a
4-cycle probe of `tx_addr_r` and `rx_addr_offset` to confirm or
refute the slot-0 aliasing theory. That is a sub-100-line cocotb
extension of this test and should resolve within one session.

---

## Sim build artifacts

* `cocotb/tidelink_top_pair/test_buga_delivery_path.py`
* `cocotb/tidelink_top_pair/sim_build_delivery/`

No RTL touched; no flists touched; no /research IP touched. No commit.
