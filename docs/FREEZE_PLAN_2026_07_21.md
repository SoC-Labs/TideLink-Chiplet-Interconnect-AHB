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

## Remaining work to freeze — STATUS 2026-07-22

| Step | What | Status |
|---|---|---|
| A | **Full `make sim_gate`** on the branch | ✅ **DONE — 33 PASS + 1 XFAIL (rc=0)**. Ran on the idle machine (the "Vivado build" was an idle 6.5-day session owned by another user, 0–2% CPU, 94 GB RAM free — no OOM risk). |
| B | **F14-A re-baseline** | ✅ **DONE (f7841a2)** — CRC re-enable CLOSES F14-A; promoted from XFAIL sentinel to positive `f14a_crc_catch` PASS (lane-7 corruption rejected, never silently committed, CRC fires). |
| C | **CI clone job** fetches the 3 sibling repos | ✅ wired. ⏳ **David: confirm branch pins + GitHub runner creds** for the chiplet repo (or split tc/eth co-sim into a non-blocking CI job). |
| D | **Hardware demo** | ✅ **DELIVERED** — KR260 **12/12 byte-exact, in-order, CRC-on clean (crc_errors=0)** on real hardware, which silicon-validates the CRC re-enable. The earlier "intermittent delivery" was a receiver read-protocol artifact (fixed-offset read of a streaming FIFO), not a link defect. |

## What remains to *declare* freeze (David's calls)
1. **F14-B waiver sign-off.** Waiver drafted: [WAIVER_F14B_DATAMODE_WEDGE.md](WAIVER_F14B_DATAMODE_WEDGE.md) — sim-only data-mode wedge, both-die POR clears, detectable via tagged-data canary, SWI_FORCE_RECAL recovers eye-cal cases; sentinel stays in the gate so the waiver can't rot. Needs your ✅.
2. **CI pins + GitHub creds** so a fresh pipeline is green (chiplet repo is on GitHub).
3. **Merge decision:** `integ/freeze-2026-07-21` → `integ/consolidation-2026-07` → `main`, and push. Tagged locally `freeze-2026-07-22` (annotated, unpushed). No push has been done — awaiting your go.

## Closed this session (was "remaining")
- ✅ **`sim_gate_dftelab`** — the ASIC DFT wrapper (the actual tapeout top, where the silicon-param
  defaults live) was in no flist and no gate; that is exactly why the dead-HONEST_MASK_HS strap went
  unseen. Now elaborated in the gate (`dft_wrapper_elab` PASS). Gate is now **34 PASS + 1 XFAIL**.

## Post-freeze (non-blocking) enhancements
- `socl_l7_real_crc_seen` W1C (self-healing watchdog), the chiplet `tl_data_mode_o` one-net swap
  (`nanosoc_eth_chiplet.sv`), F14-B retrain-lite recovery.

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
