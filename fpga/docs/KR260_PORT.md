# TideLink on the Kria KR260 — port notes (2026-07-09)

Port of the TideLink GPIO-PHY chiplet link from the Digilent Pynq-Z2
(Zynq-7000, `xc7z020`) to the Xilinx **Kria KR260** (Zynq UltraScale+, **K26 SOM
`xck26-sfvc784-2LV-c`**, board part `xilinx.com:kr260_som:part0:1.1`). The link
runs over the KR260 **Raspberry-Pi 40-pin header (J21)** between two boards,
exactly the way the Z2 pair does over its RPi header.

## Deliverables — four targets

Two boards, linked Pi-header ↔ Pi-header by a **straight-through ribbon**, in a
`die_a` / `die_b` flip pair × PTP on/off:

| TARGET | die | PTP (PHC HW clock) | bitstream role |
|---|---|---|---|
| `kr260-pair-ptp`       | die_a (straight) | **in** | master-ish (role strap 0) |
| `kr260-pair-nptp`      | die_a (straight) | out    | master-ish (role strap 0) |
| `kr260-pair-flip-ptp`  | die_b (mirror)   | **in** | slave-ish  (role strap 1) |
| `kr260-pair-flip-nptp` | die_b (mirror)   | out    | slave-ish  (role strap 1) |

Board A loads a `…pair-…` (die_a) image; board B loads the matching
`…pair-flip-…` (die_b) image. Use the two `-ptp` images together, or the two
`-nptp` images together — don't mix a PTP board with a non-PTP board.

The `-ptp` / `-nptp` split is a single build-time env (`FPGA_TIDELINK_PTP`, set
per-target in `fpga/Makefile`); one BD tcl serves both so they cannot drift.
The die_a / die_b split is the pin XDC (TX↔RX ball swap) plus the role-strap
default. `fpga/targets/kr260_resync.sh` regenerates the 3 sibling targets from
the `kr260-pair-ptp` source of truth.

## Build

```bash
source set_env.sh                      # CMSDK/XHB500 IP paths (read-only vendor tree)
make -C fpga package_ip package_phc_ip # once (part-independent; PHC needed for -ptp)
make -C fpga build_design TARGET=kr260-pair-nptp      SKIP_PACKAGE_IP=1
make -C fpga build_design TARGET=kr260-pair-ptp       SKIP_PACKAGE_IP=1
make -C fpga build_design TARGET=kr260-pair-flip-nptp SKIP_PACKAGE_IP=1
make -C fpga build_design TARGET=kr260-pair-flip-ptp  SKIP_PACKAGE_IP=1
# or fan out on the farm:
#   make -C fpga farm_build FARM_JOBS="kr260-pair-nptp@local kr260-pair-ptp@farm-host-a ..."
```
Outputs land in `imp/fpga/output/<TARGET>/tidelink.{bit,hwh,bin}` + a
provenance manifest. The build uses Vivado 2024.1 (the KR260 board files ship in
`…/Vivado/2024.1/data/xhub/boards/XilinxBoardStore/…/kr260_som/1.1`).

## Address map — relocated off DDR

On MPSoC `0x0000_0000–0x7FFF_FFFF` is DDR, so the Z2 GP0 apertures collide and
move into the PL windows. **Control** → `M_AXI_HPM0_LPD` (`0x8000_0000`),
**data** → `M_AXI_HPM0_FPD` (`0xA000_0000`). It is a pure top-nibble / top-byte
swap — every low bit and internal offset is preserved.

| aperture | Z2 | KR260 | range | master |
|---|---|---|---|---|
| ahb_sub (transparent window) | `0x4000_0000` | `0x8000_0000` | 64 MB | HPM0_LPD |
| ahb_ptp (PTP TX write; -ptp)  | `0x4402_0000` | `0x8402_0000` | 4 KB  | HPM0_LPD |
| apb (unified config)          | `0x4403_0000` | `0x8403_0000` | 32 KB | HPM0_LPD |
| strap GPIO                    | `0x4404_0000` | `0x8404_0000` | 4 KB  | HPM0_LPD |
| debug-unlock GPIO             | `0x4404_1000` | `0x8404_1000` | 4 KB  | HPM0_LPD |
| phc apb (-ptp)                | `0x4405_0000` | `0x8405_0000` | 4 KB  | HPM0_LPD |
| ahb_tx (data)                 | `0x8400_0000` | `0xA400_0000` | 64 KB | HPM0_FPD |
| ahb_fifo (RX FIFO, data)      | `0x8401_0000` | `0xA401_0000` | 64 KB | HPM0_FPD |

