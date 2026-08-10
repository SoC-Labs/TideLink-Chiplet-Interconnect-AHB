# Handover → TideLink dev: the I1 FCSM recovery fix breaks KR260 link bring-up

**From:** nanoSoC eth-chiplet integration (two-board KR260 FPGA silicon).
**Date:** 2026-07-30.
**Status:** the I1 fix on `main` regresses link bring-up on real hardware. Two
candidate fixes were built and **silicon-tested — both FALSIFIED**. This hands you a
narrowed, de-risked starting point. Nothing here is merged upstream.

---

## TL;DR

`main` commit **`b98b944`** ("fix(fcsm): I1 — re-point AXI FCSM 0-4 to local_overrides +
tune state-2 CRACK gate") makes the TideLink d2d link **fail to come up** on the KR260
eth-chiplet pair. With the AXI FC nodes sourced from `deps/` (recovery-stripped) the link
trains to **FCSM=4 (LINK_IDLE)**; with them sourced from `src/rtl/local_overrides/`
(recovery, the I1 config) it **never leaves state 0** — `cr_seen=0 crack_seen=0`. So I1
**trades the sustained-traffic wedge for a bring-up failure.** It must not ship as-is.

Two things I built + tested on silicon are **NOT** the cause:
- **NOT** the state-1/2 emit-count gate (`SOCL_L6_MIN_CR_EMITS` / `SOCL_L7_MIN_CRACK_EMITS`).
- **NOT** the `out_prepend_swi_disable_crc` CRC-off reset default.

Start from the **state-1 CR emit content** and the recovery-only state, not the gates.

Also: **the sim that "proved" I1 (`cocotb/tidelink_fcsm_silicon_ratio/`) does not exist in
the tree** — the PASS-at-gate=8 claim is not reproducible here.

---

## 1. The regression (silicon fact, one variable)

The eth-chiplet FPGA build uses `flists/tidelink_fpga_v2.flist`. The **only** change
between the working image and the failing image is which copies of the 5 AXI data-plane
FC nodes that flist pulls:

| FCSM 0–4 source | KR260 bring-up | Notes |
|---|---|---|
| `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM{,_1..4}.v` (recovery-stripped) | **UP** — `cr_seen=1 crack_seen=1 cal_done=1 fcsm=4`, both dies (proven 4×) | wedges under sustained cross-die traffic (the original bug I1 targets) |
| `src/rtl/local_overrides/WlinkGenericFCSM{,_1..4}.v` (recovery, I1) | **DOWN** — `cr_seen=0 crack_seen=0 cal_done=0 fcsm=0`, both dies | `SWI_LANE_STATUS = 0x00100000`, unchanging |

Everything else (PHY, RX LinkLayer, calibrator, autoneg — all from `local_overrides` via
the V2 flist) is **identical** in both images. `FCSM_5` stays `deps`; `FCSM_6` is the
`local_overrides` sideband node in both.

`cr_seen`/`crack_seen` here are the FCSM **credit / CRACK handshake** signals
(`cr_pkt_seen_tx_demet_io_out` / `crack_pkt_seen_tx_demet_io_out`), i.e. "this node's RX
saw the peer's CR / CRACK." They are 0 → the initial CR exchange never starts.

## 2. How it's observed

Two-board KR260, driven PS-side over the eth-chiplet's `eth_ss_0` AHB backdoor (no
firmware/SWD). The TideLink APB is at SoC `0x2E03_0000`. Bring-up (both dies together,
die_a master / die_b slave): write `ROLE_CFG` (`+0x2080`) `0x02`/`0x03`; poll
`SWI_LANE_STATUS` (`+0x2108`) bit16 `cal_done`; `SWI_TRAINING_MODE`(`+0x2100`)=0;
`WL_LINK_ENABLE_RESET`(`+0x0208`) sequence; poll `fcsm` (bits[19:17]) == 4. The failing
image never gets `cal_done`/`cr_seen`; the calibrator's `cal_done` never asserts because
the FC never reaches data mode. The ribbon + PHY are proven good (the deps image links up
on the same two boards immediately before/after every failing run).

## 3. Ruled OUT on silicon (do not re-investigate)

- **PHY / ribbon** — `deps/tidelink-phy 5c76e76`, `deps/tidelink-gpio-phy 6ee8418`
  identical; baseline links up on the same boards.
- **Timing** — the failing image closes **WNS = +0.304 ns (setup met)**; hold ≈ −22 ns,
  identical to the working baseline (pre-existing). Not timing.
- **Integration-side** (eth-chiplet `DEVICE_CLASS` strap, autoneg/`tidelink_top`) — the
  strapped die is `DEVICE_CLASS=1` (= RTL default, a no-op) and still fails;
  `tidelink_top.sv`/`tidelink_autoneg.sv` were byte-identical to the working image in one
  of the failing builds.
- **Incomplete extraction** — the *full* `main` merge (all I1 companions) fails identically
  to a minimal FCSM-only extraction. It is the FCSM RTL itself.

## 4. Candidate fixes I built + FALSIFIED on silicon

Both were compiled into full KR260 bitstreams (edit verified present in the packaged IP +
both synth copies) and bench-tested. Both gave the **byte-identical** failure signature.

| Fix | What I changed | Result |
|---|---|---|
| **v1** | Ungate the emit gates: `wire socl_l6_cr_emit_gate_ok = (~socl_l7_reached_link_data) \| (count>=SOCL_L6_MIN_CR_EMITS);` (and the L7 mirror), in all 5 AXI nodes — so state-1/2 exit is deps-like (leave on peer-seen) until first LINK_DATA, gate armed only for the traffic phase | **FALSIFIED** — link still down |
| **v2** | Flip the 5 AXI nodes' `out_prepend_swi_disable_crc` reset default `1'h1`→`1'h0` (CRC-ON), matching the **working** `FCSM_6` (`<= 1'h0`) and `deps` (`<= 1'h0`) | **FALSIFIED** — link still down |

