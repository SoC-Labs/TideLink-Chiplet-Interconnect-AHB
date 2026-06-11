# Physical Wiring Plan — I²C Sideband Between Paired Pynq-Z2 Boards

**Status:** Design only.
**Target boards:** `z2_02` and `z2_03` (the standard pair in the lab; see memory note `reference_pynq_boards.md`).
**Companion spec:** [`I2C_TRAIN_PROTOCOL.md`](I2C_TRAIN_PROTOCOL.md) §7 gives the rationale for the pin choice; this document is the bench-side build instruction.

## 1. Decision summary

| Question | Decision | Rationale |
|---|---|---|
| Which 2 FPGA pins? | `W18` (SCL) and `W19` (SDA), Vivado RPi idx 0/1, J13 phys pins 3/5 | On-board 1.8 kΩ pull-ups already present; standard Pi I²C1 alt-function; no competing use. |
| How to wire between boards? | **2 separate jumper wires** (NOT extending the ribbon) | The existing 26-way ribbon is fixed at idx 6..23. Repinning the ribbon to include idx 0/1 risks the validated data-link wiring. Jumpers are independent. |
| Pull-up source? | **External jumpers leave the on-board 1.8 kΩ in place**; do **not** add XDC `PULLUP TRUE` redundantly | Two ~1.8 kΩ in parallel = ~900 Ω, which is too aggressive (high power on the bus, sluggish rise time under heavy load). One side's on-board pull-up is sufficient. |
| Single pull-up or both? | Both. The Pynq-Z2 PCB has them on each board, and removing one would require board mod. Accept the parallel ~900 Ω as a compromise — it's still within the I²C 1 mA / 3 mA budget at 100 kHz / 400 kHz respectively. | Already done by the board; minimum hardware effort. |
| Ground return? | One jumper from a J13 GND on each side | I²C is inherently single-ended; needs a shared reference. The existing data-link ribbon may not be sharing GND adequately for I²C-only signal — be explicit. |
| Cable length? | ≤15 cm | I²C capacitance limit is ~400 pF total; 2 × 5-cm pigtails + 5-cm jumper ≈ 80 pF (28 AWG insulated wire ~16 pF/cm) — well within budget. Keep it short anyway for noise. |

## 2. Physical pin chart

Per the verified `ribbon_wiring.md` table, RPi idx 0/1 on the Pynq-Z2 v1.0 J13 connector are:

| Vivado idx | FPGA pin | BCM GPIO | J13 phys pin | Standard alt-function | Our use |
|:---:|:---:|:---:|:---:|---|---|
| 0 | W18 | 2 | **3** | I²C1 SDA on Pi (but Pynq-Z2 swaps — see note) | `i2c_scl` |
| 1 | W19 | 3 | **5** | I²C1 SCL on Pi (but Pynq-Z2 swaps — see note) | `i2c_sda` |

**Note on Pi standard convention:** on a Raspberry Pi, J13 pin 3 is BCM2 = I²C1 *SDA*, and pin 5 is BCM3 = I²C1 *SCL*. On the Pynq-Z2 the mapping is the same — base.xdc maps `raspberry_pi_tri_i_0` to W18 (BCM2) and `raspberry_pi_tri_i_1` to W19 (BCM3). The on-board 1.8 kΩ pull-ups are wired to *these specific* signals: pin 3 has the SDA pull-up, pin 5 has the SCL pull-up.

**So strictly, the standard mapping would be:** `i2c_sda` on W18 (pin 3), `i2c_scl` on W19 (pin 5).