The unified APB control surface is at `0x8403_2000` (region base `0x8403_0000`
+ TideLink `0x2000`). The peer flow-control base (`TIDELINK_PAIR_BASE`, the only
absolute address baked at build time — the RTL decode is otherwise a reset-time
identity CAM) is set to `0x8403_2000` on the tidelink_0 BD cell.

**Host software:** `pynq_host/overlay.py` and `bare_overlay.py` select the map
from `TIDELINK_SOC` — set `export TIDELINK_SOC=kr260` before running anything on
the board. The scattered bring-up/hwtest scripts still carry Z2 literals; on
KR260 apply the same swap (`0x4000_0000→0x8000_0000`, `0x4403→0x8403`,
`0x4404→0x8404`, `0x4405→0x8405`, `0x8400_0000→0xA400_0000`,
`0x8401_0000→0xA401_0000`), or export the data-plane overrides
`TIDELINK_TX_BASE=0xA4000000 TIDELINK_RXFIFO_BASE=0xA4010000`.

## Pin map / ribbon (KR260 RPi header J21, HDIO bank 44, LVCMOS33)

18 link conductors + 2 I2C conductors cross the ribbon; the two forwarded clocks
are on **HDGC (global-clock-capable)** balls so the *received* clock lands on a
real clock pin on both boards — no `CLOCK_DEDICATED_ROUTE` override, and none of
the Z2 die_b SRCC weakness (so no clock-region pblock is needed).

| signal | die_a ball (BCM) | die_b ball (BCM) | notes |
|---|---|---|---|
| pad_clk_tx / (die_b: pad_clk_rx) | AD15 (BCM0, **HDGC**) | — | clk on ribbon pin BCM0 |
| pad_clk_rx / (die_b: pad_clk_tx) | AC14 (BCM8, **HDGC**) | — | clk on ribbon pin BCM8 |
| pad_tx[0..7] (die_a) = pad_rx[0..7] (die_b) | AD14,AC13,AA13,AB13,AG14,AH14,AG13,AH13 | same balls | BCM1,9,12,13,4,5,6,7 |
| pad_rx[0..7] (die_a) = pad_tx[0..7] (die_b) | AB15,AB14,AE13,AF13,W14,W13,Y14,Y13 | same balls | BCM16,17,10,11,14,15,18,19 |
| i2c_sda_io | AE15 (BCM2) | AE15 | symmetric, no flip |
| i2c_scl_io | AE14 (BCM3) | AE14 | symmetric, no flip |
| led0..3 | H12,E10,D10,C11 (**PMOD0**) | same | OFF the ribbon (status only) |

**Ribbon:** a straight-through IDC cable connecting the two J21 headers pin-for-
pin works — `die_a pad_tx[i]` and `die_b pad_rx[i]` land on the same physical
header pin (and vice-versa), and I2C is symmetric. LEDs are on PMOD0 precisely so
that a full 40-way ribbon does **not** cause two boards to drive the same status
pin. If you crimp a partial ribbon, bridge at minimum BCM0,1,2,3,4,5,6,7,8,9,10,
11,12,13,14,15,16,17,18,19 plus a few GNDs.

## Clocking

`pl_clk0` (~100 MHz) → clk_wiz (`clk_out1 = 25 MHz` hclk/AXI **+ phc**, `clk_out2`
spare, `clk_out3 = 200 MHz` IDELAY ref) → `tidelink_phy_clk_div2` **/8** →
**3.125 MHz / 320 ns** PHY bit clock. The Z2's 4.687 MHz clk_out1 is below the
MPSoC MMCME4 floor, hence 25 MHz + /8. 3.125 MHz is conservatively close to the
Z2's silicon-proven-slow 2.343 MHz. **The link rate is the main bench knob**: it
is set in exactly two co-dependent places — `tidelink_phy_clk_div2.v` (the /8) and
`kr260_tidelink_timing.xdc` (`create_clock -period 320.000` + the two
`-divide_by 8`). Change them together on both die_a and die_b.

