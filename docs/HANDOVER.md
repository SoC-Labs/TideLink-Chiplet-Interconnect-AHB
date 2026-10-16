# TideLink handover, October 2026

Read this first. It says what state TideLink is in, where everything lives, and what is still open.
The rules for changing anything are in [CONTRIBUTING.md](../CONTRIBUTING.md). The live bug list is
[BUG_REGISTRY.yaml](BUG_REGISTRY.yaml) (rendered: [bug_registry.html](bug_registry.html)).

As of: 2026-10-20. Owner: David Mapstone (SoC Labs).

## 1. State in one paragraph

TideLink is the Wlink-based AHB chiplet interconnect used by the compute chiplet and the Ethernet chiplet.
Both chiplets have taped out with it: compute W1fin7f went to imec on 2026-10-15, and eth rc4 is frozen.
Both silicon releases carry known errata (section 5). The RTL on `main` contains the fixes for those errata,
so it is the starting point for the next spin. It is gate-green, and it is hardware-proven on the KR260
onchip image for the items listed in the registry as `hw_proven`. The work that remains is mostly
signoff collateral for that next spin (LEC/STA/area of the hardened FC nodes), plus a short list of deferred
decisions (section 4).

## 2. Where things are

| What | Where |
|---|---|
| The only branch | `main` on `origin` (GitHub SoC-Labs/TideLink-Chiplet-Interconnect-AHB). Protected: PR required, no force-push, no delete. |
| Every older line of work | annotated tags `keep/*` (pins that consumers or evidence cite) and `archive/*` (`archive/local/*`, `archive/ethclone/*`, `archive/gitlab/*`, ...). `git tag -l 'keep/*' 'archive/*'` lists them; `git log <tag>` shows the work. Nothing was deleted without a tag. |
| Old remotes | `gitlab`, `ethclone`, `mainclone` were removed 2026-10-16 after their orphan commits were tagged under `archive/`. |
| Hardware evidence | `imp/hw_gate/<bug>_<date>/`, tracked, scrubbed of host paths and IPs. Every `hw_proven` registry entry points into it. |
| Gate results | `imp/sim_gate/` (generated, not tracked) |
| HW tooling | `scripts/hw/` + `pynq_host/hw_regress/`; how to use: [scripts/hw/RUNBOOK.md](../scripts/hw/RUNBOOK.md) |
| CI | `.github/workflows/sim-gate.yml` on a self-hosted runner; setup: [CI_RUNNER.md](CI_RUNNER.md) |
| Architecture / integration | [README.md](README.md) is the index of current docs |

Files in `docs/` whose names carry a date (`*_2026_07_*`, `HANDOVER_*_2026-08-*`, `OVERNIGHT_*`, `STAGE4_*`, ...)
are **historical records**. They are kept because the registry and older evidence cite them. Do not treat them
as current; where they disagree with the registry, the registry wins.

## 3. How to check that it still works

| Check | Command | Time |
|---|---|---|
| Full regression, the authority for landing | `make sim_gate_regressions` (env: CONTRIBUTING §6, pinned `CHIPLET_HOME` + `TIDECHART_HOME`) | ~2 h |
| Registry and checker self-tests | `make selfcheck_gates sim_gate_registry_coverage` | <1 min |
| HW tooling offline rehearsal | `make hw_tooling_selftest` | ~1 min |
| KR260 onchip run | `scripts/hw/build.sh` then `scripts/hw/hw_test.sh` (RUNBOOK) | build 45-90 min, run ~10 min |
| FC-node CRC-replay contract (SVA) | `make fc_sva` | ~4 min |

Without the pinned `CHIPLET_HOME` and `TIDECHART_HOME` the TideChart pair suites fail in seconds, and that failure is the env, not the RTL.

## 4. What is open

Owner and next step for every entry are in the registry (`truth_pass_2026_10` blocks); the summary is
[REGISTRY_STATUS_2026-10.md](REGISTRY_STATUS_2026-10.md). The ones that matter for the next spin:

1. **ASIC re-synthesis collateral for TL-018/TL-019.** The ASIC flists now take the hardened FC-node overrides
   with CRC on at reset. Area, timing and LEC for the added recovery logic (about 250 flops) are not measured.
   Needs: synthesis, LEC against `main`, STA. Waiver W1 covers the gap until then.
2. **ASIC flow tool consistency** (PR #14): one `ASIC_PHY` knob so Formality, PrimeTime, Calibre and RTLA read
   the flist Fusion Compiler synthesised.
3. **Verification P1** (PR #16): CRC-replay contract SVA on every FC node, VC Formal proof, CI workflow. The
   self-hosted runner still has to be registered (CI_RUNNER.md).
4. **Board campaigns**: TL-001 (n=20 eth-pair delivery), TL-009 (sustained cross-die write soak with TL-037), TL-042.
5. **Decisions waiting on David**: TL-014, TL-021, TL-024 and TL-029 (waivers), TL-030, TL-045, TL-049.

Not TideLink's to fix: TL-023 and TL-028 (eth ASIC repos), TL-034 (tidechart repo).

## 5. Silicon errata (shipped dies)

| Erratum | Dies | RTL fix on `main` | Silicon mitigation |
|---|---|---|---|
| TL-059: a CRC-detected sideband (DataID 0xA1) message is lost instead of replayed | compute W1fin7f (ECO4 lineage), eth rc4 | design E, PR #8 | compute FW rev4; eth rc4 SB-CRC firmware |
| TL-057: FIFO SRAM macros ship EMA=000; the macro default is 010 (also the MAC BD `rf_01k`) | eth rc4 | EMA 010 | erratum M1 (draft, eth project) |

The per-die erratum text was delivered to the compute and eth projects. For any other fix, check whether a
given die has it against that die's netlist, not this table; the registry records which netlists were checked.

## 6. Landmines (each cost real time)

- **Error injector** is TLAPB+0x23C. The 0x003C alias is unmapped, and every result taken there before 2026-10-14 is void.
- **die_b is the slave.** Its Wlink APB bank is read-only unless debug-unlock is asserted (GPIO 0x8C04_1000 on the onchip image).
- **`0x8403_xxxx` outside the decoded range hangs the PS.** Use the register map, and run `make check_host_addrs`.
- **KR260 recovery is JTAG POR only.** `reboot` wedges the board. Files staged just before a POR can vanish, so `sync` and re-check md5 (hw_test.sh does this).
- **Never reload the PL on a live link.** Never run two boards' tests without holding the board lock (`flock`).
- **Stale simv after an RTL or flist edit gives false greens.** Use a fresh `SIM_BUILD`; the gate stamps and checks this.
- **A wire-name grep on a netlist always finds nothing.** Use flop markers and a must-be-present control.

## 7. Hardware rig

Two KR260 boards. The onchip image puts both TideLink dies on board 1; board 2 is only POR'd. The compute
and eth projects share the boards, so restore their standard images after a run (hw_test.sh prints what to restore).
Site settings (IPs, lock path, POR host) live only in `scripts/hw/hw_rig.env` (gitignored) and passwords only in the shell environment.