The above chart inverts this — putting SCL on the SDA pin and vice versa. Either convention works (I²C doesn't care which is which as long as both ends agree), but to match the on-board pull-up labelling and any future debugging with a logic analyser that uses Pi-pin labels, **the integrator should swap to the Pi-standard convention**:

| Use | FPGA pin | J13 phys pin |
|---|:---:|:---:|
| `i2c_sda` | W18 | 3 |
| `i2c_scl` | W19 | 5 |

The reference `I2C_TRAIN_PROTOCOL.md` §7.4 XDC snippet has them as W18=SCL, W19=SDA — **the integrator should reverse those to match this section**. Inconsistency is intentional flagging: this is one of the open items.

Both J13 pin numbers cross to the *opposite* board's matching J13 pin number (3↔3, 5↔5 — same pin number both sides, just two flying leads).

## 3. Build instructions

### 3.1 Materials

- 2 × 28 AWG insulated jumper wires, ≤15 cm long, with female-female DuPont connectors. (Black for GND, two distinct colours — e.g. yellow for SDA, green for SCL — to make polarity visual.)
- Optional: 1 × short heat-shrink sleeve per jumper to bundle the two signal lines together (keeps SCL and SDA twisted-pair-ish for noise immunity).

### 3.2 Procedure

1. **Power off both boards.** Disconnect the existing ribbon to prevent ESD coupling.
2. **Verify the J13 pin orientation on each board.** Pin 1 is marked with a square pad on the Pynq-Z2 silkscreen, at the corner nearest the SD card slot. Pin 2 is on the same side. The two columns are 1/3/5/.../39 and 2/4/6/.../40.
3. **Connect SCL.** Plug one jumper's female end onto Board A J13 pin 5 (W19), other end onto Board B J13 pin 5.
4. **Connect SDA.** Plug the second jumper onto Board A J13 pin 3 (W18) and Board B J13 pin 3.
5. **Connect GND.** Use a third jumper to tie Board A J13 pin 6 (or 9, 14, 20, 25, 30, 34, 39 — all GND) to the equivalent pin on Board B. Pin 9 is recommended (near the I²C pair, simple).
6. **Re-attach the data-link ribbon.** The ribbon does NOT carry I²C — the jumpers handle that. Make sure the ribbon's GND tie-downs (per `ribbon_wiring.md`: pins 9, 14, 25, 39 paired through the cable) are still in place, OR add another GND jumper if the ribbon mapping doesn't include those.
7. **Power on Board A, then Board B.** Inspect with a multimeter: with both boards powered, SCL and SDA should both be high (3V3 ±0.2 V) due to the on-board pull-ups. If either reads low, check that the jumper is not shorting to an adjacent pin.

### 3.3 Verification (passive)

Before running any bitstream that uses I²C:

1. Plug a logic analyser (Saleae or equivalent) into Board A's J13 pin 3 and pin 5 (via short hookup clips on the existing jumper backs). Set the analyser to detect I²C, address 7E (the autoneg slave address).
2. With the existing `mask_hs_bypass=0` bitstream loaded on both boards, run the autoneg sequence. You should see I²C activity on the bus — a START, the slave address `7E`, the mask result byte, a STOP. This validates the jumper wiring before the training extension is even tested.

If you don't see activity: probe with multimeter for shorts/opens, verify pin orientation, check that Vivado built with the correct XDC (the `i2c_scl_t / i2c_sda_t` outputs should drive the FPGA pins low only during the active phase of an I²C transaction).

### 3.4 Verification (active — protocol smoke test)

Once the training-mode integration is complete:

1. Load the integrated bitstream on both boards.
2. Run `pynq_host/scripts/deploy_pair.sh` (with the `train_auto_en = 1` config in `NEGO_TRAIN_CFG`).
3. Observe via mmap-read on the master: `NEGO_TRAIN_STATUS @ 0x094`. Expect to see `train_state` walk 1 → 2 → 3 → 4 → 5 in sequence over ~3 ms.
4. Verify `train_ok = 1` and FCSM = state 4 on both peers.

If `train_state` stops at 1 (ENTER) and `train_peer_nack = 1`: peer's I²C slave isn't responding — re-check jumper, swap SDA/SCL if there's a wiring uncertainty.

If `train_state` reaches 4 but FCSM is stuck: a downstream issue (per `I2C_TRAIN_PROTOCOL.md` §4.4); the I²C path is working.

## 4. Per-board check before pair-deploy

Before running pair-deploy, verify each board *individually* with `i2cdetect` from its host PYNQ user space:

```
ssh xilinx@z2_02 'sudo i2cdetect -y 0'    # or i2c bus 1, depending on which the FPGA exposes
```

This won't detect the FPGA-side I²C slave (the slave is on the FPGA fabric, not the Zynq PS), but it's a sanity check that the Pi-bus is unused by the OS so the FPGA fully owns it.

If the PS Linux is using I²C1 for something else (e.g. detecting Pmod sensors), unbind it:

```
ssh xilinx@z2_02 'sudo systemctl disable rpi-i2c-init.service'   # if such a service exists
```

This is a one-time setup; check `lsmod | grep i2c` before deploying.

## 5. Mirror on `pynq-z2-pair-flip-all`

I²C is **symmetric** — both sides drive open-drain, so unlike the data-link's TX/RX cross, the I²C wires do **not** swap between the two boards. Both XDCs use the same pin assignments (W18 for SDA, W19 for SCL); the cross-board wiring is pin-3 to pin-3, pin-5 to pin-5.

The flip XDC (`fpga/targets/pynq-z2-pair-flip-all/pynq_z2_tidelink.xdc`) gets **identical** I²C pin assignments to the non-flip XDC. The integrator must not be tempted to "flip" SDA and SCL — that would break the bus.

## 6. Cable harness photo placeholder

Include a photograph of the assembled jumper harness in the next bench session's bring-up report. Two photos:

- **Wide shot**: both boards on the bench, ribbon between them, jumpers visible above the ribbon.
- **Close-up**: J13 connector on one board with jumpers seated on pins 3, 5, and a GND.

Filename suggestion: `docs/bench/i2c_jumper_v1.jpg`. Reference from `BRINGUP_REPORT.md` once the path is integrated.

## 7. Cleanup / undo procedure

If the I²C jumpers cause unexpected issues (rare — open-drain is benign), they can be removed without affecting the existing data-link bring-up:

1. With `mask_hs_bypass_i = 1` (the current default before this protocol is integrated), un-plug the I²C jumpers.
2. The FPGA's `i2c_scl_o / i2c_sda_o` lines float (the on-board pull-ups hold them high). No effect on the rest of the design.

So the wiring change is non-destructive — leaving the I²C jumpers connected does no harm even when `train_auto_en = 0`.

## 8. Cost / time

- **Materials**: ~£2 for jumpers; on-hand at most labs.
- **Build time**: 15 minutes per pair, including verification.
- **Verification time**: 5 minutes (multimeter + bring-up smoke test).

## 9. Open items deferred to the integrator

1. **Pin assignment direction (SCL/SDA on W18 vs W19).** Section 2 above notes the inconsistency between the I2C_TRAIN_PROTOCOL.md §7.4 XDC and the Pi-standard convention. Resolve before building the cable harness.
2. **External pull-up sanity check.** The on-board 1.8 kΩ pull-ups on each board parallel to ~900 Ω. At 1 MHz I²C-fast-mode-plus, this is fine. Confirm with a scope-grab of SCL/SDA edges before committing to 1 MHz operation.
3. **Whether to wire I²C through a dedicated pmod connector on a future PCB revision.** This is the long-term answer (per the carrier-PCB note in `ribbon_wiring.md` §6); jumpers are the bench v1.
4. **Whether to share a single ground return with the data-link ribbon, or use a dedicated I²C GND jumper.** The reference implementation in §3.2 calls for a dedicated GND jumper for robustness; if signal integrity testing shows it's unnecessary, omit later.
