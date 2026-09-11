# TideLink Rev-2 Programme

TideLink chiplet interconnect · target architecture, feature-complete definition, phased plan · 2026-09-10

| | |
|---|---|
| Baseline | `origin/main` **5e8bdb5a** + `rev2/integration` **cba9774d** |
| Companion | **TideLink Rev-2 Review** (findings, defect register, evidence) |
| Audience | the people who will fund, build and adopt it |

## Contents

0. In one paragraph
1. Target architecture
2. The contract
3. Feature-complete checklist
4. The plan, step by step
5. Timeline
6. Selling it
7. Assumptions and risks

---

## 0. In one paragraph

TideLink is a die-to-die bridge that lets an AHB system on one chiplet read and write memory on another as if it were local, over eight ordinary GPIO pads, with no software involvement in bring-up. It packages Arm's XHB500 bus bridge, the open Wlink flow-control link layer and a source-synchronous GPIO PHY behind one AHB subordinate port, one register map and one mailbox. It has delivered byte-exact traffic autonomously on FPGA silicon (two dies in one KR260 fabric, 5,000 of 5,000 packets). What it does not yet have is an architecture a newcomer can hold in their head, a file set that is both validated and taped out, a gate that runs itself, and the throughput its own link could give. This programme makes it feature-complete and re-architects it so that the diagram in §1 is literally the module list.

---

## 1. Target architecture

Five layers and a control plane. Each layer has one job, one owner directory, one interface up and one down, and its own testbench. A request crosses the layers top to bottom on the initiating die and bottom to top on the target die; responses and acknowledgements come back the same way. Everything that exists today maps onto this picture; the programme's job is to make the code match it.

### Figure 1 — One 32-bit write from die A to die B

*(Converted from an inline SVG. The figure is two mirrored stacks, die A on the left as initiator and die B on the right as target. Each stack shows four boxed layers — Bus, Transaction, Link, PHY — with the transaction layer tinted, a control-plane box under each stack, and a full-width band beneath both for the services that ride on the transaction layer. Solid arrows run down the die-A stack and up the die-B stack, plus one solid arrow across at PHY level; a dashed arrow returns across at PHY level. Caption: "One 32-bit write from die A to die B. Solid arrows carry data down the initiator and up the target; the dashed return carries acknowledgements, credits and the B or R response. The transaction layer (tinted) is the part TideLink owns outright and the part this programme rebuilds.")*

| Layer | Die A · initiator | Die B · target |
|---|---|---|
| Bus | AHB subordinate → XHB500 AHB-to-AXI; single outstanding; hazard list for posted writes | XHB500 AXI-to-AHB → AHB manager → SRAM; B / R responses generated here |
| Transaction *(tinted: the part TideLink owns outright)* | TideLink core: address pipe · write hold · backstops; mailbox FIFO · returner · address translation · obs | TideLink core (peer): backstops · obs; mailbox FIFO · credit return |
| Link | Wlink FC nodes AW W B AR R + mailbox node; replay window · ACK/NACK · CRC · header ECC | Wlink FC nodes (mirror) · replay · ACK/NACK; CRC · header ECC |
| PHY | GPIO PHY: 8 lanes × 16:1 SDR · forwarded clock; deskew · calibration · autoneg · role lock | GPIO PHY (mirror) · recovered clock; deskew · calibration · autoneg · role lock |
| Control plane | APB register map · bring-up FSM · 0x21xx observability; one config profile · one obs word per layer | APB register map · bring-up FSM · 0x21xx observability; mirror of die A |

Hop labels carried on the arrows:

- Die A, Bus → Transaction: `32-bit write, hwrite, hprot`
- Die A, Transaction → Link: `AXI AW + W, awid = 0`
- Die A, Link → PHY: `13-byte packets 0x80, 0x81 (+ pktnum)`
- Across, A → B (solid): `128-bit link word / 16 UI`
- Across, B → A (dashed): `ACK · NACK · credits · B and R responses`
- Die B, PHY → Link: `packet → replay window, ACK`
- Die B, Link → Transaction: `AW + W → hazard list`
- Die B, Transaction → Bus: `AHB write → SRAM; B returns`

Services riding on the transaction layer (full-width band): PTP time transfer (short packets + servo) · TideChart election · tx_gen pattern generator · perf counters (link-cycle counter to be added).

