# TideLink RTL-Freeze Plan — 2026-07-21

Single source of truth for the freeze push. Branch: **`integ/freeze-2026-07-21`**
(cut from `integ/consolidation-2026-07` @ 9c15785; integ is left untouched).

## The four freeze decisions (David, 2026-07-21)

| # | Decision | Chosen | Status on branch |
|---|---|---|---|
| 1 | Consolidation strategy | Commit the gate-green tree, then graft w2 | ✅ done (602ef8d + merge 683280b) |
| 2 | RX-FIFO TWIN 2 — AHB-write-to-RX supported? | **Yes** → w2 qualify-the-arm (ENABLE_AHB_WRITE=1 + guard) | ✅ done (merge, `.ENABLE_AHB_WRITE(ENABLE_AHB_WRITE)`, default 1'b1) |
| 3 | Link-layer CRC | **Root-cause & re-enable now** | ✅ done (ac7dee8, POR default 1'h1→1'h0) |
| 4 | w2's 3 silicon-default flips | **Carry all three (authorized)** | ✅ done (verified reaching dft_wrapper) |

## Branch state (what is committed)

```
ac7dee8 fix(fc): re-enable link-layer CRC by POR default
683280b merge: graft integ/consolidation-w2 (silicon decisions + wider gate)
602ef8d snapshot: gate-green consolidation candidate (23 PASS + 2 XFAIL, 07-19)
9c15785 (integ/consolidation-2026-07)  ← base, untouched
```
Tag `freeze-candidate-snapshot-2026-07-21` marks the pre-merge green point.

### Silicon defaults now on the ASIC tapeout top (`tidelink_dft_wrapper.sv`) — AUDITED
- `HONEST_MASK_HS = 1'b1` (:93) — honest mask handshake; inert at shipped unlock defaults but no longer dead silicon.
- `ROLE_FROM_STRAP = 1'b1` (:144) — terminal role from strap (survives dead-I2C; enables zero-poke autonomy).
- `NEGO_CFG_RESET = 7'h61` (:137, forwarded down; `tidelink_top` default stays 7'h00 by w2 design so FPGA sets its own).
- `ENABLE_AHB_WRITE = 1'b1` with the `ahb_pkt_start_ok` + zero-length-reject guard (TWIN 2 closed without removing the feature).
- CRC ON by POR (`WlinkGenericFCSM_6.v` local override, restores upstream default).
- B1 `SWI_FORCE_RECAL` W1P retrain (calibrator override + axi_chiplet_controller) and B3 `tl_data_mode_o` export present.

Elaboration verified: `asic_v2_elab` PASS, `asic_v1_elab` PASS on the merged+CRC branch.

## CRC re-enable — the important nuance (docs/CRC_ROOTCAUSE.md)

Root cause of the June disable = **(c) real corruption, not a false fire.** The CRC
was correctly catching a marginal 4-lane (0xE4) 2-beat DATA eye at 6.25 MHz; TX/RX
are symmetric and an ideal-pad sim CRCs the path clean, so it was never an RTL bug.
Disabling it hid real corruption (the F14-A silent-commit). The "die_b register
unwritable" premise is refuted (bit[16]@0x1714 is a normal APB reg both dies).

**Two consequences that MUST be handled:**
1. **Eye coupling (bring-up):** a re-enabled CRC will legitimately fire/NACK on a
   marginal eye. **Bring the FPGA link up at 25 MHz** (byte-exact both dirs) with the
   capture-clock BUFG hoist. On a bad eye it NACK-wedges *by design*. The ASIC path
   is a different physical regime and is not FPGA-eye-limited.
2. **Sticky watchdog:** `socl_l7_real_crc_seen` is POR-clear-only — the first real
   CRC error permanently disarms the state-7 NACK watchdog for that reset cycle
   (intentional). A resettable W1C is a documented **post-freeze enhancement**.
3. **Gate impact:** the F14-A/F14-B XFAIL sentinels assert the *CRC-off* silent-
   corruption signature. With CRC on they flip **XFAIL→XCHG** (CRC now *catches* the
   corruption) — this fails the gate until re-baselined. That is expected and
   desirable; see remaining work.

## Remaining work to freeze

| Step | What | Blocker |
|---|---|---|
| A | **Run full `make sim_gate`** on the branch — captures the new F14-with-CRC-on signatures and validates the whole merge behaviourally | ⛔ a Vivado build was running (07-21); do NOT co-run (OOM = fake regressions). Script staged: `scratchpad/run_gate.sh` |
| B | **Re-baseline the F14 sentinels** to positive "CRC catches + rejects" assertions (was silent-corruption XFAIL). Harden `crc_diag/test_crc_matrix` cells B–D asserts; add an inject-corrupt-and-assert-`crc_errors`++-AND-rejected test; promote `sim_gate_nack_wedge` (parked) | needs step A output for the exact new signatures |
| C | **CI clone job** must fetch the 3 sibling repos or 6 suites go red on a fresh pipeline. URLs: tidechart `git.soton.ac.uk:soclabs/tidechart.git`; ethernet-subsystem-ahb `git.soton.ac.uk:soclabs/ethernet-subsystem-ahb.git`; chiplet **GitHub** `SoC-Labs/NanoSoC-Ethernet-Chiplet` (needs GitHub runner creds). All on feature branches — **pins are David's call.** Resolve via `TIDECHART_HOME`/`CHIPLET_HOME`/`ETH_SS_HOME`. Alternative: split the tc/eth co-sim into a non-blocking CI job (they test sibling integration, not tidelink tapeout correctness) | David: branch pins + GitHub creds |
| D | **Hardware demo** — deploy the Set-B on-chip bitstream (md5 `8f8792c9…`, WNS +28.3, BUFG capture clock), AFI canaries green both dies, byte-exact data at 25 MHz. Best vehicle: `kr260-pair-onchip` (one board, no ribbon, no pin lottery). PTP = exploratory upside only (never synced on HW) | David: board lease + `KR260_PASSWORD`/ssh keys |

## Open items needing David (not blocking A/B)

- **Sibling CI pins + GitHub creds** (step C).
- **AFI persistence** across reboot (systemd unit; our psu_init never runs on Kria).
- **`socl_l7_real_crc_seen` W1C** — post-freeze self-healing enhancement (or accept sticky).
- **The ASIC DFT wrapper is in no flist and no gate** (`sim_gate_dftelab` gap) — if it's the tapeout top, why does nothing elaborate it? Add the elab suite regardless.
- **Chiplet one-net swap** for `tl_data_mode_o` (`nanosoc_eth_chiplet.sv:809`) + FPGA IP re-package so the pin exists.
- **HONEST_MASK_HS=1 is inert** at shipped unlock defaults (controller ORs `apb_debug_unlock_i`) — confirm that's intended, or the debug-unlock strap is still effectively always-open.

## Bitstreams (Set B — timing-clean, capture-clock BUFG in)

Stranded on `wip/kr260-recovery-2026-07` worktree `imp/fpga/output/`; must be
rebuilt from this freeze branch before deploy (do NOT deploy the in-tree Set-A
`-ptp` builds — they fail timing, WNS −2.4/−2.7).

| target | md5 | WNS |
|---|---|---|
| kr260-pair-onchip | 8f8792c975d3dc27790c5631a042b400 | +28.306 |
| kr260-pair-nptp | 436e33572389e3ed8982eabc16a97e3e | +0.745 |
| kr260-pair-flip-nptp | 60164ed348b220ace98aab5bda89bb91 | +1.338 |
| kr260-pair-ptp | b221e071d17e7f4651fee7a25e1ccd52 | +1.089 |
| kr260-pair-flip-ptp | 551b9acb0c51b8aa9e5b649b6bc985e8 | +1.262 |

## Do-not-forget rules (from memory)
- Never co-run Vivado + sim_gate (OOM = fake regressions).
- `make -n sim_gate` writes FAKE pass files — never use it.
- Export `TIDELINK_PHY_V2=1` or you build a fix-less V1.
- KR260 canary before trusting any reading: `rd 0x8403_0204`==0x1, `rd 0x8403_0214`==0xE4E4 (else re-apply the AFI poke).
- Never `reboot` a KR260 (JTAG-POR only) — power-cycle.
