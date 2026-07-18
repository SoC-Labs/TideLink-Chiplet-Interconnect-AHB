# TideLink F14 — Error Injection / Recovery Findings (sim)

**Date:** 2026-07-18 · **Lane:** Y-C (verification-plan gap F14)
**Bench:** `cocotb/tidelink_error_injection/` (new; this lane owns it)
**Config:** V2 (`TIDELINK_PHY_V2=1`), `tidelink_top_pair_v2`-derived harness,
EPOCH_PROFILE=zero (no skew), VCS, SW bring-up (`BYPASS_AUTONEG=1`).

> Closes the "no systematic degradation/recovery matrix exists" gap recorded at
> `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:70` (F14) and the checklist item at
> `:345`. Prior F14 coverage was ad-hoc power-cycle recovery only
> (`fpga/hw_regression/overnight_autonomy.sh`).

---

## 1. Headline

**Two tapeout-gating findings, both reproduced with controls:**

1. **F14-A (CRITICAL — SILENT CORRUPTION):** corrupting **lane 7** of a direction
   causes the receiver to **COMMIT a packet with a corrupted length and corrupted
   payload** instead of rejecting it, and **no CRC error is raised**
   (`crc_errors` and `io_rx_crc_err` stayed 0 in **all 12** trials). Reproduced
   **4/4 in three independent fault modes** (flip, stuck-1, stuck-0). The
   **adjacent lane 6, same stimulus, is correctly NOT committed 4/4** — so this is
   a lane-7-specific escape, not a general "corruption gets through".
2. **F14-B (HIGH — WEDGE):** any **transient link disturbance during data mode**
   (all-lane corruption, link-clock dropout, or a single-lane X) leaves the link
   **wedged in a way the standard SW re-bring-up (`to_data_mode` + CR/CRACK)
   CANNOT clear**. Only a **full POR of BOTH dies** recovers it. Root cause is
   architectural: the SYNC beacon is OFF in data mode, and `to_data_mode` does
   not re-arm the deskew/calibrator.

Everything else tested **recovers**: reset storms (N≤5), single-die LL swreset,
SYNC-patterned payloads, and the phantom-pop regression.

---

## 2. Methodology

### 2.1 Bench and injection mechanism

`cocotb/tidelink_error_injection/` is self-contained. It compiles the shared V2
RTL flist (`flists/tidelink_fpga_v2.flist`) **read-only** — no shared RTL was
edited. Files owned by this lane:

| File | Role |
|---|---|
| `err_inject.sv` | **NEW.** The fault injector: per-lane `stuck-0 / stuck-1 / stuck-X / flip` + `clk_kill` (link-clock dropout). All controls are decl-initialised **undriven** regs, so a cocotb deposit is the only driver and the default is **pure passthrough**. |
| `tb_top.sv` | Copy of the v2 pair harness with **one surgical edit**: both pad directions now route `pad_skid -> err_inject -> peer RX` (replacing the s2m-only, flip-only `eye_fault`). |
| `pad_skid.sv`, `pair_v2_common.py` | Verbatim copies (per-directory copy is the repo convention). |
| `errinj_common.py` | Injection + recovery-ladder helpers. |
| `test_ei_*.py` | The six scenarios + the reproducibility test. |

Injection points (both directions, post-skid / pre-RX):
`u_inj_m2s` corrupts the **slave's** RX; `u_inj_s2m` corrupts the **master's** RX.
Die reset uses the harness's existing per-die POR gate (`tb_top.sv:165`) and the
real **LL swreset via APB 0x0208 bit[3]** (`Wlink.v:2457-2463`).

### 2.2 Protocol per scenario

Every test **(a)** proves the link healthy first (byte-exact packet **both**
directions + both FCSMs in LINK_IDLE), **(b)** injects precisely, **(c)** re-checks
byte-exact data, **(d)** classifies via a fixed **recovery ladder**:

