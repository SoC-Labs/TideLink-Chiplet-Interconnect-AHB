# TideLink v1-RC GPIO-PHY Bring-up — Known Limits and FPGA/ASIC Differences

Author: SoC Labs (David Mapstone)
Branch: `feat/td-combined` @ `56a8aca`+ (parent), submodule `deps/axi-chiplet-controller` @ `678a9b3`+
Date: 2026-05-20
Audience: SoC Labs engineers preparing for v1 ASIC port at ~100 MHz

This document catalogues what v1 does not yet do well, what is an artefact of
the Pynq-Z2 FPGA rig rather than the architecture, and what is explicitly
deferred to v2. Measured data is from the 30-deploy reliability
characterisation run on 2026-05-20 at 25 MHz (MASTER=192.168.4.101,
SLAVE=192.168.6.101). Architecture and design context lives in
`docs/GPIO_PHY_ARCHITECTURE.md`, `docs/GPIO_PHY_SEPARATION_DESIGN.md`, and
`docs/CONVERGENCE_SPEEDUP.md`; this document does not re-derive those
references but cites them where the explanation would otherwise be
self-contained.

---

## 1. FPGA-only artefacts — not architectural shortcomings

These items exist because of Zynq-7020 silicon constraints. They disappear on
an ASIC implementation; no architectural change is needed.

### 1.1 Bank-13 / bank-35 IDELAYCTRL column split

The Pynq-Z2 RPi GPIO header (J13) forces two of the eight RX data lanes
(`pad_rx[1]` = C20, `pad_rx[3]` = A20) onto bank 35, while the remaining six
RX lanes and the forwarded RX clock land on bank 13. Vivado places one
IDELAYCTRL per IDELAY column; bank 13 pins use IDELAYCTRL_X0Y0 and bank 35
pins use IDELAYCTRL_X1Y2. These are physically distinct cells with independent
VT-dependent tap-time references. At runtime the bank-35 cells produce taps
that are typically 5–10 % off the bank-13 cells in both magnitude and
centring, even when the same IODELAY_GROUP string and reference clock are
applied (see `GPIO_PHY_ARCHITECTURE.md` §7.1).

No XDC `set_property PACKAGE_PIN` rotation avoids this. Six of the eighteen
J13 pins are physically bonded to bank 35 and all eight RX data pins plus the
RX clock are needed; two RX data lanes must land there. The per-deploy
reliability characterisation shows the consequence: die_a lane 3 (the
worst-case bank-35 lane) locks only 53% of deploys one-shot versus 97–100%
for the all-bank-13 lanes. This is a pin-out artefact, not a calibration
algorithm deficiency.

On an ASIC there are no bank groups. The IO ring presents all pads to the same
delay reference, and the per-lane IDELAYE2 logic is replaced by a foundry
programmable delay cell driven by the same calibrator phase values. The bank-35
VT divergence disappears entirely.

### 1.2 IDELAYE2 hard-IP wrapper

`fpga/rtl/tidelink_idelay_rx.sv` instantiates Xilinx `IDELAYE2` and
`IDELAYCTRL` primitives to provide per-lane RX analogue delay control
(see `GPIO_PHY_ARCHITECTURE.md` §5.1). These are 7-series Xilinx-specific
hard-IP cells. The calibrator drives a 4-bit `phase_tap` per lane; the
wrapper maps this to a 5-bit tap count (multiply by 2 to span the 0–30 range)
and holds `LD=1` so the IDELAYE2 continuously tracks the live calibrator
output.

The ASIC equivalent is a foundry-provided programmable delay cell — typically
a configurable inverter chain or a binary-weighted RC ladder — driven by
exactly the same 4-bit `phase_tap` interface. The gate parameter `USE_IDELAY`
(default 0; set to 1 by `tidelink_vivado_wrapper.v`) prunes the entire
IDELAYE2 instantiation at elaboration time on ASIC, restoring a
passthrough (`pad_rx_o = pad_rx_i`). The ASIC integrator replaces this
passthrough with the foundry delay cell wrapper at that boundary.

