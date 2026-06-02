# Bug A — Address-Aliasing + PKT_WORD_LEN Probe (2026-06-01)

Successor to `docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md` (slot-0
aliasing hypothesis). This run instruments the master TX `tx_addr_r` /
`tx_fc_word`, the slave RX `fc_rx_fifo_*`, AND the
`tidelink_fifo_ctrl` internal length-capture path concurrently. It
runs the same stimulus twice — once with the existing PairTB BFM
(reproduces the "PKT_WORD_LEN=0" sim result) and once with a fixed BFM
that drives `hwdata` synchronously with the address phase so cocotb 2.x
deferred-write scheduling does not clobber the data phase.

---

## 1. Test path

* `/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/test_buga_addr_aliasing.py`
* `SIM_BUILD=sim_build_addr_alias`, `TB_TOP_NO_DUMP=1`, ~5 min/run.
* Read-only on RTL.

## 2. Stimulus

One 4-word PKT_WR_REQ via the fixed BFM:

| AHB byte addr | hwdata     | meaning                  |
|--------------:|:-----------|:-------------------------|
| 0x00          | 0x00240000 | word0 (length=2, type=0) |
| 0x04          | 0x00000000 | dest addr                |
| 0x08          | 0xdeadbeef | payload[0]               |
| 0x0c          | 0xcafebabe | payload[1]               |

## 3. Per-stage trace (fixed BFM)

### Master TX (FC-adapter side)

| cy | tx_addr_r | ahb_tx_hwdata | tx_fc_word     |
|---:|:----------|:--------------|:---------------|
|  3 | 0x000     | 0x00240000    | 0x000000240000 |
|  9 | 0x004     | 0x00000000    | 0x000400000000 |
| 15 | 0x008     | 0xdeadbeef    | 0x0008deadbeef |
| 21 | 0x00c     | 0xcafebabe    | 0x000ccafebabe |

### Slave fc_rx_fifo (writes into fifo_mem RAM)

| cy | fc_rx_fifo_addr | fc_rx_fifo_wdata |
|---:|:----------------|:-----------------|
| 57 | 0x0000          | 0x00240000       |
| 64 | 0x0004          | 0x00000000       |
| 70 | 0x0008          | 0xdeadbeef       |
| 76 | 0x000c          | 0xcafebabe       |

### Slave fifo_ctrl internal state

| cy | event                                        |
|---:|:---------------------------------------------|
| 57 | `fc_write_addr0` pulses (word0 length capture)|
| 58 | `packet_word_length_r`: 0 → **2** ✅           |
| 58 | `packet_active_r`: 0 → 1                     |
| 76 | `write_complete & fc_write_complete` (4th write hits target = (2+1)<<2 = 12) |
| 77 | `packet_word_length_r`: **2 → 0** ← THE RESET |
| 77 | `packet_active_r`: 1 → 0                     |
| 77 | `packet_committed_irq_r`: 0 → 1              |

After the 800-cy idle window, the APB read of `REG_PKT_WORD_LEN`
returns 0 — because the register self-cleared at cy=77.

## 4. Verdict

**Slot-0 aliasing: REFUTED.** Address transit `0 → 4 → 8 → c` is
preserved end-to-end (`tx_addr_r → tx_fc_word[45:32] →
tl_fc_l2a_data[45:32] → rx_addr_offset → fc_rx_fifo_addr`).

**Different bug found — TWO independent issues exposed:**

### Bug X1 (test infrastructure) — `PairTB._ahb_tx_write_word` is broken under cocotb 2.x

Setting `hwdata.value = data` *after* the address-phase `await
RisingEdge` in cocotb 2.x causes the deferred write to skip the
following data-phase rising edge. The RTL therefore samples
`ahb_tx_hwdata = 0` when it constructs `tx_fc_word = {PKT_FIFO_DATA,
tx_addr_r, ahb_tx_hwdata}` at `tidelink_fc_adapter.sv:243`. **This
zeroes every TX payload in sim.** Prior PKT_WR_REQ tests using this
BFM have been silently exercising "all-zero payloads", which renders
the docs/BUG_A_DELIVERY_PATH `S.fc_rx_fifo_addr = 0x0` observation
(addr=0 happened to be the first FIFO write, then writes 3-4 dropped)
benign — not the silicon failure mode.

