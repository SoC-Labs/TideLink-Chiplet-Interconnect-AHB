# TideLink — Pynq-Z2 Paired GPIO-Bridge Target (Target A — mmcmbypass variant)

**Target A** variant of `pynq-z2-pair-all` that cuts the slave-side
capacitive load on `pad_clk_rx` by replacing the 8 per-lane BUFGs inside
`WavD2DGpio` with **a single IBUFG + BUFG at the BD level**. See
[docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md](../../../docs/TARGET_A_MMCM_BYPASS_DRAFT_2026_05_28.md)
for the full diagnosis (~48 pF -> ~8 pF on the slave's `pad_clk_rx` pad).

Pairs with the RTL parameter split landing on branch `feat/target-a-rtl`
(`USE_CLKBUF` -> `USE_CAP_CLKBUF` + `USE_LNK_CLKBUF`). This BD sets:

- `USE_CAP_CLKBUF = 1'b0` -- no per-lane BUFG on `io_pad_clk` (BD already
  drives a global clock net via `tidelink_clk_rx_buf`).
- `USE_LNK_CLKBUF = 1'b1` -- keep per-lane BUFG on the derived word clock.

`USE_IDELAY = 1'b1` and `USE_T3A = 1'b1` retain their IP defaults; this
change is independent of those features.

**XDC pin assignments are unchanged** from `pynq-z2-pair-all` -- Y9 for
`pad_clk_rx`, etc. The 200 ohm external series resistor on each RPi GPIO
is on-board and can't be removed; this variant only reduces internal load.

Otherwise identical to `pynq-z2-pair-all` -- same address map, same paired
fpgahub flow, same AXI GPIO at `0x4404_0000` whose bit 0 drives
`role_strap_i`. The same bitstream programs **both** boards in a paired
set; role is selected at runtime from the `FPGAHUB_LOCAL_ROLE` env var that
fpgahub injects into the action subprocess (`die_a` → 0, `die_b` → 1).

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
# Target A mmcmbypass variant — pairs with the FLIP variant for the cross
# cable. Build the master (this target) on z2-a and the FLIP variant on z2-b.
FPGA_USE_IDELAY=1 make -C fpga TARGET=pynq-z2-pair-mmcmbypass-all build_design
```

Output bitstream: `imp/fpga/output/pynq-z2-pair-mmcmbypass-all/tidelink.bit`.
The FLIP variant (mirror RPi pinout) lives in
`fpga/targets/pynq-z2-pair-mmcmbypass-flip-all/`.

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

## Bring-up sequence (verified 2026-04-27)

Programming the bitstream is **not enough on its own** — Wlink stays in reset until the role is locked via APB. The minimum sequence is:

1. `fpgahub pair lease acquire bridge1 --user $(whoami) --ttl 3600`
2. SCP `tidelink.bin` + `tidelink.hwh` to each board, copy to `/lib/firmware/`, `echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware`
3. Write the strap GPIO at `0x4404_0000`: 0 → die_a/master, 1 → die_b/slave (note: chiplet-controller inverts, so strap=0 → master)
4. **Lock the role**: write `0x2` (master, lock=1) or `0x3` (slave, lock=1) to `0x4403_2080`. This releases Wlink from reset (`wlink_por_reset = ~poresetn | ~role_locked`).
5. After ~1 s, LD0 should be solid on both boards.

`pynq/scripts/deploy_pair.sh` does the whole sequence; `pynq/scripts/wlink_probe.sh` dumps current state.

## ⚠ AHB_TX hang hazard

**Do not write to `0x4400_0000` (AHB_TX) until the link is verified UP.**

If Wlink's TX FC node is wedged (RX deserializer not synced with the peer, ribbon wrong, `pad_clk_rx` clocking unreliable, etc.), the FC adapter never asserts HREADY. The AXI-Lite-to-AHB bridge stalls, SmartConnect blocks, and the PS's `mmap` write hangs in kernel space — taking down SSH and requiring a physical power-cycle (UART reboot may not recover).

Bench evidence (2026-04-27): an AHB_TX write on z2_02 with link unsynced took the board offline; UART reboot did not bring it back within 4 minutes.

The PYNQ overlay's `TidelinkOverlay.assert_link_safe_for_tx()` and the stress runner's `write_packet()` both gate on a Wlink-activity probe before issuing AHB_TX writes — use those rather than rolling your own write loop.

## PHC tie-off

PHC inputs are zeroed for first bring-up (Q4 in the plan). PTP tests are gated until `ptp-hardware-clock-ahb` is wired in.

## Pin map

The bitstream's GPIO PHY pads are mapped to the same 18 RPi GPIOs on both boards. See `pynq_z2_tidelink_pair.xdc` for the FPGA-pin → RPi-pin table, and `ribbon_wiring.md` for how the ribbon cable swaps them between boards.
