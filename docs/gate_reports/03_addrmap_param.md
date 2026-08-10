# TideLink SoC-Integration Gate — Dimension 3: ADDRESS-MAP / APERTURE / CONFIG-PLUMBING

Scope: does the APB/region decode alias anywhere; does the aperture-base assumption survive
relocation; do integrator-set parameters actually reach the netlist (OOC/component.xml trap);
does a consumer's resolved flist match the intended V1/V2 + FPGA/ASIC posture. READ-ONLY audit.

Consumers examined: `~/SoCLabs/nanosoc-ethernet-chiplet` (+ NanoSoC-Compute/Hetrogeneous variants),
all via `flist/resolve_tidelink_flist.py`. FPGA path via `fpga/vivado_ip/tidelink_vivado_wrapper.v`
→ packaged IP `imp/fpga/tidelink_ip/component.xml`.

---

## 1. Register / aperture / parameter surface into the SoC

### 1a. APB aperture — three-level decode
The single APB slave face (`tidelink_vivado_wrapper.v:316`, PADDR carried 32-bit, truncated to
`apb_paddr[14:0]` at `tidelink_top.sv:643`/port `:300`) is decoded in THREE nested layers:

**Layer 1 — top sub-aperture (`tidelink_top.sv:809-811`), by `apb_paddr[14:13]`:**
| paddr[14:13] | SoC offset | Sub-slave |
|---|---|---|
| 00 | 0x0000-0x1FFF | Wlink chiplet controller (8 KB) |
| 01 | 0x2000-0x3FFF | **TideLink config regs** (8 KB) |
| 10 | 0x4000-0x5FFF | Address translator config (8 KB) |
| 11 | 0x6000-0x7FFF | **Reserved → silent OKAY** (`:829-837`: prdata=0, pready=1, pslverr=0) |

**Layer 2 — TideLink region select (`tidelink_apb_regs.sv:210`), `apb_region = paddr[8:5]`,
slot = `paddr[4:2]`:** 16 region values, mapped 0x2000-0x21FF (see table §1b). Note the width:
`tl_apb_regs` receives only `apb_paddr[11:0]` (`tidelink_top.sv:921`, `tl_apb_paddr[APB_ADDR_W-1:0]`,
`APB_ADDR_W`=12) and uses only `[8:2]`.