### 1.3 IP-boundary BUFG (USE_CLKBUF) — boundary-only after ASIC purification

The Wav `WavD2DGpioRx` deserialiser routes the recovered pad clock through
three `WavClockMux` cells (lines 139, 145, 151 of `WavD2DGpioRx.v`). On
7-series Vivado these LUT-inferred mux cells appear on general routing on the
clock pin, triggering `Place 30-568` clock-DRC and producing non-deterministic
per-lane skew.

The previous fix put a Xilinx `BUFG` at the IP boundary (`tidelink_rxclk_buf`,
now in `fpga/rtl/`) AND two internal `BUFG` cells inside `WavD2DGpioRx`
(`g_clkbuf` generate branch) so each lane's clock reached its capture flops
on the dedicated clock network. On the 16-deploy reliability characterisation
that combination delivered the ≈ 89 % 16/16-lane lock rate.

**Post-ASIC-purification (2026-05-20):** the in-PHY `g_clkbuf` branch has been
removed from `WavD2DGpioRx.v` because it was FPGA-specific contamination
inside a vendor Chisel-generated PHY file. The IP-boundary `BUFG`
(`fpga/rtl/tidelink_rxclk_buf.sv`, gated by the boundary-only `USE_CLKBUF`
parameter on the `axi_chiplet_controller` instance) is retained — the FPGA
build now relies on the boundary BUFG plus the calibrator's best-of-sweep
phase + bit-slip + IDELAYE2 path, not the in-PHY BUFG.

Expected FPGA reliability impact: the 16/16-lane lock rate is likely to
regress from the in-PHY BUFG figure (≈ 89 %) toward the boundary-only
baseline (≈ 60–70 % per historical b_clkbuf coverage). Convergence at the
pair level (full link) is preserved by the calibrator's best-of-sweep
search; total bring-up time may increase due to more per-lane retries
within the autonomous bring-up script. If the regression measures worse
than ≈ 60 % the in-PHY BUFG can be re-introduced as an explicit FPGA-only
wrapper in `fpga/rtl/` (e.g. by adding a thin RTL wrapper that drives the
`WavD2DGpio` clock inputs through `BUFG`s before they enter the vendor
file); it should NOT live inside the vendor file again.

BUFG is a Xilinx global clock buffer primitive. On ASIC, the synthesised
clock tree replaces it. The `USE_CLKBUF` parameter (default 0 in
`tidelink_top`, ASIC) prunes the boundary BUFG entirely at elaboration —
which is the correct path for the foundry standard-cell flow.

### 1.4 25 MHz pad_clk rate

The forwarded clock at `pad_clk_tx` / `pad_clk_rx` runs at 25 MHz on the FPGA
rig. This is driven by Vivado timing-closure limits on LVCMOS33 GPIO routed
through RPi-header pins over a passive ribbon cable, not by any protocol
constraint. The 40 ns UI leaves ample timing margin for the IDELAYE2 tap range
to span the entire setup window.

The v1 ASIC target is approximately 100 MHz (`project_tidelink_v1_asic_target`
memory). At 100 MHz the UI shrinks to 10 ns. The calibrator search space
(128 points: 16 phase offsets × 8 bit-slip values, with `DWELL_CYCLES = 64`)
and the IDELAYE2 → foundry delay cell replacement remain valid; what changes is
the analogue delay cell's tap resolution and range, which must be characterised
against a 10 ns UI rather than 40 ns. The `USE_IDELAY` / `USE_CLKBUF` /
`USE_T3A` paths are quarantined behind their gate parameters and must not be
removed from the source tree; they remain active on any future FPGA
characterisation rig.

---

## 2. Real architectural shortcomings — carry over to ASIC

These items are present in the architecture regardless of implementation
technology. They will require RTL or algorithm changes before or after the v1
tape-out.

