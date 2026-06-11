# Scope-Trace Signal-Integrity Regression — 2026-06-02

## 1. Headline

**The Build #11 mmcmbypass-oddr targets silently lost both the RX cap-reduction
AND the forwarded-clock timing closure**: the IPI overrides `USE_CAP_CLKBUF=0` /
`USE_LNK_CLKBUF=1` (`tidelink_design.tcl:402-403`) refer to RTL parameters that
**were never landed in the packaged IP** (`fpga/vivado_ip/tidelink_vivado_wrapper.v:67`
only exposes the unified `USE_CLKBUF`, default `1'b1`). Vivado prints
`CRITICAL WARNING: [BD 41-1276] Cannot set the parameter USE_CAP_CLKBUF on
/tidelink_0. Parameter does not exist`, ignores both overrides, and the per-lane
WavD2DGpioRx BUFGs stay active. The `clk_rx_buf` wrapper still drives the IP
input, so pad Y9 / Y7 now sees the original ~48 pF of 8 cap-side BUFG inputs
**PLUS** the new IBUFG. Net SI = strictly worse than `pynq-z2-pair-all`. On top,
TX drive is fixed at `DRIVE 8` mA, half of LVCMOS33 default — that is what the
scope is showing (~2 V peak into the 200 Ω series at ~50 pF lumped load).

## 2. Build #11 wrapper inventory

| Mechanism                          | Wired? | Effective? | Evidence |
|------------------------------------|--------|------------|----------|
| `clk_rx_buf` (IBUFG+BUFG) BD cell  | YES    | PARTIAL    | `tidelink_design.tcl:362, 667-668` |
| `clk_tx_oddr` (SAME_EDGE ODDR)     | YES    | UNTIMED    | `tidelink_design.tcl:378, 653-654` |
| `USE_CAP_CLKBUF=1'b0` IPI override | YES    | **IGNORED**| log `@local.20260602-100359.log:` BD 41-1276 |
| `USE_LNK_CLKBUF=1'b1` IPI override | YES    | **IGNORED**| same line                                |
| `pad_clk_tx_fwd` generated clock   | DECL   | **DROPPED**| `[Vivado 12-4739]` x3, lines 164/172/173 of `pynq_z2_tidelink_timing.xdc` |

The generated clock fails because `-source [get_pins ... clk_tx_oddr/u_oddr/C]`
resolves to zero pins at constraint-parse time (likely the ODDR cell name is
namespaced differently in the synthesised netlist). Consequence: `pad_tx[*]`
get **NO `set_output_delay`** — implementation runs unconstrained, with
arbitrary lane-to-lane skew.

## 3. XDC audit (pad_* IOSTANDARD/SLEW/DRIVE)

`fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/pynq_z2_tidelink.xdc:76-90`:

```
pad_clk_tx  Y9   LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[0]   F19  LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[1]   V10  LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[2]   V8   LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[3]   W10  LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[4]   B20  LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[5]   W8   LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[6]   V6   LVCMOS33  SLEW FAST  DRIVE 8
pad_tx[7]   W9   LVCMOS33  SLEW FAST  DRIVE 8
```

`DRIVE 8` is **half** the Vivado LVCMOS33 default (12 mA), and exactly the value
that into `200 Ω + ~50 pF` gives `τ = RC = 10 ns` plus a saturated drop of
`I·R = 8 mA · 200 Ω = 1.6 V` short of rail — i.e. the ~2 V peak the scope
shows.

The MPS3 placeholder XDC (`fpga/targets/mps3/mps3_tidelink.xdc:95-110`, commit
`e08a00c`) commented the intended PYNQ-Z2 value as `DRIVE 12`. The Pi-header
pin-map rebase commit (`fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc` git
history) left `DRIVE 8` everywhere by inheritance from the original Wave-B1
single-instance scaffold.

DRC + timing XDCs add no `IBUF_LOW_PWR FALSE` or `IN_TERM` override on the
inputs. The PYNQ-Z2 RPi header has no on-board termination so this is the
default Xilinx "low-power IBUF" setting — fine.

## 4. Comparison to the known-good build