### Layer ownership

| Layer | Owner | What it does | Owned files |
|---|---|---|---|
| Bus | Arm XHB500 (generated, digest-pinned) | Turns AHB transfers into AXI and back. Single outstanding read; up to four posted writes tracked by a page-granular hazard list. TideLink does not modify it; TideLink constrains it (HPROT tie-down) and watches it. | `deps/xhb500/generated` · `TREE.sha256` |
| Transaction | TideLink (rebuilt in this programme) | Guarantees the bus never hangs: an address pipe, a write-data hold, per-direction age timers with bounded ERROR or synthetic responses, a six-rank ready mux with one assertion per rank, an honest observability word. Also the mailbox FIFO, credit returner and address translation. | `src/rtl/core/` · `tidelink_ahb_sub_pipe`, `write_hold`, `sub_backstop`, `hready_mux`, `xhb_obs`, `apb_fabric`, `fifo/*`, `fc_adapter` |
| Link | Wlink, vendored with a patch manifest | Reliable delivery per channel: one flow-control node per AXI channel plus one for the mailbox, each with a replay window, cumulative ACK, NACK-and-replay, CRC and header ECC. One parameterised node replaces six hand-patched copies; recovery features are named parameters that both targets compile. | `src/vendor/wlink/` · `MANIFEST.md` (upstream SHA + patch list) |
| PHY | TideLink GPIO PHY (one submodule, tagged) | Eight lanes of 16:1 SDR with a forwarded clock; lane deskew, one-time calibration with a forced-recalibrate door, autonomous negotiation over I2C or in-band, and role lock as a mutual clock enable. Divider for rate control with its constraints closed. | `deps/tidelink-phy @ tag` · `src/rtl/phy/` (V2 only) |
| Control plane | TideLink | One register map generated from RDL (SV decode, C headers, docs from one source); one configuration profile per target (ASIC tapeout, KR260 pair, sim); a bring-up FSM whose every state has a bounded exit or a software-visible terminal; one observability word per layer whose every bit has a must-fail control. | `src/rdl/` · `src/rtl/cfg/tidelink_cfg_pkg.sv` · `docs/CONFIG_MATRIX.md` (generated) |
| Services | TideLink | PTP time transfer with a servo that converges from any initial offset; TideChart root election; the pattern generator and performance counters used to prove throughput on silicon. | `src/rtl/services/` · ptp, ptp_servo, phc_cdc, tx_gen, perf, tidechart shim |

### 1.1 Before and after

### Figure 2 — What changes structurally

*(Converted from an inline SVG. Two columns of stacked boxes with a "re-architect" arrow between them: "Today (5e8bdb5a)" on the left with its top two boxes tinted red, and "Target" on the right with two boxes tinted green. Caption: "What changes structurally. Red: the two things a newcomer cannot understand or a tool cannot check today. Green: the two things that make the layered picture true in code.")*

**Today (5e8bdb5a)**

| Box | Detail |
|---|---|
| `tidelink_top.sv` · 3,477 lines (3,968 on rev2) — *red* | top + APB fabric + 620-line backstop block + lab notebook (43% comments); cannot be unit-tested, linted or CDC-checked in parts |
| `local_overrides/` · 38,385 lines · this IS the product — *red* | `axi_chiplet_controller.sv` 6,871 (vendor original 1,766); `Wlink.v` 2,945 (original 2,352) · RxLinkLayer, PHY, deskew, calibrator forked; 6 × `WlinkGenericFCSM` copies, hand-patched — the ASIC flist takes 5 of them from `deps`; CDC flow black-boxes the controller and waivers cover the forks; 3 inconsistent parameter-default sets; V1 still default in 3 entry points |
| `deps/` · vendor originals, never compiled | README points here; nothing builds from here |
| two hand-maintained 186-file flists + 10 forks | 174 shared / 12 divergent; the tapeout split is an 18-line comment |

**Target**