### 2.1 One-shot calibration success rate: 16.7% perfect, 80% near

The best-of-N calibrator (§9.9 of `GPIO_PHY_ARCHITECTURE.md`) performs one
full 128-point sweep on each role-lock event and latches the widest-eye
(slip, phase) pair per lane. Reliability characterisation at 25 MHz over
N = 30 independent deploys (no retry):

| Metric | Result |
|---|---|
| 16/16 lanes locked (perfect, one-shot) | 5/30 — **16.7%** |
| 14+/16 lanes locked (near, one-shot) | 24/30 — **80.0%** |
| FCSM state >= 2 on both sides | 18/30 — **60.0%** |
| die_a (master RX) lock count | min=5, max=8, **mean=7.03/8** |
| die_b (slave RX) lock count | min=6, max=8, **mean=7.27/8** |
| Combined lock count | min=12, max=16, **mean=14.30/16 (89.4%)** |

The mean combined lock count (14.30/16) confirms the calibration stack is
working; the residual failure is concentrated in the tail. Per-lane analysis
(`CONVERGENCE_SPEEDUP.md` §3.1) identifies die_a lane 3 as the single worst
lane (53% lock rate), attributable to the bank-35 IDELAYCTRL VT spread
(§1.1). Removing the FPGA-rig artefact will improve the distribution but will
not eliminate it entirely: the shared single-phase calibrator sweep is
fundamentally a one-shot Bernoulli trial per deploy. The architectural fix is
a per-bank-group (or per-lane) independent phase search, deferred to v2
(§4.2).

The closed-loop `bringup_pair_converge.sh` script treats each deploy as an
independent retry and achieves convergence in 2–17 iterations with geometric
distribution (mean ~3 min at current 30 s per-deploy wall-clock). This is the
v1 operational bring-up path; it is not a substitute for improving the
per-shot rate.

### 2.2 No automatic on-line retraining after mid-operation link drop

Calibration is triggered by the rising edge of `role_locked` or by an explicit
`SWI_RECAL` write (MMIO `0x4403_2100` bit 1). Once `calibration_done` asserts
and `training_mode` drops to 0, the calibrator enters `S_DONE` (sticky) and
stops sweeping. If a lane degrades mid-operation (e.g. thermal drift shifts
the eye centre past the calibrated tap), there is no hardware mechanism to
detect the degradation and re-trigger a sweep without driving `SWI_RECAL` from
software or asserting `swreset`.

The `SWI_LANE_STATUS` register (`0x4403_2108`, bits [7:0] `lane_locked`)
exposes the per-lane lock state in real time, so a software watchdog could
poll and issue `SWI_RECAL` on lock-bit loss. This is not currently implemented
in the bring-up scripts. The architectural change required is: detect sustained
`lane_locked[i] = 0` (e.g. via a counter on the `S_DONE`-state lane_checker
output) and re-trigger `S_ARM` autonomously. This is a calibrator FSM
extension, not a PHY change.

### 2.3 Sequential per-lane calibration sweep — no parallel-lane search

The calibrator's 128-point sweep uses a single shared iterator
(`sweep_slip[2:0]` × `sweep_phase[3:0]`; `GPIO_PHY_ARCHITECTURE.md` §4.1.1).
All eight lanes are evaluated at the same (slip, phase) point simultaneously
within each dwell window. This is efficient for lanes whose optimal point is
near the shared sweep centre, but suboptimal for lanes whose eye centre lies at
a different phase from the majority: the calibrator discovers the best
phase for the majority and the minority lane settles for whatever score it
achieved at that phase.

The correct fix (identified in `GPIO_PHY_ARCHITECTURE.md` §10.2) is a
per-bank-group calibrator with independent phase iterators — one iterator per
IDELAYCTRL column group — while keeping the bit-slip search shared. On ASIC,
where bank groups do not exist, the equivalent split is per-group of lanes
sharing a common analogue delay reference. Until this is implemented, the
bank-35 lane pair will continue to show reduced per-shot lock probability
relative to the bank-13 majority.