```
no action  ->  SW re-bring-up (to_data_mode + CR/CRACK)  ->  full POR of BOTH dies
RECOVERS       RECOVERS-WITH-INTERVENTION(...)               WEDGES(unwedged only by ...)
```
`SILENT-CORRUPTION` = the RX **committed** a packet (PKT_LEN latched / fresh data
present) whose contents differ from what was sent.

### 2.3 Evidence standard

The one-shot 8-lane sweep produced **inconsistent** single-trial classes (a stale
RX-FIFO word can masquerade as a delivery). The lane-7 claim is therefore backed
by `test_ei_lane7_repro.py`, which **drains the RX FIFO before every trial**, uses
a **unique payload tag per trial**, repeats **4×**, and runs an **adjacent-lane
control**. Results marked *indicative* below were **not** re-run under that
stricter protocol and must not be quoted as measured.

---

## 3. The matrix

| # | Scenario | Injection | Expected (from RTL) | Observed | Verdict |
|---|---|---|---|---|---|
| S0 | Passthrough sanity | injector idle | bit-identical to un-injected harness | bring-up + both directions byte-exact | **PASS** (harness sound) |
| S1a | Mid-burst link glitch — **all-lane corruption** | `u_inj_s2m` FLIP mask=0xFF during a 3-packet s→m burst | CRC fail → NACK → a2l replay (`WlinkGenericFCSM_6.v:257-297`, re-ACK `:180-189`) should recover | all 3 packets **not** byte-exact; after release link **still broken**; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| S1b | Mid-burst link glitch — **link-clock dropout** | `u_inj_s2m.clk_kill` during a 2-packet s→m burst | no SYNC beacon in data mode ⇒ framing slip has no re-anchor (`WlinkRxLinkLayer.v:315-321`) | both packets lost; s2m stayed broken; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| S2a | Mid-burst **die LL swreset** | APB 0x0208 bit[3] on slave (`Wlink.v:2457-2463`) | local-only reset ⇒ dies desync (exp_pkt_num/credits re-zero on one side only) | fcsm m=4 s=4; recovered after `to_data_mode`+CR/CRACK | **RECOVERS-WITH-INTERVENTION** (SW re-bring-up) |
| S2b | Mid-burst **single-die full POR** | `s_por_gate` low 60 hclk (`tb_top.sv:165`) | peer must re-handshake; models KR260 partial-reset (fcsm=2) class | slave left at **fcsm=0**; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| S3a | **Lane 7** dropout | flip / stuck-1 / stuck-0, lane 7, s→m | corrupted 16-bit slice ⇒ CRC fail ⇒ drop (`crc_errors` `WlinkGenericFCSM_6.v:439`, `io_rx_crc_err` `:1044`) | **4/4 COMMITTED-WRONG in all three modes** (PKT_LEN 0xd / 0xf / fresh-wrong), **`crc_errors` 0→0, `io_rx_crc_err` 0→0** | **SILENT-CORRUPTION** ⚠ |
| S3b | **Lane 6** dropout (control) | flip, lane 6, s→m | same as S3a | **4/4 NOT-COMMITTED** (PKT_LEN=0x0) — correctly rejected (also with `crc_errors` 0→0) | **DETECTED** (correct behaviour) |
| S3c | Lane 2 **stuck-X** | stuck-X, lane 2, s→m | X may propagate into control state | packet not committed; link then **wedged** | **WEDGES** (full POR of both dies) |
| S3d | 8-lane one-shot sweep | flip, each lane | map load-bearing lanes | lanes 0-2 no-commit; 3-6 no-commit(stale); **7 committed-wrong** | *indicative only* (see §2.3) |
| S4a | Credit observability | none (probe) | credit/a2l regs readable | `a2l_wptr`/`synced_ack`/`full`/`fe_rx_credit_max` all readable & sane | **PASS** |
| S4b | **Phantom-pop regression** | 8× read of an **empty** RX FIFO | pre-fix bug popped a phantom pkt + minted credit above max (fixed `f9b94b7`) | a2l pointers **stable**, no credit runaway, link healthy after | **PASS** (fix holds) |
| S5 | **SYNC-word collision** | payloads = SYNC slices (`0x1F001F00`, `0x3D2E1F00`, `0xF1E2D3C4`, `0x0`), both directions | payload can never alias SYNC: low byte 0x00 is an invalid length + fixed nibble ramp (`WlinkRxLinkLayer.v:333-360`) | **all byte-exact**, no strip / no mis-frame | **PASS** (RTL claim confirmed) |
| S6 | **Reset storm** | N = 1, 2, 3, 5 rapid LL swresets on slave, 8 hclk apart | F-1 NACK watchdog (`WlinkGenericFCSM_6.v:113-168`) pulls stuck state-7 → 4 | **every N recovered**; fcsm m=4 s=4 each time | **RECOVERS** |