| Box | Detail |
|---|---|
| `tidelink_top` · ~900 lines · instances and wiring only | no logic; LEC-equivalent to today at the split |
| `core/` · 8 owned modules, one testbench each — *green* | `ahb_sub_pipe` · `write_hold` · `sub_backstop` (age timers, synthetic B and R); `hready_mux` (one assertion per rank) · `xhb_obs` (honest bits); `apb_fabric` · `swi_harden` · `ptp_servo_wrap` |
| `link_ctrl/` · owned, split by concern | `ctrl_obs` (Regions 8/9/C/D/F) · `role_block` · `phy_cal_wrap` · bring-up FSM; CDC flow sees inside; ~75 ad-hoc syncs → one sync cell |
| `vendor/wlink` · manifest + patches — *green* | one parameterised FC node; recovery = named parameters; generated == committed checked in CI; both targets compile one tree |
| `design/tidelink.core.yaml` → every flist · cfg pkg · RDL | tapeout vs FPGA = a one-line reviewed choice; V1 gone |

---

## 2. The contract

An architecture sells when its guarantees are short and true. These are the guarantees the target makes; the status column says which are true today.

| Guarantee | Meaning | Today | Made true by |
|---|---|---|---|
| **Transparent access** | An AHB master on die A reads and writes die B memory through a window; no driver, no descriptors. | *(done)* writes yes · reads yes | — |
| **Autonomous bring-up** | Both dies negotiate, calibrate and lock without a host write, from reset, within a bounded time. | *(partial)* on-chip pair yes; two-board lottery; ASIC default is config | Phase 2 (config profile), Phase 5 (bring-up FSM timeouts) |
| **The bus never hangs** | Any lost response becomes a bounded AHB ERROR; the port recovers; an idle bus is never held. | *(missing)* write wedge and read dead gate fixed only on rev2, in sim | Phase 1 (land), Phase 5 (synthetic R, HW proof) |
| **Same recovery on silicon as on FPGA** | The file set that tapes out is the file set that was validated. | *(missing)* ASIC FC nodes have zero recovery | Phase 2 |
| **Link integrity** | Every packet CRC-checked, every header ECC-corrected, replay on NACK, one policy on both targets. | *(partial)* ECC live; CRC default differs per target | Phase 2 (decision), Phase 4 (parameter) |
| **Every diagnostic can fail** | Each sticky bit, script verdict and gate has a must-fail control; a green means green. | *(missing)* ~49 diagnostics cannot report; two lying obs bits | Phase 1, Phase 5 |
| **Exclusives are refused, not silently executed** | A locked access either crosses correctly or errors. | *(missing)* tie-off; needs the parent chiplet's AHB5 port | Phase 6 |
| **Bursts cross correctly** | INCR/WRAP bursts become one AXI burst; no data corruption; posted writes bounded. | *(missing)* never executed; two-burst corruption when driven | Phase 6, after Phase 5's wedge closure |
| **Time transfer** | PTP servo locks from any initial offset; PHC hop proven on two boards. | *(missing)* servo cannot converge from over one second | Phase 6 |
| **Throughput envelope** | Stated in link cycles per word with a counter that measures it on silicon. | *(partial)* 3.06 today, no on-silicon counter | Phase 7 |
| **One-hour understanding** | A newcomer reads one document and the module list matches it. | *(missing)* 22 stale claims; no CONTRIBUTING | Phase 8 (continuous) |

---

## 3. Feature-complete checklist

