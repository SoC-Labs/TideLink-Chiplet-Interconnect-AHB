# Zynq-7000 (xc7z020 / PYNQ-Z2) LVCMOS33 IO Timing Spec Research

**Date:** 2026-05-28
**Branch:** `feat/zynq7-io-timing-research`
**Scope:** Establish numerical IO timing / drive bounds for the J13 ribbon
GPIO PHY on PYNQ-Z2 (xc7z020-1clg400). Used as input for the SLEW/DRIVE
question on `pad_clk_tx`, `pad_clk_rx`, and the 8 forwarded data lanes.
**Primary sources:** UG471 v1.10 (May 2018), DS187 v1.19 (Oct 2016),
UG483 v1.14, UG953.

---

## 1. Drive strength — UG471 Table 1-8, DS187 Table 10 (notes 3-5)

LVCMOS33 is **only** available in HR (High-Range) banks (DS187 Table 10
note 2). The PYNQ-Z2 routes all J13 PMOD pins to banks 34 and 35, both HR
— so we are firmly in HR-bank LVCMOS33 territory throughout.

| `DRIVE` setting | HR bank LVCMOS33 supported? | Approx Ron (Ω)¹ | Implied static IOL/IOH at V_OL=0.4V |
|---|---|---|---|
| 2 | No (HP only, and not for LVCMOS33) | — | — |
| 4 | **Yes** | ~100 | 4 mA |
| 8 | **Yes** | ~50 | 8 mA |
| 12 | **Yes** (Vivado default) | ~33 | 12 mA |
| 16 | **Yes (max for LVCMOS33 in HR)** | ~25 | 16 mA |
| 24 | **NOT supported for LVCMOS33** (only LVCMOS18, LVTTL) | — | — |

