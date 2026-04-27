# TideLink Pynq-Z2 Single-Instance Target (Wave B1)

This target produces a Vivado block design for a single TideLink chiplet bridge
node running on a Digilent PYNQ-Z2 board (Zynq XC7Z020CLG400-1). The Zynq PS
acts as the software controller via PYNQ MMIO, and the TideLink GPIO PHY pads
are brought out to the Raspberry Pi GPIO header for direct inter-board wiring.
`role_strap_i` is hardcoded to `0` (slave mode) for this target.

## Build command

```bash
make -C fpga TARGET=pynq-z2-single build_design
```

Output: `imp/fpga/output/pynq-z2-single/tidelink.bit` and `tidelink.hwh`.

## Address map (PS7 M_AXI_GP0)

| Base address  | Size   | Interface   | Description                               |
|---------------|--------|-------------|-------------------------------------------|
| `0x4000_0000` | 256 MB | `ahb_sub`   | AHB slave — transparent chiplet data window |
| `0x4400_0000` | 64 KB  | `ahb_tx`    | AHB slave — TX aperture (RAM_ADDR_W = 14) |
| `0x4401_0000` | 64 KB  | `ahb_fifo`  | AHB slave — RX FIFO read window           |
| `0x4402_0000` | 4 KB   | `ahb_ptp`   | AHB slave — PTP TX write port (4-bit decode) |
| `0x4403_0000` | 32 KB  | `apb`       | APB slave — unified config registers (15-bit PADDR) |

## PHY pin map (Raspberry Pi GPIO header, J13)

TX side (driven by TideLink, wired to paired board's RX side):

| Signal      | FPGA pin | RPi header pin | BCM GPIO |
|-------------|----------|----------------|----------|
| `pad_clk_tx` | W18     | 4              | GPIO2    |
| `pad_tx[0]`  | W19     | 6              | GPIO3    |
| `pad_tx[1]`  | W14     | 8              | GPIO4    |
| `pad_tx[2]`  | V17     | 10             | GPIO14   |
| `pad_tx[3]`  | V18     | 12             | GPIO15   |
| `pad_tx[4]`  | W10     | 16             | GPIO23   |
| `pad_tx[5]`  | V9      | 18             | GPIO24   |
| `pad_tx[6]`  | V13     | 22             | GPIO25   |
| `pad_tx[7]`  | T16     | 24             | GPIO8    |

RX side (received by TideLink, wired from paired board's TX side):

| Signal       | FPGA pin | RPi header pin | BCM GPIO |
|--------------|----------|----------------|----------|
| `pad_clk_rx` | R16      | 26             | GPIO7    |
| `pad_rx[0]`  | U17      | 36             | GPIO16   |
| `pad_rx[1]`  | T17      | 38             | GPIO20   |
| `pad_rx[2]`  | R17      | 40             | GPIO21   |
| `pad_rx[3]`  | P18      | 32             | GPIO12   |
| `pad_rx[4]`  | N17      | 33             | GPIO13   |
| `pad_rx[5]`  | V16      | 35             | GPIO19   |
| `pad_rx[6]`  | U16      | 37             | GPIO26   |
| `pad_rx[7]`  | T12      | 31             | GPIO6    |

Source: Digilent PYNQ-Z2 v1.0 Reference Manual, Table 6.10.
Verify before first board bring-up against the master XDC at
https://reference.digilentinc.com/_media/reference/programmable-logic/pynq-z2/pynq-z2_v1.0.xdc

To wire a loopback pair: connect TX pin N on board A to RX pin N on board B,
and vice versa, plus a common GND.

## LED assignments

| LED  | FPGA pin | Signal                 | Description               |
|------|----------|------------------------|---------------------------|
| LD0  | R14      | `link_active`          | Lit when D2D link is up   |
| LD1  | P14      | `role_is_master_o`     | Lit when node is master   |
| LD2  | N16      | `wlink_irq`            | Strobes on Wlink events   |
| LD3  | M14      | `released_credits_irq` | Strobes on credit release |

## PHC tie-off note (Q4)

The PTP Hardware Clock (PHC) interface is tied off for first bring-up:
`phc_nanoseconds`, `phc_seconds`, `phc_hw_cap_*` are driven to zero;
`phc_pps` and `phc_locked_i` are held low. The `phc_clk` is the same
50 MHz clock as `hclk` (phase-aligned second output from the same MMCM —
no CDC issue). A proper PHC IP integration is planned for Q4 once
`ptp-hardware-clock-ahb` is brought into the TideLink BD.

## Role strap note

`role_strap_i` is hardcoded to `1'b0` (slave) in `tidelink_design_wrapper.v`
for this single-instance target. The node will always enter slave mode after
auto-negotiation. To run as master, use a different bitstream or use the
paired target (`pynq-z2-pair`) which exposes the role strap via AXI GPIO.

## IRQ routing

Six TideLink interrupts are concatenated (via `xlconcat`) and wired to
`IRQ_F2P[5:0]` of the Zynq PS7:

| `IRQ_F2P` bit | Signal                  |
|--------------|-------------------------|
| `[0]`        | `released_credits_irq`  |
| `[1]`        | `doorbell_irq`          |
| `[2]`        | `packet_committed_irq`  |
| `[3]`        | `ptp_irq`               |
| `[4]`        | `perf_irq`              |
| `[5]`        | `wlink_irq`             |
