# KR260 recovery plan — 2026-07-17 (multi-agent, coordinated)

Owner: assessment session (Claude, srv03335). Coordinates with the live hardware-debug session
via `~/.claude/projects/.../memory/project_kr260_link_up_image_swap_2026_07_17.md` (§3a-MECHANISM).
This doc is the cross-session contract: **lane ownership + gates**. Do not start work in a lane you
don't own.

## ⚡ STATUS UPDATE (15:15) — G0 CONFIRMED AND APPLIED BY THE LIVE SESSION
AFI measured on BOTH boards: LPD 0xFF419000=0x0000_0200 (128-bit), FPD 0xFD615000=0x0000_0A00
(128-bit) vs the 32-bit BD ⇒ the 16-byte-stride dead-word rule, exactly. Cleared [9:8] on both ⇒
0x204→0x1, 0x214→0xE4E4, 0x208→0x27f07, and **cal=1 on BOTH dies, slave fcsm=4 — first ever KR260
link-up**. No rebuild was needed for this defect; contingency lane C is CANCELLED.
NEW FRONT BLOCKER: master fcsm=2 — `HARDEN_SWI_ENABLE=1` (tidelink_top.sv, no BD override) masks
bit[3] swi_swreset on every 0x208 write, so the FC/LL never gets its reset pulse (KR260's baked
NEGO_CFG_RESET=0x61 consumed the cold-boot trigger). Fix candidates for the build lane: per-target
HARDEN_SWI_ENABLE=0 override for kr260, or a reviewed non-0x208 swreset path. ALSO new: the
deployed build shows HOLD violations (WNS −2.174/TNS −1986, phc_0/u_clock_core + pad_tx) on top of
the setup failure R1 is fixing. AFI persistence (boot-path/systemd re-poke) is lane R4's task.

## Ground truth (as of 15:00)
- The KR260 control plane drops every 32-bit word at odd 8-byte (likely 16-byte) alignment —
  platform-wide, every APB slave, both boards, survives PL reload. Proven on hardware by the live
  session (0x230 TOOK vs 0x214 IGNORED; PHC 0x8405_0008 IGNORED).
- Prime mechanism candidate (static analysis, NOT yet measured): **AFI PS-port width mismatch** —
  stock Kria firmware programs `afi_fs` (LPD_SLCR 0xFF419000[9:8] = HPM0_LPD; FPD_SLCR
  0xFD615000[9:8] = HPM0_FPD; 00=32b default / 01=64b / 10=128b); our psu_init never runs; BD
  assumes 32-bit on both. If confirmed, **no rebuild is needed for this defect** — a devmem poke
  fixes it, re-applied per boot.
- The link itself is healthier than recorded: mask flops healthy (0xE4), anchors genuine, all 8
  conductors good, training-mode escape works.

## Gates
- **G0 (HW lane, do FIRST, blocks the SmartConnect theory):** on either board, as root:
  `devmem 0xFF419000` and `devmem 0xFD615000`. If 0xFF419000[9:8] != 0 → AFI confirmed →
  `devmem 0xFF419000 32 <val & ~0x300>`; canaries: `devmem 0x84030204` → 0x00000001,
  `devmem 0x84030214` → 0x0000E4E4, write 0x84050008=40 → reads 40. Fix 0xFD615000[9:8] the same
  way (data plane). Apply on BOTH boards. If [9:8]==0 already → AFI refuted → SmartConnect BD trace
  becomes the front-runner (contingency lane C).
- **G1:** R1–R5 diffs adversarially reviewed + sim_gate green → allowed to build.
- **G2:** fresh bitstreams structurally verified (V2 markers, RETIRE_EN, WNS ≥ 0) → allowed to
  deploy (power-cycle → deploy BOTH → bring-up → test; lease rules apply).
- **G3:** bring-up statistics N≥8 per die (the anchor is a placement lottery — n=1 proves nothing).
  Success criterion = control-plane canaries + EPOCH anchored + byte-exact channel data both
  directions. NOT cal/fcsm alone.

## Lanes
- **HW lane (live session / David):** G0 AFI check; then training-mode escape (R8=0x1C), swi_recal
  calibrator arm (R8 0x1F→0x1D both dies), manual recipe with devmem/tl_poke only (absolute
  addresses; mirrored staging). DO NOT start a Vivado rebuild — the rebuild lane is owned here and
  is gated on G0/G1.
- **R1 (repo):** kr260 ptp targets MMCM fix — hclk and phc_clk must not be two near-identical
  frequencies (WNS −2.427 ns, 1673 endpoints). Files: `fpga/targets/kr260-pair-ptp/tidelink_design.tcl`,
  `fpga/targets/kr260-pair-flip-ptp/tidelink_design.tcl`.
- **R2 (repo):** I2C `PULLUP TRUE` in all buildable kr260 XDCs + floating-input audit.
- **R3 (repo):** port the Z2 capture-clock-tree fix (phaseB BUFG parent hoist — NOT USE_CAP_CLKBUF,
  which kills the link) into kr260 targets; respects USE_IDELAY=0 / HDIO constraints.
- **R4 (repo):** AFI check/--fix script + deploy-path integration + board-env docs (cma/kexec/
  fpgautil/no-reboot) + bench checklist.
- **R5 (repo):** tooling hardening — Z2-only guards on scripts that hang a ZynqMP (undecoded
  0x4403), tl39 loud-fail through the stderr-discarding harness, verify_build.sh reads the OOC
  synth log + fails on WNS<0.
- **Build lane (this session, after G1):** rebuild `kr260-pair-nptp` (primary bring-up vehicle,
  no PHC CDC) AND `kr260-pair-ptp` (+flips) from clean integ HEAD (post-b1e1199). Never
  co-scheduled with sim_gate (OOM).
- **Contingency C (only if G0 refutes AFI):** BD/netlist trace of the control SmartConnect,
  paddr[2]/[3] handling, per the live session's note.

## Non-goals (deliberately out of scope)
- LANE_MASK 0xE4→0xFF (the 2× lever) — separate campaign, do not conflate with the recovery build.
- fifoSize/packing changes — known credit-fix interaction, ship separately.
