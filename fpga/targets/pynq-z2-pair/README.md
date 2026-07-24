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

## Bring-up sequence (verified 2026-04-27)

Programming the bitstream is **not enough on its own** — Wlink stays in reset until the role is locked via APB. The minimum sequence is:

1. `fpgahub pair lease acquire bridge1 --user $(whoami) --ttl 3600`
2. SCP `tidelink.bin` + `tidelink.hwh` to each board, copy to `/lib/firmware/`, `echo tidelink.bin > /sys/class/fpga_manager/fpga0/firmware`
3. Write the strap GPIO at `0x4404_0000`: 0 → die_a/master, 1 → die_b/slave (note: chiplet-controller inverts, so strap=0 → master)
4. **Lock the role**: write `0x2` (master, lock=1) or `0x3` (slave, lock=1) to `0x4403_2080`. This releases Wlink from reset (`wlink_por_reset = ~poresetn | ~role_locked`).
5. After ~1 s, LD0 should be solid on both boards.

`pynq/scripts/deploy_pair.sh` does the whole sequence; `pynq/scripts/wlink_probe.sh` dumps current state.

## Damaged ribbon recovery (lane mask)

The 8-lane GPIO PHY can operate at reduced width if a ribbon pin is broken or marginal. Each lane k can be individually disabled via the Wlink `link_lane_mask` register at offset `0x214` (absolute APB address `0x4403_0214`). When a lane is masked off the LinkLayer skips it during striping, the GPIO PHY drives the corresponding TX pad to 0, and the RX side ignores any garbage that pin produces.

**Both boards must be programmed with identical masks** before the link is enabled — there is no auto-detection ([SHORTCOMINGS.md #14a](../../../docs/reference/SHORTCOMINGS.md)). The cleanest way to update the mask is from PYNQ on each board:

```python
from overlay import TidelinkOverlay
ol = TidelinkOverlay()
ol.set_lane_mask(0xFB)            # drop physical lane 2 in both directions
tx, rx = ol.get_lane_mask()       # confirm
print(ol.get_active_lanes())      # (7, 7)  — popcount(0xFB) per direction
ol.assert_link_safe_for_tx()      # rejects mask=0
```

Recommended sequence when a specific ribbon pin starts misbehaving:
1. Identify the suspect lane index from the `pad_tx[k]` / `pad_rx[k]` mapping in `pynq_z2_tidelink_pair.xdc`.
2. On **both boards**, disable Wlink LL: APB write `0x0` to `0x4403_0208` (clears `lltx_enable` and `llrx_enable`).
3. On **both boards**, write `tx_lane_mask = rx_lane_mask = ~(1 << k) & 0xFF` to `0x4403_0214`.
4. On **both boards**, re-enable LL: APB write the original value back to `0x4403_0208` (default `0x027F0107`).
5. Confirm `link_health()` reports `wlink_activity_seen=True` and `tx_active_lanes / rx_active_lanes` both equal `popcount(mask)`.
6. Send a probe packet via `local_hw.write_packet(...)` to verify round-trip.

The `lane_mask_burnt_lane` test in `pynq/stress/bridge_tests.py` walks every lane k in 0..7, programs the mask on both ends, and verifies traffic still survives — useful as a regression after a ribbon swap.

If you've already lost a known ribbon pin, you can also re-pin physically: swap the ribbon mapping in the XDC so the dead pad lands on the highest logical lane index, then drop the mask down to a contiguous range. The `pynq-z2-pair-flip` target is an existing example of remapping the ribbon for orientation; the same pattern works for moving a dead pin out of the active set.

## ⚠ AHB_TX hang hazard

**Do not write to `0x4400_0000` (AHB_TX) until the link is verified UP.**

If Wlink's TX FC node is wedged (RX deserializer not synced with the peer, ribbon wrong, `pad_clk_rx` clocking unreliable, etc.), the FC adapter never asserts HREADY. The AXI-Lite-to-AHB bridge stalls, SmartConnect blocks, and the PS's `mmap` write hangs in kernel space — taking down SSH and requiring a physical power-cycle (UART reboot may not recover).

Bench evidence (2026-04-27): an AHB_TX write on z2_02 with link unsynced took the board offline; UART reboot did not bring it back within 4 minutes.

The PYNQ overlay's `TidelinkOverlay.assert_link_safe_for_tx()` and the stress runner's `write_packet()` both gate on a Wlink-activity probe before issuing AHB_TX writes — use those rather than rolling your own write loop.

## PHC tie-off

PHC inputs are zeroed for first bring-up (Q4 in the plan). PTP tests are gated until `ptp-hardware-clock-ahb` is wired in.

## Pin map

The bitstream's GPIO PHY pads are mapped to the same 18 RPi GPIOs on both boards. See `pynq_z2_tidelink_pair.xdc` for the FPGA-pin → RPi-pin table, and `ribbon_wiring.md` for how the ribbon cable swaps them between boards.