| Feature | Status today | What completes it | Phase |
|---|---|---|---|
| AHB write path, single beats | *(done)* (on-chip 5000/5000) | hazard-list wedge closed on hardware; HPROT tie-down landed in the chiplet | 5 |
| AHB read path, single beats | *(partial)* works; lost R parks the bridge | synthetic R after age expiry; AR/R replay self-heal in the ASIC flist; HW proof | 1, 5 |
| AHB bursts (INCR4/8/16, WRAP) | *(missing)* missing and unsafe | root-cause the leading all-zero burst; hazard scheme; gated non-single tests | 6 |
| Posted (bufferable) writes | *(missing)* tied off | per-ID aging of the oldest outstanding B; then enable | 6 |
| Exclusive access | *(missing)* silently executed | TL-045 refuse path plus the chiplet's HEXCL pin, or a documented no-exclusives contract | 6 |
| Mailbox / FIFO path with credits | *(partial)* done; arbiter drops; no write-side timeout | one-hot grant arbiter; packet watchdog with a sticky | 5 |
| Autonomous bring-up | *(partial)* on-chip yes; two-board 17/20; ASIC default off | config profile sets the tapeout default; anchor-pair gate; FIN-state timeouts; forced-recal proven | 2, 5 |
| Link recovery on the ASIC file set | *(missing)* zero hooks; measured wedge | re-point or parameterise; ASIC-fileset regression in the gate; FPGA image from the tapeout set deployed | 2, 4 |
| Link CRC and header ECC policy | *(partial)* ECC live; CRC split | one parameter at the top; both targets validated in the same combination | 2, 4 |
| Rate control (link-clock divider) | *(partial)* RTL sound; port unconnected; no SDC | wire both wrappers; generated clocks; DFT exclusion; symmetric-ratio rule | 1, 6 |
| PTP time transfer | *(missing)* servo cannot converge; PHC hop unproven | servo v2; two-board convergence artefact; suite in the gate | 6 |
| TideChart election | *(partial)* dual-root reproduced; timeout widened; claims often do not cross | root cause in progress; setters for the error bits; APB decode fixed | 5 (tidechart owner) |
| Observability | *(partial)* rich but two bits lie; new bits undecoded | honest bits; host decoders; one obs word per layer; link-cycle counter | 5, 7 |
| DFT / MBIST | *(missing)* scaffold | scan insertion, MBIST wrapper that can report PASS, ATPG | 6 |
| ASIC timing closure | *(missing)* no post-fix build; design fails correct constraints | archived runs; real derates; divider constraints; the design fixed to close | 6 |
| Throughput | *(partial)* 8% of raw; one lever known | counters, window depth, 8 lanes, multi-word packets | 7 |
| Verification gate that runs itself | *(missing)* none | hygiene, self-clean gate, CI on the public forge, coverage ratchet, assertions | 1, 3 |
| Documentation and onboarding | *(missing)* stale; no one-hour doc | the §6.2 document, CONTRIBUTING, generated register map and config matrix | 8 |

---

## 4. The plan, step by step

Phases are ordered by dependency. Inside a phase the numbered steps can run in parallel across agents or engineers unless a step says otherwise. Each phase ends with exit criteria that are files on disk, not prose. Durations assume two to three parallel lanes with a human reviewer each and board time for the hardware steps; the review's five-wave task list (§9 there) gives the per-task files and effort.

### Phase 0 — Decide and freeze
*1 week · human*

1. Rotate the board credential on every host that shares it; treat the published value as burned.
2. Decide ASIC link recovery: re-point the five FC nodes and the address sync to the recovery-bearing overrides (recommended), and pick one CRC default for both targets.
3. Decide the TL-035 Part-B default (opt-in, recommended), the forge (GitHub Actions plus a self-hosted licensed runner, recommended), and the land order: hygiene, then integration, then one chiplet pin lineage.
4. Sign or replace the two waivers; approve V1 retirement; approve the exclusives port change in principle.
5. Name owners: one for the core, one for the link, one for verification infrastructure, one for the ASIC flow, one coordinator who owns the ledger.

**Exit criteria**
- a dated decision note in `docs/` covering all seven decisions
- the credential no longer works

### Phase 1 — Make the ground trustworthy
*2 weeks · 5 lanes*

1. Land `rev2/hygiene` onto main and integration (two trivial conflicts; keep the "bit[10] is pressure" wording).
2. Close the rev2/integration checklist: resolve the flist-divergence FAIL per Phase 0's decision; restore the dropped T6 fix and its control; wire the checker controls and the UVM loss self-tests as prerequisites of the gate; register TL-043-ARR, TL-044, TL-045 and de-collide the IDs; update the 0x21F8 host decoders for bits 12 to 16; untrack the generated `dut_src_*.f` files.
3. Fix the gate tooling: nothing the gate runs writes a tracked file; the environment check resolves every flist variable, refuses an uninitialised submodule and a dirty tree; `cocotb make regression` exits non-zero on failure; recursive recipes are dry-run safe; a flist digest joins the stamp.
4. Run the full gate on the clean integration tip and keep every `.status` with a clean stamp. Deploy that image to the on-chip pair: autonomy, 5,000-packet soak, cross-die read/write regression, a forced R loss (TL-044 bits) and a forced B loss (TL-042 bit) with normal traffic resuming after each.
5. Registry truth pass: demote the three unbacked hardware-proven claims; update the six under-reported fixes; delete the false "blocking CI job" sentence; correct the suite counts.
6. Repository hygiene: tag and delete the 28 merged branches, push the two local-only tips, tag the ethclone-ahead branches, remove the dead remotes, reset local main, remove scratch files and tracked generated HTML.