Fix: pre-arm `hwdata.value` **before** the address-phase
`await RisingEdge` (held into the data phase, per AHB-Lite protocol).
The fixed BFM is inlined as `_ahb_tx_write_word_fixed` in
`test_buga_addr_aliasing.py` and the corrected run produces the trace
in §3 above.

### Bug X2 (RTL-design semantics) — `REG_PKT_WORD_LEN` self-clears on packet commit

Even with the fixed BFM giving us the correct data path, the APB read
of `REG_PKT_WORD_LEN` returns **0**.

`tidelink_apb_regs.sv:466`:
```systemverilog
3'h2: prdata = {{(SYS_DATA_W-RAM_ADDR_W){1'b0}}, packet_word_length};
```
Reads `packet_word_length` directly. That signal mirrors
`packet_word_length_r` in `tidelink_fifo_ctrl.sv`, which is an
**in-flight** counter used to compute `write_target_addr_r`. It is
*reset to 0* in the same cycle `write_complete` fires
(`tidelink_fifo_ctrl.sv:186-189`):

```systemverilog
if (write_complete || read_complete) begin
    packet_word_length_nxt = '0;
    packet_active_nxt = 1'b0;
    check_addr_nxt = 1'b0;
end else if (fc_write_addr0) begin
    packet_word_length_nxt = clamp_length(fc_wr_wdata);
    packet_active_nxt = 1'b1;
end
```

So after a packet commits, `REG_PKT_WORD_LEN` reads 0 even though the
RAM holds a complete packet with `length=2` baked into word0. The
`packet_committed_irq_r` flag IS set, so the doorbell-response path
*can* react to the committed packet — but SW polling
`REG_PKT_WORD_LEN` for "did a packet arrive?" will always see 0 on a
healthy link.

## 5. Implication for the silicon symptom

The HW observation that `REG_PKT_LEN` reads 0 is **expected RTL
behaviour** once a packet has fully committed. The actual silicon
question becomes whether `packet_committed_irq` and the rest of the
returner path advance correctly.

Three possibilities for HW Bug A:

1. **Most likely**: the silicon DID commit the packet but SW only
   polled `REG_PKT_WORD_LEN` to detect arrival. SW should instead poll
   `REG_STATUS bit[4]` (packet_committed) per `tidelink_apb_regs.sv:470`
   — that bit is sticky-set and cleared by reading FIFO addr 0.
2. The silicon never reaches `write_complete` because the actual hwdata
   on the link's `tl_fc_l2a_data[31:0]` is corrupted (signal-integrity
   on the GPIO lanes / IDELAY phase). Falsifiable by an ILA capture of
   `u_slave.u_fc_adapter.fc_rx_fifo_wdata`.
3. The silicon's PYNQ-driven AHB write delivers `hwdata=0` due to an
   axi_ahblite_bridge / SmartConnect data-phase issue (low probability,
   would also break AHB writes to other slaves).

## 6. Where PKT_WORD_LEN write-enable lives (per the task spec)

* Write-enable trigger: `fc_write_addr0` (`tidelink_fifo_ctrl.sv:157`)
  ≡ `fc_wr_valid && fc_wr_write && (fc_wr_addr == '0)`.
* Latch: `packet_word_length_nxt = clamp_length(fc_wr_wdata)` at
  `tidelink_fifo_ctrl.sv:194`.
* `fc_wr_wdata` itself enters fifo_ctrl as
  `{2'b0, fc_rx_fifo_wdata[31:20]}` (`tidelink_fifo_mem.sv:156`).

The path fires correctly once per packet (cy=57 in §3). It does NOT
fire per `fc_rx_fifo_valid` — only on the addr=0 word — which is the
documented protocol.

## 7. Proposed next step (one-line decision)

Update SW polling to use `REG_STATUS bit[4]` (`packet_committed`) rather
than `REG_PKT_WORD_LEN` as the arrival flag, AND deploy an HW ILA on
`u_slave.u_fc_adapter.fc_rx_fifo_wdata` to confirm payload integrity
on silicon. Once both are in place, the silicon Bug A is closed if the
ILA shows the correct wdata sequence.

## Artifacts

* `cocotb/tidelink_top_pair/test_buga_addr_aliasing.py` (includes both
  reproduction with original BFM and `_ahb_tx_write_word_fixed`)
* `cocotb/tidelink_top_pair/sim_build_addr_alias/`

No RTL touched; no flists touched; no IP library touched. No commits.