### phc_clk timing fix (2026-07-17, R1) — the `-ptp` builds failed setup

The deployed `kr260-pair-ptp` bitstream failed setup with **WNS −2.427 ns / 1673
failing endpoints, ALL on the `clk_out1↔clk_out2` crossing**. Root cause: `clk_out1`
and `clk_out2` both *request* 25 MHz, but one MMCM resolves them to **different
actual** frequencies — `clk_out1` on fractional-capable CLKOUT0 = **25.011 MHz
(39.982 ns)**, `clk_out2` on an integer-only CLKOUTn = **24.955 MHz (40.072 ns)**.
The tool then times every `hclk↔phc_clk` (and `axi_apb_phc→phc_0/apb`) path as a
near-common-period inter-clock crossing with ~0.09 ns of budget. **Fix: drive
`tidelink_0/phc_clk` and `phc_0/clk` from `clk_out1` (== hclk)** so the crossing is
single-clock (intra-`clk_out1` WNS +28.8 ns). The PHC is a 25 MHz timebase either
way and its `hclk↔phc_clk` boundary is CDC'd in RTL, so this is a zero-function
change (same NS_INCR budget; 24.955→25.011 MHz is 0.2%, closer to nominal).
`clk_wiz` CLKOUT2 is left enabled-but-unconnected (harmless spare; do **not**
reconnect phc to it). Applied to both `kr260-pair-ptp` and `kr260-pair-flip-ptp`.

