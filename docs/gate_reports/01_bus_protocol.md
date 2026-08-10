# TideLink SoC-Embedding Gate — Dimension 01: BUS / PROTOCOL / BACKPRESSURE

Scope: everything on the AHB-Lite / APB / AXI-Stream / XHB500 boundary that a
real SoC fabric drives differently from the cocotb BFMs. Goal: high confidence
that embedding TideLink behind a shared interconnect (SmartConnect / CMSDK bus
matrix / cross-die decode) won't surprise us. READ-ONLY analysis; nothing edited.

Repo: `/home/dam1n19/SoCLabs/tidelink` (branch `fix/v2-sync-clock-gate`).
Consumer of record: `~/SoCLabs/nanosoc-ethernet-chiplet` (`verif/g2_soc_pair`).

---

## 1. Integration surface — interfaces crossing the embedding boundary

From `fpga/vivado_ip/tidelink_vivado_wrapper.v` (the IP face a SoC integrates)
and `src/rtl/tidelink_top.sv` (the RTL it wraps):

| Port | Dir | Role | Width / notes | RTL |
|---|---|---|---|---|
| `ahb_sub` | slave | Regular chiplet access → XHB500 AHB→AXI → chiplet ctrl → link (address-translated) | 32-bit addr, HBURST+HPROT present | wrapper:234-243 |
| `ahb_tx` | slave | TideLink TX aperture → FC adapter → link | 14-bit addr, **no HBURST/HPROT**, single xfers only | wrapper:250-257 |
| `ahb_fifo` | slave | Local RX FIFO read window | 14-bit addr, **no HBURST/HPROT** | wrapper:264-271 |
| `ahb_ptp` | slave | PTP TX write port | 4-bit addr, minimal signals | wrapper:277-284 |
| `ahb_mng` | **master** | Incoming remote transaction → XHB500 AXI→AHB → **drives a local SoC slave** | 32-bit; HPROT is **[6:0]** (only [3:0] auto-connects in IPI) | wrapper:295-306 |
| `apb` | slave | Unified config: Wlink 0x0000-1FFF / TideLink 0x2000-3FFF / addr-xlat 0x4000-5FFF | 15-bit internal, PSTRB+PPROT present on face | wrapper:316-325 |
| `tc_axis_tx` | master | TideChart TX (pkt_type=10 routed out) | 48-bit, **TVALID/TDATA/TREADY only — no TLAST/TKEEP/TSTRB** | wrapper:331-333 |
| `tc_axis_rx` | slave | TideChart RX | 48-bit, **no TLAST/TKEEP** | wrapper:338-340 |
| `s_i2c_axi` | slave | CPU-driven I2C master path | full AXI4 (AWLEN/AWBURST/…): the one true burst-capable port | wrapper:460-494 |
| IRQ x9, PHC, role/nego, scan | misc | sideband | — | wrapper:355-506 |

Bus-fabric-facing wrapper contract (the load-bearing assumption):
**every AHB slave port is wired HSEL=1'b1 with HREADYOUT looped straight back
into HREADY_IN** (`wrapper.v:27-35` header, `:513-523`, `:581/589/592` etc.).
The wrapper assumes a **single-slave bus** — Xilinx `axi_ahblite_bridge:3.0`
omits HSEL/HREADY_IN. Consequences for a *shared* interconnect are the crux of
this report (§2.1, §2.2).

---

## 2. Embedded-specific failure modes (concrete scenarios)

### 2.1 — Shared interconnect drives HREADY_IN low; TideLink can't see it
The wrapper discards HSEL and HREADY_IN. On a shared AHB bus matrix (multiple
masters, or slaves further down the decode), the interconnect drives HREADY_IN
low to hold TideLink's data phase while another slave finishes. Because the
wrapper ties HSEL=1 and loops HREADYOUT→HREADY_IN, **TideLink believes it is
always selected and always the sole owner of bus timing.** A ahb_sub read whose
address phase is extended by the fabric (HREADY_IN low) will have its internal
`pipe_valid_r` / `rd_pipe_r` sequencing (`tidelink_top.sv:1404,1633`) advance on
the *wrong* cycle relative to when the master actually latches HRDATA.
Scenario: CPU + DMA both behind a SmartConnect that muxes onto ahb_sub; a
back-pressured beat mis-times the read-pipe → stale HRDATA (exactly the I2 class,
but re-opened by fabric wait-states the wrapper hides).

