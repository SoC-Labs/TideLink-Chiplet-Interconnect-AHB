# pynq-z2-loopback-ext — Single-Board J13 RPi Jumper Wiring

Variant B of the bring-up diagnostic pair (sibling: `pynq-z2-loopback`,
which routes TX→RX inside the FPGA fabric and exposes no pad pins).

This image runs on a **single** Pynq-Z2 board with **nine** short jumper
wires bridging the J13 RPi GPIO header so each TX pad re-enters the same
board on its matching RX pad. Used to isolate the pad / IDELAY / board
layer from the RTL / FCSM layer — if internal loopback passes but
external loopback fails on the same board, the bug is in the IO path.

## FPGA pin map (verbatim from pynq-z2-pair-all)

| Signal       | FPGA pin | J13 physical pin |
|--------------|----------|------------------|
| pad_clk_tx   | Y9       | 40 (SRCC_13 P)   |
| pad_clk_rx   | Y7       | 18 (MRCC_13 P)   |
| pad_tx[0]    | F19      | 24               |
| pad_tx[1]    | V10      | 21               |
| pad_tx[2]    | V8       | 19               |
| pad_tx[3]    | W10      | 23               |
| pad_tx[4]    | B20      | 32               |
| pad_tx[5]    | W8       | 33               |
| pad_tx[6]    | V6       | 8                |
| pad_tx[7]    | W9       | 13 (LANE-7 remap, was B19/pin 36) |
| pad_rx[0]    | U7       | 11               |
| pad_rx[1]    | C20      | 12               |
| pad_rx[2]    | Y8       | 35               |
| pad_rx[3]    | A20      | 38               |
| pad_rx[4]    | U8       | 15               |
| pad_rx[5]    | W6       | 16               |
| pad_rx[6]    | Y6       | 10               |
| pad_rx[7]    | V7       | 37 (LANE-7 remap, was F20/pin 22) |

## Required jumpers (9 wires)

Each line is one short M-M jumper wire across J13 pins on the SAME board:

```
J13 pin 40 (Y9   pad_clk_tx)  <-->  J13 pin 18 (Y7   pad_clk_rx)
J13 pin 24 (F19  pad_tx[0])   <-->  J13 pin 11 (U7   pad_rx[0])
J13 pin 21 (V10  pad_tx[1])   <-->  J13 pin 12 (C20  pad_rx[1])
J13 pin 19 (V8   pad_tx[2])   <-->  J13 pin 35 (Y8   pad_rx[2])
J13 pin 23 (W10  pad_tx[3])   <-->  J13 pin 38 (A20  pad_rx[3])
J13 pin 32 (B20  pad_tx[4])   <-->  J13 pin 15 (U8   pad_rx[4])
J13 pin 33 (W8   pad_tx[5])   <-->  J13 pin 16 (W6   pad_rx[5])
J13 pin  8 (V6   pad_tx[6])   <-->  J13 pin 10 (Y6   pad_rx[6])
J13 pin 13 (W9   pad_tx[7])   <-->  J13 pin 37 (V7   pad_rx[7])
```

PMOD-B JB1 (Y16) is unused in loopback — leave open. Strap GPIO at
0x4404_0000 is still present; SW writes `1` (master) at runtime since
there is no peer to negotiate with.

## Deploy

See `pynq_host/scripts/deploy_loopback.sh` — forces master strap +
`role_lock=1` and skips the peer-convergence wait that the pair flow
uses.