**Layer 3 — chiplet-controller sub-bank (`axi_chiplet_controller.sv:1103-1111`),
`ctrl_reg_addr[4:3]`:** Regions 4/8/C fold onto 2'b01/2'b10/2'b11; Regions 9/10/D/F all fold onto
2'b00 and are disambiguated by the mutually-exclusive flags `ctrl_reg_rf > ctrl_reg_rd >
ctrl_reg_r10 > (region9)` (priority chain, `:1104-1107`).

### 1b. TideLink register-region map (offset within 0x2000 window)
| region [8:5] | off | owner | R/W | pslverr on RO-write? |
|---|---|---|---|---|
| 0000 | 0x000-01C | apb_regs cfg/status | mixed | YES (slots 2,3,4,6) `:742` |
| 0001 | 0x020-03C | credits + PTP basic | mixed | YES (slot2 RO, slot3 WO) `:748-751` |
| 0010 | 0x040-05C | PTP HW-sync + servo cfg | mixed | **NO case** |
| 0011 | 0x060-07C | servo status + mbox (WO) | mixed | **NO case** |
| 0100 | 0x080-09C | Region 4 controller role cfg | mixed | **NO case (gap)** |
| 0101-0111 | 0x0A0-0FC | perf 5/6/7 | mixed (RO counters) | **NO case (gap)** |
| 1000 | 0x100-11C | Region 8 SWI/NEGO train | mixed | YES (slots 2,4,7) `:756` |
| 1001 | 0x120-13C | Region 9 SYNC obs (V2) | mostly RO | YES (all but slot2) `:765` |
| 1010 | 0x140-17F | Region 10 eye(V1)/perlane-wp(V2) | delegated | delegated to eye_regs `:770-774` |
| 1011 | 0x160-17F | Region 11 gpio_phy slave | delegated (top `:1205`) | delegated |
| 1100 | 0x180-19C | Region C autoneg obs | RO | YES `:768` |
| 1101 | 0x1A0-1BF | Region D rxcap obs | RO | YES `:776` |
| 1110 | 0x1C0-1DF | **Region E txgen** (top `:954`) | mixed | **NO (forced pslverr=0, top `:1352/1365`)** |
| 1111 | 0x1E0-1FF | Region F axinode obs (I4) | RO | YES `:779` |

### 1c. Parameter surface (integrator-settable)
Wrapper params (`tidelink_vivado_wrapper.v:40-189`), all recorded in `component.xml` (verified —
see §3): `SYS_ADDR_W/DATA_W`, `RAM_ADDR_W`, `FC_DATA_W`, `NUM_PHY_LANES`, **`TIDELINK_PAIR_BASE`
(default 0x44032000, `:61`)**, `PHC_LOCK_GATE_EN`, `USE_IDELAY/USE_CLKBUF/USE_T3A` (FPGA-on),
`HARDEN_SWI_ENABLE`, `STUB_SERVO/PERF/PTP`, `BYPASS_ADDR_XLAT`, `NEGO_CFG_RESET` (0x61),
`NEGO_TRAIN_CFG_RESET`, `RETIRE_EN`, `HONEST_MASK_HS`, `DEBUG_UNLOCK_DEFAULT` (1=locked-open),
`TRAIN_ENTRY_FALLBACK`. `APB_ADDR_W` is hard-set to 12 by the wrapper (`:533`).

Compile-time posture (NOT parameters — carried by flist/define): **`TIDELINK_PHY_V2`** (V1↔V2),
and the FCSM 0-4 held-on-`deps` in both ASIC flists.

---

## 2. Embedded-specific failure modes (concrete scenarios)

**S1 — Register-bank aliasing across undecoded high bits (LIVE bug, already observed).**
`tidelink_apb_regs.sv` decodes only `paddr[8:2]`; `paddr[11:9]` are dropped, and `paddr[12]` never
reaches the block (only `[11:0]` forwarded, `tidelink_top.sv:921`). So the 512-byte map repeats
across the 8 KB TideLink window. Concretely: SoC `0x2208 == 0x2008` (the documented "0x208 aliases
0x008, untrustworthy read" prior — this is `paddr[9]` non-decode), and `0x3008 == 0x2008`
(`paddr[12]` dropped). Any integrator or firmware that computes a register address with a stray
high bit set reads/writes a *different* register with no error. Writes to `0x22xx` silently hit the
real config registers (pair_base, release_threshold, CTRL) — a functional-safety concern, not just
a read artifact.

**S2 — Reserved sub-aperture answers OKAY, not error.** `paddr[14:13]==11` (SoC 0x6000-0x7FFF)
returns prdata=0 / pready=1 / **pslverr=0** (`tidelink_top.sv:834,837`). An integrator who maps a
new peripheral there (or a bus fabric that forwards a misdecoded transaction) gets silent success:
reads return 0, writes vanish. No decode-hole trap.

**S3 — Base-relocation breaks the fixed internal sub-map.** The Wlink/TideLink/addr-xlat split is
hard-wired to `paddr[14:13]` = 00/01/10. TideLink config is reachable ONLY at IP-base + 0x2000, not
IP-base + 0x0000. A consumer that assigns the IP a base and expects TideLink registers at offset 0
will actually address the **Wlink** controller. Relocation is coarse (must be 32 KB-aligned window;
`TIDELINK_PAIR_BASE` is a *separate* datapath value, NOT the APB base — easy to conflate).

**S4 — Direct-instantiation PADDR width mismatch (ASIC/nanosoc path).**
`tidelink_top.apb_paddr` is fixed `[14:0]` (`:300`) and is NOT tied to `APB_ADDR_W` (=12). A
direct RTL consumer (no Vivado wrapper) that wires a 12-bit PADDR net, or that trusts `APB_ADDR_W`
to describe the addressable range, leaves `paddr[14:13]` = 0 → `apb_sel_tidelink` and
`apb_sel_addr_xlat` never assert → **the entire TideLink + addr-translator register space is
unreachable**, while Wlink still works. Fails silently as "config writes have no effect."

**S5 — Bounded-stall watchdog covers only 1 of 3 sub-slaves.** The "structurally hang-proof"
`ext_timeout` (EXT_STALL_LIMIT=1024, `tidelink_top.sv:902-919`) is OR'd into **`tl_regs_pready`
only** (`:1386`). `apb_pready` for the Wlink region uses `wlink_pready` directly and the
addr-translator uses `adr_xlat_pready` directly (`:832-834`) — no watchdog. On a Zynq M_AXI_GP
(no bus timeout) a stuck Wlink or addr-xlat sub-slave hangs the PS forever. The hang-proof claim in
the header comment (`:893-901`) is region-specific and does not hold for 2/3 of the aperture.

**S6 — Silicon hard-stall registers are invisible to the watchdog AND to sim.** `0x21AC/0x21B0/
0x21B4` (Region D slots 3/4/5) "hard-stall the Zynq PS, uninterruptible, power-cycle only"
(`docs/AUTONOMOUS_BRINGUP.md:116`). In RTL these are Region-D reads served combinationally
(apb_regs pready=1), so **sim always returns pready=1 and can never reproduce the hang** — the
stall is above/beside the TideLink APB slave and the `ext_timeout` watchdog (which only fires on
`!tl_apb_pready`) never engages. Any exhaustive silicon register sweep MUST carry a curated
blocklist as load-bearing; the same is true for `0x4403_xxxx`-undecoded-on-ZynqMP.

**S7 — Param-not-reaching-OOC / default drift.** All the "reachability" params
(NEGO_CFG_RESET, DEBUG_UNLOCK_DEFAULT, HONEST_MASK_HS, TRAIN_ENTRY_FALLBACK, RETIRE_EN) only affect
the netlist through their **component.xml default** — a `+define+` provably does NOT reach OOC
synth (memory `project_verilog_define_never_reaches_ooc_ip`; wrapper header `:118-125`). Today
`check_wrapper_params.sh` guards ONLY `USE_IDELAY/USE_CLKBUF/USE_T3A` (`:55`). Nothing checks that
the *value* of DEBUG_UNLOCK_DEFAULT / NEGO_CFG_RESET in the wrapper matches the packaged
component.xml, and nothing STRUCTURALLY proves a per-instance `CONFIG.*` override reached the
synthesized IP. This is exactly the class that produced the SHAM mask-gate on silicon
(kr260-pair-onchip 2026-07-23, wrapper header `:161-169`).

**S8 — Flist V1↔V2 / FPGA↔ASIC provenance drift at the consumer.**
`resolve_tidelink_flist.py` processes whatever flist it is handed; it does NOT assert V1-vs-V2
posture. If a consumer points it at `tidelink_top_full_asic.flist` (no `+define+TIDELINK_PHY_V2`)
expecting V2, it silently gets V1 — the same silent-V1 class that `build_provenance.tcl` was
written to catch on the FPGA side, but the ASIC/direct-instantiation consumers do NOT run that gate
(they have no packaged IP). The V2 ASIC flist adds the define at `:37`; both ASIC flists hold
FCSM 0-4 on `deps` (`:153-158`), so the local_overrides FCSM state-machine fixes are absent from
the tapeout netlist for banks 0-4 — a divergence the consumer inherits invisibly.

**S9 — Region-10 slot-0 latent alias (currently masked).** A read of `0x2140` (Region 10 slot 0)
sets `ctrl_reg_addr = {2'b10, 3'b000}` = Region 8 slot 0 in the controller
(`tidelink_apb_regs.sv:589-591`, because `region10_hit` excludes slot 0). It is benign *only*
because apb_regs zeroes region-10 slot-0 prdata (`:708`) and the parent substitutes the gpio_phy
epoch word. Any refactor of the read-mux priority (`tidelink_top.sv:1313-1343`, the perlane_wp
exclusion is already a fragile hand-maintained slot list) can expose it. Not currently a bug;
flagged as fragile.

---

## 3. Current coverage vs gaps

**What exists (good):**
- `component.xml` DOES record all integrator params incl. NEGO_CFG_RESET, DEBUG_UNLOCK_DEFAULT,
  HONEST_MASK_HS, TRAIN_ENTRY_FALLBACK, RETIRE_EN, TIDELINK_PAIR_BASE (verified by grep of
  `imp/fpga/tidelink_ip/component.xml`). So the params are *surfaced*; the gap is verifying them.
- `check_wrapper_params.sh:55-65` greps the wrapper for USE_IDELAY/USE_CLKBUF/USE_T3A == 1'b1, and
  `:89-112` best-effort cross-checks those 3 against component.xml (only fails on an explicit `0`;
  a *missing* entry passes).
- `build_provenance.tcl`: `tl_verify_packaged_ip:164` content-hashes every flist source vs the
  packaged `src/` copy (kills stale-IP); `tl_write_manifest:253` records git SHA + V1/V2 marker +
  flist + submodule pins + USR_ACCESS. `tl_phy_marker:96` derives V1/V2 from `TIDELINK_PHY_V2` env.
- `cocotb/tidelink_apb_regs/test_region_f_decode.py`: Region F routes via `ctrl_reg_rf`, no alias
  with Region C, RO→pslverr, Region D regression. Solid but narrow (F/C/D only).
- `test_tidelink_apb_regs.py:815-871` (Shortcoming #12): RO-write→pslverr and WO-read→pslverr — but
  ONLY for Region 0/1 regs (PKT_WORD_LEN, CREDIT_COUNT, STATUS, REL_ACC, PAIR_CREDIT_COUNTER,
  PAIR_CONSUME). `test_perf_region_decode.py`, `tidelink_axinode_obs/test_axinode_obs.py`.
- `farm_gate.sh` Tier-0.a IP-match (silent-V1 + content hash + V2 marker in packaged IP).

**Gaps (with citations):**
- **G1 — No high-address alias test.** Every apb_regs test masks `addr & 0xFFF` and only drives
  0x000-0x1FF (e.g. `test_region_f_decode.py:44`). The `paddr[9]`/`paddr[12:9]` alias (S1) — the
  documented live 0x208↔0x008 bug — is UNTESTED.
- **G2 — The dedicated aliasing test was DELETED.** Only a stale
  `cocotb/tidelink_top_pair/__pycache__/test_buga_addr_aliasing.cpython-310-pytest-9.0.3.pyc`
  survives; the `.py` source is gone (confirmed: no `test_buga_addr_aliasing.py` in the dir). The
  Bug-A address-aliasing regression is no longer runnable — a rotted-out gate.
- **G3 — sim_gate runs only ONE apb_regs module.** `Makefile:606-611` (`sim_gate_axinode_obs`)
  invokes `MODULE=test_region_f_decode` only. The full `test_tidelink_apb_regs.py` (default MODULE,
  `cocotb/tidelink_apb_regs/Makefile:10`) and `test_perf_region_decode.py` are NOT in the gate — the
  pslverr / lock / saturation coverage can rot without turning sim_gate red. Same "green-but-blind"
  pattern the memory flagged for tidelink_ahb.
- **G4 — RO-write→pslverr not implemented for Regions 2/3/4/5-7/E.** `tidelink_apb_regs.sv:735-784`
  has no pslverr case for `apb_region` 0010/0011/0100/0101/0110/0111; Region E forces pslverr=0
  (`tidelink_top.sv:1352,1365`). Writes to perf RO counters and Region-4 role-config RO bits return
  OKAY. No test can catch this because the behaviour isn't in RTL.
- **G5 — No param-value / OOC structural gate.** Nothing verifies wrapper defaults for
  NEGO_CFG_RESET / DEBUG_UNLOCK_DEFAULT / HONEST_MASK_HS / TRAIN_ENTRY_FALLBACK / TIDELINK_PAIR_BASE
  match component.xml, and nothing proves a `CONFIG.*` override constant-folded into the netlist
  (memory: "md5 proves NOTHING, verify structurally"). `check_wrapper_params.sh` guards 3 of ~12.
- **G6 — Watchdog scope (S5) untested.** No sim asserts that a stuck Wlink / addr-xlat sub-slave
  cannot hang the bus (it can — no watchdog there).
- **G7 — No consumer-side flist posture assertion.** `resolve_tidelink_flist.py` never checks
  V1/V2 or FPGA/ASIC intent; the nanosoc consumers have no equivalent of `build_provenance.tcl`.

---

## 4. Proposed tests (light sim where possible; unit-level over full-pair)

Each is small and deterministic — drive the apb_regs / top APB face, no PHY bring-up.

**T1 (★ EXHAUSTIVE DECODE + ALIAS SWEEP — unit, `tidelink_apb_regs`).** For every
`paddr[8:2]` (128 word slots) drive a read and a write. Assert: (a) each implemented slot produces
its unique behaviour (prdata source + ctrl_reg_addr + write-strobe target); (b) writing an RO slot
raises pslverr; (c) **then sweep `paddr[11:9]` (and, at top level, `paddr[12]`) over a fixed slot
and assert the response is either IDENTICAL to the base (documented alias, ratcheted) or raises a
decode error — no NEW silent alias may appear.** This is the guard G1/G2 need; make the alias set a
checked-in golden so a future decode change that adds/removes an alias turns it red. Replaces the
deleted `test_buga_addr_aliasing`.

**T2 (Reserved-aperture trap — unit, `tidelink_top`).** Drive `apb_paddr[14:13]==11` and each
region value not owned by any sub-slave; assert the response is a defined decode error (pslverr) OR
a checked-in golden "silent-OKAY" waiver — so S2 is a conscious, ratcheted decision, not an
accident. (Today it is silent OKAY.)

**T3 (Base-relocation invariance — unit, `tidelink_top`).** Parameterise a synthetic APB base
offset and assert TideLink registers are reachable at base+0x2000 and Wlink at base+0x0000, and
that a transaction to base+0x0000 does NOT hit TideLink config (guards S3 against a refactor that
"simplifies" the `[14:13]` decode).

**T4 (★ Direct-instantiation PADDR-width — elaboration/unit).** Instantiate `tidelink_top` the way
the ASIC/nanosoc consumers do (no wrapper), with the PADDR net width the consumer actually uses;
assert `apb_sel_tidelink` and `apb_sel_addr_xlat` can assert (i.e. bits 14:13 are real). Fails S4
loudly at elaboration/sim instead of silently on silicon. Add an assertion that `APB_ADDR_W`≥15 or
that PADDR is ≥15 bits.

**T5 (★ STRUCTURAL param-reaches-OOC gate — script, extend `check_wrapper_params.sh`).** For EACH
integrator param (not just the 3 clock params), assert the wrapper default and the packaged
`component.xml` `<spirit:value>` agree, and FAIL on a *missing* component.xml entry (not just an
explicit 0). Then a post-elaboration structural probe: elaborate the packaged IP (or `tidelink_top`
with the param) and read the reset value of the target register (e.g. `nego_cfg_reg`,
`apb_debug_unlock` tie, `pair_base_addr`) — proving the param constant-folded, per the
"verify structurally" rule. This is the guard for S7/G5 and the sham-gate class.

**T6 (RO-write pslverr completeness — unit).** Extend `test_tidelink_apb_regs.py` to cover RO-write
→ pslverr for Regions 2/3/8/9/C/D and the perf RO counters; where RTL intentionally returns OKAY
(Region 4/E/perf), make that an explicit asserted+documented waiver so G4 is a decision on record.

**T7 (Watchdog-scope — unit, `tidelink_top`).** Force `wlink_pready` and `adr_xlat_pready` low for
>EXT_STALL_LIMIT cycles; assert the PS-facing `apb_pready` still terminates (it will NOT today —
this test documents S5/G6 as a known gap and pins any future fix).

**T8 (Silicon hazard-register blocklist — script/data gate).** Machine-check that the curated
blocklist (`0x21AC/0x21B0/0x21B4`, `0x4403_xxxx`) is present and identical across every artefact
that sweeps registers (hwtest scripts, GUI agent, docs). A drift here re-arms S6. Pure text gate;
no sim.

**T9 (Add the full apb_regs suite to sim_gate — Makefile).** Make `sim_gate` run
`test_tidelink_apb_regs` (default MODULE) AND `test_perf_region_decode` AND T1, not only
`test_region_f_decode`. Closes G3. Cheap (unit sims, seconds).

**T10 (★ Consumer flist V1/V2 + FPGA/ASIC provenance gate — script).** In (or alongside)
`resolve_tidelink_flist.py`: emit a manifest line (mirror `build_provenance.tcl:tl_phy_marker`)
recording resolved V1/V2 (presence of `+define+TIDELINK_PHY_V2`), FPGA-vs-ASIC flist name, FCSM
source (deps vs local_overrides), and the tidelink submodule pin. Assert it matches an
integrator-declared "intended posture" and fail on mismatch. Closes G7/S8 for the nanosoc chiplets
that never run the FPGA gate.

**T11 (Region-10 slot-0 alias pin — unit).** Assert that a read/write of `0x2140` cannot strobe or
return a Region-8 register (pins S9 so the fragile masking can't silently break).

**T12 (perlane_wp exclusion-list golden — unit, `tidelink_top` V2).** The hand-maintained
`eye_shim` exclusion slots (`tidelink_top.sv:1323-1342`) are a decode surface; drive each excluded
offset and assert it reaches the intended source (ctrl_reg vs eye_shim vs gpio_phy). Guards a whole
family of "reads 0 with no marker" silicon symptoms the comments describe.

**T13 (component.xml ↔ wrapper param-set completeness — script).** Assert every `parameter` on the
wrapper module face has a matching `component.xml` entry (a NEW param added to the wrapper but not
re-packaged is invisible to integrators — the "same omission as 2bd5612/51b5169" the wrapper header
keeps re-documenting). Extends T5.

---

## 5. Risk ranking

| # | Scenario / gap | Sev | Likelihood | Why |
|---|---|---|---|---|
| R1 | **S4/T4** direct-instantiation PADDR width → TideLink+xlat unreachable | ★★★★★ | High | nanosoc/ASIC consumers instantiate directly; fixed `[14:0]` decoupled from APB_ADDR_W; fails silent |
| R2 | **S7/G5/T5** param default drift / override never reaches OOC (sham-gate class) | ★★★★★ | Med-High | already burned silicon twice; only 3/12 params guarded; security-relevant (DEBUG_UNLOCK) |
| R3 | **S1/G1/G2/T1** register-bank aliasing, alias test deleted | ★★★★★ | High | LIVE bug (0x208↔0x008), guard rotted to a stale .pyc; writes to RO alias hit real config regs |
| R4 | **S8/G7/T10** consumer flist silent-V1 / FCSM-deps drift | ★★★★☆ | Med-High | ASIC consumers skip build_provenance; V2→V1 degrade is the campaign's most expensive class |
| R5 | **S5/G6/T7** watchdog covers only TideLink region → PS hang on Wlink/xlat stall | ★★★★☆ | Med | Zynq has no bus timeout; "hang-proof" claim is false for 2/3 of aperture |
| R6 | **S6/T8** silicon hard-stall regs invisible to sim + watchdog | ★★★★☆ | Med | power-cycle recovery only; any exhaustive sweep re-triggers it |
| R7 | **G3/T9** full apb_regs + perf suites not in sim_gate | ★★★☆☆ | High (rot) | green-but-blind; coverage can silently regress |
| R8 | **S2/T2** reserved aperture answers OKAY not error | ★★★☆☆ | Low-Med | bites on integrator remap / misdecode; silent write-loss |
| R9 | **G4/T6** RO-write→pslverr missing for R2/3/4/5-7/E | ★★☆☆☆ | Low | protocol-hygiene; masks integrator bugs rather than causing one |
| R10 | **S9/S12/T11/T12** region-10 slot-0 + perlane_wp fragility | ★★☆☆☆ | Low (now) | benign today; one refactor from a silent-read-0 silicon symptom |

---

## 6. Green-but-blind / unreachability flags

- **S6 is fundamentally unreachable in sim.** `0x21AC/0x21B0/0x21B4` return pready=1 in every
  simulation; the hard-stall is a silicon-only, above-the-slave phenomenon. No functional sim can
  ever be a negative control for it — coverage MUST be a curated data-gate (T8), never "the sweep
  passed in sim."
- **The alias regression is currently GREEN because its test is GONE (G2).** A rotted `.pyc` with no
  source produces no failure and no signal. Treat absence of the `.py` as red until T1 lands.
- **sim_gate is green while the bulk of apb_regs decode is untested (G3).** The gate exercises only
  `test_region_f_decode`; the pslverr/lock/saturation/perf suites pass locally but are not gated, so
  a decode change can ship with sim_gate green.
- **`+define+`-based V1/V2 selection is invisible to OOC synth (S7).** A green FPGA build proves
  nothing about which params reached the netlist unless verified structurally — md5/log-grep is not
  evidence. `check_wrapper_params.sh`'s component.xml check passes on a *missing* param entry, so a
  newly-added-but-unpackaged param reads as "OK."
- **The ASIC/direct consumers have NO provenance gate at all.** `build_provenance.tcl` /
  `farm_gate.sh` are FPGA-packaging-only; the nanosoc chiplets that embed via flist inherit
  V1/V2 and FCSM-deps posture with zero assertion (S8/G7).

---
### Load-bearing file:line index
- Top decode + reserved-OKAY: `src/rtl/tidelink_top.sv:809-837`; PADDR fixed `[14:0]`: `:300`,`:643`;
  APB_ADDR_W=12: `:45`,`:533`; watchdog TideLink-only: `:902-919`,`:1386`,`:832-834`;
  txgen Region E pslverr=0: `:954`,`:1352`,`:1365`; perlane_wp exclusion: `:1313-1343`.
- apb_regs decode `paddr[8:2]`: `src/rtl/fifo/tidelink_apb_regs.sv:210`; read mux `:615-729`;
  pslverr `:735-784` (no R2/3/4/5-7 case); region fold `:565-591`.
- Controller sub-bank mux: `src/rtl/local_overrides/axi_chiplet_controller.sv:1103-1111`.
- Wrapper params + OOC rationale: `fpga/vivado_ip/tidelink_vivado_wrapper.v:61,118-189,533`.
- Guards: `fpga/scripts/check_wrapper_params.sh:55-112`; `fpga/scripts/build_provenance.tcl:96-103,164`.
- Tests: `cocotb/tidelink_apb_regs/test_region_f_decode.py`; `.../test_tidelink_apb_regs.py:815-871`;
  gate wiring `Makefile:606-611`; deleted-source `.pyc`:
  `cocotb/tidelink_top_pair/__pycache__/test_buga_addr_aliasing.cpython-310-pytest-9.0.3.pyc`.
- Flists: `flists/tidelink_top_full_asic.flist:153-158` (FCSM deps, V1);
  `flists/tidelink_top_full_asic_v2.flist:37` (+define+TIDELINK_PHY_V2);
  consumer `nanosoc-ethernet-chiplet/flist/resolve_tidelink_flist.py`.
- Hazard regs: `docs/AUTONOMOUS_BRINGUP.md:116`.
