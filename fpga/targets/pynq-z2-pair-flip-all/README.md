# TideLink — Pynq-Z2 Paired GPIO-Bridge Target (FLIP / die_b)

Same Vivado design as `pynq-z2-single` plus an AXI GPIO at `0x4404_0000` whose bit 0 drives `role_strap_i`. The same bitstream programs **both** boards in a paired set; role is selected at runtime from the `FPGAHUB_LOCAL_ROLE` env var that fpgahub injects into the action subprocess (`die_a` → 0, `die_b` → 1).

## pad_clk_rx BUFG fix (die_b A→B, 2026-06-23)

This FLIP target's `pad_clk_rx` lands on **Y9** (`IO_L14P_T2_SRCC_13`, the weaker single-region clock pin) vs the straight target's Y7 (MRCC). The packaged TideLink IP's internal BUFG (`USE_CLKBUF=1`) is built out-of-context **inside** the IP, so the top-level IO clock placer cannot see it on the ~97%-packed die; top-level BUFG inference on the SRCC pin then fails and Vivado falls back to a LUT-routed clock (WHS −21.7 ns) — the diagnosed die_b A→B failure.

The fix mirrors the PHY-BIST flip target (which closed clean, WHS +0.05):

- **`tidelink_clk_rx_buf.v`** — explicit top-level `IBUFG`+`BUFG` instantiated in the BD (`clk_rx_buf`) between the `pad_clk_rx` port and `tidelink_0/pad_clk_rx`.
- **`tidelink_design.tcl`** — IPI override `CONFIG.USE_CLKBUF {1'b0}` on `tidelink_0` so the IP's internal per-lane BUFGs are pruned (the BD's single BUFG is the only one; no illegal BUFG-cascade).
- **`pynq_z2_tidelink_drc.xdc`** — `set_property CLOCK_DEDICATED_ROUTE TRUE` on the `pad_clk_rx` net so the BUFG must use the dedicated clock network from the clock-capable Y9 pin (a regression to a LUT route becomes a hard placer error, not a silent eye killer).
- **`pynq_z2_tidelink_timing.xdc` [4c]** — per-lane recovered RX word clocks (`gpiorx0..7_word_clk`, pad_clk_rx /16) + the bit→word handoff `set_max_delay` + a 3-group async `set_clock_groups` (recovered-RX / hclk / TX word clock). With `USE_CLKBUF=0` the RTL prunes the per-lane word-clock BUFG, so the /16 word domain must be declared here or it routes as an untimed "no_clock" fabric net.

### Build setting: `FPGA_USE_IDELAY=0`

Build this target with **`FPGA_USE_IDELAY=0`** (the default — do **not** set it to 1). The PHY-BIST flip target closed timing **without** the per-lane `IDELAYE2` line, and `USE_IDELAY` defaults to `0` in the RTL/IP. With `FPGA_USE_IDELAY=0`, `build_design.tcl` skips `pynq_z2_tidelink_idelay.xdc` entirely (its `get_cells {REF_NAME == IDELAYE2}` selectors would otherwise be empty and trip the Vivado message gate, and its `IOB FALSE` would conflict with the `IOB TRUE` request the timing XDC makes on `pad_rx[*]`). `pynq_z2_tidelink_idelay.xdc` is **kept** in the target dir (not deleted) so an `FPGA_USE_IDELAY=1` experiment is a one-flag change.

```bash
# This target — explicit FPGA_USE_IDELAY=0 (also the default):
make -C fpga TARGET=pynq-z2-pair-flip-all FPGA_USE_IDELAY=0 build_design
```

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

## ⚠ AHB_TX hang hazard

**Do not write to `0x4400_0000` (AHB_TX) until the link is verified UP.**

If Wlink's TX FC node is wedged (RX deserializer not synced with the peer, ribbon wrong, `pad_clk_rx` clocking unreliable, etc.), the FC adapter never asserts HREADY. The AXI-Lite-to-AHB bridge stalls, SmartConnect blocks, and the PS's `mmap` write hangs in kernel space — taking down SSH and requiring a physical power-cycle (UART reboot may not recover).

Bench evidence (2026-04-27): an AHB_TX write on z2_02 with link unsynced took the board offline; UART reboot did not bring it back within 4 minutes.

The PYNQ overlay's `TidelinkOverlay.assert_link_safe_for_tx()` and the stress runner's `write_packet()` both gate on a Wlink-activity probe before issuing AHB_TX writes — use those rather than rolling your own write loop.

## PHC tie-off

PHC inputs are zeroed for first bring-up (Q4 in the plan). PTP tests are gated until `ptp-hardware-clock-ahb` is wired in.

## Pin map

The bitstream's GPIO PHY pads are mapped to the same 18 RPi GPIOs on both boards. See `pynq_z2_tidelink_pair.xdc` for the FPGA-pin → RPi-pin table, and `ribbon_wiring.md` for how the ribbon cable swaps them between boards.