**Exit criteria**
- main = hygiene + integration, credential count 0, provenance fail-closed
- a full gate on main with uniform clean stamps and PASS from its own summary
- a hardware artefact directory for that exact commit with the five proofs above
- a fresh worktree with an unset environment refuses the gate in under two seconds

### Phase 2 — One file set, one configuration
*2–3 weeks · 4 lanes*

1. Write `design/tidelink.core.yaml` (filesets × targets) and the generator; regenerate every flist, the Vivado read list and the cocotb overlays; commit the generated lists with a regenerate-and-diff check; activate the flist merge driver. The tapeout-versus-FPGA delta becomes one named fileset.
2. Implement Phase 0's recovery decision: the ASIC v2 target compiles the same FC nodes and address sync as the validated set; run the ASIC-fileset suites (state-7 starvation, silicon-ratio, pair data) in the gate; build the FPGA image from the tapeout file set and deploy it once (the on-chip pair, with the prepared state-7 probe).
3. Create `tidelink_cfg_pkg.sv` with three profiles (ASIC tapeout, KR260 pair, sim); the DFT wrapper and the Vivado wrapper forward, never redefine; generate `docs/CONFIG_MATRIX.md`; synthesis errors on any test-mutant define.
4. Retire V1: delete the V1 PHY files, flists, shims, the empty generate and the duplicate submodule; make V2 unconditional; re-point CDC, lint and the pair bench; pin the one PHY submodule at a tag.
5. Register map from RDL: fix the two documented divergences, generate the C headers and both docs from the RDL, add the regenerate-and-diff check and a cocotb readback test; leave the SV decode hand-written until Phase 3 replaces it.

**Exit criteria**
- `make flists-check`, `regmap-check` and `config-check` clean in the gate
- the ASIC arm of the state-7 A/B escapes like the FPGA arm; the ASIC-fileset image ran on a board
- no `TIDELINK_PHY_V2` ifdef remains; one PHY submodule

### Phase 3 — Re-architect the core
*4–6 weeks · 3 lanes*

1. Assertion pack first: bind properties for the pipe invariant, the six ready-mux ranks, N1 exclusion, credit bounds, the replay-full condition and hazard occupancy; each with a mutant that trips it. Wire SpyGlass CDC to the shipping flist with the controller un-black-boxed and waivers re-derived; fix the X-prop makefile so a missing tool cannot pass.
2. Extract in dependency order, each step LEC-equivalent and gate-green before the next: `ahb_sub_pipe`, `write_hold`, `sub_backstop` (moving its cocotb suites with it), `hready_mux`, `xhb_obs`, `apb_fabric`, `swi_harden`, `ptp_servo_wrap`. The top becomes instances and wiring.
3. Inside `sub_backstop`, replace the two aggregate timers with per-direction age timers (the rev2 head-of-line watchdog is the write half) and add synthetic R; add the drain-debt counter; make the observability bits honest while they move.
4. Give the fc_adapter a one-hot grant arbiter with per-source ready; add the RX-FIFO write-side packet watchdog; move the transaction-layer prose into `docs/design_notes/TL-0xx.md`.
5. Make the root Makefile table-driven from `verif/suites.yaml` (under 500 lines) and split it into `mk/*.mk`.

**Exit criteria**
- `tidelink_top.sv` under 900 lines; eight core modules each with its own bench and assertions
- Formality LEC equivalent at every extraction step; full gate green with coverage collected
- SpyGlass run archived on the shipping flist with a reviewed waiver file

### Phase 4 — Re-architect the link (parallel with Phase 3)
*4–6 weeks · 2 lanes*

