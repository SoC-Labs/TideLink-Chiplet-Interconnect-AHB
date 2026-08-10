# Gate Report 05 — Multi-Instance / Interrupt / Sideband / PTP Integration

**Scope:** SoC-embedding boundary of TideLink + TideChart + PHC, as assembled in
`~/SoCLabs/nanosoc-ethernet-chiplet` (`src/rtl/nanosoc_eth_chiplet.sv`, `src/rtl/tidechart_shim.sv`)
and exercised by the `g2_soc_pair` two-die harness. Read-only design review.
Date 2026-07-30.

**Bottom line:** the data-plane crossing is well-instrumented, but the *sideband*
surface (IRQ routing, per-die election straps, PHC lock) is where integration
surprises hide. The single highest-risk item is structural and unfixable from the
generator: **`tidechart_shim` has no `device_strap` port, so the controller's
per-die election tiebreak dangles to X in every embedding.** The one full-SoC
election sim that passes does so on *timing asymmetry*, not the strap — a textbook
green-but-blind. All SoC-level testbenches tie `d2d_irq = 16'h0`, so the entire
interrupt fabric is unstimulated above the block level.

---

## 1. The integration surface into the SoC

### 1a. Interrupts — `d2d_irq[15:0]`
Assembled in `nanosoc_eth_chiplet.sv:847-861`, then split inside
`nanosoc_multicore_soc` by the NVIC concat muxes
(`nanosoc-multicore-system/sys_desc/nanosoc_multicore_soc.yaml:305-316`, CPU0 map
`:1990-1997`, CPU1 map `:2023-2031`):

| d2d_irq bit | source | net | NVIC | core | assert style |
|---|---|---|---|---|---|
| 0 | TideLink doorbell | `tl_doorbell_irq` | CPU0 IRQ10 | net | **LEVEL** (acc≠0) |
| 1 | released credits | `tl_released_credits_irq` | CPU0 IRQ11 | net | **LEVEL** (acc≠0) |
| 2 | packet committed | `tl_packet_committed_irq` | CPU0 IRQ12 | net | LEVEL |
| 3 | PTP | `tl_ptp_irq` | CPU0 IRQ13 | net | LEVEL (**tied 0 if `STUB_PTP=1`**) |
| 8 | wlink | `tl_wlink_irq` | CPU1 IRQ9 | chip | event/level |
| 9 | nego error | `tl_nego_error_irq` | CPU1 IRQ10 | chip | event |
| 10 | train fail | `tl_train_fail_irq` | CPU1 IRQ11 | chip | event |
| 11 | perf | `tl_perf_irq` | CPU1 IRQ12 | chip | LEVEL (**tied 0 if `STUB_SERVO/perf` off**) |
| 12 | i2c not-busy | `tl_i2c_nbsy_irq` | CPU1 IRQ13 | chip | level |
| 13 | i2c rd-empty | `tl_i2c_nrd_empty_irq` | CPU1 IRQ14 | chip | level |
| 14 | **TideChart** | `tc_tidechart_irq` | CPU1 IRQ15 | chip | **1-CYCLE PULSE (edge)** |

- TideLink level IRQs are accumulator-driven and **clear-on-read**:
  `released_credits_irq = (released_credits_acc != 0)`
  (`tidelink/src/rtl/fifo/tidelink_apb_regs.sv:354`),
  `doorbell_irq = (doorbell_response_acc != 0)` (`:380`). The accumulators at APB
  `0x020`/`0x024` are **W-add / R-clear**; the doorbell reg `0x014` is W1C
  (`:162`). An ISR that does not perform the clearing read leaves the line high →
  the level-sensitive M0 NVIC re-pends immediately → interrupt storm.
- TideChart IRQ is an **edge pulse**: `(election_done & ~prev) | (enum_done & ~prev)
  | (|hotplug_change_r)` (`tidechart/src/rtl/tidechart_apb_regs.sv:340-352`).
  Mixing a self-clearing pulse and stuck-until-cleared level lines into one NVIC
  vector is the classic edge/level hazard.