¹ Ron is derived from the LVCMOS33 V_OL=0.4 V spec (DS187 Table 10):
`Ron ≈ V_OL / IOL = 0.4 V / IOL`. This is the figure Xilinx FAEs cite on
the forums and matches what falls out of the 7-series IBIS models in
typical PVT. It is **not** an exact factory-trimmed impedance — HR-bank
LVCMOS drivers are NOT digitally calibrated. The only DCI/calibrated
drivers in 7-series are LVDCI / HSLVDCI / DCI-suffixed standards, and
those live exclusively in HP banks (UG471 p. 19 *"7 Series FPGA DCI —
Only available in the HP I/O banks"*). xc7z020 has **no HP banks at
all** on the clg400 package, so DCI is not an option for us.

**Default if DRIVE is omitted:** `DRIVE = 12` (UG471 p. 48 *"The default
DRIVE value is 12."*). Several of our XDCs (`pair-all`, `pair-flip-all`,
etc.) currently force `DRIVE 8` — that is a step *down* from the silent
default, costing ~33 % drive current vs leaving the property unset.

**Bank power/thermal constraint:** DS187 Table 1 note 9 — *"A total of
200 mA per PS or PL bank should not be exceeded."* Our PHY uses 9 LVCMOS
signals in a single bank (8 lanes + 1 clock). Even at DRIVE 16 with a
worst-case 50 % toggle and 100 pF, average current is well under that
ceiling, so the bank limit is not what's gating us.

---

## 2. Slew rate — UG471 §"Output Slew Rate Attributes" (p. 48)

The allowed SLEW values for 7-series **are exactly two**:

| SLEW | Notes |
|---|---|
| `SLOW` | Default. Quoted: *"the default used to minimize the power bus transients when switching non-critical signals."* |
| `FAST` | Quoted: *"It might be important to specify FAST slew rate for high-performance applications such as high-frequency memory interfaces."* |

There is **no `QUIETIO` option in 7-series.** `QUIETIO` was a Spartan-3 /
Virtex-4 / Virtex-5 attribute and was dropped from 7-series. The
SelectIO guide for Zynq-7000 / Artix-7 / Kintex-7 explicitly enumerates
only `SLOW` and `FAST` (UG471 p. 48).

**No explicit rise/fall-time numbers** are published in either DS187 or
UG471 for LVCMOS33 — Xilinx specifies the IOB instead via the propagation
delay tables (DS187 Table 52). From that table for HR LVCMOS33 at
speed grade -1, output prop delay TIOOP (input pin → pad):

| Standard | TIOOP -1 max (ns) | Delta vs S8 |
|---|---|---|
| `LVCMOS33_S4` | 4.18 | +1.06 |
| `LVCMOS33_S8` | 3.90 | — |
| `LVCMOS33_S12` | 3.46 | -0.44 |
| `LVCMOS33_S16` | 3.77 | -0.13 |
| `LVCMOS33_F4` | 3.64 | -0.26 |
| `LVCMOS33_F8` | 3.12 | -0.78 |
| `LVCMOS33_F12` | 2.93 | -0.97 |
| `LVCMOS33_F16` | 2.93 (-1Q: 3.06) | -0.97 |

Test load is **CREF = 0 pF, RREF = 1 MΩ, VMEAS = 1.65 V** (DS187 Table
55) — i.e. an effectively unloaded probe-only measurement. These delays
therefore characterise the **driver-internal** transition (Ron · C_int);
real-world rise time at 80 pF will scale roughly as `Ron · C_load` and
swamp the table numbers. For our analysis below we use the standard
0-to-V_CCO RC approximation rather than these table values.

---

## 3. Maximum recommended toggle rate / our actual case

Neither DS187 nor UG471 publishes a hard "max LVCMOS33 toggle frequency"
number — Xilinx leaves it to the user to verify rise/fall time fits the
period. The rule of thumb that matches their IBIS data and the
SelectIO recommendations is **F_max ≈ 1 / (4 · t_rise)**, i.e. allow at
least a full rise + full fall + ~50 % margin within one half-period.

### 3.1 RC charge time of our actual load

We are driving J13 PMOD → 10 cm ribbon → far-side PYNQ-Z2 PMOD. The
relevant capacitive elements:

| Element | Typical value | Source |
|---|---|---|
| Far-side xc7z020 pad C_in (Cin) | ≤ 8 pF | DS187 Table 3 line 199 |
| Near-side driver self-load (parasitic) | ~4 pF | UG471 — implicit, no separate spec |
| 10 cm IDC ribbon (raw, no controlled-Z) | ~50 pF (≈ 5 pF/cm rule of thumb for ribbon) | Industry rule, UG483 §3 |
| PMOD connector + via stubs (×2 ends) | ~6 pF | Vendor headers ~3 pF each |
| ILA probe pin (if armed on the same net) | ~2 pF | LA probe load |
| **Total C_load** | **≈ 70 – 80 pF** | — |

That 80 pF figure is consistent with what we measured indirectly (~1 V
swing instead of full 3.3 V on the forwarded clock at 25 MHz).

### 3.2 t_rise at each DRIVE setting (Ron · C_load, 0 → 90 % V_CCO)

Single-pole RC, 0 → 0.9·V_CCO is 2.3·τ. With C_load = 80 pF:

| DRIVE | Ron (Ω) | τ = Ron·C (ns) | t_rise 10-90 % ≈ 2.2·τ (ns) | F_max ≈ 1/(4·t_rise) |
|---|---|---|---|---|
| 4  | 100 | 8.0 | 17.6 | ~14 MHz |
| 8  | 50  | 4.0 | 8.8  | ~28 MHz |
| 12 | 33  | 2.6 | 5.8  | ~43 MHz |
| 16 | 25  | 2.0 | 4.4  | ~57 MHz |

Our forwarded clock is **25 MHz on FPGA target, 50 MHz on ASIC target**
(memory entry `project_tidelink_v1_asic_target.md`). At DRIVE 8 with
80 pF, the 28 MHz F_max is barely above 25 MHz — explaining the
mush we see on the scope. **DRIVE 16 doubles the headroom** in time,
which is what gives the swing back.

### 3.3 Swing at DRIVE 8 vs DRIVE 16 (steady-state during a half-bit)

For a square-wave drive at frequency f, the achieved swing as a
fraction of V_CCO is approximately `1 − exp(-T/(2·τ))` where T = 1/f.

| f | T/2 (ns) | DRIVE 8 (τ=4 ns) swing | DRIVE 16 (τ=2 ns) swing |
|---|---|---|---|
| 25 MHz | 20 | 99 % (3.27 V) | 100 % (3.30 V) |
| 50 MHz | 10 | 92 % (3.04 V) | 99 % (3.28 V) |
| 100 MHz | 5 | 71 % (2.34 V) | 92 % (3.04 V) |

The 1 V swing the lab is seeing at 25 MHz **does not match a clean RC
model with C_load ≤ 80 pF** — by that math we should be at >3 V swing
even with DRIVE 8. The likely additional offenders:

1. **Transmission-line reflection** on an unterminated 10 cm ribbon. At
   25 MHz the line is electrically short (~ λ/240) so reflections
   *should* settle, but a low-Z driver into a high-Z far end without
   series termination rings — and the scope may be capturing the
   midpoint of a damped oscillation rather than the steady-state.
2. **C_load larger than 80 pF.** If the ribbon is bundled with other
   signal wires acting as adjacent grounds you can easily hit 150 pF on
   the clock conductor. Then DRIVE 8 τ = 7.5 ns, and at 25 MHz the
   swing only reaches ~93 % — still not 1 V, so even that is not the
   full story.
3. **Probe loading.** A passive 10× scope probe at the receiver end
   adds another 10-15 pF. That is non-trivial on top of 80 pF.
4. **Receiver IBUF_LOW_PWR default = TRUE** (UG471 p. 47). Low-power
   input buffer mode has a higher input threshold uncertainty and may
   register the asymmetric edge incorrectly even when V_pp is healthy
   — but does *not* change the analog swing we observe on the scope.

The 1 V symptom therefore is most likely **reflection + probe loading**
on top of an already-marginal drive, not the steady-state RC level.

---

## 4. Termination recommendation for our setup

**Cable:** 10 cm 0.05" pitch IDC ribbon, no ground plane, characteristic
impedance Z₀ ≈ 100-130 Ω depending on adjacent-conductor pattern. The
PMOD J13 pinout intersperses some ground returns, which helps.

**Source-series termination value** to match the line at the driver,
target Rs + Ron ≈ Z₀:

| DRIVE | Ron | Series R for Z₀ = 100 Ω | Series R for Z₀ = 130 Ω |
|---|---|---|---|
| 8  | 50  | **51 Ω** ✓ closest std | 82 Ω |
| 12 | 33  | 68 Ω | 100 Ω |
| 16 | 25  | 75 Ω | 100 Ω |

**Best practical choice for our case:**
- `DRIVE 12` (Vivado default) + **68 Ω external series resistor** at the
  driver pin gives near-perfect match to a 100 Ω ribbon while keeping
  the on-chip driver at moderate strength.
- `DRIVE 16` + **75 Ω external series resistor** is the maximum-edge-
  rate option and is what we should pick if we want margin for the ASIC
  target's 50 MHz operation.
- At the receiver end, **no parallel termination** (LVCMOS is
  high-impedance input, and Zynq-7 HR banks have *no* DCI). The single
  source-series resistor is the only thing taming reflections.

UG483 (7-series PCB Design Guide) explicitly recommends source-series
termination for LVCMOS over PCB traces longer than ~λ/10 of the edge
rate — for our 1-3 ns edges at LVCMOS33 that threshold is around 3 cm.
A 10 cm ribbon **clearly** needs the series Rs.

---

## 5. IBUFG vs IBUF on MRCC clock pins

UG471 §"IBUF and IBUFG" (p. 35, lines 1567-1572):

> *"The IBUF and IBUFG primitives are the same. IBUFGs are used when an
> input buffer is used as a clock input. In the Xilinx software tools,
> an IBUFG is automatically placed at clock input sites."*

**There is no electrical difference** between IBUF and IBUFG — they map
to the same physical input cell. `IBUFG` is a Vivado-level alias whose
sole purpose is to direct Vivado's clock-region router to drive the
global clock buffer (BUFG / BUFR / BUFIO / MMCM input mux) instead of a
fabric net.

Therefore the **internal capacitive load** seen at `pad_clk_rx` (Y9) is
the same whether the net is named `clk` or routed through an explicit
IBUFG instantiation: **Cin = 8 pF max** at the pad (DS187 Table 3 line
199, parameter CIN, *"PL die input capacitance at the pad"*).

The MMCM / IDELAYCTRL / flop-bank fanout downstream of the IBUFG sits
on the **clock-tree routing resources** (BUFG output net, BUFR/BUFIO),
which are *driven by* the IBUFG output — not by the pad. The pad only
sees the 8 pF input cell; the downstream load is a separate problem
solved entirely on-chip by the clock buffer (which is a high-current
driver designed for that fanout). **No extra pad-side load is added by
having an MMCM / IDELAYCTRL on the same net.**

So when we say *"the pad is driving 80 pF"* — that 80 pF is essentially
all external (ribbon + connector + far-side Cin + probe). The 8 pF
local Cin is already baked into our estimate.

---

## Verdict — answer to the 5 starting questions

1. **Drive strength:** `DRIVE 16` is the **maximum legal value** for
   LVCMOS33 in HR banks (UG471 Table 1-8). `DRIVE 24` is **not
   allowed** for LVCMOS33 (only for LVCMOS18 and LVTTL). Going
   `DRIVE 8 → DRIVE 16` doubles the sink/source current and **halves
   Ron from ~50 Ω to ~25 Ω**. Bank power is not the limit; total bank
   current at our 9-pin × 25 MHz / 50 MHz is well under the 200 mA
   bank cap.

2. **Slew rate:** `SLEW FAST` (already used everywhere) is the only
   alternative to `SLEW SLOW`. No `QUIETIO`. Going to `SLEW FAST` is
   already done — there is nothing more to gain on this axis.

3. **Max toggle rate:** Not directly tabulated. RC-derived F_max at our
   estimated 80 pF load is **~28 MHz at DRIVE 8 and ~57 MHz at DRIVE
   16**. That maps directly to our symptom: 25 MHz is squeezed at
   DRIVE 8 (barely above F_max) and comfortable at DRIVE 16.

4. **Internal pad C:** 8 pF max (DS187 Table 3). MMCM/IDELAYCTRL fanout
   is downstream of the BUFG and does **not** appear at the pad.

5. **Termination:** No DCI on this chip (HR-only, no HP banks on
   clg400). Use external **source-series resistor**: 51 Ω with
   DRIVE 8, 68 Ω with DRIVE 12, 75 Ω with DRIVE 16, targeting ~100 Ω
   ribbon Z₀.

6. **IBUFG vs IBUF:** identical primitive, identical 8 pF Cin.

### Action recommendation for the XDC

**Yes, change DRIVE 8 → DRIVE 16 on the forwarded-clock pin and the 8
data lanes** in the active FPGA targets (`pynq-z2-pair-flip-all`,
`pynq-z2-pair-flip-ila`, `pynq-z2-pair-all`).

Expected delta on our 80 pF load:
- τ drops from 4.0 ns → 2.0 ns
- 10-90 % rise time drops from ~8.8 ns → ~4.4 ns
- Swing at 25 MHz: already adequate by RC math but will be **more
  square-cornered** with less ringing-into-threshold ambiguity. Swing at
  50 MHz goes from ~92 % to ~99 % — material for the ASIC target.

**But: the internal driver alone is NOT sufficient as a complete fix
without a series resistor.** DRIVE 16 = 25 Ω driving an unterminated
~100 Ω line will worsen overshoot/ringing, not improve it, because the
mismatch becomes 4:1 instead of 2:1. The 1 V symptom likely involves
reflection settling on a high-Z driver into a high-Z line. The proper
fix is **DRIVE 16 + 75 Ω 0603 SMT series resistor on each PMOD pin at
the source side**, or equivalently **DRIVE 12 + 68 Ω series**.

If retrofitting series resistors is impractical (no PCB rework), the
**second-best** option is `DRIVE 12` (the silent default — drop our
explicit `DRIVE 8`) to get a slightly closer Ron-to-Z₀ match (33 Ω vs
50 Ω vs 25 Ω) without external parts. That alone will improve edges
about 50 % versus the current explicit `DRIVE 8`.

**External buffer chip not required.** The xc7z020 LVCMOS33 driver
*does* have enough headroom to source 80-100 pF at 50 MHz with the
right Ron and an external series Rs. The fundamental limit is the
unterminated transmission line, not driver strength.

---

## Sources

- UG471 v1.10 (May 8, 2018), *7 Series FPGAs SelectIO Resources User
  Guide* — Table 1-8 (DRIVE values, p. 48), §Output Slew Rate Attributes
  (p. 48), §IBUF and IBUFG (p. 35).
  https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug471_7Series_SelectIO.pdf
- DS187 v1.19 (October 3, 2016), *Zynq-7000 SoC (Z-7007S/.../Z-7020) DC
  and AC Switching Characteristics* — Table 3 (Cin, p. 4), Table 10 (DC
  Input/Output Levels including LVCMOS33 supported drive notes 3-5,
  p. 11), Table 52 (HR IOB Switching Characteristics, p. 35), Table 55
  (Output Delay Measurement Methodology, p. 39).
  https://www.farnell.com/datasheets/2301214.pdf
- UG483 v1.14 (May 21, 2019), *7 Series FPGAs PCB Design Guide* —
  chapters 4-5 (signal-integrity and termination guidance).
- UG953, *Vivado 7-series Libraries Guide* — IBUFG primitive (same
  internal cell as IBUF).
- Xilinx FAE forum guidance: `Ron ≈ V_OL / IOL` for HR-bank LVCMOS, e.g.
  the *Impedance Matching on HR Bank LVCMOS33* thread on
  adaptivesupport.amd.com (question 0D52E00006hpV1BSAU).