### 2.2 — ahb_mng mastering into a SoC slave that wait-states or errors — NO backstop
`ahb_mng` (XHB500 AXI→AHB) wires the far-slave `hready`/`hresp` **straight
through** with no local timeout (`tidelink_top.sv:2352-2364`; grep for any
`mng.*timeout` returns nothing). ahb_sub has TWO backstops (§2.3); **ahb_mng has
zero.** If the local SoC slave the manager targets (e.g. `d2d_ahb_s` → SRAM, or
an arbiter that never grants) holds HREADY low indefinitely, the XHB500 stalls,
back-pressures AXI, back-pressures the link, credit stops returning → the *whole
link wedges from the far side inward* with no recoverable bus error. A real SoC
slave CAN wait-state (refresh, contention) or return HRESP=ERROR (decode hole);
TideLink's manager has no defined recovery for either.

### 2.3 — The ahb_sub backstops under real (non-BFM) interconnect timing
ahb_sub has three guards, all in `tidelink_top.sv`:
- **read-pipe completion (I2, `rd_pipe_r`)** `:1633-1641`, masks master-facing
  HREADYOUT for one cycle on a read so the master doesn't capture the bridge's
  IDLE-state HREADYOUT=1 leak (`:1651`). Provenance: *"Found by the two-real-SoC
  g2_soc_pair read round-trip (a zero-latency far-side memory hides it)"* `:1631`.
- **per-beat SUB_STALL** `:1482-1491,1573-1579`, fires when XHB500 holds
  HREADYOUT **low** past `SUB_STALL_TIMEOUT_LOG2` (default 16, `:1457`).
- **I5 outstanding-response** `:1493-1515,1591-1599`, tracks s_axi AR/AW→R/B
  handshakes and times out **regardless of HREADYOUT** (default 16, `:1466`) —
  built for a lost response while HREADYOUT stays **HIGH** (posted write / bridge
  parking ready), the blind spot the per-beat timer can't see (`:1497-1500`).

The risk is not that these are wrong; it's that they were tuned against BFMs with
a zero-latency far side and a bug-dodging master (§3). Under a real far side with
bounded read latency + fabric wait-states, the interplay of `pipe_valid_r`,
`rd_pipe_r`, and `xhb_sub_hreadyout_raw` has never been exercised.

### 2.4 — ahb_tx TX aperture depends on the UPSTREAM master's beat pacing
The FC adapter collapses/holds beats by watching for IDLE gaps
(`tidelink_fc_adapter.sv:200-244`, `TX_IDLE_GAP=3`). Its own comment admits the
correctness boundary: *"a spec-master issuing back-to-back same-address NONSEQ
beats with no IDLE gap would be collapsed to one transfer — unreachable through
the axi_ahblite_bridge, which idles between AXI transactions"* (`:196-199`). So
**one-store-one-FC-word is only safe because the Xilinx bridge idles between
transactions.** A different master/interconnect (CMSDK bus matrix, a CPU tight
loop, a DMA burst) that drives ahb_tx without those idle gaps can silently
**merge two writes into one FC word** (data loss) or, conversely, the between-word
separator model can drop words (the documented A→B 5× / B→A 25→0 regressions,
`:222-234`). ahb_tx also has **no HSIZE/HBURST decode**: a byte/halfword write or
a burst from a real master is not defined.