### 1b. Multi-instance straps / config
- `role_strap_i` (chiplet boundary `nanosoc_eth_chiplet.sv:167`) is threaded **only
  to TideLink** (`:737`), where it sets master/slave role-lock.
- `DEVICE_CLASS` param (`:804`) is the TideChart grandmaster-election priority
  (lower wins). Default `16'h0001` on both dies.
- `device_strap` — the per-die election tiebreak — **exists on the controller
  (`tidechart_controller.sv:63` → FSM `tidechart_election_fsm.sv:60`,
  `own_random_r <= {device_strap, lfsr_r[7:0]}` at `:310-311`) but has NO port on
  the shim** and is therefore left unconnected when the shim instantiates the
  controller (`tidechart_shim.sv:159-213` — no `.device_strap`). See §2a.

### 1c. Congestion / AXIS sideband
- `tc_axis_rx/tx` = 48-bit AXI-Stream (`FC_DATA_W=48`); the shim flattens the
  per-port unpacked arrays to `*_flat` vectors (`tidechart_shim.sv:77-92`).
- `local_link_state_i` (5-bit congestion), `local_link_state_change_i`,
  `local_bcast_ack_o` — flattened likewise.
- **`link_active` gating contract (load-bearing):** the shim's `link_active` must
  be driven by TideLink `tl_data_mode_o` (FCSM≥4), **not** `role_locked`. Feeding
  `role_locked` arms the election ~5 µs early (before any CLAIM can cross the die
  boundary) → silent dual-root. This is the "G1 sequencing contract"
  (`docs/TIDECHART_G1_SEQUENCING_CONTRACT.md`; enforced in the pair TB
  `tb_tc_pair.sv:373-378`).

### 1d. PTP / PHC hop
- Cross-die timebase = PHC hardware **servo source 0**, carried on the `d2d_phc_*`
  nets (`nanosoc_eth_chiplet.sv:305-315`, wired `:694-704`): seconds/nanoseconds,
  `hw_capture`, `hw_set_*`, `hw_adj_*`.
- `phc_locked_i` into TideLink is **tied `1'b1`** — "single-link deployment: PHC
  lock always granted" (`nanosoc_eth_chiplet.sv:707`). ⚠ This **contradicts** the
  standing memory note ("phc_locked_i tied 0 → gate on R_SERVO_OFFSET"). See §2d.
- `ethernet_ss_ahb_phc` is the PHC subsystem; HA1588 RTC disciplines the PHC
  through the servo. Its first functional (driven) sim exists only at
  `tidelink/cocotb/eth_ptp_phc_subsystem` (`tb_top.sv:4,118`).

---

## 2. Embedded-specific failure modes (concrete scenarios)

### 2a. 🔴 X-propagation from the unwired `device_strap` (STRUCTURAL)
The shim cannot pass a strap it has no port for, so `tidechart_controller.device_strap`
is an unconnected input → `'z`/X in sim, tool-defaulted constant in synth.
`own_random_r[15:8]` (`election_fsm.sv:310`) then takes that value, feeds
`best_random_r`, and the `rx_class/rx_random < best` comparisons
(`:181-184`) become X-poisoned. Two outcomes, both bad:
- **Sim:** X in the tiebreak; whether a die latches `is_root` depends on
  X-optimism and reset symmetry — nondeterministic across simulators.
- **Silicon:** the strap synthesises to the *same* constant on both dies (both from
  one netlist) → identical claims → **dual root** (exactly the case the FSM-level
  `test_identical_straps_can_dual_root` proves fatal).
The only thing preventing dual-root today is either (i) building the two dies with
*different* `DEVICE_CLASS` params (FPGA does this: `kr260-eth-chiplet` die_a=1 vs
`-flip` die_b=2, `tidelink_design.tcl:152-154`) — a two-netlist requirement that is
a silent footgun if ever violated — or (ii) timing asymmetry (§3). Recommended fix
(per design intent): add a `device_strap` port to the shim and wire
`{7'b0, role_strap_i}` at `nanosoc_eth_chiplet.sv:801`; `role_strap_i` is already
per-die (`g2` TB drives 0/1 at `tb_g2_soc_pair.sv:315,454`).