Rationale that made these look right — and why the falsification is informative:
- **v1:** the emit gate ties state-1/2 exit to a fixed count of this node's own CR/CRACK
  transmits (`SOCL_L6_MIN_CR_EMITS=32`, `SOCL_L7_MIN_CRACK_EMITS=8`). But `FCSM_6` uses
  the **same** gate logic at 32/32 and brings up (single sideband node), so the threshold
  was never the discriminator — and ungating it confirmed the gate is not the blocker.
- **v2:** the 5 AXI nodes were the **only** FCSMs defaulting CRC-off; `FCSM_6` and `deps`
  default CRC-on. A TX-format change was a clean suspect for breaking the RX CR framing.
  Falsified → the CRC default is not the blocker either.

**Both fixes on branch `integ/i1-fcsm-on-proven` (LOCAL, do-not-merge):**
`0853c4c` (v1) and `6d85c68` (v2, includes v1). Base is `809f038` + the I1 FCSM re-point.

## 5. Where to look next (still-unaddressed `local_overrides` vs `deps` FCSM diffs)

Priority order, given `cr_seen` never even flickers (the break is at/before the state-1 CR
emit, not the exit gating or CRC):

1. **State-1 CR emit content / selection** — what the recovery node actually drives onto
   the link in state 1 (the `FC.scala ~459-486` `_GEN_*` region). If the emitted CR
   word/prepend differs from `deps`, the shared RX LinkLayer never latches it. This is the
   top suspect.
2. **Recovery-only state at reset** — `socl_l6_cr_emit_count`, `socl_l7_crack_emit_count`,
   `socl_l7_reached_link_data`, `socl_l7_real_crc_seen`, `socl_reack_*`, and the extra
   `always` blocks. Confirm none gates TX-enable or the CR emit in states 0–3 out of reset.
3. **`isNotExpPacket_l7` / `socl_l7_crack_release`** feedback into `send_nack_req` and the
   emit-select during bring-up.

A clean way to see all of it: `diff` `src/rtl/local_overrides/WlinkGenericFCSM.v` against
`deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM.v` and ignore the recovery regs
that are provably states-≥4 only.

## 6. The sim gap (please close before re-shipping)

- `cocotb/tidelink_fcsm_silicon_ratio/` — referenced in RTL comments
  (`local_overrides/WlinkGenericFCSM.v` ~line 71) and in the flist, but **the directory
  does not exist** in this checkout. The "recovery PASSes at gate=8" claim is not
  reproducible. Nearest real env: `cocotb/tidelink_error_injection`.
- Whatever silicon-ratio sim ran evidently proved *"recovery fires under injected ACK-loss
  on an idealized single pair"* — a **different** question from *"does the initial CR/CRACK
  handshake complete across the 5 AXI nodes time-muxed onto one serial link, with a
  slow-aligning RX framer, at the 40 ns link:app ratio, on two asynchronously-reset dies."*
  The four things that TB must model and evidently doesn't: (1) RX LinkLayer byte-align /
  hunt latency after reset; (2) the 5-way multiplex of the AXI FC nodes onto one link;
  (3) async reset-release + clock phase between the two dies (the finish-first race);
  (4) calibrator/`cal_done` coupling. Build that pair-TB and the state-1 emit bug should
  reproduce without a board cycle.

## 7. The ask

A recovery-capable AXI FCSM that **brings up (FCSM=4) AND recovers under sustained
traffic** at the KR260 silicon ratio. Today: `deps` brings up but has no recovery;
`local_overrides` (I1) has recovery but does not bring up. Neither the emit-gate threshold
nor the CRC default is the lever (both eliminated on silicon).

## 8. Key references

- Regression commit (yours, `main`): **`b98b944`**.
- Failing FCSMs: `src/rtl/local_overrides/WlinkGenericFCSM{,_1,_2,_3,_4}.v`. Working
  reference: `.../WlinkGenericFCSM_6.v` (sideband) and
  `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM{,_1..4}.v`.
- Gate localparams: `SOCL_L6_MIN_CR_EMITS` (=32) and `SOCL_L7_MIN_CRACK_EMITS` (=8, lowered
  by I1) near the top of each AXI FCSM; the sticky `socl_l7_reached_link_data` (set at
  `state==3'h5`) is the arm/disarm hook (`socl_l7_bringup_forgive` already uses it).
- CRC default: `out_prepend_swi_disable_crc <= 1'h1` (AXI) vs `<= 1'h0` (FCSM_6/deps);
  SW override is `auto_in_pwdata[16]` of the per-node SWI reg.
- Flist: `flists/tidelink_fpga_v2.flist`, FCSM region — carries a **stale** "reverted to
  deps" comment while actually pointing FCSM 0–4 at `local_overrides` (please fix the
  comment).
- My candidate branch (LOCAL, do-not-merge): `integ/i1-fcsm-on-proven`
  (`90fe6cc`→`0853c4c`→`6d85c68`).
- Fuller eth-chiplet-side write-up (silicon tables, ruled-out list): eth-chiplet repo
  `docs/I1_FCSM_BRINGUP_REGRESSION.md` and `docs/TIDELINK_SILICON_FEEDBACK.md`.

**Boards:** restored to the working deps-FCSM baseline (link UP), leases released.