### 2.5 — APB config registers ignore PSTRB (byte/halfword writes corrupt)
`apb_pstrb` is forwarded to the chiplet controller and addr-translator
(`tidelink_top.sv:2395,2589`) but the **TideLink register file
`tidelink_apb_regs.sv` never references pstrb** (grep: zero hits). The
`cmsdk_ahb_to_apb` bridge in `tidelink_ahb.sv:126` leaves PSTRB unconnected. A
real APB/AHB master doing a sub-word write to a TideLink config/status register
writes the full 32-bit word — unstrobed lanes are silently overwritten. Low
probability (config is usually word-access) but a genuine silent-corruption seam.

### 2.6 — AXI-Stream (tc_axis) has no TLAST/TKEEP
`tc_axis_tx`/`tc_axis_rx` expose only TVALID/TDATA/TREADY (48-bit)
(`wrapper.v:331-340`, `top:409-413`; `tidechart_shim.sv` confirms). A standard
Xilinx AXIS SmartConnect / AXIS-Interconnect / DMA propagates or *requires* TLAST
for packet framing. Routed through generic AXIS infrastructure, TideChart packet
boundaries (which are position/count-implicit here) can be mis-framed with no
elaboration error. The shim's ordering convention is also "load-bearing —
getting it backwards silently swaps link ports" (`tidechart_shim.sv:35-44`).

### 2.7 — APB address decode aliasing at 0x208 / 0x008 (prior class)
The Tier-2 swi_enable/swreset gate special-cases Wlink `0x208`
(`tidelink_top.sv:2426-2461`, `paddr[12:0]==13'h208`). The apb_regs map has RO
`0x008` Packet Word Length (`tidelink_apb_regs.sv:159`) and multiple
special-cased region folds (Region 9/10/D/F alias onto controller 2'b00 select,
`apb_regs.sv:113-132`, `axi_chiplet_controller.sv:2046-2055`). Region-decode
aliasing is a demonstrated bug class here; a wider paddr from a real fabric (the
IPI face carries 32-bit PADDR truncated to [14:0], `wrapper.v:643`) can land an
access on an aliased slot the narrow-BFM tests never hit.

### 2.8 — Flist / netlist drift at the submodule boundary (integration, not sim)
`nanosoc-ethernet-chiplet/flist/resolve_tidelink_flist.py` **shadows TideLink's
pinned `tidelink_top.sv` with a chiplet-local `local_overrides/` copy**
(`:130-147`, patches/0003 = the I2 read-pipe fix) and drops the `deps/` copy of
`WlinkGenericFCReplayAddrSync_18` to avoid a tool-order-dependent netlist
(`:54-59,92-95`). Two integration hazards: (a) the consumer's override copy can
**drift** from the upstream TideLink RTL that sim_gate tests — the two are
different files; (b) any tool that does "first-declaration-wins" silently binds
the wrong module → the a2l false-FULL wedge on silicon (`:29-32`). This is the
class where "green in sim proves nothing about which module tapes out."

---

## 3. Current coverage vs gaps (with citations)

### 3.1 `cocotb/tidelink_ahb` (AHB-slave suite)
- **HREADY is a hard loopback** in `tb_top.sv:55-56,59-60` (`assign
  ahbs_hready = ahbs_hreadyout;`) → the tb **cannot inject a single fabric
  wait-state** into either slave. Slave HREADY-low-in handling is structurally
  unreachable.
- **No HBURST/HPROT ports** on any bus in `tb_top.sv` → bursts, protection
  attributes, byte-strobes structurally unreachable.
- Dominant hand-rolled driver **never samples HREADYOUT**; reads captured at a
  fixed 2-cycle offset (`test_tidelink_ahb.py:190-206`). Only NONSEQ+IDLE, HSIZE
  always word; no SEQ/BUSY, no pipelined back-to-back, no HRESP ERROR.
- Drain/credit tests assert **RX pop-side credit accounting only** — never fill
  the FIFO to capacity, never check write-refusal / credit-floor / HREADY-low
  when full / overrun (`test_tidelink_drain_credit.py` Q1 fills ~0.3%; Q2 is a
  non-advancing reader; Q3 returner has no far-side backpressure).