### 2b. 🔴 IRQ stuck-high / storm and missed-pulse at the NVIC
- **Stuck/storm:** a level line (`doorbell`, `released_credits`) whose accumulator
  is never read-cleared holds the NVIC input high → re-pends every ISR exit.
- **Missed pulse:** `tc_tidechart_irq` is one `sys_hclk` cycle. If the election
  settles while the NVIC is masked, or if any resync stage sits between the shim
  and the core, the edge can be lost; there is no level "election_done IRQ pending"
  bit to re-read — SW must poll `TC_STATUS[0]` (`tc_apb_regs.sv`) to recover.
- **Spurious at reset:** benign today — `election_done` and its `_prev` both reset
  to 0 (`tc_apb_regs.sv:342-347`) and TideLink accumulators reset to 0, so no line
  is asserted out of reset. Worth an explicit assertion so a future change can't
  silently break it.
- **Cross-talk:** the CPU0/CPU1 split must be clean — driving a data-plane line
  must not perturb the management bus and vice-versa.

### 2c. 🔴 Dual-root in a real 2-die SoC
Covered by 2a's mechanism. Additional angles: `force_root` (TC_CTRL[2],
`tc_apb_regs.sv:326`) must yield exactly one root even when it collides with the
strap/class ordering; `TC_CTRL[3]` RESET must re-arm (clear `election_done`) and a
fresh election must again converge to one root — the "TC_CTRL reset didn't clear
election_done" bug is fixed in RTL (`tc_apb_regs.sv:327-332`, FSM restart clears at
`election_fsm.sv:267-284`) but is only tested at FSM scope, never through the shim's
APB (§3). Election `timeout` default was raised to 4096 cycles
(`election_fsm.sv:43`) — must exceed real multi-hop FC round-trip, else a slow link
settles before a CLAIM crosses → dual root even with distinct straps.

### 2d. 🟠 PHC lock defeated / servo arms on an undisciplined clock
`phc_locked_i` tied `1'b1` (`nanosoc_eth_chiplet.sv:707`) means TideLink's HW-sync
gate is **always open** regardless of whether the PHC servo has actually locked.
The gate's purpose (per the LG-0x plan, `VERIFICATION_PLAN.md:263-268`) is to block
IDLE→ARMED until `phc_locked`; tying it high defeats that and lets HW-sync arm on an
undisciplined timebase. The memory prior said the opposite (tied 0 → dead gate);
**what the RTL shows now is tied 1 → open gate.** Either way the real value is a
constant and the *dynamic* lock signal is not consulted — flag for the integrator to
decide (a real `ha1588_servo_locked`/servo-offset-threshold feed is the intended
source; `ha1588_servo_locked` is an output at `:485`).

### 2e. 🟠 PHC won't bind / rots
`ethernet_ss_ahb_phc` historically had **no sim target anywhere**
(`docs/ETHERNET_PTP_CHAIN_GAP.md:246`); a functional driven sim now exists and
passes 5/5 with a negative control, closing the bind gap at subsystem level
(`ETHERNET_PTP_CHAIN_GAP.md:25`, 2026-07-21). But that suite is **not in any
gate** (§3), so it can silently rot back to non-binding on the next generator/flist
change — the exact stale-simv failure mode the repo has been bitten by before.

### 2f. 🟠 TideChart AXIS handshake under SoC backpressure
The election CLAIM flood only advances when `claim_tx_ready` is high
(`election_fsm.sv:328-333`). If the TideLink FC adapter deasserts `tc_axis_tx_tready`
(credit exhaustion, FIFO full), the flood stalls and the election can hang in
CLAIM_TX/LISTEN. No suite drives `tc_axis_*_tready` low (§3).

---

## 3. Current coverage vs gaps (with citations)

**What IS covered**
- FSM-scope election, strap driven **directly**:
  `tidechart/cocotb/tidechart_election_pair/test_tidechart_election_pair.py` —
  distinct-strap single root (`:64-82`), reversed (`:86-99`), force_root on loser
  (`:102-120`), **identical-strap dual-root is asserted as expected** (`:124-141`),
  restart re-arm (`:144-171`). Proves the FSM logic *given a real strap*.