1. Decide Verilog-parameterised versus Chisel-regenerated (Chisel recommended if the upstream tree is reachable and the team can run it; otherwise a template plus generator with a generated-equals-committed check). Either way: one FC node with every recovery feature a named parameter; one replay node; one address sync; one multibit sync with coherent reset.
2. Vendor Wlink as `src/vendor/wlink/` with `MANIFEST.md` (upstream SHA, patch list, why each patch exists); both targets compile one tree; the manifest check runs in the gate.
3. Split the 6,871-line controller into `tidelink_link_ctrl/` by concern: control-plane observability, role block, PHY calibration wrapper, bring-up FSM; replace the ~75 ad-hoc synchroniser chains with one sync cell; fence every ILA tap behind one macro.
4. Bring-up liveness: one document plus one assertion file covering autoneg, winscan, calibrator, FC-node CR/CRACK and the auto-anchor beacon; every state has a bounded exit or a software-visible terminal; the FIN-state cross-FSM dependency gets its assertion.
5. Apply the small link fixes on the way: clear `sop` on the forced exit, Part-B opt-in, credit-max fix on all nodes, watchdog on the mailbox node, rewind on the mailbox replay node, an outstanding-age watchdog in the replay node so a silent peer becomes an error, not a stall.

**Exit criteria**
- one FC-node source; the six copies deleted; generated == committed in CI
- the ASIC and FPGA flists name the same link files
- state-7 exit test shows zero stale NACKs; enable-dip test shows packet-number wrap
- the bring-up assertion file trips on an injected peer that never finalises

### Phase 5 — Close the defects on silicon (parallel with 3 and 4, by lane)
*3–6 weeks · up to 8 lanes + board time*