### 2.4 FCSM cr/crack handshake uses sticky-OR latch — cannot distinguish stale from fresh

Submodule commit `0e126b0` made `cr_pkt_seen_rx` and `crack_pkt_seen_rx`
sticky-latched at the ECC syndrome gate in `WlinkGenericFCSM_6.v`. Once a
valid cr packet is seen, the flag holds until the FCSM consumes it. This was
the fix for the single-error cr-miss mode (a per-lane bit error in the cr
header is detected by Hamming(33,24) ECC but the frame is discarded rather
than retried, causing the FCSM to miss the cr seed it needed to advance past
state 1 — see `docs/AGENT_BRIEF_FCSM_RX_BUG.md`).

The sticky latch is correct for the miss-mode it fixes, but it introduces a
new property: once set, the flag cannot be cleared without a `swreset` cycle.
If a cr packet is seen on a marginal lane during a partial-convergence window
(before `calibration_done`), the stale `cr_pkt_seen_rx` flag may be consumed
by the FCSM in a later training window where the packet was not re-received.
The FCSM state machine cannot distinguish a fresh cr from a latched stale one.
This is visible in the characterisation data as the FCSM-both->=2 rate (60.0%)
being lower than the 14+/16 near-convergence rate (80.0%): some deploys lock
14+ lanes but still sit at FCSM state < 2, which is consistent with a stale-cr
scenario where the FCSM advanced on one side from a pre-convergence cr that
did not survive to full link-up.

The architectural fix is a sequence-number or timestamp on the cr frame, or a
re-seedable latch (cleared on every swreset or training_mode deassertion).
Neither is in tree for v1.

### 2.5 ECC restored to upstream Hamming(33,24) SECDED — HW validation pending

`WlinkEccSyndrome.v` was hand-patched on 2026-05-05 to bypass ECC (to isolate
an unrelated FCSM bug). The bypass was restored to upstream Chisel-generated
Hamming(33,24) SECDED on headers (single-bit correct, double-bit detect) and
is present in the `feat/td-combined` tree at submodule `678a9b3`+. The
restoration is cocotb-regressed but has not been exercised on hardware with the
current `feat/td-combined` + `best-of-sweep` + `S_HOLD` bitstream. The
reliability characterisation run (N=30, 2026-05-20) used this bitstream;
the ECC counters at SWI_LANE_STATUS slot 5 (`ECC_COUNTERS`, offset 0x114) were
not read in that run. HW confirmation that ECC is active (corrected-count > 0
under marginal-lane conditions) is still outstanding.

### 2.6 I2C autoneg integration is bench-validated on inert pins — active-rig HW test pending

Branch `feat/i2c-autonomous-lock-integ` at `e22528a` (submodule `34126b6`)
adds I2C-based master/slave role negotiation via dedicated pins. The initial
rig used W9/V7 channel pins, which proved inert (weak board pull-up, floating
high; no I2C activity routed through). The design was repinned to Arduino
connector P15/P16, which carry on-board 2.2 kΩ pull-ups and are unused in the
active Ethernet / flash path. Bitstreams for the repinned variant are
rebuilding (see `project_tidelink_i2c_autonomy` memory entry). Full HW
validation of the autoneg protocol on active P15/P16 pins has not been
completed. The current `feat/td-combined` bring-up (`bringup_pair_converge.sh`)
does not use the I2C autoneg path; role straps are set manually via MMIO at
deploy time.

---

## 3. Open verification items

### 3.1 cocotb test duplication between cocotb/phy_align/ and top-level cocotb/*.py