- **NOT in `make sim_gate`** (aggregate `Makefile:1051-1109` never calls it). It
  runs only in `.gitlab-ci.yml:362,371,417-419` → gate can be green while CI is
  red (a known hole class).

### 3.2 `cocotb/tidelink_top_pair_v2` (XHB window path)
- `test_v2_xhb_window.py`: idealized master drives **hready constant-high** and
  on a read **skips the accept pulse — waits for HREADYOUT to go LOW first**
  (`:88,135-147`). This BFM *deliberately dodges* the I2 leak — the exact
  "green-but-blind" shape.
- `test_v2_xhb_lostresp_pipe.py::test_i2_strict_read_pipe_offset`: DOES exercise
  `rd_pipe_r` via a strict master that captures on first HREADYOUT-high
  (`:120-133,171-179`). Good — but via master capture timing, not far-side
  latency.
- `test_v2_xhb_lostresp_pipe.py::test_i5_lost_response_backstop`: trips the I5
  outstanding backstop **but wedges the far BRAM by holding HREADYOUT LOW** (same
  as the stall test) and has **no assertion that HREADYOUT was HIGH** (`os_raw_hi`
  is counted `:209,217-220` but never asserted `>0`). **I5 exists specifically
  for the HREADYOUT-HIGH lost-response case (posted write / bridge parking ready)
  — that literal condition is NOT reproduced.** It proves attribution (via split
  timeouts) not the blind-spot itself.
- `test_v2_xhb_window_stall.py`: trips per-beat SUB_STALL (shrinks only
  `SUB_STALL_TIMEOUT_LOG2`, far side held low).
- `test_v2_xhb_window_bridge.py`: bridge-accurate **near-side** BFM (PG320 hwdata
  timing, `:99-103`), but far side is still the **zero-latency BRAM**
  (`tb_top.sv:1127` `HREADY = force_stall ? 0 : 1`). No test models a
  **bounded read-latency far side**.
- **All ahb_sub/ahb_mng window stimulus is single-beat, one outstanding, no
  bursts, no master wait-states** (only far-terminus binary `force_stall`).
- Idle-link / pad-clock-gate / SYNC case is **structurally unreachable** (§6).

### 3.3 Gating reality
- `sim_gate_xhb` (runs `test_v2_xhb_window_bridge`) is **deliberately OUT of the
  aggregate** (`Makefile:631`; comments `:630,718,931`) — gated only on the HW
  farm via `td_v2_channels.sh --channels xhb` (bounded 8-txn soak, needs the
  physical board pair).
- `test_v2_xhb_window_stall` and `test_v2_xhb_lostresp_pipe` (the I5/stall
  backstop tests) have **no `make` target at all** — orphan tests in no gate.
- **`g2_soc_pair`** (two real `nanosoc_multicore_soc` dies through a real SoC
  matrix into real `shared_sram_0` — the test that CAUGHT both the I2 read-pipe
  bug and the write-data-phase drop) is **only in the consumer repo, referenced
  nowhere in TideLink's Makefile or CI.** The strongest real-interconnect test we
  have does not gate TideLink releases. `sim_gate_eth_*` runs the lighter
  `eth_tidelink_pair` instead, whose ahb_mng terminus is `cmsdk_ahb_to_sram` with
  **HREADYOUT tied 1'b1** (`eth_tidelink_pair/tb_top.sv:21`) — zero-wait, so it
  does not stress §2.2 either.
- `farm_gate.sh` = Tier-0 lint (provenance / IP-match / xdc / sv_anti_pattern) +
  a silicon-faithful pair sim; it does **not** add any of the above bus tests.

---

## 4. Proposed tests (exact assertion + location + gate wiring)

Keep all sims light: reuse existing pair_v2 / tidelink_ahb elaborations; shrink
timeouts with the existing `+define+TIDELINK_SUB_*_TIMEOUT_LOG2` knobs.