**Credit perturbation (S4) — why a spurious credit event is not directly
injectable:** `fe_rx_credit_max`/`fe_tx_credit_max` (8-bit,
`WlinkGenericFCSM_6.v:182,190`) and the a2l pointers (5-bit, 32-deep, `:257-297`)
are internal regs updated **only** by decoded CR/CRACK words and the ACK-pointer
CDC. There is no pad-level path that forces a credit **increment**. The two
reachable perturbations are (i) corrupting the CR/CRACK handshake word (covered
destructively by S1/S3) and (ii) the AHB-side empty-FIFO pop, which is exactly
the phantom-pop class tested in S4b.

---

## 4. Findings ranked for tapeout gating

### F14-A — CRITICAL · lane-7 corruption is committed, not rejected
**Verdict: SILENT-CORRUPTION. Recommend GATING.**

A corrupted lane 7 yields a packet **committed into the RX FIFO** with a
corrupted header/length and corrupted payload. Lane 6 under identical stimulus is
correctly dropped. Evidence (`test_ei_lane7_repro.py`, 4 reps each, RX drained,
unique tag per trial):

```
lane7 flip   rep0..3 -> COMMITTED-WRONG/SILENT (PKT_LEN=0xd got=[0xdb0000, 0xff0000, 0x7ea80010, 0xa5ff0010]  crc_errors 0->0  rx_crc_err 0->0)
lane7 stuck1 rep0..3 -> COMMITTED-WRONG/SILENT (PKT_LEN=0xf got=[0xff0000, 0xff0000, 0x7eff0010, 0xa5ff0010]  crc_errors 0->0  rx_crc_err 0->0)
lane7 stuck0 rep0..3 -> COMMITTED-WRONG/SILENT (PKT_LEN=0x0 got=[0x0, 0x0, 0x7e000010, 0xa5000010]            crc_errors 0->0  rx_crc_err 0->0)
lane6 flip   rep0..3 -> NOT-COMMITTED          (PKT_LEN=0x0)                                                  crc_errors 0->0  <-- CONTROL
   (sent hdr=0x00240000, payload=[0x7E5700xx, 0xA50000xx])
```