The PHY-align test suite lives under `cocotb/phy_align/` (pair-level
integration: `test_pair_align.py`, `test_pair_align_asymmetric*.py`,
`test_pair_align_staggered_bringup.py`). Several top-level `cocotb/*.py` files
cover overlapping calibrator and lane-checker scenarios that were written before
the `cocotb/phy_align/` suite existed. The duplicate coverage is not harmful
but makes it harder to determine the authoritative regression for a given
failure: a CI failure in the top-level stubs does not necessarily point at the
same root cause as the corresponding `phy_align` test. The canonical test map
is `cocotb/PHY_TESTS.md`; the top-level stubs that overlap with entries in
that map should be migrated or removed.

### 3.2 Three RTL files with stale or incorrect header comments

The following files carry comments that do not match their current function:

- `src/rtl/tidelink_lane_checker.sv` — module header claims the file is
  `wlink_*` (pre-rename from an earlier naming convention). The module name and
  interface are correct; the header comment is stale.
- `src/rtl/tidelink_phy_align_regs.sv` — 141-line file implementing a Region 8
  APB slave that is superseded by the Region 8 logic now embedded in
  `deps/axi-chiplet-controller/logical/top/axi_chiplet_controller.sv` (line
  1273 instantiates the chiplet-internal register block; `tidelink_phy_align_regs`
  is not included in either the ASIC flist or the FPGA Vivado IP). The file is
  dead code in the current build. It should be removed or archived to avoid
  confusing engineers who find it in `src/rtl/` and assume it is active.
- `src/rtl/tidelink_fifo.sv` — naming collision with a second
  `src/rtl/fifo/tidelink_fifo.sv`. The top-level `src/rtl/tidelink_fifo.sv`
  is the FIFO subsystem wrapper; `src/rtl/fifo/tidelink_fifo.sv` is the
  SRAM-backed FIFO controller. Both are in the ASIC flist; the duplicate module
  name is resolved by elaboration-order dependency but is fragile and generates
  tool warnings in some EDA flows.

### 3.3 Extended reliability characterisation (50+ deploys post-I2C) not yet run

The characterisation data cited in this document is 30 deploys on the
`feat/td-combined` bitstream before I2C autoneg repinning. The v1-RC
validation target is 50+ deploys with the full autoneg path active and ECC
counters read per deploy. This run has not been executed. The current N=30
baseline gives a per-shot mean of 14.30/16 and a 16.7% perfect rate; the
extended run is needed to confirm these numbers are stable and to produce the
per-lane lock probability table (`CONVERGENCE_SPEEDUP.md` §3.1) at sufficient
statistical confidence (binomial 1-σ at N=30 is ±9 pp per lane).

### 3.4 ECC + autoneg interaction not HW-tested on the same bitstream

The ECC restoration (§2.5) and the I2C autoneg repinning (§2.6) each represent
independent changes to the `feat/td-combined` + submodule state. Neither has
been exercised simultaneously on the same hardware bring-up. The specific
concern is the interaction during the FCSM credit-grant window: if the autoneg
I2C transaction overlaps with cr-packet reception and the ECC corrects a
single-bit error in the cr header, the sticky `cr_pkt_seen_rx` flag should
latch and the FCSM should advance normally. This path is cocotb-covered but
not HW-confirmed.

### 3.5 DFT plan, UPF power plan, and ASIC hard-IP inventory in flight as separate documents

`docs/ASIC_HARD_IP_INVENTORY.md` identifies the Xilinx-specific cells and
their ASIC substitution candidates. A UPF power intent file and a DFT
insertion plan (scan chain, boundary scan, MBIST for the Wlink SRAM) are
referenced in architecture discussions but not yet written. The `io_scan_mode`
and `io_scan_asyncrst_ctrl` ports on `WavD2DGpioRx` are present and tied 0 in
the production flow; the scan-chain insertion plan that would make use of them
has not been drafted. These are pre-tape-out deliverables, not v1-RC items, but
they are called out here to avoid late-stage discovery.

---

## 4. What v1-RC explicitly does NOT include — deferred to v2

