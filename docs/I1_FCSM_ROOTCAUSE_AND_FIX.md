# I1 FCSM bring-up regression — root cause, reproduction sim, and fix (2026-07-30)

Branch: `fix/i1-fcsm-bringup` (from consolidated `main` `18491ef`).
Companion to the silicon finding `nanosoc-ethernet-chiplet/docs/I1_FCSM_BRINGUP_REGRESSION.md`.

## TL;DR

- **Root cause (functional):** the local-override AXI FC nodes hold state 1
  (SEND_CREDITS1) until they have transmitted `SOCL_L6_MIN_CR_EMITS = 32` of
  *their own* CR packets. At the ~40 ns silicon link:app ratio, on a
  marginal/retrying link, a node **cannot** accrue 32 own emits before the
  handshake is reset — it is throttled ~6–7× by the **fair round-robin
  `WlinkTxRouter`** that time-multiplexes all seven FC nodes (5 AXI + general-bus
  + **sideband**) onto one link. The state-1 exit never fires → no LINK_IDLE →
  `cr_seen=0`, `fcsm` stuck 0/1, **both dies**. `deps` has no gate (state 1
  leaves on the *first* peer CR/CRACK seen), so it always converges. It is the
  **L6 CR gate (32)** — never lowered by I1 — that binds, not the L7 CRACK gate
  (8) that the earlier analysis, the `tidelink_fcsm_silicon_ratio` suite, and
  both silicon candidate fixes fixated on.
- **Why v1/v2 were "falsified" on silicon — almost certainly a packaging
  false-negative.** The KR260 eth-chiplet bitstream is built from a
  **pre-packaged IP-XACT core** (`ipx::package_project -import_files` copies the
  RTL in at package time); the stale-IP guard is **explicitly disabled** for this
  target (`FPGA_SKIP_IP_VERIFY=1`). Editing `local_overrides/WlinkGenericFCSM*.v`
  does **not** reach the bitstream unless `make package_eth_chiplet_ip` is
  re-run. The **byte-identical** failure signature across I1/v1/v2 is the exact
  signature of edits that never reached the synthesized netlist — there is a
  documented in-tree precedent (a `verilog_define` that never reached the IP →
  byte-identical builds, `fpga/vivado_ip/package_tidelink_ip.tcl:75-81`,
  2026-05-19). So v1/v2 did not refute the gate/CRC hypotheses; they most likely
  never tested them.
- **The doc's "RX byte-align latency" ingredient does not exist in the
  integrated link:** every `WavD2DGpioRx` instance is hard-wired `USE_T3A=0`, so
  there is no comma-hunt FSM — byte alignment is fixed by the /16 word clock at
  reset. The failure is purely the emit-count HOLD vs the shared-arbiter
  throughput at the slow ratio, not an alignment race.
- **Fix:** hold the emit gate **OPEN during every bring-up handshake** — a new
  `socl_reached_link_idle` latch (set at `state>=4`, cleared on re-entering IDLE
  `state==0`) forces both gate-OK terms true whenever the link is not up. The
  handshake becomes **bit-identical to the proven `deps` path** (initial *and*
  every re-bring-up); the min-emit HOLD and the independent Fix A/D/E traffic
  recovery still arm for the
  post-LINK_IDLE traffic phase. Applied to the 5 AXI nodes
  (`WlinkGenericFCSM.v`, `_1..4`). Proven RED→GREEN in a new cocotb env.

## 1. What the silicon status register actually reports

`SWI_LANE_STATUS @ 0x2E03_2108` bits `cr_seen[23]`/`crack_seen[24]`/`cal_done[16]`/
`fcsm[19:17]` are driven from the **sideband** node, not the AXI nodes:
`axi_chiplet_controller.sv:1922,1924` latch `sync_obs_cr_seen ← obs_cr_pkt_seen_rx_w`,
and `obs_cr_pkt_seen_rx` is wired only from `TideLinkToWlink.v` / the sideband
`WlinkGenericFCSM_6.v` (grep: it does **not** appear in the AXI `WlinkGenericFCSM{,_1..4}.v`).
So `cr_seen=0`/`fcsm=0/1` on silicon means the **sideband** node never latched a
peer CR — even though I1 only re-pointed the **AXI** nodes.

## 2. The shared link — why re-pointing the AXI nodes breaks the sideband