1. Write wedge: land the HPROT tie-down in the chiplet with an eth-chiplet FPGA build that proves the RTL edit; hardware A/B of the head-of-line watchdog reading the obs bits; re-take the 08-13 and 08-19 stimuli on one bitstream to settle the two-class question.
2. Read dead gate: induce a lost R on the on-chip pair; confirm containment today and recovery after Phase 3's synthetic R; a write to another page completes afterwards.
3. Burst corruption: root-cause the leading all-zero AXI burst in the XHB500 non-single arm; turn the characterisation bench into gated assertions that fail without the tie-down.
4. Bring-up: anchor-pair gate in the bring-up script; forced-recalibrate measured against the clock-dropout wedge; ASIC-side capture-clock balance as a CTS constraint.
5. Observability: honest bits, host decoders, a per-layer obs word, must-fail control per bit; the link-cycle counter (also Phase 7's first step).
6. Unwired benches: triage the 43, fix or kill the nine red or unknown, wire the green ones into the quick or full gate; hazard-list saturation bench; divider at ratios other than one in the gate; the system-level cross-die read through the inbound bridge.
7. UVM: one environment (`top_system`), IRQ by reference, INCR allowed, backpressure responders, gated in full; the other six retired.
8. TideChart: finish the dual-root campaign; error-bit setters; APB decode width and `pslverr`.

**Exit criteria**
- every Critical and High row of the review's register has a status of fixed-HW-proven with the vehicle named, or an accepted waiver signed
- FSM transition coverage ratchet set and rising; zero benches with unknown state
- the on-chip pair passes the forced-loss cases with normal traffic resuming

### Phase 6 — Feature completion
*6–10 weeks · 5 lanes*

1. Bursts and posted writes: with the wedge closed (Phase 5) and the corruption fixed, enable the XHB500 non-single arm and bufferable writes behind per-ID aging of the oldest outstanding B; gated INCR4/8/16 and WRAP tests on both dies; saturating-B-return injection that recovers with traffic resuming.
2. Exclusives: land TL-045 together with the parent chiplet connecting the HEXCL pin (or publish the no-exclusives contract and keep the refuse path as the guard).
3. PTP servo v2: full seconds-and-nanoseconds offset arithmetic, per-state timeouts, tagged and sequenced mailbox, capture synchronised to the PHC handshake, reset control flops, saturating frequency word; two-board convergence artefact; the AHB port bounded.
4. Rate control closure: wire the divider ratio in both wrappers, generated clocks and case analysis in the SDC, DFT exclusion, the symmetric-ratio rule or a peer-ratio handshake; document every ratio-dependent timer.
5. ASIC: archive a Fusion Compiler run after every constraint change (red is information); replace placeholder derates with foundry tables; scan insertion, an MBIST wrapper that can report PASS, ATPG; one POR truth between the top and the DFT wrapper; fix the design where the correct constraints fail.

**Exit criteria**
- every row of §3 reads done or has a signed contract exclusion
- an archived ASIC run that closes timing under the correct constraints with DFT inserted
- PTP converges on two boards from a five-second initial offset

### Phase 7 — Throughput, measured then moved
*4–8 weeks · staged*

1. Instrument: link-cycle, packet, window-full and ACK counters in the tx-link domain, APB-readable; prove each can read zero and non-zero.
2. Validate the model in simulation with no RTL change: the 3.0 link-cycles-per-word invariant at three clock ratios; the ACK round-trip decomposition; the window law with forced credit maxima (12.2, 6.1, 4.1).
3. Ship the free wins: ACK spacing 4 on the receiver side, release threshold 0 at bring-up; measure the KR260 eye at a higher link clock before raising the divider.
4. Deepen the replay windows to cover the round trip (mailbox node to 64, AXI nodes deeper) through Phase 4's regeneration path; confirm one link cycle per word at 8 lanes in sim and on the on-chip counters.
5. Enable eight lanes on the FPGA build; then multi-word packets on the mailbox node and a DMA that targets the mailbox port, after the concurrent-drain corruption is closed.

**Exit criteria**
- link cycles per word read on silicon: ≈3.0 before, ≈1.0 after windows, ≈0.3 after packing
- the throughput envelope stated in the architecture document with the counter that measures it

### Phase 8 — Documentation and the pitch (continuous; ends the programme)
*throughout · 1 lane*

1. From Phase 1: `CONTRIBUTING.md` with the land-readiness rules (four test arms, must-fail controls, provenance stamps, artefact-backed hardware claims with the vehicle named, no gate-tooling edits in a running worktree).
2. From Phase 2: the generated register map and configuration matrix replace the hand-written pages; the 29 dated notes move to `docs/history/`; `docs_site` renders `docs/`.
3. From Phase 3: the one-hour document (§6.2) written against the new module list, every claim grep-verifiable; the diagrams in §6.3 produced from the same source.
4. At the end: a specification with the contract of §2 as its first chapter, the throughput envelope with its measurement, and the evidence index.

**Exit criteria**
- a newcomer reproduces the hierarchy tree from the document and the document from the tree
- the README says what needs a licence and offers the licence-free path

---

## 5. Timeline

Calendar weeks, assuming the lane counts above. Phases 3, 4 and 5 overlap deliberately; Phase 6 waits on Phase 5's wedge closure only for its first step. Roughly five to six months to feature-complete and re-architected; Phase 1 alone returns a trustworthy gate and a landed rev2 in two weeks.

*(The source renders this as a 24-week Gantt chart; the bar spans are given here as week ranges, inclusive of the first week and exclusive of the last.)*

| Phase | Weeks |
|---|---|
| P0 decide | 1 |
| P1 trustworthy ground | 2–3 |
| P2 one file set | 4–6 |
| P3 core re-architect | 7–12 |
| P4 link re-architect | 7–12 |
| P5 defects on silicon | 5–11 |
| P6 feature completion | 12–21 |
| P7 throughput | 13–20 |
| P8 docs and pitch | 2–24 |

---

## 6. Selling it

### 6.1 The claims, and when each becomes true

| Claim | Defensible today | After |
|---|---|---|
| AHB-native die-to-die memory access with no driver | yes, writes and reads on the on-chip pair | — |
| Autonomous bring-up from reset | yes on the on-chip pair; two-board needs the anchor-pair gate | Phase 5: on both vehicles, with the tapeout default set by profile |
| Eight GPIO pads per direction, no SerDes, any foundry | yes | — |
| Recoverable: a lost response never hangs the bus | no (say: "recovery designed, proven in simulation on the integration branch") | Phase 5: proven on hardware; Phase 2: same on the tapeout file set |
| Link integrity: CRC, header ECC, replay | ECC yes; CRC per-target default; replay yes | Phase 4: one policy on both targets |
| Observable: every layer reports, every bit can fail | rich but two bits lie and ~49 diagnostics cannot report | Phase 5 |
| Measured throughput envelope | 1.6–2.0 Mb/s KR260, ≈65 Mb/s at 100 MHz ASIC (8% of raw); the limiting mechanism is known | Phase 7: ≈200 Mb/s, then ≈640 Mb/s on the same PHY |
| Time transfer (PTP) across the die boundary | no (say: "designed; servo redesign scheduled") | Phase 6 |
| Open, understandable, buildable | open yes; understandable no; buildable only with Arm IP and licensed tools | Phase 8: one-hour document; README states the licence line honestly |
| Silicon-proven | FPGA-proven on one vehicle; ASIC flow not closed | Phase 6: timing and DFT closed; first silicon is a separate milestone |

### 6.2 The one-hour document (outline)

1. **What it is and what it guarantees**: the §0 paragraph and the §2 contract table.
2. **The layered picture**: the §1 diagram; one paragraph per layer with its interface up and down.
3. **The journey of one write and one read**: hop table with widths, clocks, packet sizes and where responses come from (the review's throughput section already has it).
4. **Bring-up**: the sequence from reset to role lock as a state diagram; what is autonomous, what the strap decides, what software may override.
5. **Recovery**: the ladder from link-layer replay to transaction-layer age timers to bounded AHB ERROR, with the time bound at each rung and which obs bit records it.
6. **Configuration**: the three profiles and the generated matrix; how a target is chosen; what the tapeout profile differs in and why.
7. **Register map**: generated; the four obs words explained.
8. **Files**: the hierarchy tree with owners; the one design description that generates the file lists; how to build, simulate and gate; what needs a licence.
9. **Throughput**: the envelope in link cycles per word, the counter that measures it, the levers.
10. **Evidence**: how a claim in this document is checked (grep, test name, artefact directory).

### 6.3 The story for a sceptical room

- **"Why not UCIe?"** Different product. UCIe needs a SerDes-class PHY and a licence; TideLink needs eight GPIO pads and gives AHB-native access with autonomous bring-up. State the ceiling honestly: about 1.6 Gb/s on an eight-lane GPIO PHY; beyond that is a different chiplet.
- **"Is it proven?"** On FPGA silicon, yes, on one vehicle, with the artefacts to show; on the tapeout file set, after Phase 2; on first silicon, a milestone this programme prepares.
- **"What does it do when the link breaks?"** Today, honestly: the write path can wedge and a lost read can park the bridge; the fixes exist on the integration branch in simulation. After Phase 5 the answer is a time bound and an error code, measured.
- **"How fast?"** Give the number in link cycles per word and the raw pad rate; explain the one lever (the replay window against the acknowledgement round trip) and the ten-fold headroom on the same PHY.
- **"Can my team maintain it?"** After Phase 3 and 4 the diagram is the module list, the file list is generated, the register map is generated, and a newcomer's first hour is a document whose claims are grep-verifiable. Before that, say no.
- **"What is the risk?"** The vendor link stack (Wlink) is forked today; Phase 4 vendors it properly. The XHB500 bridge is Arm IP with a page-granular hazard list that this design must constrain. The PHY is one-time calibrated; a forced recalibrate exists and its efficacy is a Phase 5 measurement.

### 6.4 Diagrams to produce (from the same source, kept in the repo)

The layered stack with the packet journey (above); the before/after structure (above); the bring-up sequence as a state diagram; the recovery ladder with time bounds; the register-map regions; the file-list generation flow; the throughput model as one chart of link cycles per word against window depth. Each is a mechanism, not a box with a name, and each is regenerated when the source changes.

---

## 7. Assumptions and risks

- **Board time** is the pacing resource for Phases 1, 5 and 7; the on-chip pair is one board and the two-board vehicle has a bring-up lottery until the anchor-pair gate lands.
- **The Chisel route** for Phase 4 needs the upstream Wlink tree and its toolchain; if unavailable, the Verilog template route costs more and delivers the same end state.
- **Arm and foundry collateral** gate every ASIC step and the public repository will never build without them; state it rather than hide it.
- **Refactors regress silicon behaviour** unless LEC and the full gate bracket every step; the review found nine fixes that reached hardware and were refuted, so each phase's exit criteria are artefacts, not descriptions.
- **Two wedge classes** may exist on the write path; the plan schedules the measurement that decides before any posted-write work.
- **What shortens it**: landing Phase 1 first (it pays for itself in every later phase), running Phases 3, 4 and 5 truly in parallel with separate owners, and choosing the flist re-point in Phase 0 rather than deferring the ASIC recovery decision.

---

*Companion to the TideLink Rev-2 Review (findings, the open-defect register with line-cited evidence, the per-task action plan). Baseline origin/main 5e8bdb5a and rev2/integration cba9774d; 2026-09-10.*
