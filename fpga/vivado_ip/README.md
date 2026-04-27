# TideLink Vivado IP

## Role

`tidelink_vivado_wrapper.v` is the IP Integrator-friendly facade over `tidelink_top`. It adds Xilinx `X_INTERFACE_INFO` / `X_INTERFACE_PARAMETER` attributes so Vivado can auto-infer AHB, APB, AXI-Stream, clock, reset and interrupt bus interfaces without manual editing in the IP customiser.

## HSEL / HREADY Pattern

Xilinx's `axi_ahblite_bridge:3.0` master omits `HSEL` and `HREADY_IN` from its bus-interface outputs — it assumes a single-slave bus where the slave is always selected and where the slave's own `HREADYOUT` is the only `HREADY` on the wire. Exposing those pins via `X_INTERFACE_INFO` causes Vivado to leave them unconnected (tied 0), so the slave is never selected and every transfer hangs.

Fix applied to all four AHB slaves (`ahb_sub`, `ahb_tx`, `ahb_fifo`, `ahb_ptp`):
- `HSEL` is hardwired to `1'b1` inside the wrapper.
- `HREADYOUT` is looped back to `HREADY_IN` inside the wrapper.
- Only `HREADYOUT` is exported to IPI, using sub-signal name `HREADY`.

## IRQ Annotations

Each IRQ output carries `X_INTERFACE_INFO ... INTERRUPT INTERRUPT` and `SENSITIVITY LEVEL_HIGH`. In a block design, run each pin into a `util_vector_logic` Concat block, then feed the concatenated vector to `axi_intc` or the PS `IRQ_F2P` port.

The nine IRQ pins are: `released_credits_irq`, `doorbell_irq`, `packet_committed_irq`, `ptp_irq`, `perf_irq`, `wlink_irq`, `nego_error_irq`, `i2c_nbsy_irq`, `i2c_nrd_empty_irq`.

## Memory Map Sizes

| Interface | Range    | Derivation |
|-----------|----------|------------|
| `ahb_sub` | 4 GB     | Full 32-bit addr space; internal translator scopes to remote |
| `ahb_tx`  | 16 KB    | `RAM_ADDR_W=14` default: 2^14 byte-addressed FIFO aperture |
| `ahb_fifo`| 16 KB    | Same SRAM depth as TX side |
| `ahb_ptp` | 16 B     | 4-bit address port: 2^4 bytes |
| `apb`     | 24 KB    | Three 8 KB sub-regions (0x0000 Wlink, 0x2000 TideLink+PTP, 0x4000 addr-translator) |

## Packaging

```
make -C fpga package_ip
```

This invokes `vivado -mode batch -source fpga/vivado_ip/package_tidelink_ip.tcl` with the required env vars set by `fpga/Makefile`.
