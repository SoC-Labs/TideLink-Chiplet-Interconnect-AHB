# Clock-Forwarding Reference Research — 2026-05-28

**Author:** David Mapstone (research compiled by Claude)
**Branch:** `feat/clock-fwd-research` (off eyecenter HEAD)
**Scope:** READ-ONLY. No RTL, XDC, or submodule changes were made. Background
research for the 50 MHz LVCMOS33 forwarded-clock signal-integrity issue
between two PYNQ-Z2 boards (~10 cm ribbon, J13 RPi headers, Y9 RX clock,
8 mA / SLEW FAST drive, no termination, ~80 pF estimated load → ≤1 V swing).

---

## TL;DR

| Question | Answer |
|---|---|
| Is 50 MHz LVCMOS33 over ~10 cm ribbon **achievable on a 7-series Zynq**? | **Yes — comfortably.** Multiple existing designs run LVCMOS33 single-ended at 25–100 MHz over comparable interconnects. Our specific problem is a **load/termination** issue, not a fundamental signaling-rate limit. |
| Top concrete fix to try | **External source-series termination ≈ 33–47 Ω** at the TX pad on `pad_clk_tx`, combined with **DRIVE 16, SLEW FAST** in XDC, **and confirmation of whether the J13 RPi header pin in question carries the 200 Ω protection resistor** (PYNQ-Z2 fits these on Pmod and several digital connectors per Digilent's standard practice). |
| Top reference design | **Analog Devices "Source-synchronous interface design with FPGAs" wiki** ([link](https://wiki.analog.com/resources/fpga/docs/ssd_if)) — the cleanest open description of the 7-series MRCC → BUFIO/BUFR → IDDR pattern that mirrors what `tidelink_top` is doing today. |
| Should we abandon LVCMOS for LVDS? | **No, not yet.** Move to LVDS only if (1) external Rs termination doesn't fix it on the bench AND (2) we cannot reduce internal fan-out below ~50 pF effective load. LVDS on 7-series demands a differential pair on adjacent P/N pins — the current single-pin Y9 routing is not LVDS-ready, so this is a non-trivial pivot. |

---

## A. Reference Designs Found

### A1. **PonyLink** (Clifford Wolf / YosysHQ) — single-wire bi-directional chip-to-chip link
- URL: <https://github.com/cliffordwolf/PonyLink>
- Tested on **Xilinx Series 7 and Lattice iCE40**. Achieves 100 Mbit/s at 166 MHz over a single wire, with optional LVDS for higher rates.
- Embedded clock + 8b10b, dc-free (caps / magnetics tolerated).
- **What we can borrow:** the encoding/clock-recovery approach is *not* a forwarded-clock design — but it proves that a **single-ended Series-7 GPIO can carry ≥100 Mb/s of clock-embedded data** without any LVDS hardware block. If our forwarded-clock fix proves unworkable, PonyLink-style embedded-clock is the next architectural fallback, not LVDS.
- License: ISC (permissive). Pure Verilog, ~1700 LUTs.

### A2. **Analog Devices source-synchronous interface design pattern** — generic 7-series template
- URL: <https://wiki.analog.com/resources/fpga/docs/ssd_if>
- ADI's published recipe for source-synchronous on 7-series: `ad_data_clk.v` (`IBUFG → BUFG/BUFR`) and `ad_data_in.v` (`IBUF → IDELAY → IDDR`). This is the canonical pattern we are already using.
- Caps `CORE_CLK` at ~200 MHz; our 50 MHz forwarded clock is **a quarter of the safe ceiling**. Confirms our target is conservative.
- **What we can borrow:** ADI's RTL is BSD-licensed and the `ad_serdes_*` modules give a known-working IDELAY/ISERDES wrapping if we ever need to upgrade the lane samplers.

### A3. **XAPP585 — LVDS Source Synchronous 7:1 SerDes (Clock Multiplication)**
- URL: <https://docs.amd.com/api/khub/documents/JlDZcsu8DsMLJ6KXAZfq5Q/content>
- Reference for LVDS forwarded-clock 7:1 SerDes at 660+ Mb/s. Includes XDC fragments for `set_input_delay` / `set_output_delay` against the forwarded clock.
- **What we can borrow:** XDC examples (input/output delay vs. forwarded clock) and the recommendation to **drive a constant pattern (e.g. `1100001`) to the clock OSERDES** so the clock and data have a guaranteed phase relationship. Even without an OSERDES, the XDC patterns are directly portable to LVCMOS forwarded clocks.

### A4. **Spartan-6 XAPP1064 — Source-Synchronous SerDes (up to 1.05 Gb/s)**
- URL: indexed at <https://www.xilinx.com/support/documentation/application_notes/xapp1064.pdf>
- Older but contains explicit treatment of **single-ended SDR/DDR source-synchronous reception** at moderate speeds — closer to our use case than XAPP585.
- **What we can borrow:** the IDELAY phase-shift calibration loop (very close to what `tidelink_phy_align_calibrator.sv` does today).

### A5. **Digilent Pmod High-Speed Interface Specification** (related architecture)
- URL: <https://digilent.com/reference/pmod/specification>
- Quotes: "Speeds greater than 100 MHz should be achievable using high-speed ports" and "signals have been sent reliably at 24 MHz over 4 m of CAT5 cable" using the standard Pmod electrical spec.
- **What we can borrow:** the **200 Ω series resistor** that Digilent fits on every standard Pmod is essentially a deliberate (over-)source-series termination — it works for slow GPIO but kills high-speed signalling, which is exactly why their "high-speed" Pmod ports omit those resistors. **Action item: confirm from the PYNQ-Z2 schematic (`TUL_PYNQ_Schematic_R12.pdf`) whether the specific J13 pins we use have the 200 Ω resistors or not.** If they do, that single fact may be the root cause of the swing collapse (200 Ω + ~80 pF τ ≈ 16 ns ≫ 10 ns half-period).

---

## B. Application Notes & Answer Records

| Doc | Key takeaway for our problem |
|---|---|
| **UG471** (7-series SelectIO User Guide) | DRIVE options for LVCMOS33 in HR banks: **4 / 8 / 12 / 16 mA**. SLEW = FAST or SLOW. UG471 §1 explicitly warns that *"faster slew rates can also lead to reflections or increased noise issues if not properly designed (such as with terminations, transmission line impedance continuity, and cross-coupling)"* — i.e. the standard expectation is that for any LVCMOS line longer than a few cm at >25 MHz, you add termination. ([UG471 v1.10 PDF](https://0x04.net/~mwk/doc/xilinx/ug/ug471_7Series_SelectIO.pdf)) |
| **UG899** (Vivado I/O & Clock Planning) | Confirms MRCC clock-capable pins (Y7, Y9 on our XC7Z020) feed `BUFIO` (for IDELAY/ISERDES) and `BUFG` (global fan-out). Y9 SRCC is a clock-capable pin but feeding both `IDELAYCTRL` and `BUFG` on a single LVCMOS input is well-supported. ([UG899 PDF](https://www.xilinx.com/support/documents/sw_manuals/xilinx2022_1/ug899-vivado-io-clock-planning.pdf)) |
| **Skyworks AN1236 — LVCMOS Output Best Practices** | Industry-standard rule for source-series termination of single-ended CMOS: `Rs ≈ Z0 − R_on`. Typical low-EMI LVCMOS clock fanout uses **Rs in the 22–47 Ω range** for ~50 Ω lines. ([AN1236 PDF](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/application-notes/an1236-si533xx-44qfn-lvcmos-output.pdf)) |
| **Renesas / IDT AN-845 — LVCMOS Termination** | Same Rs = Z0 − Rout rule. Notes that **Rs slows the edge** as a side effect, which is *exactly* what we want at 50 MHz — slower edge → less ringing → cleaner sampling window for the receiver MMCM/IDELAY. ([IDT AN-845](https://www.idt.com/document/apn/845-termination-lvcmos)) |
| **Lattice "Can I drive long PCB traces with an LVCMOS output?"** AR-851 | Lattice's stance: above ~10 cm or above ~25 MHz, single-ended LVCMOS needs source-series termination or it will exhibit reflections and reduced swing. Matches our symptoms. ([Lattice AR-851](https://www.latticesemi.com/en/Support/AnswerDatabase/8/5/851)) |
| **Xilinx forum: "IOB source impedance"** | Community-consensus output impedance for 7-series LVCMOS33 from IBIS analysis: roughly **40–60 Ω at DRIVE 8 mA** falling toward ~20–30 Ω at DRIVE 16 mA. Treat as ballpark, not spec. ([Forum thread](https://forums.xilinx.com/t5/Other-FPGA-Architecture/IOB-source-impedance/td-p/886217)) |
| **Digilent Pmod spec (general)** | All standard Pmod ports have **200 Ω series resistors** which limit drive strength to ≈ ±2 mA. High-speed Pmods omit these. Strong hint to check the J13 pin schematic. ([Pmod spec PDF](https://digilent.com/reference/_media/reference/pmod/pmod-interface-specification-1_2_0.pdf)) |

---

## C. Recommended Changes for Our 50 MHz Forwarded Clock

Listed roughly in order of **impact × ease**:

### C1. Verify the on-board series resistor on the J13 clock pin (zero-cost first step)
- The PYNQ-Z2 schematic `TUL_PYNQ_Schematic_R12.pdf` documents 200 Ω protection resistors on numerous GPIO. **Check whether Y7 (`pad_clk_tx`) and Y9 (`pad_clk_rx`) carry them.**
- If yes: that 200 Ω in series with an ~80 pF load gives `τ ≈ 16 ns` — completely explains the 1 V swing at 10 ns/half-period. The fix would be to **bypass the resistor (zero-ohm jumper across the pad)** or **use a different J13 pin without the resistor**.
- If no: proceed to C2.

### C2. Boost DRIVE and add external source-series termination
**XDC (per-pin overrides on the TX and clock pads):**
```tcl
# Master clock TX pad — boost drive, FAST slew
set_property -dict { PACKAGE_PIN Y7 IOSTANDARD LVCMOS33 \
                     DRIVE 16 SLEW FAST } [get_ports pad_clk_tx]

# Data TX pads — same treatment (8 of them)
foreach pin {U7 C20 Y8 A20 U8 W6 Y6 F20} idx {0 1 2 3 4 5 6 7} {
  set_property -dict [list PACKAGE_PIN $pin IOSTANDARD LVCMOS33 \
                          DRIVE 16 SLEW FAST] [get_ports pad_tx[$idx]]
}
```
**External (between board and ribbon, TX end only):**
- Solder a **33 Ω 0603 resistor in series with `pad_clk_tx`** at the TX board.
- This gives Rs + R_on ≈ 33 + ~25 = **58 Ω**, a near-match to 50–100 Ω ribbon Z0.
- Add the same 33 Ω in series with each of the 8 `pad_tx[]` lanes if they show degraded eyes (lower priority — data lanes are sampled mid-bit so they tolerate more distortion than the clock).

### C3. Reduce receiver-side internal fan-out
- Y9 currently drives **BUFG → MMCM → IDELAYCTRL → ILA → lane samplers** all from one IBUFG. Each downstream BUFG/BUFIO branch adds load.
- **Action:** Insert a `BUFG` between `IBUFG` and the splitter, so the IBUFG only drives one global buffer. Then fan out from the BUFG to MMCM input — the global buffer is heavily driven and isolates the pad capacitance from the rest of the clock tree.
- Pattern is in ADI's `ad_data_clk.v` (reference A2).

### C4. Verify pin choice — Y9 is MRCC, but is it the best one?
- The current XDC comments say `Y9 = SRCC_13_P` (RX flip target) and `Y7 = MRCC_13_P` (TX flip target). **MRCC is preferable to SRCC for clock inputs** because MRCC pins can drive BUFR (regional clock buffer) directly without going through BUFG first — that helps reduce loading.
- Suggest swapping pad_clk_rx to a true MRCC if a free one is available on J13. (Some MEM notes already flag Y9 as MRCC; confirm against XC7Z020 pinout.)

### C5. (Optional) Add receiver-end Thevenin or parallel termination
- A single 100 Ω resistor from the RX pad to GND (or split-Thevenin: 200 Ω to 3.3 V + 200 Ω to GND, Vth = 1.65 V) absorbs reflections.
- Cost: more DC current, but reduces ringing further. Only worth fitting if C1+C2+C3 don't close the eye.

### C6. (Architectural — only if C1–C5 fail)
- **Half the forwarded-clock rate to 25 MHz** and use DDR sampling on data lanes (keeps line rate, halves the SI burden on the clock). The Wlink core already supports DDR mode.
- **OR** migrate `pad_clk_tx/pad_clk_rx` to an LVDS pair (would require pin re-allocation onto an adjacent P/N pin in the same bank, and a new pair of XDC IOSTANDARDs `LVDS_25` plus `IBUFDS`/`OBUFDS` wrappers in RTL).

---

## D. Verdict — Is 50 MHz LVCMOS33 Ribbon-Cable Forwarding Reasonable?

**Yes — and it should work on the existing chip without abandoning LVCMOS.**

Rationale:
1. **50 MHz is well within LVCMOS33 capability.** UG471 itself characterises LVCMOS33 with FAST slew for memory interfaces well above 100 MHz. Industry comparable: HyperBus runs single-ended 3.0 V CMOS at 200 MHz; legacy parallel-LVDS variants put 50 MHz LVCMOS over similar-length flat cables routinely; Digilent claims standard Pmod can carry 24 MHz over 4 m of CAT5.
2. **The symptom (1 V swing on the clock only) is classic of an under-driven RC load, not a fundamental signaling-rate issue.** With τ ≈ R·C: 8 mA into 3.3 V is ~25–50 Ω effective Rout; into 80 pF that's τ ≈ 2–4 ns — *should* close 90% in 5–10 ns, but only if there isn't a much larger series-R hidden in the path. The probable culprits in order of likelihood are: (a) a 200 Ω on-board protection resistor; (b) excessive internal fan-out adding tens of pF at the receiver; (c) reflections from an unterminated ~100 Ω ribbon.
3. **The fix kit is mostly external.** Bumping DRIVE 8 → 16, adding a 33 Ω TX-side Rs, and inserting a clean `IBUFG → BUFG` boundary at the RX should each give independent improvement and should be tried in that order.
4. **LVDS is a heavier pivot** (pinout change, RTL `IBUFDS`/`OBUFDS` wrappers, paired routing on the ribbon) and is only justified if the cumulative effect of C1–C5 still leaves a closed eye on the bench. Hold it in reserve.

**Recommended next bench experiment:**
- Probe `pad_clk_tx` (TX side, before the ribbon) and `pad_clk_rx` (RX side, after the ribbon) with a scope. If TX is healthy 3.3 V and RX is 1 V, the ribbon + RX loading is the issue → apply C2 (DRIVE 16) + C3 (BUFG isolation) + an external 33 Ω at TX. If TX itself is only 1 V, the on-board 200 Ω resistor is in play → C1.

---

## Sources

- [XAPP585 — LVDS Source Synchronous 7:1 SerDes (Clock Multiplication)](https://docs.amd.com/api/khub/documents/JlDZcsu8DsMLJ6KXAZfq5Q/content)
- [Analog Devices wiki — Source-synchronous interface design with FPGAs](https://wiki.analog.com/resources/fpga/docs/ssd_if)
- [PonyLink — single-wire chip-to-chip interface for FPGAs (GitHub)](https://github.com/cliffordwolf/PonyLink)
- [UG471 — 7 Series FPGAs SelectIO Resources User Guide (v1.10, May 2018)](https://0x04.net/~mwk/doc/xilinx/ug/ug471_7Series_SelectIO.pdf)
- [UG899 — Vivado Design Suite User Guide: I/O and Clock Planning](https://www.xilinx.com/support/documents/sw_manuals/xilinx2022_1/ug899-vivado-io-clock-planning.pdf)
- [Skyworks AN1236 — Si533xx LVCMOS Output Best Practices](https://www.skyworksinc.com/-/media/Skyworks/SL/documents/public/application-notes/an1236-si533xx-44qfn-lvcmos-output.pdf)
- [Renesas/IDT AN-845 — LVCMOS Termination](https://www.idt.com/document/apn/845-termination-lvcmos)
- [Lattice AR-851 — Can I drive long PCB traces with an LVCMOS output?](https://www.latticesemi.com/en/Support/AnswerDatabase/8/5/851)
- [Xilinx Forum — IOB source impedance discussion](https://forums.xilinx.com/t5/Other-FPGA-Architecture/IOB-source-impedance/td-p/886217)
- [Xilinx Forum — Slew rate numbers for Kintex-7 LVCMOS33](https://forums.xilinx.com/t5/Other-FPGA-Architectures/Slew-rate-numbers-for-Kintex-7-LVCMOS33/td-p/645115)
- [Digilent Pmod Interface Specification 1.2.0](https://digilent.com/reference/_media/reference/pmod/pmod-interface-specification-1_2_0.pdf)
- [Digilent Pmod Standard reference](https://digilent.com/reference/pmod/specification)
- [PYNQ-Z2 schematic R12 (TUL)](https://dpoauwgwqsy2x.cloudfront.net/Download/TUL_PYNQ_Schematic_R12.pdf)
- [PYNQ-Z2 Reference Manual v1.1](https://dpoauwgwqsy2x.cloudfront.net/Download/PYNQ_Z2_User_Manual_v1.1.pdf)
- [Wikipedia — Source-synchronous](https://en.wikipedia.org/wiki/Source-synchronous)
- [Infineon HyperBus specification (low signal count, high performance DDR bus)](https://www.infineon.com/dgdl/Infineon-HYPERBUS_SPECIFICATION_LOW_SIGNAL_COUNT_HIGH_PERFORMANCE_DDR_BUS-AdditionalTechnicalInformation-v09_00-EN.pdf?fileId=8ac78c8c7d0d8da4017d0ed619b05663)