The **8-endpoint hold failure (WHS −23.198 ns)** in the same report is a SEPARATE,
pre-existing item: it is entirely on `user_ref_clk_div2 → pad_clk_tx_fwd`, i.e. the
`pad_tx[7:0]` **source-synchronous forwarded-clock outputs** (20 ns output-delay
constraint vs a forwarded clock) — the known benign WHS artifact class. It is not
PHC-related and this fix neither touches nor worsens it. **Note for `-nptp`:** those
targets still tie `tidelink_0/phc_clk` to `clk_out2`; with the PHC core absent the
crossing is small, but if an `-nptp` routed report shows `clk_out1↔clk_out2` setup
failures, apply the same one-line re-point there (out of R1's file scope).

## You must `export TIDELINK_PHY_V2=1` (silent-V1 trap)

`TIDELINK_PHY_V2` is exported **only** by `.gitlab-ci.yml`. It is *not* in
`set_env.sh`. If it is unset:

- `package_ip` resolves `flists/tidelink_fpga.flist` and bakes the **V1** PHY
  (`src/rtl/local_overrides/Wav*.v`) into `imp/fpga/tidelink_ip`;
- `build_design.tcl` never injects `-verilog_define TIDELINK_PHY_V2`;
- the build **succeeds**, and you get a V1 bitstream. On silicon that is the
  marginal-eye lottery, and none of the V2 bring-up recipes apply.

The manifest records it (`"phy_marker": "V1"`), but only *after* the build. To
check the packaged IP up front, compare content — the two PHYs share filenames,
so a filename check proves nothing:

```bash
md5sum imp/fpga/tidelink_ip/src/WavD2DGpio.v \
       deps/tidelink-phy/rtl/wav/WavD2DGpio.v \   # V2
       src/rtl/local_overrides/WavD2DGpio.v       # V1
```

The packaged copy md5-matches exactly one of them; that is your PHY version.
Build KR260 bitstreams as:

```bash
export TIDELINK_PHY_V2=1
make -C fpga package_ip                       # must be re-run when the flag changes
make -C fpga build_design TARGET=kr260-pair-ptp SKIP_PACKAGE_IP=1
```

`package_ip` **must** be re-run whenever `TIDELINK_PHY_V2` changes — it rewrites
the shared `imp/fpga/tidelink_ip`. (`build_design`'s `tl_verify_packaged_ip` will
hard-fail if you set the define but the packaged sources are the other version,
so a V2-define-on-V1-sources build cannot slip through silently.)

## HDIO constraint: `USE_IDELAY=0` is mandatory (not a tuning choice)

The KR260's RPi header is entirely on **HDIO bank 44**, and HDIO banks physically
cannot host `I/ODELAY` or `I/OSERDES` primitives. The packaged tidelink IP defaults
to `USE_IDELAY=1`, which puts a per-lane delay line on every `pad_rx` (`IDELAYE2`
on 7-series, `IDELAYE3` on US+). Left at the default, the KR260 build fails three
ways, all from the same cause:

| Error | Meaning |
|---|---|
| `Vivado 12-1411` ×8 | can't place `IDELAYE3` in HDIO (`presence of I/ODELAY or I/OSERDES is not supported in HDIO`) |
| `DRC ADEF-911` ×9 | `SIM_DEVICE` unset on those same `IDELAYE3` cells |
| `DRC UCIO-1` | consequence — the failed placement **drops the `pad_rx[7:0]` LOCs**, so they look "unconstrained" |

The last one is the misleading symptom: it reads like a bad pin XDC, but the pin
XDC is fine. The fix is in the BD, on `tidelink_0`:

```tcl
set_property -dict [list \
    CONFIG.TIDELINK_PAIR_BASE {0x84032000} \
    CONFIG.USE_IDELAY         {0} \
] $tl
```

`USE_IDELAY=0` prunes the generate branch to a pure combinational passthrough
(`pad_rx_o = pad_rx_i`), which places cleanly in HDIO. Eye centring is unaffected —
it is done by the Wlink calibrator's bit-slip × phase sweep, not the delay line.
`pynq-z2-pair` / `-pair-flip` already ship this same override; only the Z2 `-all`
targets keep `USE_IDELAY=1`, and they get away with it because their `pad_rx` pins
are in HR banks, which *do* host IDELAY.

Corollary: there is **no** IDELAY escape hatch on the RPi header. The K26 exposes
HP/HR-bank IO only on the SOM240 connectors, so "keep the IDELAY, move the pins"
means abandoning the RPi header. The 200 MHz `clk_out3` IDELAYCTRL reference is
retained in the BD but is now unused inside the IP (harmless).

## HDIO constraint #2: `IOB FALSE` on `pad_rx[*]` (V2 PHY only)

Same family, different primitive — and it only bites on the **V2** PHY, so a V1
build hides it. HDIO's input flip-flop (IPFF) requires its `D` pin to drive the
flop and nothing else.

The V2 PHY adds a per-lane register `gpiorx_N/g_word_pin_auto.wpa_shift_q_reg[0]`
that the V1 PHY does not have (`grep -c g_word_pin_auto` → V1: 0, V2: 1). Unlike
the intended capture flop `link_data_pad_clk_reg` (which has a mux on `D` and so
can never pack), that register *is* a legal IOB candidate. The Z2 timing XDC's
`set_property IOB TRUE [get_ports {pad_rx[*]}]` therefore propagates onto it,
Vivado packs it into the HDIO IPFF, and post-route DRC fails 8× (one per lane):

```
ERROR: [DRC PDRC-248] HDIOLOGIC_IPFF_unsupported_D_fanout: The IPFF in
HDIOLOGIC_M_X0Y15 (from cell .../gpiorx_2/g_word_pin_auto.wpa_shift_q_reg[0],
IOB=TRUE ...)
```

The KR260 timing XDC inverts the Z2 constraint to `set_property IOB FALSE`.
Nothing is lost: IOB packing was never what made the capture deterministic — that
is `(3b) set_max_delay` and `(3c) set_bus_skew`, both unaffected. `FALSE` rather
than deleting the line also stops the placer packing it opportunistically.

**Rule of thumb for this port:** HDIO banks are cheap IO, not full HP/HR IO. They
refuse structures the Z2's HR banks accept. If a new DRC error names
`HDIOLOGIC_*`, the fix is to stop asking for the IO-side structure, not to move
the pins — the RPi header has nowhere else to go.

## HDIO constraint #3: I2C sideband needs `PULLTYPE PULLUP` in-fabric

The autoneg I2C sideband (`i2c_sda_io` AE15/BCM2, `i2c_scl_io` AE14/BCM3) is
open-drain: the wrapper only ever drives '0' or Hi-Z, so the bus relies on a
pull-up to reach the idle-high '1'. On a real Raspberry-Pi carrier the Pi board
fits ~1.8 kOhm pull-ups — but in the **KR260<->KR260 straight ribbon** there is no
Pi and no HAT, so **nothing** pulls the bus up. A floating SDA/SCL can clock the
on-die I2C autoneg *slave* into spurious transactions, and that slave shares the
Wlink APB port — i.e. a floating sideband can hijack control-plane accesses. (The
old XDC comment "the carrier / peer board provide the bus pull-ups" was simply
wrong for this topology; corrected 2026-07-17.)

Fix (all four buildable ribbon XDCs — `kr260-pair-{,flip-}{ptp,nptp}`):

```tcl
set_property -dict { PACKAGE_PIN AE15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_sda_io]
set_property -dict { PACKAGE_PIN AE14 IOSTANDARD LVCMOS33 PULLTYPE PULLUP } [get_ports i2c_scl_io]
```

Two port-name / property notes that matter here:

- **`PULLTYPE PULLUP`, not the 7-series `PULLUP TRUE`.** xck26 is UltraScale+, where
  the single `PULLTYPE` property (values `NONE`/`PULLUP`/`PULLDOWN`/`KEEPER`)
  replaces the 7-series boolean `PULLUP`/`PULLDOWN`/`KEEPER` properties. HDIO bank
  44 supports a weak pull, so `PULLTYPE PULLUP` is legal and DRC-clean there;
  `PULLUP TRUE` is the wrong syntax for this family. (The Z2 XDCs legitimately use
  `PULLDOWN TRUE` — they are 7-series; do not copy that form here.)
- The SOM internal pull is weak (~50 kOhm), enough to guarantee a **safe idle** and
  stop the slave self-triggering, but for signal integrity at speed a bench
  **2.2 kOhm to 3V3 on exactly one board** is still preferred. Do not fit external
  pull-ups on both boards (doubles the load, halves the effective value).

`kr260-pair-onchip` is unaffected: it instantiates both dies in one bitstream and
wires the I2C wired-AND *inside the fabric* — there are no external I2C pads and no
XDC, so the floating-bus hazard cannot occur there.

**Floating-input audit (done alongside the pull-up fix):** the only top-level input
ports on the ribbon wrapper are `pad_clk_rx`, `pad_rx[7:0]` and the two I2C inouts.
The clock/data RX pins are driven push-pull by the peer board's `DRIVE 8` TX outputs
(one driver per conductor) — not floating in steady state, and out of scope for a
pull (a weak pull would only fight the driver and close the eye). There is **no**
role-strap / enable / present *input* pin to worry about: the die role is set
internally by BD `xlconstant` straps + I2C autoneg, not by an external pin. So the
I2C bus is the only genuine floating-input hazard, and it is now closed.

## Deploy on KR260 (differs from the Z2 fpga_manager flow)

Boards run the **PYNQ Kria image**, so `make deploy` now handles KR260 directly.
`fpga/Makefile` picks a `DEPLOY_STYLE` off the TARGET:

| TARGET | `DEPLOY_STYLE` | How the PL is loaded |
|---|---|---|
| `pynq-z2-*` | `fpga_manager` | `bit2bin.py` → `/lib/firmware` → `/sys/class/fpga_manager/fpga0/firmware` |
| `kr260-*` | `pynq_overlay` | `pynq.Overlay('tidelink.bit')` (drives the zynqmp fpga_manager itself) |

> **Trap:** `fpga/scripts/bit2bin.py` is **Zynq-7000 only** — its byte-swap targets
> the `zynq-fpga` driver (`bootgen -arch zynq`). ZynqMP needs `-arch zynqmp` and a
> different format. Feeding a KR260 a `bit2bin` `.bin` silently produces a bad PL
> load. The `kr260-*` artefact list therefore omits `tidelink.bin` entirely; the
> Makefile enforces this, don't re-add it.

Deploy stages `.bit` + `.hwh` into `$(PYNQ_DEST)/pynq_host/` (PYNQ resolves the
`.hwh` by sibling basename, and `TidelinkOverlay()` defaults its bitfile to the
copy next to `overlay.py`), then loads and prints the PL state.

```bash
# one board, explicit target
make -C fpga deploy TARGET=kr260-pair-ptp BOARD=<kria board>

# fpgahub pair roles (SOC + PTP select among the 4 targets)
make -C fpga deploy_pair_role ROLE=die_a SOC=kr260 PTP=1 BOARD=<a>   # kr260-pair-ptp
make -C fpga deploy_pair_role ROLE=die_b SOC=kr260 PTP=1 BOARD=<b>   # kr260-pair-flip-ptp
make -C fpga deploy_pair_role ROLE=die_a SOC=kr260 PTP=0 BOARD=<a>   # kr260-pair-nptp
```

`SOC` defaults to `z2`, so the existing Z2 `deploy_pair_role` calls are unchanged.
PS-side MMIO pokes use the relocated addresses above — deploy exports
`TIDELINK_SOC=kr260` for the load and prints the runner command with it set.

## First thing to run on the bench: the plumbing smoke test

`pynq_host/scripts/kr260_smoke.py` checks exactly the three things this port put
at risk, and claims nothing more. Run it on **each** board right after deploy:

```bash
sudo TIDELINK_SOC=kr260 python3 pynq_host/scripts/kr260_smoke.py --expect-role die_a
sudo TIDELINK_SOC=kr260 python3 pynq_host/scripts/kr260_smoke.py --expect-role die_b --ptp --unlock
```

It verifies (1) the relocated apertures actually respond, (2) the **die-role
strap** reads back `0` on a die_a image and `1` on a die_b (flip) image — the
cheapest possible proof you flashed the right bitstream to the right board — and
(3) a PL register is writable. It exits non-zero on any failure.

> **Safety:** on ZynqMP a read of an *undecoded* PL address can hang the AXI bus
> with no timeout and wedge the board. The PTP-only apertures (`ahb_ptp`, `phc`)
> are absent from the `-nptp` images, so the script probes them **only** under
> `--ptp`. Don't pass `--ptp` to an `-nptp` image, and don't remove that gate.

`tl_poke.py`'s `rd`/`wr` take absolute addresses and are SoC-agnostic; its `obs`
decode now derives `OBS_FC_CREDIT` from `TIDELINK_SOC` (`0x8403_219C` on KR260).
The remaining `pynq_host/scripts/**` bring-up scripts still hold Z2 address
literals and have **not** been ported — they are shared with the live Z2 campaign.

## Validated tonight vs. needs bench iteration

**Validated (Vivado 2024.1, offline):**
- xdc_lint clean on all KR260 XDCs; BD tcl parses/executes for PTP on & off, die_a & die_b.
- `kr260-pair-nptp` and `kr260-pair-ptp` **elaborate + `validate_bd_design` pass** on
  `xck26` with the KR260 board preset, the relocated address map, `USE_IDELAY=0`,
  and (for -ptp) the full PHC subsystem (`/phc_0` + `/axi_apb_phc`; the -nptp BD
  correctly carries only `xlconst_phc_tieoff_*` instead).
- The design synthesises, places, routes and phys-opts on `xck26`. The only build
  stopper found was the HDIO/IDELAY issue above, now fixed.

**Needs a bench pass (expected, first silicon on a new board):**
1. **Link eye / rate.** 3.125 MHz is a conservative guess; the real KR260 eye is
   uncharacterised. Tune the one clock knob (above). The autoneg/role-lock +
   calibrator bring-up recipe is inherited from the Z2 and will likely need the
   same kind of sequencing (see `pynq_host/scripts/bringup_*`). Note the KR260 RX
   path has **no per-lane IDELAY** (see above), so the calibrator's bit-slip ×
   phase sweep is the *only* eye-centring mechanism — one fewer knob than the Z2
   `-all` targets.
2. **Timing.** The first routed `-nptp` run closed with **WNS ≈ −1.79 ns, WHS ≈
   −23.3 ns** *with* the IDELAY cells mis-placed, so those numbers are not
   meaningful; re-read the post-fix `*_timing_summary_routed.rpt` before trusting
   them. Expect some of the hold noise to be the dbg_hub/BSCAN paths the Z2 timing
   XDC already documents as benign.
3. **HDIO clock fan-out.** The RX path buffers the recovered clock onto per-lane
   nets; HDIO bank 44 has a smaller clock-resource pool than an HP bank. If
   route_design complains about clock placement, that's the spot.
4. **Deploy plumbing** (xmutil/.dtbo vs PYNQ) per above.
4. **I2C pull-ups** on the RPi-header I2C1 (BCM2/3) — the XDCs now fit an in-fabric
   `PULLTYPE PULLUP` (see "HDIO constraint #3" above), which guarantees a safe idle
   in the carrier-less KR260<->KR260 ribbon. For signal integrity at speed still add
   a 2.2 kOhm to 3V3 on exactly one board.
5. **Host scripts** beyond the two overlay modules still hold Z2 address literals.