- Election through **real TideLink + real shim**:
  `tidelink/cocotb/tidechart_tidelink_pair/test_tc_pair_election_datamode.py` —
  proves the `tl_data_mode_o` gate holds election in WAIT_LINKS pre-data-mode and
  that a PKT_EXT CLAIM crosses the link, asserts `n_roots == 1` (`:414-416`).
  In the tidelink sim_gate aggregate (`tidelink/Makefile:1007`;
  target `sim_gate_tc_election` `:699-704`).
- IRQ **routing** (static): `nanosoc-multicore-system/cocotb/soc_d2d_loopback/
  test_soc_d2d_loopback.py:301` force-drives each `d2d_irq[i]` and checks the NVIC
  bus bit + that the other core's bus is undisturbed (verified non-vacuous,
  `capabilities.yaml:841`). PHC servo-0 disciplines the clock: same file `:372`.
- TideLink credit/doorbell **accumulators** with careful read-to-clear:
  `tidelink/cocotb/tidelink_top_pair/test_tidelink_pair_doorbell.py:856-889`.
- `phc_locked` **gate behaviour** (LG-01..06): `tidelink/cocotb/tidelink_ptp/
  tb_top_gated.sv:52,120` drives it as a controllable input;
  `VERIFICATION_PLAN.md:263-268`.
- PHC subsystem functional bind+timestamp: `tidelink/cocotb/eth_ptp_phc_subsystem`
  (HA1588→servo→PHC, 5/5 + negative control).

**Gaps**
- **No test wires or checks `device_strap` through the shim.** The FSM pair test
  bypasses the shim; the full-SoC election test leaves it unconnected and relies on
  **master/slave timing asymmetry** to desymmetrise the LFSR (docstring, and
  `tb_tc_pair.sv:365-388,404-423` — no `.device_strap`). GREEN-BUT-BLIND (§6).
- **Every SoC-level testbench ties `d2d_irq = 16'h0`** (34+ TBs, e.g.
  `nanosoc-multicore-system/cocotb/*/tb_top.sv`; FPGA/ASIC wrappers too —
  `capabilities.yaml:825-835` waiver "no link on any board asserts d2d_irq"). The
  IRQ fabric above the block level is exercised **only** by the static force in
  `soc_d2d_loopback`; **no level-vs-edge, no clear-on-read, no stuck-high/storm, no
  missed-pulse, no reset-spurious test anywhere.**
- **`g2_soc_pair` does not touch TideChart, IRQs, or PHC at all** — it is a pure
  data-plane write/read/burst crossing (`verif/g2_soc_pair/test_g2_soc_pair.py`),
  and both dies default `DEVICE_CLASS=0x0001` with `device_strap` X
  (`tb_g2_soc_pair.sv:208,347`); only `role_strap_i` differs (`:315,454`).
- **No PTP/PHC suite is in the `sim_gate` aggregate** (`tidelink/Makefile:996-1011`
  contains none; only `tidelink_ptp` is referenced elsewhere in the Makefile;
  `eth_ptp_chain`, `eth_ptp_phc_subsystem`, `tidelink_phc_cdc`, `tidelink_ptp_servo`,
  `debug/phc_pair` are ungated). The first-ever PHC functional sim can rot silently.
- **`fpga/farm_gate.sh` has zero IRQ/PTP/TideChart/strap coverage** (grep clean) —
  it is build/timing only.
- **No backpressure test on `tc_axis_*`**: `tidechart_system` holds
  `tc_axis_tx_tready = 0b11` throughout (`test_tidechart_system.py:89,911,956`).
- **`ptp_irq`/`perf_irq` may be tied 0** by build config (`tidelink_top.sv:1759`
  under `STUB_PTP`; `:1973` under perf-off; real arms at `gen_ptp_real` `:1888` /
  `gen_servo_real` `:1992`). Any IRQ test on those bits is vacuous unless the build
  enables the feature.
- `test_irq_map.py` (`nanosoc_gen/tests/unit`) checks the *generator's* concat
  extraction on synthetic fixtures — it does **not** assert real `d2d_irq`
  placement.