- `pynq-z2-pair-all` (the v1-release baseline now on `/tmp/tidelink_deploy`
  before Build #3 was overwritten): same `DRIVE 8`, same XDC. No `clk_rx_buf`
  cell. RX clock fans into 8 per-lane BUFGs (~48 pF load). Cleaner edges
  than current Build #11 because no extra IBUFG sits in parallel and no broken
  generated-clock ERROR drops the TX constraints.
- `pynq-z2-pair-mmcmbypass-all` (sibling, no ODDR): **same broken IPI override**
  (`tidelink_design.tcl:376-377`), so it also did not cap-reduce; but it has no
  `clk_tx_oddr` and therefore no `[Vivado 12-4739]` ERROR on TX timing.

The user's recollection of "we reduced RX-side capacitance and it was cleaner"
was on a build where the IPI-override CRITICAL WARNING was probably checked and
they hand-edited the BD pre-synth or had a different IP package. The current
repo HEAD has no path that actually delivers the cap reduction.

## 5. Recommendations (ranked by priority)

### R1 — Raise TX drive strength to LVCMOS33 default (HIGH-IMPACT, ~5 min)

Files: `fpga/targets/pynq-z2-pair-mmcmbypass-oddr-{,flip-}all/pynq_z2_tidelink.xdc`
(and matching `pynq-z2-pair-mmcmbypass-{,flip-}all` siblings).

Replace every `DRIVE 8` on `pad_tx[*]` and `pad_clk_tx` with `DRIVE 12` (or
`DRIVE 16` if any single lane stays slow after that). Expected: peak rises to
~3.0 V, edge slope shortens from ~3-4 ns to ~1.5-2 ns. Risk: ~4 dB more
crosstalk into adjacent lanes — mitigate by leaving `pad_tx[7]` at `DRIVE 8`
(crosstalk-sensitive per commit `1e95f24`).

```
-set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8}  [get_ports pad_clk_tx]
+set_property -dict {PACKAGE_PIN Y9 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports pad_clk_tx]
... (same for pad_tx[0..6])
```

### R2 — Fix the broken ODDR generated clock (MEDIUM, ~10 min)

`pynq_z2_tidelink_timing.xdc:164`. The `-source` pin pattern resolves to zero
pins. Either change to a port-level definition (no `-source`, use the
clk_wiz output as master and divide_by 1 on the port), or expand the wildcard:

```
-create_generated_clock -name pad_clk_tx_fwd -source [get_pins -hier -filter {NAME =~ "*/clk_tx_oddr/u_oddr/C"}] -divide_by 1 [get_ports pad_clk_tx]
+create_generated_clock -name pad_clk_tx_fwd -source [get_pins -hier -filter {NAME =~ "*clk_tx_oddr*/C"}]          -divide_by 1 [get_ports pad_clk_tx]
```

Until this is fixed, `pad_tx[*]` are routed unconstrained and lane-to-lane
skew is whatever the placer felt like — degrades eye independently of drive.

### R3 — Remove the dead IPI overrides (LOW-IMPACT, ~2 min)

`fpga/targets/pynq-z2-pair-mmcmbypass-oddr-all/tidelink_design.tcl:399-404` and
mirrored in `-flip-all`, `-mmcmbypass-all`, `-mmcmbypass-flip-all`. Delete
`CONFIG.USE_CAP_CLKBUF` and `CONFIG.USE_LNK_CLKBUF` lines OR replace with
`CONFIG.USE_CLKBUF {1'b0}` (the parameter that actually exists). With
`USE_CLKBUF=0` AND `clk_rx_buf` providing the BUFG, RX pad load drops from
~48 pF to ~8 pF — the cap-reduction the user remembers having.

### R4 — Strip `clk_rx_buf` if R3 is reverted (LOW, ~2 min)

If R3 cannot land (e.g. ASIC parity concern), then `clk_rx_buf` is dead weight
adding 1 IBUFG load on top of the IP's 8 BUFGs. Delete the cell + the two
`connect_bd_net` lines at `tidelink_design.tcl:667-668` so pad_clk_rx goes
directly to `tidelink_0/pad_clk_rx` (back to `pair-all` topology).

### R5 — Verify in next build log (gating)

After R1-R3, the build log must show: zero `BD 41-1276`, zero `Vivado 12-4739`,
and `pad_clk_tx_fwd` listed in `report_clocks`. Without those three, R1 is
necessary but not sufficient.

---

VERDICT: Cap-reduction was never effective on Build #11 (IPI override silently
ignored); add R1+R2+R3 together to recover both edge slope and peak voltage.