`Wlink.v` instantiates one `WlinkTxRouter txrouter` that arbitrates **8** app
channels onto the single serial link: AXI AW/W/B/AR/R on `auto_in_0..4`,
general-bus on `in_5`, **sideband (tidelinktl) on `in_6`** (`Wlink.v:2091,2305-2333,2415`).
`WlinkTxRouter.v` is a **fair rotating round-robin** (`curr_ch_reg`, sop-keyed,
`auto_in_N_advance = auto_out_advance & curr_ch==N`, `WlinkTxRouter.v:65-149`):
no permanent starvation, but each of the ~7 simultaneously-handshaking nodes gets
only ~1/7 of the link. `WlinkRxRouter` is a **broadcast** fan-out — every FC node
sees every received packet and self-selects by `data_id` (`WlinkGenericFCSM.v:201-207`).

Consequence: the AXI nodes' *emit windows* and the sideband's share the same
arbiter. With `deps` AXI nodes (emit-until-peer-seen, ~1 emit) the arbiter is
uncongested and the sideband racks up its own emits and comes up. With the
local-override AXI nodes each demanding **32 own CR emits**, the arbiter is
congested ~6-ways and, at the slow ratio on a retrying link, **no** node —
including the sideband `SWI_LANE_STATUS` reads — completes.

## 3. The binding gate is L6 (CR=32), and gates can only *delay*

`local_overrides/WlinkGenericFCSM.v` state exits (vs `deps`):

| exit | deps (`deps/…/WlinkGenericFCSM.v`) | local override |
|---|---|---|
| state 1→2 | `(crack_pkt_seen \| cr_pkt_seen)` | **AND** `socl_l6_cr_emit_gate_ok` = `cr_emit_count >= 32` (`:288,312`) |
| state 2→3 | `crack_pkt_seen` | **AND** `socl_l7_crack_emit_gate_ok` = `crack_emit_count >= 8` (`:291,292`) |

The emit counters increment only on `auto_tx_out_advance & sop` — once per CR/CRACK
this node actually *wins the arbiter and transmits* — and reset on every state
change (`:824-847`). Crucially the gate is **ANDed onto** the already-required
peer-seen term: it can only ever **delay** a state exit, never cause a premature
one. That is why **v1 (ungating) could not have caused a premature-exit failure**,
and it reframes the doc's "gate=8 → 8 packets fly past before align" theory: there
is no premature exit and (see §5) no align FSM. The failure is a **livelock**: on
a link that resets the count faster than 32 grants accrue under the 6–7-way
round-robin, the state-1 exit condition is never simultaneously satisfiable.

`disable_crc` is **inert** during bring-up: it gates only the RX *data*-packet
`crc_corrupt` check (`WlinkGenericFCSM.v:195-198`); CR/CRACK detection
(`pkt_is_cr_pkt`/`pkt_is_crack_pkt`, `:201-203`) is CRC-independent. This is why
v2 (CRC-on) changed nothing even if it *had* reached the netlist.

## 4. Why v1/v2 almost certainly never reached silicon (packaging staleness)

The KR260 eth-chiplet BD instantiates the whole SoC as a packaged IP by VLNV
(`fpga/targets/kr260-eth-chiplet/tidelink_design.tcl:151`,
`soclabs.org:user:nanosoc_eth_chiplet_vivado_wrapper:1.0`). `build_design.tcl`
consumes it from `$FPGA_IP_REPO` and the packaging step
`fpga/vivado_ip/package_eth_chiplet_ip.tcl:42-60` runs
`ipx::package_project … -import_files`, which **copies the source content into the
IP** (a self-contained snapshot). The eth-chiplet target sets
`FPGA_SKIP_IP_VERIFY=1` (`fpga/Makefile:322,430`) so the content-hash staleness
guard `tl_verify_packaged_ip` is **skipped** (`build_design.tcl:469-470`). Under
`SKIP_PACKAGE_IP=1` (the farm path) or a plain `build_design` re-run, an edited
`WlinkGenericFCSM.v` that was not re-packaged is silently synthesized from the
**old imported copy** → **byte-identical bitstream**. The repo documents this exact
failure class and its "on-silicon obs read all-zeros because the instrument was
never synthesised" signature (`fpga/scripts/build_provenance.tcl:20-26`), and the
IDELAY precedent (`package_tidelink_ip.tcl:75-81`).

**Implication:** the v1/v2 "falsifications" are unreliable. The gate hypothesis is
**not** refuted — and this fix targets the gate.