---

## 4. Proposed tests (ranked by risk)

Keep all sims light — the shim/controller and the FSM pair are cheap; only the
two-real-SoC election is heavy.

**P1 — `tc_shim_strap_wiring` (X-propagation / strap at the shim).** New light
cocotb (or lint) on `tidechart_shim` + controller: (a) *structural* — assert the
netlist has a driven `device_strap` (fails today: no port); (b) *behavioural* —
drive complementary straps on two shim instances and assert exactly one root, and
that `own_random_r[15:8]`/`best_random` are never X after WAIT_LINKS. Directly
targets §2a. Add as a `check`/`elab-strict` item so it also catches the missing
port at generate time.

**P2 — `soc_irq_each_asserts_and_clears` (IRQ integration through the NVIC).** Extend
`soc_d2d_loopback` from static force to the real sources: for each of the 11 live
IRQs, cause the source to assert (doorbell ring, credit release, election settle,
train-fail inject…), confirm the correct NVIC bit sets, perform the documented clear
(R-clear `0x020`/`0x024`, W1C `0x014`, or poll `TC_STATUS`), and confirm the bit
**drops**. Explicitly separate LEVEL vs PULSE handling. Targets §2b.

**P3 — `soc_election_two_die` (election in a real 2-die SoC).** Add a TideChart +
IRQ layer to the `g2_soc_pair` harness (or a lighter `tc_pair`-based SoC wrap): bring
both dies to data-mode, run the election, assert **exactly one root** *with straps
distinct AND with `DEVICE_CLASS` identical* (so the result cannot lean on the
build-param crutch), and assert the winner's `tidechart_irq` reaches CPU1's NVIC.
Targets §2a/§2c and de-blinds the timing-asymmetry pass.

**P4 — `soc_election_symmetric_dualroot_guard`.** Same harness, **identical straps +
symmetric bring-up** → assert the design *detects* or *prevents* dual root (today it
would dual-root). This is the negative control that proves P3 isn't passing on luck.

**P5 — `phc_hop_bind_and_timestamp` (gate the PHC).** Promote
`eth_ptp_phc_subsystem` into `sim_gate`: assert `ethernet_ss_ahb_phc` elaborates,
an MII PTP event is timestamped by HA1588, the servo produces a non-zero
offset/adjust, and the PHC advances — with the existing negative control. Stops the
bind from rotting (§2e).

**P6 — `phc_locked_gate_polarity`.** Assert the *dynamic* PHC-lock semantics the
integration actually needs: with `phc_locked_i` driven low the HW-sync must NOT arm
(unless `force_en`); driven high it must arm. Then flag that
`nanosoc_eth_chiplet.sv:707` hard-ties it `1'b1`, defeating the gate — force the
integrator to choose the real source. Targets §2d.

**P7 — `irq_reset_no_spurious`.** From POR, with no stimulus, assert `d2d_irq == 0`
and both NVIC buses idle for N cycles across TideLink + TideChart. Cheap; locks §2b
reset behaviour.

**P8 — `tc_ctrl_reelection_via_apb`.** Through the shim's APB: settle an election,
write `TC_CTRL[3]` RESET, assert `TC_STATUS.election_done` clears and a fresh
election re-converges to one root; then `TC_CTRL[2]` force_root and assert the
forced die wins. Lifts the FSM-only re-arm/force coverage to shim/APB scope (§2c).

**P9 — `tc_axis_backpressure`.** Hold `tc_axis_tx_tready` low during a CLAIM flood;
assert the FSM stalls cleanly and resumes (no lost/duplicated CLAIM, no deadlock)
when ready returns. Targets §2f.

**P10 — `irq_stuck_high_storm`.** Assert a level source (credits) without the
clearing read; confirm the line stays high and (if a storm counter/model exists) the
ISR would re-enter — documents the mandatory clear contract as an executable check.

**P11 — `election_timeout_vs_rtt`.** Parametrise the FC round-trip latency up to the
real multi-hop worst case and assert the election still crosses a CLAIM before
`election_timeout` expires (guards §2c timeout regression).