Interpretation: lane 7 carries the header/**length** field bits. Corrupting it
rewrites the length (`0x00240000` → `0xdb0000` / `0xff0000`) and the receiver
**accepts** the packet at the corrupted length rather than failing it. Software
reading `PKT_WORD_LEN=0xd` would consume 13 words of garbage as valid data.

**The corruption is unflagged.** `crc_errors` (`WlinkGenericFCSM_6.v:439`) and
`io_rx_crc_err` (`:1044`) were sampled immediately before and after every trial
and **never left 0** — so a corrupt-but-committed lane-7 packet is
indistinguishable from a good one at the FCSM's error interface. There is no
status bit for software to gate on.

**Two honest caveats:**
- `crc_errors` also stayed 0 for the **lane-6 control**, which was correctly
  *not* committed. So the CRC counter is not the discriminator in either case:
  lane 6 is rejected by some other (length/framing) path. The measured claim is
  narrow and solid — *lane 7's corrupt packet is committed, lane 6's is not, and
  neither raises a CRC error* — but "the CRC caught lane 6" is **not** shown.
- `crc_errors` is cleared under some conditions (`:1174`, `:1182`), so a
  transient assertion between samples cannot be fully excluded. A waveform
  (`DUMP=1`) on one trial would close that gap.

**Why it matters for the ASIC:** a stuck/marginal lane 7 is exactly the field
failure this program has been chasing, and the RX's own length field is the one
thing that must never be trusted from a corrupt word.

### F14-B — HIGH · data-mode disturbances need a full both-die POR
**Verdict: WEDGES. Recommend GATING (recovery path is missing).**

S1a, S1b and S3c all end the same way: after the fault is **removed**, the link
is still broken, `to_data_mode` + CR/CRACK does **not** fix it, and only a full
POR of **both** dies restores byte-exact traffic. Notably the FCSMs read a
healthy-looking `m=4 s=4` (LINK_IDLE) while data will not cross — so **FCSM state
is not a valid liveness indicator after a disturbance** (another instance of
*verify the instrument before the DUT*).

Mechanism (consistent with the RTL): the SYNC beacon is **OFF** in data mode
(`swi_sync_insert_en_r` POR=0, `axi_chiplet_controller.sv:1888`; `do_to_data_mode`
writes R8 slot0=0), so a framing slip has **no re-anchor delimiter**
(`WlinkRxLinkLayer.v:315-321`); and the deskew re-anchor is compiled off
(`SYNC_REANCHOR_EN` default `1'b0`, `tidelink_lane_deskew_v2.sv:201`). The SW
re-bring-up only pulses the LL swreset — it does **not** re-arm the
deskew/calibrator, which is why only a POR (full retrain) recovers.

**Implication:** on silicon there is no in-field recovery from a transient link
event short of a power cycle. If that is not acceptable for the product, a
"retrain-lite" path (re-arm calibrator + deskew anchor without POR) is needed.

### F14-C — MEDIUM · single-die POR desyncs the pair
**Verdict: WEDGES (both-die POR).** S2b left the slave at `fcsm=0` with the master
at 4, unrecoverable by SW re-bring-up. This is the **KR260 fcsm=2 partial-reset
class** reproduced in sim. By contrast S2a (LL swreset only) **does** recover via
SW re-bring-up — so the boundary between "recoverable" and "needs POR" sits
between an LL swreset and a full die POR. Worth documenting in the bring-up
recipe: **never POR one die alone.**

### Non-findings (verified good — keep these as regressions)
- **S6 reset storm** N≤5 always recovers (F-1 NACK watchdog behaves).
- **S5 SYNC collision**: the `WlinkRxLinkLayer.v:333-360` "data can never alias
  SYNC" argument is **empirically confirmed** in both directions.
- **S4b phantom-pop**: the `f9b94b7` fix **holds** — empty-RX reads neither advance
  the a2l pointers nor mint credit.

---

## 5. How to re-run

```bash
source ./set_env.sh && export TIDELINK_PHY_V2=1
cd cocotb/tidelink_error_injection
make ei_matrix                          # all scenarios, in order
make MODULE=test_ei_lane7_repro         # the F14-A critical evidence
```
Runtime: ~1-2 min to compile, then ~20 s - 4 min per module (the recovery ladder
runs a full POR bring-up per wedged case).
All tests **pass** by design: a WEDGE or SILENT-CORRUPTION is recorded as a
`VERDICT[...]` log line, not a test failure, so the suite documents behaviour
rather than asserting a policy. Grep the run for `VERDICT`.

## 6. Harness limitations (read before extending)

1. **Injection is post-skid, pre-RX** — it models a wire/eye fault, not a TX-side
   logic fault.
2. **`clk_kill` holds the recovered clock low**; it does not model jitter or a
   partial-edge glitch.
3. **The recovery ladder's last rung is a full POR**, which also re-runs autocal —
   so "needs full POR" here means "needs a full retrain", and this bench cannot
   distinguish POR-the-power-domain from retrain-the-PHY. Splitting those two is
   the natural next experiment for F14-B.
4. **Lane classes for lanes 0-6 in the one-shot sweep are indicative only** (§2.3);
   only lane 7 and the lane-6 control were run under the drained/repeated
   protocol.
5. `EPOCH_PROFILE=zero` only — no skew is combined with the faults yet.