**T1 — ahb_mng far-slave stall backstop (HIGHEST).**
New `cocotb/tidelink_top_pair_v2/test_v2_mng_farstall.py`. Wedge the manager's
own far terminus (`u_*_mng_bram.force_stall=1`) on an *inbound peer write/read*
that reaches `ahb_mng`, then run the link long enough that a legitimate
round-trip would complete.
Assert: the link does not wedge permanently — either a manager-side timeout drops
the beat with a recoverable error, or (if none exists, the expected result today)
the test **fails**, documenting that ahb_mng has no backstop (`tidelink_top.sv`
lacks any `mng` timeout). This is the mirror of the ahb_sub SUB_STALL backstop
that §2.2 shows is missing. Wire into `sim_gate` next to `sim_gate_apb_preempt`
(both are PS-wedge safety).

**T2 — I5 in its real HREADYOUT-HIGH condition (HIGH).**
Extend `test_v2_xhb_lostresp_pipe.py` with `test_i5_posted_write_hready_high`:
issue a **posted write** (or drive the far terminus so the bridge parks HREADYOUT
**high** between beats while the B-response is lost), build with
`SUB_OUTSTANDING_TIMEOUT_LOG2` small / `SUB_STALL_TIMEOUT_LOG2` large.
Assert: `os_raw_hi > 0` during the wedge (proves HREADYOUT was HIGH), `sub_err1_r`
pulses, `sub_stall_ctr_r < top/4` (per-beat timer never armed), HRESP=ERROR.
Closes the blind spot in §3.2. Add a `sim_gate_xhb_lostresp` target and put it in
the aggregate.

