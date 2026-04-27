# TideLink — Pynq-Z2 Paired GPIO-Bridge Target

Same Vivado design as `pynq-z2-single` plus an AXI GPIO at `0x4404_0000` whose bit 0 drives `role_strap_i`. The same bitstream programs **both** boards in a paired set; role is selected at runtime from the `FPGAHUB_LOCAL_ROLE` env var that fpgahub injects into the action subprocess (`die_a` → 0, `die_b` → 1).

The two boards are wired together by a flat ribbon cable plugged into both Raspberry Pi headers (J13 on each Pynq-Z2). The ribbon is the cross-strap: the bitstream's `pad_tx[*]` exits each board on the same RPi pin, and the cable physically swaps TX↔RX so Board-A's `pad_tx[n]` lands on Board-B's `pad_rx[n]` (and vice versa). See `ribbon_wiring.md` for the full wire chart.

## Address map

| Region | Offset | Size | Purpose |
|---|---|---|---|
| `ahb_sub` | `0x4000_0000` | 256 MB | Transparent chiplet window (XHB500 → AXI → Wlink) |
| `ahb_tx` | `0x4400_0000` | 64 KB | FC TX aperture (write packets to remote FIFO) |
| `ahb_fifo` | `0x4401_0000` | 64 KB | RX FIFO read port (receive packets from remote) |
| `ahb_ptp` | `0x4402_0000` | 4 KB | PTP TX write port |
| `apb` | `0x4403_0000` | 32 KB | Unified config (Wlink + TideLink + addr translator) |
| `strap` | `0x4404_0000` | 4 KB | AXI GPIO; bit 0 = `role_strap_i` (paired-only) |

## Build

```bash
cd ~/SoCLabs/tidelink
source set_env.sh
make -C fpga TARGET=pynq-z2-pair build_design
```

Output bitstream: `imp/fpga/output/pynq-z2-pair/tidelink.bit`. Same bitstream goes onto both boards.

## Bring-up sequence

Once `[pairs.tidelink_bridge_01]` is registered in `/etc/fpgahub/config.toml` (see `fpga/docs/fpgahub_pair_config.md` once Wave C2 lands):

```bash
# Acquire the pair lease + bind/attach both boards in bringup_order.
fpgahub pair up tidelink_bridge_01 --ttl 7200

# The fpgahub.toml ci_pair_full action programs each board, sets the
# strap from $FPGAHUB_LOCAL_ROLE, and runs the bridge stress catalogue.
fpgahub actions run tidelink_z2_a ci_pair_full
fpgahub actions run tidelink_z2_b ci_pair_full

# Or just stress an already-loaded pair:
fpgahub actions run tidelink_z2_a stress_pair

# Tear down — releases the pair lease atomically.
fpgahub pair down tidelink_bridge_01
```

## Strap register convention

```
0x4404_0000  GPIO_DATA register, bit 0:
  0 = die_a (slave)   — strap when FPGAHUB_LOCAL_ROLE == "die_a"
  1 = die_b (master)  — strap when FPGAHUB_LOCAL_ROLE == "die_b"
```

The Vivado AXI GPIO defaults to 0 at reset, so an unprogrammed strap = `die_a`. The PYNQ runtime overlay writes the bit during overlay load (see `pynq/overlay.py` once Wave C1 lands).

## Sanity checks after programming

After `fpgahub pair up` and the bitstream programs both boards, the LEDs report:

| LED | Signal | Expected on healthy paired link |
|---|---|---|
| LD0 | `link_active` | Solid on (D2D link is up) |
| LD1 | `role_is_master_o` | One board solid on, the other off — confirms strap works |
| LD2 | `wlink_irq` | Brief blinks during link-up handshake |
| LD3 | `released_credits_irq` | Blinks when credits are released to peer |

If LD0 is off after a few seconds: ribbon may be wired wrong, or `user_ref_clk` not present. If LD1 is the same on both boards: strap GPIO write didn't land.

## PHC tie-off

PHC inputs are zeroed for first bring-up (Q4 in the plan). PTP tests are gated until `ptp-hardware-clock-ahb` is wired in.

## Pin map

The bitstream's GPIO PHY pads are mapped to the same 18 RPi GPIOs on both boards. See `pynq_z2_tidelink_pair.xdc` for the FPGA-pin → RPi-pin table, and `ribbon_wiring.md` for how the ribbon cable swaps them between boards.
