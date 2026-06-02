# Bug A — Address-Collapse Sim Findings (2026-06-01)

**Predecessor**: `docs/BUG_A_DELIVERY_PATH_SIM_2026_06_01.md` confirmed the
master TX fires 4× FIFO_DATA, slave RX delivers 4× FIFO_DATA, slave
`fc_rx_fifo_valid` fires 4×, but `REG_PKT_WORD_LEN=0` after the burst.

**Hypothesis**: all 4 writes encode `addr_offset=0` →
`packet_word_length` never increments and slot 0 keeps getting
overwritten.

**Verdict**: **HYPOTHESIS REFUTED**. Addresses transit cleanly end-to-end;
the bug is in the **payload** field, not the address field.

---

## 1. Test path

* `/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/test_buga_addr_collapse.py`
* Reuses `PairTB` + `run_bringup_full`. Read-only RTL probes only.
* Build: `SIM_BUILD=sim_build_addr_collapse TB_TOP_NO_DUMP=1`, ~4 min.

AHB sequence driven into master `m_ahb_tx_*` (4 writes, word stride):

| offset | wdata             |
| ------ | ----------------- |
| 0x00   | 0x00240000 (word0) |
| 0x04   | 0x00000000 (dest)  |
| 0x08   | 0xDEADBEEF         |
| 0x0c   | 0xCAFEBABE         |

---

## 2. Per-cycle trace (cycles relative to test start, sim_time t=8509840 ns)

### Master TX — address-phase pulses

```
cycle   ahb_tx_haddr   ahb_tx_hwdata (sampled at addr phase — pre-data)
   2    0x00000000     0x00000000
   8    0x00000004     0x00000000
  14    0x00000008     0x00000000
  20    0x0000000c     0x00000000
```

### Master TX — `tl_fc_a2l_valid & tl_fc_a2l_ready` fires

```
cycle   pkt_type      addr_offset[45:32]   payload[31:0]   full 48-bit word
   4    0=FIFO_DATA   0x0000               0x00000000      0x000000000000
  10    0=FIFO_DATA   0x0004               0x00000000      0x000400000000
  16    0=FIFO_DATA   0x0008               0x00000000      0x000800000000
  22    0=FIFO_DATA   0x000c               0x00000000      0x000c00000000
```

### Slave RX — `tl_fc_l2a_valid & tl_fc_l2a_accept` fires

```
cycle   pkt_type      addr_offset[45:32]   payload[31:0]   full 48-bit word
  55    0=FIFO_DATA   0x0000               0x00000000      0x000000000000
  62    0=FIFO_DATA   0x0004               0x00000000      0x000400000000
  68    0=FIFO_DATA   0x0008               0x00000000      0x000800000000
  74    0=FIFO_DATA   0x000c               0x00000000      0x000c00000000
```

### Slave RX — `fc_rx_fifo_valid` pulses (final FIFO write)

```
cycle   fc_rx_fifo_addr   fc_rx_fifo_wdata
  57    0x0000            0x00000000
  64    0x0004            0x00000000
  70    0x0008            0x00000000
  76    0x000c            0x00000000
```

`S.REG_PKT_WORD_LEN = 0x00000000` (post burst, via APB read).

---

## 3. Address-list summary (FIFO_DATA only)

| stage              | addrs             |
| ------------------ | ----------------- |
| master AHB haddr   | [0x0, 0x4, 0x8, 0xc] |
| master `tl_fc_a2l` | [0x0, 0x4, 0x8, 0xc] |
| slave `tl_fc_l2a`  | [0x0, 0x4, 0x8, 0xc] |
| slave `fc_rx_fifo` | [0x0, 0x4, 0x8, 0xc] |

**Address propagation is byte-perfect across all 4 transit boundaries.**

---

## 4. Definitive verdict

`ADDR_TRANSITS_INTACT__bug_is_downstream_of_fc_rx_fifo_addr`

But the real finding is sharper: **the data payload is zero on the
master FC word for every write, including for `0xDEADBEEF` and
`0xCAFEBABE`**. The address field travels but the data field does not.

So:

* "addr stuck at 0" hypothesis: **REFUTED**.
* **New** primitive: **master TX payload always reads 0 on `tx_fc_word`**.