**T3 — ahb_sub read against a bounded-latency far side (HIGH).**
New `tb_ahb_bram_slave` variant (or param) with an N-cycle read latency
(HREADY low for N then data), replacing the zero-latency `force_stall`-only model
(`tb_top.sv:1127`). Run `StrictAHBSubMaster` reads for N=1..4.
Assert: HRDATA byte-exact AND captured only on the cycle the bridge is genuinely
returning data (`rd_pipe_r` masked exactly the pipe-offset cycles, no stale
capture). This exercises §2.3 the way g2_soc_pair does but light. Wire into
`sim_gate` (extend the lostresp target's build).

**T4 — ahb_sub under injected fabric wait-states (HIGH).**
Add a master-side HREADY_IN driver to the pair_v2 ahb_sub BFM (today all masters
tie hready high). Randomly stall the *master* side 0-3 cycles per beat across a
16-transfer read/write mix.
Assert: every beat's data is correct and `pipe_valid_r`/`rd_pipe_r` never advance
on a stalled cycle. Directly probes §2.1 (the wrapper hides HREADY_IN, so this
must be tested at the RTL boundary where it still exists). New target
`sim_gate_sub_waitstate`, into the aggregate.

**T5 — ahb_tx beat-pacing / burst-merge guard (HIGH).**
New `cocotb/tidelink_ahb` or pair_v2 test driving ahb_tx with **back-to-back
same-address NONSEQ, no IDLE gap** and separately with an INCR burst.
Assert: N distinct writes produce **N distinct FC words** (no merge, no drop) —
i.e. `tx_xfer_lock_r` behaviour is correct without the Xilinx-bridge idle gap.
This is the §2.4 boundary the RTL comment flags as "unreachable through the
axi_ahblite_bridge." If it can't pass, the aperture needs an explicit
integration constraint (documented required IDLE gap). Wire into `sim_gate`.

**T6 — FIFO write-side backpressure / full (MEDIUM-HIGH).**
Extend `test_tidelink_drain_credit.py`: fill the RX FIFO toward capacity with the
reader stalled.
Assert: credit floors at 0 and does not wrap; the write path is honestly
back-pressured (HREADYOUT low or write refused) rather than overrunning; no
phantom pop. Covers the §3.1 gap that all drain tests miss. Same suite → add to
CI *and* create a `sim_gate_fifo_drain` target in the aggregate.

**T7 — HRESP=ERROR propagation from a real far slave (MEDIUM).**
Far terminus returns a 2-cycle AHB ERROR (decode hole) to `ahb_mng`, and
separately a downstream ERROR to a `ahb_sub` read.
Assert: the error becomes a RRESP/BRESP=SLVERR back over the link and surfaces as
HRESP=ERROR to the originating master — not swallowed to OKAY. Neither BFM path
exercises HRESP today (§3.1, §3.2). New light test in pair_v2; `sim_gate_hresp`.

**T8 — APB PSTRB honored / documented (MEDIUM).**
`cocotb/tidelink_apb_regs`: issue a byte-strobed APB write to a RW config
register with only one lane enabled.
Assert: either the untouched lanes are preserved (if PSTRB is honored) OR the test
codifies "config is word-access only" and the wrapper/bridge ties PSTRB=1111 and
rejects sub-word (PSLVERR). Today `tidelink_apb_regs.sv` ignores PSTRB (§2.5).
Add to CI + a `sim_gate_apb_pstrb` unit.

**T9 — AXIS TLAST/framing contract (MEDIUM).**
Static + light sim: assert the tc_axis packing/ordering (`tidechart_shim.sv:35-44`)
and add a testbench that feeds tc_axis_rx through a TLAST-inserting model to prove
framing survives (or document that TideChart must be point-to-point, no generic
AXIS interconnect). Wire the static check into `farm_gate.sh` Tier-0.

**T10 — g2_soc_pair as a TideLink release gate (HIGHEST, process).**
Add a `sim_gate_g2_soc_pair` target that (when the sibling checkout is present,
same pattern as `sim_gate_eth_*` `SIM_GATE_*_DEP`) runs the consumer's
`verif/g2_soc_pair` against the **current** TideLink RTL — NOT the frozen pin.
Assert: STAGE 2/2b/2c pass (write crosses, read round-trips, 8-word burst intact)
against live `src/rtl/tidelink_top.sv`. This is the only test that drives a real
SoC matrix + real SRAM through ahb_sub AND ahb_mng; making it gate TideLink closes
the §3.3 process gap that let I2 ship. Slow (~min) → put in the full aggregate,
not `sim_gate_quick`.

**T11 — flist single-definition / no-drift check (MEDIUM, static).**
Port the invariant behind `resolve_tidelink_flist.py` into TideLink's own
`farm_gate.sh` Tier-0: assert `tidelink_fpga*.flist` has exactly one definition
per module (no `deps/` + `local_overrides/` duplicate that relies on tool order),
and emit a diff if the consumer's shadow `tidelink_top.sv` diverges from upstream.
Prevents §2.8 (the a2l false-FULL tape-out trap).

**T12 — multi-master arbitration onto ahb_sub (MEDIUM).**
Light pair_v2 test with two masters (or the strict master + a background poker)
interleaving onto ahb_sub through a minimal 2:1 AHB mux.
Assert: no transaction is lost/merged when selection changes mid-flight; HSEL
deselect between owners is honored (the wrapper's HSEL=1 tie means this must be
proven at the tidelink_top boundary where HSEL still exists). Covers §2.1
arbitration. `sim_gate_sub_arb`.

---

## 5. Risk ranking

| # | Test | Failure it catches | Likelihood on real SoC | Blast radius | Priority |
|---|---|---|---|---|---|
| T1 | ahb_mng far-stall backstop | link wedge from far side, no recovery | High (any wait-stating/erroring SoC slave) | PS/link hang, power-cycle | **P0** |
| T10 | g2_soc_pair as TL gate | any ahb_sub/ahb_mng regression vs real matrix | High (it already caught 2) | ships broken to consumer | **P0** |
| T2 | I5 HREADYOUT-HIGH lost-resp | posted-write/parked-ready wedge | Medium-High | PS hang | **P0** |
| T5 | ahb_tx burst-merge | silent TX data merge/drop | Medium-High (non-Xilinx master) | silent data corruption | **P1** |
| T3 | bounded-latency far read | stale HRDATA (I2 re-open) | Medium-High | silent read corruption | **P1** |
| T4 | fabric wait-states on ahb_sub | mis-timed read-pipe | Medium (shared bus) | read corruption / hang | **P1** |
| T6 | FIFO full backpressure | overrun / credit wrap | Medium | data loss | **P1** |
| T7 | HRESP=ERROR propagation | error swallowed to OKAY | Medium | silent fault masking | **P2** |
| T11 | flist single-definition | wrong module taped out | Low-Medium | silicon wedge | **P2** |
| T12 | multi-master arbitration | lost/merged on select change | Medium | data corruption | **P2** |
| T8 | APB PSTRB | sub-word config corruption | Low | config corruption | **P3** |
| T9 | AXIS TLAST framing | TideChart mis-frame via AXIS IP | Low-Medium (only if generic AXIS used) | framing | **P3** |

---

## 6. Green-but-blind / structural unreachability (flagged)

1. **Idle-link + pad-clock-gate + SYNC re-anchor is UNREACHABLE in the pair
   suite** — the exact hole that let the V2 pad clock-gate SYNC bug ship. There is
   NO pinned `tx_en` (searched), but the case is unreachable for two independent
   reasons: (a) the pad model forwards the clock unconditionally —
   `pad_skid.sv:76-78` `assign pad_clk_out = pad_clk_in;` with the comment "the
   bug is data-vs-clock skew, not a clock dropout" (no gate/restart to model), and
   (b) the SYNC beacon is left OFF at bring-up — `pair_v2_common.py:266-267` writes
   `R8_SLOT0=0`, corroborated `tb_top.sv:290-291` and `Makefile:113-115` ("the
   default build has NO active whole-word corrector"). So the LL idling + clock
   gate + beacon-resync chain cannot occur here. Any fix on `fix/v2-sync-clock-gate`
   is unprovable in this suite → needs an idle-then-resume + clock-gate pad model
   (a real gap, tracked separately in the PHY dimension; noted here because it is
   the canonical prior).

2. **I5 test passes without reproducing its own condition** — `test_i5_...` wedges
   the far BRAM with HREADYOUT held LOW and never asserts `os_raw_hi>0`
   (`test_v2_xhb_lostresp_pipe.py:209,217-220,291-302`). The I5 backstop exists for
   the HREADYOUT-**HIGH** lost-response case (`tidelink_top.sv:1497-1500`); that
   case is not exercised. Green, blind → T2.

3. **`test_v2_xhb_window.py`'s master dodges the very bug the window path has** —
   it "waits for HREADYOUT to go LOW first, then completes" on reads
   (`:135-147`), structurally sidestepping the IDLE-state HREADYOUT=1 leak. A real
   master captures on the first HREADYOUT-high. Only the *strict* master (T3-style)
   catches it; the baseline is a false comfort.

4. **All AHB-slave coverage runs against a hard HREADY loopback** (`tidelink_ahb
   tb_top.sv:55-56,59-60`) and **no HBURST/HPROT ports** — wait-states, bursts,
   byte-strobes, HRESP are not "untested," they are *unrepresentable* in that tb.

5. **The strongest real-interconnect test does not gate the DUT** — `g2_soc_pair`
   lives only in the consumer; TideLink's own gate runs the zero-wait
   `eth_tidelink_pair` (`tb_top.sv:21` HREADYOUT tied 1) and keeps `sim_gate_xhb`
   out of the aggregate (`Makefile:631`). A TideLink change can be green here and
   break the consumer → T10.

6. **The consumer shadows `tidelink_top.sv` with a divergent local copy**
   (`resolve_tidelink_flist.py:130-147`) — sim_gate tests the upstream file, the
   consumer builds the override. Nothing asserts they match → T11.

---

### One-line bottom line
The ahb_sub read/stall/outstanding guards are real and thoughtfully built, but
every one was tuned against a zero-latency far side and a bug-dodging master; the
**ahb_mng manager has no backstop at all**, the **ahb_tx aperture silently
depends on the Xilinx bridge's beat pacing**, and the **only real-interconnect
test (g2_soc_pair) doesn't gate TideLink** — start with T1, T10, T2.