## 5. No RX byte-align latency in the integrated link

Every `WavD2DGpioRx` instance is `.USE_T3A(1'b0)` (`local_overrides/WavD2DGpio.v`
and `WavD2DGpio_v2.v` `gpiorx_0..7`), so the S_SETTLE/S_HUNT/S_LOCKED comma-hunt
FSM is compiled out; byte alignment is assumed correct from reset (the /16 word
clock). The RX link layer `WlinkRxLinkLayer.v` asserts `auto_out_valid` on the
first good header ECC after enable — no multi-symbol lock counter. So the doc's
"peer's RX framer needs many symbols to byte-align" mechanism is architecturally
absent; it is not part of this bug.

## 6. Reproduction sim (RED → GREEN)

New env: **`cocotb/tidelink_fcsm_bringup_race/`** (self-contained copy of the V2
paired-die harness; the only DUT knob is the FCSM source + the bring-up-hold
compile switch). It models: the 5-way AXI multiplex + sideband on one arbiter;
the ~40 ns silicon ratio (`TIDELINK_SIM_REF_PERIOD_NS=40`); and a marginal/
retrying link (periodic LL re-bring-up = the sim stand-in for the async two-die
reset/retry). It observes the **sideband** (the real `SWI_LANE_STATUS` source)
and all 10 AXI FC nodes.

Measured results (HOLD=800, `TIDELINK_SIM_REF_PERIOD_NS=40`):

| target | FCSM source | bring-up hold | AXI max_state | sideband (tl2wl) max_state | verdict |
|---|---|---|---|---|---|
| `make repro`  | local_overrides | armed from reset (`+define+SOCL_FCSM_BRINGUP_HOLD_ALWAYS`) | **`{1:10}`** (all stuck state 1) | **m=1 s=1** | **FAIL (RED)** |
| `make fixed`  | local_overrides | **the fix** (open until LINK_IDLE, deps-clean per handshake) | **`{4:10}`** | **m=6 s=6** | **PASS (GREEN)** |
| `make deps`   | deps (no gate)  | n/a | `{4:10}` | m=6 s=6 | PASS (baseline) |
| `make control`| local_overrides | fix; **clean** link (no re-bring-up) | `{4:10}` | m=6 s=6 | PASS (link-up not broken) |

The `repro` FAIL is exactly the silicon signature: no node reaches LINK_IDLE
(`fcsm` stuck 0/1), and the sideband — the node `SWI_LANE_STATUS` reads —
corroborates (`m=1 s=1`). The fix restores the **sideband** to LINK_DATA (`m=6`),
i.e. `fcsm→4+`, matching the `deps` baseline exactly.

**Honest limitations of the sim:**
- The marginal-link model (periodic LL re-bring-up) is an **abstraction** of the
  async two-die reset/retry, not a bit-accurate silicon replay. It reproduces the
  duration/contention livelock mechanism; it cannot reproduce a packaging or
  timing effect.
- The reproduced failure is `fcsm` **stuck below LINK_IDLE** on all nodes
  (the operative silicon signature). The exact `cr_seen=0` *bit* is not
  bit-reproduced: the sim's fair, synchronous arbiter lets each node's RX latch a
  peer CR (`cr_seen=1`) before the state-1 emit-gate livelock bites, so in RED the
  sideband reads `cr_seen=1, fcsm=1` rather than silicon's `cr_seen=0, fcsm=0/1`.
  The link-never-comes-up outcome — and its removal by the fix — is faithful.
- This is a functional cocotb TB: it proves the **functional** livelock and its
  fix. It does **not** prove the silicon outcome (see §4/§7 — packaging).

## 7. The fix

`src/rtl/local_overrides/WlinkGenericFCSM.v` (and `_1..4`), one sticky reg + a
guard on the two gate-OK terms:

```verilog
reg  socl_reached_link_idle;
`ifdef SOCL_FCSM_BRINGUP_HOLD_ALWAYS
  wire socl_bringup_hold_open = 1'b0;                     // RED control (pre-fix I1)