The following capabilities are absent from `feat/td-combined` by deliberate
deferral. They are architecturally considered but not implemented. Including
them in the v1 scope would require RTL changes with non-trivial regression cost
in the current bring-up window.

### 4.1 On-line retrain (adaptive re-calibration without swreset)

The calibrator has no autonomous degradation-detect path. Re-calibration
requires either `role_locked` re-assertion (requires a link drop and role
renegotiation) or a software-issued `SWI_RECAL`. A hardware monitor that
detects sustained `lane_locked[i] = 0` and autonomously re-triggers `S_ARM`
without dropping `role_locked` is the correct v2 feature. The `MAX_RESWEEPS`
parameter (default 0 = unlimited) and the T3 continuous re-sweep
(`GPIO_PHY_ARCHITECTURE.md` §4.1.2) handle the cold-boot case but not
mid-operation degradation.

### 4.2 Per-lane parallel calibration sweep

The shared 128-point iterator evaluates all eight lanes at the same
(slip, phase) point. A per-lane independent iterator — or a per-bank-group
iterator as the intermediate fix — would allow the calibrator to find the
per-lane optimal point in a single sweep rather than settling for the
majority-optimal point. The RTL change is a moderate calibrator refactor
(per-group score arrays, per-group phase register, per-group iterator);
estimated at 5–7 days including regression (§4.2 of `GPIO_PHY_ARCHITECTURE.md`).
Not in v1.

### 4.3 Adaptive equalisation (DFE / FFE)

The v1 GPIO PHY at ~100 MHz on a bare-metal CMOS process does not require
decision-feedback equalisation or feed-forward equalisation. The channel model
(short on-chip or chiplet-to-chiplet trace, LVCMOS33 signalling) does not
produce inter-symbol interference at 100 Mb/s rates. This is explicitly noted
here for engineers porting to higher-rate links: at 1 Gb/s+ with longer traces,
DFE/FFE become necessary and `WavD2DGpioRx`'s count-based deserialiser would
need replacement with an ISERDESE2 or GTX-class front-end.

### 4.4 PTP single-phase protocol

`tidelink_ptp.sv` and the associated `FC_NODE_REGISTRY.md` PTP FC node are in
tree on `feat/td-combined`. The PTP path is not a v1 validation target. The
PHC `hw_capture` input, the UVM `tidelink_ptp_stress` environment, and the
cocotb PTP tests are present and passing; the protocol has not been exercised
on the FPGA hardware bring-up pair. PTP bring-up on silicon is a v2 milestone.

### 4.5 TideChart dynamic chiplet ID protocol

TideChart (dynamic chiplet identity assignment via a separate peer repository
`~/SoCLabs/tidechart`) is architecturally planned as the layer above TideLink
but is not integrated into `feat/td-combined`. The `tc_axis_*` interface ports
on `tidelink_top.sv` are present as stubs. No TideChart protocol traffic has
been exercised on the FPGA rig. This is a separate project with its own release
timeline.

---

## Cross-references

- `docs/GPIO_PHY_ARCHITECTURE.md` — full calibrator FSM, FPGA structural fixes,
  bank-35 asymmetry analysis, bring-up sequence timeline
- `docs/GPIO_PHY_SEPARATION_DESIGN.md` — proposed clean architectural
  separation; the five-level USE_* parameter threading and the vendor-freeze
  refactor plan; schedule for post-v1 cleanup window
- `docs/CONVERGENCE_SPEEDUP.md` — per-deploy latency waterfall, geometric
  reliability model, per-lane lock probability table, phased optimisation plan
- `docs/ASIC_HARD_IP_INVENTORY.md` — per-primitive ASIC substitution candidates
- `pynq_host/scripts/bringup_reliability.sh` — the characterisation harness
  that produced the N=30 data cited in §2.1
- SWI_LANE_STATUS MMIO: `0x4403_2108`; SWI_RECAL: write `0x2` to `0x4403_2100`