`tx_fc_word = {PKT_FIFO_DATA, tx_addr_r, ahb_tx_hwdata}`
(`src/rtl/tidelink_fc_adapter.sv:243`).

`tx_addr_r` is **registered** from `ahb_tx_haddr` at addr phase
(`tidelink_fc_adapter.sv:204`); `ahb_tx_hwdata` is **combinational**.
The skid loads `tx_fc_word` on the rising edge where
`tx_data_phase_r=1 && skid_can_accept`. With the testbench
`_ahb_tx_write_word` in `test_tidelink_pair_doorbell.py:232–271`, the
driver:

1. Sets `haddr, hsel, htrans, hwrite, hsize` and waits one rising edge
   (cycle K → K+1) — addr phase.
2. Clears hsel/htrans/hwrite and sets `hwdata = data`, waits for hready
   (cycle K+1 → K+2) — data phase.
3. Immediately sets `hwdata = 0` after the loop breaks.

`tx_data_phase_r` is registered HIGH at edge K+1. At edge K+2 the
arbiter loads `tx_fc_word`, which combinationally takes the *current*
`ahb_tx_hwdata`. If `hready` was high through K+1→K+2 the loop exits in
zero extra cycles and `hwdata = 0` is driven BEFORE the next sample
cycle — but the skid already latched on edge K+2 using the data-phase
hwdata. **Yet our trace shows it latches 0.**

The fc_adapter skid loads at the **same** edge K+2 that `tx_data_phase_r`
transitions to 1. But `arb_valid` depends on `tx_fc_valid =
tx_data_phase_r` — combinational off the register, so `arb_valid` is 1
*at* edge K+2 only if `tx_data_phase_r` is already 1, which it isn't
until that edge. So the load actually happens at edge K+3, by which
point the testbench has already cleared `hwdata` to 0 (line
`test_tidelink_pair_doorbell.py:271`).

That is a **testbench timing bug**, not RTL — but it has been masking
the real Bug A loop for hours, because every payload arrives as 0 and
the FIFO controller therefore latches `packet_word_length = 0`
(clamp_length(0) at `tidelink_fifo_ctrl.sv:199`).

---

## 5. Proposed fix

**Two parallel fixes** — both small, both required for the next probe
pass to be meaningful.

### Fix A (testbench timing — IMMEDIATE)

Hold `hwdata` until after the **next** rising edge past hready=1, not
clear it on the same cycle. Patch
`cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:259-271`:

```python
        # Data phase
        hsel.value   = 0
        htrans.value = 0
        hwrite.value = 0
        hwdata.value = data & 0xFFFFFFFF
        for _ in range(50):
            try:
                if int(hready.value):
                    break
            except ValueError:
                pass
            await RisingEdge(dut.hclk)
        await RisingEdge(dut.hclk)   # NEW — let skid latch hwdata
        hwdata.value = 0
```

### Fix B (RTL — register hwdata into the skid path)

Mirror `tx_addr_r`: also register `ahb_tx_hwdata` at the same address
phase so `tx_fc_word` doesn't rely on the AHB master holding hwdata
through the data phase past the skid load:

```systemverilog
// tidelink_fc_adapter.sv — alongside tx_addr_r
logic [SYS_DATA_W-1:0] tx_data_r;
always_ff @(posedge hclk or negedge hresetn) begin
    if (!hresetn)        tx_data_r <= '0;
    else if (tx_data_phase_r && skid_can_accept && !sideband_grant)
                         tx_data_r <= ahb_tx_hwdata;
end
// Replace line 243:
wire [FC_DATA_W-1:0] tx_fc_word = {PKT_FIFO_DATA, tx_addr_r, tx_data_r};
```

Fix B is the more **defensive** fix — AHB-Lite spec only requires hwdata
to be valid during the data phase (one cycle after addr phase when
hready was high), and a downstream skid that wants the data on a later
cycle MUST register it. The current code accidentally works on FPGA only
because the PS AXI master holds hwdata for multiple cycles.

**Recommendation**: apply Fix A first to unblock probing, then Fix B in
RTL once the next probe pass confirms the bug shape.

---

## 6. Constraints honoured

* READ-ONLY against RTL. No commits.
* SIM_BUILD=sim_build_addr_collapse, TB_TOP_NO_DUMP=1.
* Runtime ~4 min, under 15-min cap.
* No touches to `/research/AAA/ip_library/**`.