`else
  wire socl_bringup_hold_open = ~socl_reached_link_idle;  // FIX
`endif
wire socl_l6_cr_emit_gate_ok    = socl_bringup_hold_open | (socl_l6_cr_emit_count    >= SOCL_L6_MIN_CR_EMITS);
wire socl_l7_crack_emit_gate_ok = socl_bringup_hold_open | (socl_l7_crack_emit_count >= SOCL_L7_MIN_CRACK_EMITS);
// …
always @(posedge io_tx_clk or posedge io_tx_reset)
  if (io_tx_reset)          socl_reached_link_idle <= 1'b0;
  else if (state == 3'h0)   socl_reached_link_idle <= 1'b0;  // fresh handshake from IDLE -> deps-clean
  else if (state >= 3'h4)   socl_reached_link_idle <= 1'b1;
```

While in a bring-up handshake (`socl_reached_link_idle=0`), both gate-OK terms are
1 → state 1/2 exit **exactly on peer CR/CRACK seen** — bit-identical to `deps`.
Because the latch is also cleared on re-entering IDLE (`state==0`), **every** fresh
handshake — the initial one *and* any full re-bring-up — is deps-clean, so the
livelock cannot recur on a marginal recovery. The HOLD arms only while the link is
actually up (`state>=4`), where the CR/CRACK emit gates are not consulted anyway.
The independent traffic-recovery machinery (Fix A `socl_l7_bringup_forgive`, Fix D
`socl_l7_wdog`, Fix E `socl_reack_*`) is **untouched** — it acts in states ≥3/≥4
and never depended on these gates — so I1's traffic-wedge recovery is preserved by
construction.

**How this differs from the falsified v1:** v1 keyed the ungate on
`~socl_l7_reached_link_data` (LINK_DATA = state 5); this keys on the sticky
`socl_reached_link_idle` (LINK_IDLE = state 4), so the min-emit HOLD arms one
state earlier for the traffic phase. But the decisive difference is **§4**: v1
most likely never reached the packaged-IP netlist. Any FCSM fix — including this
one — is inert on silicon unless `make package_eth_chiplet_ip` is re-run and the
imported copy is confirmed to match.

## 8. Residual risk & the exact silicon check

1. **Packaging (highest risk, and the likely reason I1/v1/v2 all "failed"):**
   before building, run `make package_eth_chiplet_ip` (with `TIDELINK_PHY_V2=1`,
   after the parent's `make elab`) and **verify** the imported copy matches:
   `diff imp/fpga/eth_chiplet_ip/src/WlinkGenericFCSM.v src/rtl/local_overrides/WlinkGenericFCSM.v`
   (and `_1..4`). If they differ, the fix is not in the bitstream regardless of
   this branch. Consider re-enabling `FPGA_SKIP_IP_VERIFY=0` for eth-chiplet.
2. **Sideband (`FCSM_6`) is unmodified.** It shares the same latent 32/32 gate.
   Decongesting the AXI nodes is sufficient to bring it up in this TB (sideband
   reaches LINK_DATA under `make fixed`, matching `deps`), and the `deps` baseline
   proves the same on silicon. But if bench observation shows the AXI nodes come
   up while `SWI_LANE_STATUS cr_seen` stays 0, apply the identical fix to
   `WlinkGenericFCSM_6.v` (note: it ships in the **ASIC** flists too — weigh the
   blast radius). A cleaner, more robust variant for both is the doc's fix #2:
   replace the transmit-**count** hold with a **cycle-count dwell** (immune to the
   arbiter throttle, still long enough to defeat the one-shot-CRACK deadlock that
   Fix B/C originally addressed — see the `WlinkGenericFCSM_6.v:606-618` comment).
3. **Recovery re-handshake after LINK_IDLE:** the latch is cleared on re-entering
   IDLE, so a full re-bring-up is deps-clean and cannot re-livelock (verified: the
   fixed run stays green across ~800 re-bring-ups). In-place traffic recovery
   (Fix D/E) never leaves states ≥4, so the CR/CRACK emit gates are not consulted
   there at all.

**Silicon check to run (after a *re-packaged* build):** on each die read
`SWI_LANE_STATUS @ 0x2E03_2108` over the `eth_ss_0` backdoor and confirm
`cr_seen=1, crack_seen=1, cal_done=1, fcsm→4` bilaterally, then a sustained-traffic
soak to confirm the recovery still clears a wedge.

## Commit contents
- `src/rtl/local_overrides/WlinkGenericFCSM.v`, `_1.v`, `_2.v`, `_3.v`, `_4.v` — the fix.
- `cocotb/tidelink_fcsm_bringup_race/` — the new RED→GREEN regression env.
- this document.