**P12 — `irq_cdc_pulse_capture`.** If any of the management IRQs (`wlink`,
`nego_error`, `train_fail`) originate in the link clock domain, assert a synchroniser
exists and a 1-cycle event is not lost crossing into `hclk` before the NVIC.
(Investigate domain first; may fold into P2.)

**P13 — `perf_ptp_irq_alive`.** Build with PTP/perf enabled and assert `ptp_irq`
(bit 3) and `perf_irq` (bit 11) can actually toggle — guards against a config that
silently ties them 0 (§3).

---

## 5. Risk ranking (summary)

| Rank | Item | Failure | Why top |
|---|---|---|---|
| 1 | `device_strap` unwired at shim (§2a) | dual-root / X in-SoC | structural, unreachable by generator, and the passing SoC election test is blind to it |
| 2 | IRQ fabric untested above block level (§2b) | stuck-high storm, missed pulse | every SoC TB ties `d2d_irq=0`; only a static force exists; ships to CPU firmware |
| 3 | Dual-root in real 2-die SoC (§2c) | two grandmasters | election path only recently simmed; relies on timing/build-param, not the strap |
| 4 | `phc_locked_i` hard-tied (§2d) | arm on undisciplined clock | RTL ties `1'b1`, contradicting the design gate and the memory prior |
| 5 | PHC hop ungated (§2e) | silent rot to non-binding | first-ever functional sim not in any gate |
| 6 | AXIS backpressure on election (§2f) | election hang | no coverage; plausible under credit exhaustion |
| 7 | edge/level mix + `ptp/perf_irq` stub-0 (§1a,§3) | vacuous IRQ tests | config-dependent dead lines |

---

## 6. Green-but-blind / structural unreachability

- **`tc_pair_election_datamode` passes on TIMING, not the strap.** Its own docstring
  says the desymmetriser is master-vs-slave data-mode skew (the LFSR sampled at
  different cycles), and the shim instances carry **no `device_strap`
  (`tb_tc_pair.sv:365-423`)**. So the gate's single-root proof would survive even
  though the deterministic tiebreak is unwired — it certifies the wrong invariant.
  De-blind with P3/P4 (identical `DEVICE_CLASS`, symmetric bring-up).
- **`device_strap` is structurally unreachable** from `nanosoc_eth_chiplet.sv` /
  nanosoc_gen: the shim exposes no such port (`tidechart_shim.sv` port list
  `:69-123`), so no amount of top-level wiring can drive it. It can only be fixed by
  adding the port to the shim. Until then, single-root depends on the two-netlist
  `DEVICE_CLASS` split — correct on today's FPGA targets, but a same-bitstream
  deployment silently regresses to dual-root.
- **`soc_d2d_loopback` IRQ test is a wiring proof, not a behaviour proof.** It forces
  `d2d_irq` bits and checks the concat; it never exercises a real source, a clear, a
  pulse width, or a storm. A green here says nothing about whether the CPU can
  actually service and clear a TideLink/TideChart interrupt.
- **`phc_locked_i = 1'b1`** makes any downstream "gate blocked until lock" assertion
  vacuous in this integration; the LG-0x tests prove the gate *in isolation* with a
  driven input, but the shipping wrapper defeats it.
- **PTP/perf IRQ lines** (bits 3, 11) are 0 by construction under `STUB_PTP` /
  perf-off (`tidelink_top.sv:1759,1973`); a suite asserting "no PTP IRQ" would pass
  for the wrong reason.

---

### Note on a memory-vs-RTL discrepancy (unverified prior)
The standing note "PHC: `phc_locked_i` tied 0 (gate on R_SERVO_OFFSET)" does **not**
match the current RTL, which ties `phc_locked_i = 1'b1`
(`nanosoc_eth_chiplet.sv:707`). I did not find an `R_SERVO_OFFSET` register
referenced in the PHC/PTP cocotb suites I checked, so the "gate on R_SERVO_OFFSET"
proxy is **unverified** from my reading and should be confirmed against
`ptp-hardware-clock-ahb` register RDL before relying on it. Treat §2d as "the tie is
a constant, polarity per RTL is high" and let the integrator pick the real source.
