# TideLink F14 — Error Injection / Recovery Findings (sim)

**Date:** 2026-07-18 · **Lanes:** Y-C (original matrix) · **Z-B** (F14-A
characterisation + revision, §3.1 / §4 / §4.1-4.5)
**Bench:** `cocotb/tidelink_error_injection/` (new; this lane owns it)
**Config:** V2 (`TIDELINK_PHY_V2=1`), `tidelink_top_pair_v2`-derived harness,
EPOCH_PROFILE=zero (no skew), VCS, SW bring-up (`BYPASS_AUTONEG=1`).

> Closes the "no systematic degradation/recovery matrix exists" gap recorded at
> `docs/TIDELINK_FPGA_VERIFICATION_PLAN.md:70` (F14) and the checklist item at
> `:345`. Prior F14 coverage was ad-hoc power-cycle recovery only
> (`fpga/hw_regression/overnight_autonomy.sh`).

---

## 1. Headline

**Two tapeout-gating findings, both reproduced with controls** (F14-A
re-characterised and re-scoped by lane Z-B on 2026-07-18 — see the callout below):

1. **F14-A (CRITICAL — SILENT CORRUPTION, GENERIC):** the TideLink data path has
   **no working integrity check**. `disable_crc` is **hard-defaulted to 1** by a
   deliberate SoC Labs override —
   `src/rtl/local_overrides/WlinkGenericFCSM_6.v:1159-1167` — which forces
   `crc_corrupt = false` for every packet (`FC.scala:157`), so `crc_errors` /
   `io_rx_crc_err` can never assert and no NACK is ever raised for a corrupt
   packet. Consequence, measured over a full 8-lane × 3-mode × 2-direction sweep
   (§3.1): **any corruption confined to payload bytes is COMMITTED SILENTLY** —
   `write_ptr` advances, credit is consumed, `packet_committed_irq` sets, and the
   data is wrong. Reproduced **4/4 on lanes 5 and 6 (flip and stuck-1, both
   directions)** and **4/4 on lane 7 under stuck-0**; lane 7 under flip/stuck-1 is
   instead rejected-but-left-open (§4.5). **Zero** of the 48 cells raised any
   error indication.
   **This override is in both ASIC flists** (`flists/tidelink_top_full_asic*.flist`).

   > **This supersedes the original F14-A**, which reported the defect as a
   > *lane-7-specific* escape. That reading was inverted by an instrument error
   > (`PKT_WORD_LEN` is an in-progress latch, not a commit indicator) — lane 7 is
   > in fact **rejected**, and lanes 5/6 are the silent ones. See §4.1. The
   > lane-6 "control" that made the original finding look bounded was the same
   > inversion. Corrected severity: **worse, and generic.**
2. **F14-B (HIGH — WEDGE):** any **transient link disturbance during data mode**
   (all-lane corruption, link-clock dropout, or a single-lane X) leaves the link
   **wedged in a way the standard SW re-bring-up (`to_data_mode` + CR/CRACK)
   CANNOT clear**. Only a **full POR of BOTH dies** recovers it. Root cause is
   architectural: the SYNC beacon is OFF in data mode, and `to_data_mode` does
   not re-arm the deskew/calibrator.

Everything else tested **recovers**: reset storms (N≤5), single-die LL swreset,
SYNC-patterned payloads, and the phantom-pop regression.

**Third finding added by lane Z-B:** the reason the CRC is off is recorded in the
override itself — *"V2 long DATA packets arrive but header-CRC fails (crc_errors
saturates) -> FCSM SEND_NACK -> no enqueue"*. So there is a **latent CRC/framing
bug on good traffic** that was worked around by disabling the check rather than
fixed. Re-enabling the CRC will re-expose it. See §4.6.

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

**Lane Z-B addendum — the protocol was necessary but not sufficient.** Draining,
tagging and repeating removed the *stale-data* failure mode but not the
*wrong-register* failure mode: the classifier still keyed on `PKT_WORD_LEN`,
which reads the **opposite** of commit (§4.1). The sweep in §3.1 therefore adds a
third requirement to the standard:

> **Classify on the signal that the RTL uses to make the decision, not on a
> status register that correlates with it.** Here that is `write_ptr_r` /
> `credit_count_r` / `packet_committed_irq_r` in
> `src/rtl/fifo/tidelink_fifo_ctrl.sv`, sampled **before** any AHB read (an
> aperture read itself moves `read_ptr`, `packet_committed_irq` and
> `packet_word_length`).

This is a fifth instance of *verify the instrument before the DUT*.

---

## 3. The matrix

| # | Scenario | Injection | Expected (from RTL) | Observed | Verdict |
|---|---|---|---|---|---|
| S0 | Passthrough sanity | injector idle | bit-identical to un-injected harness | bring-up + both directions byte-exact | **PASS** (harness sound) |
| S1a | Mid-burst link glitch — **all-lane corruption** | `u_inj_s2m` FLIP mask=0xFF during a 3-packet s→m burst | CRC fail → NACK → a2l replay (`WlinkGenericFCSM_6.v:257-297`, re-ACK `:180-189`) should recover | all 3 packets **not** byte-exact; after release link **still broken**; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| S1b | Mid-burst link glitch — **link-clock dropout** | `u_inj_s2m.clk_kill` during a 2-packet s→m burst | no SYNC beacon in data mode ⇒ framing slip has no re-anchor (`WlinkRxLinkLayer.v:315-321`) | both packets lost; s2m stayed broken; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| S2a | Mid-burst **die LL swreset** | APB 0x0208 bit[3] on slave (`Wlink.v:2457-2463`) | local-only reset ⇒ dies desync (exp_pkt_num/credits re-zero on one side only) | fcsm m=4 s=4; recovered after `to_data_mode`+CR/CRACK | **RECOVERS-WITH-INTERVENTION** (SW re-bring-up) |
| S2b | Mid-burst **single-die full POR** | `s_por_gate` low 60 hclk (`tb_top.sv:165`) | peer must re-handshake; models KR260 partial-reset (fcsm=2) class | slave left at **fcsm=0**; SW re-bring-up **insufficient** | **WEDGES** (full POR of both dies) |
| ~~S3a~~ | ~~**Lane 7** dropout~~ | ~~flip / stuck-1 / stuck-0, lane 7, s→m~~ | — | ⚠ **SUPERSEDED by §3.1.** The COMMITTED classification was an instrument inversion (`PKT_LEN` is an in-progress latch, §4.1). Lane 7 flip/stuck-1 is **NOT committed**; lane 7 stuck-0 **is**. | see §3.1 |
| ~~S3b~~ | ~~**Lane 6** dropout (control)~~ | ~~flip, lane 6, s→m~~ | — | ⚠ **SUPERSEDED by §3.1 — the control was inverted too.** Lane 6 flip is **COMMITTED-WRONG/SILENT 4/4**, not rejected. | see §3.1 |
| S3c | Lane 2 **stuck-X** | stuck-X, lane 2, s→m | X may propagate into control state | packet not committed; link then **wedged** | **WEDGES** (full POR of both dies) |
| ~~S3d~~ | ~~8-lane one-shot sweep~~ | ~~flip, each lane~~ | — | ⚠ **SUPERSEDED by §3.1**, which runs all 8 lanes × 3 modes × 2 directions under the strict protocol with commit-signal classification. | see §3.1 |
| S3e | **CRC configuration + coverage probe** | none (config read) + continuous monitor on `crc_corrupt` | CRC should be live and should fire for in-coverage corruption | **`disable_crc = 1` on both dies straight out of reset**; `crc_corrupt` asserted **0×** on clean and corrupted packets; monitor proven live (`pkt_is_data_pkt` 26× on the clean baseline) | **CHECK ABSENT** ⚠ (§4.2, §4.6) |
| S4a | Credit observability | none (probe) | credit/a2l regs readable | `a2l_wptr`/`synced_ack`/`full`/`fe_rx_credit_max` all readable & sane | **PASS** |
| S4b | **Phantom-pop regression** | 8× read of an **empty** RX FIFO | pre-fix bug popped a phantom pkt + minted credit above max (fixed `f9b94b7`) | a2l pointers **stable**, no credit runaway, link healthy after | **PASS** (fix holds) |
| S5 | **SYNC-word collision** | payloads = SYNC slices (`0x1F001F00`, `0x3D2E1F00`, `0xF1E2D3C4`, `0x0`), both directions | payload can never alias SYNC: low byte 0x00 is an invalid length + fixed nibble ramp (`WlinkRxLinkLayer.v:333-360`) | **all byte-exact**, no strip / no mis-frame | **PASS** (RTL claim confirmed) |
| S6 | **Reset storm** | N = 1, 2, 3, 5 rapid LL swresets on slave, 8 hclk apart | F-1 NACK watchdog (`WlinkGenericFCSM_6.v:113-168`) pulls stuck state-7 → 4 | **every N recovered**; fcsm m=4 s=4 each time | **RECOVERS** |

### 3.1 S3c — the full single-lane corruption sweep (lane Z-B)

`make ei_sweep` · `cocotb/tidelink_error_injection/test_ei_full_sweep.py`
8 lanes × 3 modes × 2 directions = **48 cells**, N=4 per cell, RX drained and a
unique payload tag per trial, classified on the RTL commit signals (§4.1), with
the FCSM error wires sampled before and after every trial.

**Harness constraint, and why some cells are N=1.** A second `run_bringup_full`
in the same simulation does **not** re-run autocal (measured: the retry returns
`cal=IDLE`, `cal_done=0`, `fcsm=0`, and CR/CRACK never lands). There is exactly
**one usable healthy link per simulation**, so each cell is its own cocotb test
run as its own `simv` invocation, and a trial that leaves the link degraded
**aborts its row** rather than classifying further cells against a broken link.
Cells whose very first trial degrades the link are therefore `N=1` and marked
`+DISTURBED`. Their class is consistent across all 3 modes and both directions,
but they are **not** N=4 and must not be quoted as such.

Legend — `COMMITTED-WRONG` = `write_ptr_r` advanced (`tidelink_fifo_ctrl.sv:121`)
with wrong contents; `NOT-COMMITTED` = it did not; `+OPEN` = `packet_active_r`
left 1 (stuck half-written packet); `+READABLE` = the uncommitted corrupt words
were still readable through the AHB aperture; `+DISTURBED` = link degraded
afterwards; `/SILENT` = **no** error indication moved (`crc_errors`,
`io_rx_crc_err`, `send_nack_req`, `crcCorruptSeen`, `isNotExpPacket`,
`valid_rx_pkt_crc_err` all unchanged).

**`/SILENT` applied to every cell. Across the whole sweep — every lane, every
mode, every direction, committed and rejected alike — `crc_errors`,
`io_rx_crc_err`, `send_nack_req`, `crcCorruptSeen`, `isNotExpPacket` and
`valid_rx_pkt_crc_err` never moved. Not one cell raised any error indication of
any kind.**

**Direction S→M (master RX corrupted)**

| lane | wire bytes carried | flip | stuck-1 | stuck-0 |
|---|---|---|---|---|
| 0 | byte0 `data_id` + byte8 `app[31:24]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 |
| 1 | byte1 `word_count[7:0]` + byte9 `app[39:32]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +OPEN +READABLE 4/4 |
| 2 | byte2 `word_count[15:8]` + byte10 `app[47:40]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | BYTE-EXACT 2/3 · BYTE-EXACT +DISTURBED 1/3 |
| 3 | byte3 **ECC** + byte11 **CRC[7:0]** | BYTE-EXACT 4/4 | BYTE-EXACT 4/4 | BYTE-EXACT 4/4 |
| 4 | byte4 FC pktnum + byte12 **CRC[15:8]** | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 |
| 5 | byte5 `app[7:0]` | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 |
| 6 | byte6 `app[15:8]` | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 | BYTE-EXACT 4/4 |
| 7 | byte7 `app[23:16]` | NOT-COMM / SILENT +OPEN +READABLE 4/4 | NOT-COMM / SILENT +OPEN +READABLE 4/4 | **COMMITTED-WRONG / SILENT** 4/4 |

**Direction M→S (slave RX corrupted)**

| lane | wire bytes carried | flip | stuck-1 | stuck-0 |
|---|---|---|---|---|
| 0 | byte0 `data_id` + byte8 `app[31:24]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 |
| 1 | byte1 `word_count[7:0]` + byte9 `app[39:32]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +OPEN +READABLE 4/4 |
| 2 | byte2 `word_count[15:8]` + byte10 `app[47:40]` | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | BYTE-EXACT 4/4 |
| 3 | byte3 **ECC** + byte11 **CRC[7:0]** | BYTE-EXACT 4/4 | BYTE-EXACT 4/4 | BYTE-EXACT 4/4 |
| 4 | byte4 FC pktnum + byte12 **CRC[15:8]** | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 | NOT-COMM / SILENT +DISTURBED 1/1 |
| 5 | byte5 `app[7:0]` | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 |
| 6 | byte6 `app[15:8]` | **COMMITTED-WRONG / SILENT** 4/4 | **COMMITTED-WRONG / SILENT** 4/4 | BYTE-EXACT 4/4 |
| 7 | byte7 `app[23:16]` | NOT-COMM / SILENT +OPEN +READABLE 4/4 | NOT-COMM / SILENT +OPEN +READABLE 4/4 | **COMMITTED-WRONG / SILENT** 4/4 |

<!-- cells parsed: 48/48 -->

**Reading the matrix.** The class is a pure function of *which wire byte* the
lane carries (map in §4.4), not of the lane index, and it is **identical in both
directions in 23 of 24 (lane, mode) pairs**. The single exception is
`s2m / stuck-0 / lane 2`, which delivered BYTE-EXACT twice and then
BYTE-EXACT+DISTURBED once (row aborted at N=3) where `m2s` was a clean 4/4
BYTE-EXACT — a flaky *link disturbance*, not a different class. No cell in either
direction produced a different verdict class from its opposite-direction twin:

* **Framing lanes (0, 1, 2, 4)** — `data_id`, `word_count`, FC packet number.
  Packet dropped (`pkt_is_data_pkt` measured 0), link left degraded. This is the
  F14-B wedge class reached from one stuck lane.
* **Lane 3** — the header **ECC** byte and **CRC[7:0]**. **Byte-exact, no effect,
  4/4.** Direct evidence that neither check is enforced.
* **Payload lanes (5, 6, 7)** — silently committed whenever the corruption misses
  TideLink's length field; rejected-but-left-open when it hits it.

The mode column matters only through which *value* the byte takes: e.g. lane 6
stuck-0 is BYTE-EXACT because the byte it carries was already `0x00` in this
payload, and lane 7 stuck-0 zeroes the length field (`0x2` → `0x0`) so the FIFO's
address match fires **early** and commits a truncated packet — silently.

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

### F14-A — CRITICAL · the data path has NO integrity check; payload corruption is committed silently
**Verdict: SILENT-CORRUPTION, GENERIC (not lane-specific). Recommend GATING.**

> **REVISION 2026-07-18 (lane Z-B).** The original F14-A entry said *"corrupting
> lane 7 causes the receiver to COMMIT a packet with a corrupted length and
> payload"* and cited the lane-6 control as evidence that this was a bounded,
> lane-7-specific escape. **Both halves of that statement are now refuted**, and
> the corrected finding is WORSE, not better. The error was an instrument error:
> `PKT_WORD_LEN` was read as a commit indicator, and it is the opposite of one.
> Details in §4.1; the full 8-lane sweep is in §3.1.

#### 4.1 The instrument error that inverted the original reading

`test_ei_lane7_repro.py` classified a trial as COMMITTED when `PKT_WORD_LEN`
(APB 0x2008) read non-zero. That register is `packet_word_length_r`, the
**in-progress** packet-length latch of the RX FIFO controller
(`src/rtl/fifo/tidelink_fifo_ctrl.sv:199,204,232`), and it is explicitly cleared
the moment a packet **completes**:

```
src/rtl/fifo/tidelink_fifo_ctrl.sv:191-194
    // Clear packet_word_length, packet_active, and check_addr on completion
    if (write_complete || read_complete) begin
        packet_word_length_nxt = '0;
```

So a **correctly delivered** packet reads `PKT_WORD_LEN == 0` — visible on every
healthy round trip in this bench's own logs (`[health-m2s] ... PKT_LEN=0x0` with
byte-exact data) — and `PKT_WORD_LEN != 0` means the packet write is **still
open and never completed**. The original run read the sign backwards.

This lane therefore re-classified every cell on the **ground truth for commit**,
sampled directly from `u_tidelink_fifo.u_fifo_mem.u_fifo_ctrl` *before* any AHB
read perturbs it:

| Signal | file:line | Meaning |
|---|---|---|
| `write_ptr_r` | `tidelink_fifo_ctrl.sv:121-122` | advances by `(len+2)*4` **only** on `write_complete` — **this is "committed"** |
| `credit_count_r` | `:270-275` | decrements by `(len+2)` on commit |
| `packet_committed_irq_r` | `:296-306` | sets on `write_complete` |
| `packet_active_r` | `:200,205` | left `1` ⇒ an OPEN, never-completed packet |

#### 4.2 What the CRC actually protects: **nothing — it is switched OFF**

Measured (`test_ei_crc_probe.py::test_01`, `VERDICT[S3d_crc_static_config]`):

```
{'out_prepend_swi_disable_crc': 1, 'swi_data_id_1': 161,
 'en_ff2_rx_demet_io_out': 1, 'crc_errors': 0}
```

`disable_crc` is **1**. In the FC state machine the CRC comparison is gated on
it:

```
FC.scala:157  (as compiled: src/rtl/local_overrides/WlinkGenericFCSM_6.v:437-438)
  crc_corrupt = Mux((ll_rx.sop && ll_rx.valid && (ll_rx.data_id === swi_data_id))
                     & ~disable_crc, (rx_crc_computed =/= ll_rx.crc), false.B)
```

> **All line numbers below are in `src/rtl/local_overrides/WlinkGenericFCSM_6.v`,
> which is the file the flists actually compile** (`tidelink_fpga_v2.flist:270`) —
> *not* `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v`, whose
> reset values differ. Reading the deps copy is how you conclude the CRC is
> enabled when it is not.

With `disable_crc = 1` the mux selects `false.B` unconditionally. Therefore, by
construction and for **every** packet:

* `crc_corrupt` (`:437-438`) is permanently 0 ⇒ `crc_errors` (`:439`, incremented
  at `:1178`) can never increment and `io_rx_crc_err = |crc_errors` (`:1044`)
  can never assert;
* `valid_rx_pkt_crc_err` (`:457`) never fires, so `crcCorruptSeen` (`:535`) never
  fires, so **no NACK is ever raised for a corrupt packet**;
* `pkt_is_data_pkt = valid_rx_pkt && data_id match && ~crc_corrupt` (`:440`)
  becomes *unconditionally true* for any packet whose data_id matches — the CRC
  no longer gates acceptance at all.

**State this plainly: the integrity check does not exist in this configuration.**
"The CRC missed the lane-7 corruption" was never the right description — there
was no CRC evaluation to miss. That also explains, without any further
hypothesis, the honest anomaly lane Y-C flagged: `crc_errors` stayed 0 for the
lane-6 *control* too. It stays 0 for everything.

Two supporting measurements rule out "the counter was cleared before we sampled
it" (`crc_errors` is zeroed on every edge that `en_ff2_rx` is low —
`src/rtl/local_overrides/WlinkGenericFCSM_6.v:1181-1182`):

1. `test_ei_crc_probe.py` replaces the before/after counter sample with a
   **continuous monitor** that latches every assertion of the *combinational*
   `crc_corrupt` / `valid_rx_pkt_crc_err` / `send_nack_req` wires. Across a clean
   packet and a corrupted one, `crc_corrupt` was asserted **0 times**. The monitor
   is not blind: it saw `pkt_is_data_pkt` assert 26× on the clean baseline
   (`VERDICT[S3d_clean_baseline]`), so it is watching live RX packet events.
2. `en_ff2_rx_demet_io_out` read **1** at sample time, so the counter was armed,
   not held in its cleared state.

**Coverage, for the record, if it were enabled.** A Wlink data packet is 13 bytes
(`wordCountSize = 56/8 = 7`, `FC.scala:74`): byte 0 `data_id`, bytes 1-2
`word_count`, byte 3 ECC over the 24-bit header, bytes 4-10 `ll.data[55:0]`
(48-bit app data + 8-bit FC packet number), bytes 11-12 CRC-16
(`LinkLayer.scala:786-794`). `rx_crc_computed = WlinkCrcGen(ll_rx.data)`
(`FC.scala:155`) covers **the whole 56-bit data field and nothing else**. So even
fully enabled:

* the **payload** would be fully covered — enabling the CRC is a real fix, not a
  partial one, for the silent-corruption class;
* the **header** would still be covered only by the ECC byte, and the CRC
  comparison is additionally gated on `data_id === swi_data_id`, so a corruption
  that changes the `data_id` makes the packet not-a-data-packet and is discarded
  before the CRC is ever consulted.

#### 4.3 What actually decides commit-vs-reject

With the CRC inert, the only thing standing between a corrupted packet and the
RX FIFO is an **address match in the TideLink FIFO controller**:

```
src/rtl/fifo/tidelink_fifo_ctrl.sv:102-111
  wire fc_write_valid    = fc_wr_valid && fc_wr_write && packet_active_r;
  wire fc_write_complete = fc_write_valid && (fc_wr_addr == write_target_addr_r);
  assign write_complete  = fc_write_complete || ahb_write_complete;
```

where `write_target_addr_r = (packet_word_length_nxt + 1) << 2`
(`:239`) and `packet_word_length_nxt = clamp_length(fc_wr_wdata)` is latched from
**the received TideLink header word's length field, bits [31:20]** (`:198-200`).

So the acceptance rule is exactly: *"commit iff the number of words that actually
arrived matches the length field the sender claimed — as received."* There is no
checksum, no sequence check, and no framing check at this layer. It is a
**self-consistency test of the corrupted packet against itself**, and it only
catches a corruption that lands **inside bits [31:20] of the header word**.

That is the whole of the lane-6-vs-lane-7 asymmetry the original entry attributed
to the CRC:

* **lane 7** carries `app[23:16]`, which is byte 2 of the TideLink header word —
  **inside** the length field. Corrupting it rewrites the length (`0x2` → `0xd`),
  the FC stream never reaches `write_target_addr_r = (13+1)*4 = 56`,
  `write_complete` never fires ⇒ **rejected**, by accident.
* **lanes 5 and 6** carry `app[7:0]` and `app[15:8]` — payload bytes **outside**
  the length field. The length still reads `0x2`, the address match still fires,
  and the packet is **committed with corrupted contents**.

#### 4.4 The measured answer to the severity question

**It is generic, not lane-7-specific — and lane 7 is not even the silent case.**
From the drained, uniquely-tagged, 4-repetition sweep (§3.1), master RX, flip:

```
lane3 flip  4/4  BYTE-EXACT                          <- ECC byte + CRC[7:0] corrupted, NO EFFECT
lane5 flip  4/4  COMMITTED-WRONG/SILENT   wptr 16->32  cred 4096->4092  cmt_irq 1
lane6 flip  4/4  COMMITTED-WRONG/SILENT   wptr 16->32  cred 4096->4092  cmt_irq 1
lane7 flip  4/4  NOT-COMMITTED/SILENT+OPEN+READABLE
                                          wptr 16->16  cred 4096->4096  cmt_irq 0
                                          pkt_active 0->1  pwl 0->13
   (sent hdr=0x00240000, payload=[0x7E5700xx, 0xA50000xx]; crc_errors 0->0 in ALL cells)
```

* **Lanes 5 and 6 are the true silent corruption.** `write_ptr` advances,
  credit is consumed, `packet_committed_irq` sets, `PKT_WORD_LEN` reads 0 — the
  packet is *indistinguishable from a good one on every status interface the
  design exposes* — and the data is wrong in every word
  (`got=[0x002400ff, 0x000000ff, 0x7e5700ee, 0xa50000ee]` for lane 5: byte 0 of
  every 32-bit word inverted; `0x0024ff00, 0x0000ff00, 0x7e57ff11, ...` for lane 6:
  byte 1 of every word). 4/4, reproduced.
* **Lane 7 is REJECTED, not committed** — the original claim is refuted on the
  ground-truth signals. It is nonetheless a defect of its own (§4.5).
* **Lane 3 is the proof that no check is enforced.** Lane 3 carries the header
  **ECC byte** (byte 3) *and* **CRC[7:0]** (byte 11). Inverting both delivered the
  packet **byte-exact 4/4 with no error flag**. If either the ECC or the CRC were
  enforced, a corrupted CRC byte alone would have to fail the packet. Neither is.

  > **Honesty note on this one cell.** The lane-3 → {ECC, CRC[7:0]} assignment is
  > *derived* from `LinkLayer.scala:768-778`, not independently measured. The map
  > is confirmed at three points by this sweep (lanes 5/6/7 ↔ `app[7:0]` /
  > `app[15:8]` / `app[23:16]`, each matching the observed corrupted byte
  > position exactly) and is consistent with lanes 0/1/2/4 destroying framing —
  > but "lane 3 carries the CRC low byte" is inference, not observation. The
  > *independent* and sufficient evidence that the CRC is not enforced is the
  > direct config read `disable_crc = 1` plus `crc_corrupt` asserting 0× under a
  > continuous monitor (§4.2). Lane 3 corroborates; it does not carry the claim.
* **Lanes 0, 1, 2 and 4** carry `data_id` / `word_count` / the FC packet number,
  i.e. the Wlink framing fields. Corrupting them destroys framing: the packet is
  dropped (`pkt_is_data_pkt` never asserts — measured 0 for lane 0) and the link
  is left **degraded** (this is the F14-B wedge class, reached via a single lane).

The general rule, which the byte map below explains and the sweep confirms:

> **Any corruption confined to payload bytes is committed silently. Corruption is
> only ever "caught" when it either (a) destroys Wlink framing — in which case the
> link wedges rather than reports — or (b) happens to land in TideLink's own
> length field, where the FIFO's write-completion address match rejects it as a
> side effect. Neither is an integrity check.**

**Lane → wire-byte map** (`LinkLayer.scala:768-778`; 8 lanes × 16-bit
`phyDataWidth` ⇒ 16 bytes/cycle, so the 13-byte packet lands in one cycle; lane
*i*'s low byte → `byte_index[i]`, high byte → `byte_index[i+8]`):

| lane | low byte | high byte | measured class (flip) |
|---|---|---|---|
| 0 | byte 0 `data_id` | byte 8 `app[31:24]` | NOT-COMMITTED + link degraded |
| 1 | byte 1 `word_count[7:0]` | byte 9 `app[39:32]` | NOT-COMMITTED + link degraded |
| 2 | byte 2 `word_count[15:8]` | byte 10 `app[47:40]` | NOT-COMMITTED + link degraded |
| 3 | byte 3 **ECC** | byte 11 **CRC[7:0]** | **BYTE-EXACT (no effect)** |
| 4 | byte 4 FC pkt num | byte 12 **CRC[15:8]** | NOT-COMMITTED + link degraded |
| 5 | byte 5 `app[7:0]` | (unused) | **COMMITTED-WRONG / SILENT** |
| 6 | byte 6 `app[15:8]` | (unused) | **COMMITTED-WRONG / SILENT** |
| 7 | byte 7 `app[23:16]` | (unused) | NOT-COMMITTED + OPEN + READABLE |

The map is not just arithmetic: it **predicts the original F14-A observation
exactly**. Lane 7 carries `app[23:16]` = byte 2 of the TideLink header word, so
`0x00240000` becomes `0x00db0000` (`0x24 ^ 0xff = 0xdb`) and the length field
`[31:20]` reads `0xd` — precisely the `PKT_LEN=0xd` lane Y-C measured.

#### 4.5 Blast radius

**For the committed-corrupt case (lanes 5, 6):** software sees a completely
normal packet. `PKT_WORD_LEN` = 0, `packet_committed_irq` set, `write_ptr` and
`credit_count` both advanced by the **correct** amount for the claimed length
(`wptr 16->32`, `cred 4096->4092`, i.e. `(2+2)*4` — exactly what a good 4-word
packet does), `overrun` clear, `crc_errors` = 0.

> `underrun` reads **1** in these cells, but it is **not** a corruption signal:
> the bench's own `_drain_rx()` reads an empty FIFO before every trial, which
> sets the sticky `underrun_r` (`tidelink_fifo_ctrl.sv:334-336`). It reads 1 in
> the **BYTE-EXACT** cells too, so it carries no information here. Do not read it
> as an error indication for this defect. The **payload is wrong**; the length is right. Credit accounting
stays consistent, FIFO pointers stay coherent, and **the link remains fully
usable** — the next packets deliver byte-exact. This is the worst shape a data
corruption can take: no accounting damage to trip over later, and no signal at
all. Only an end-to-end application checksum would catch it.

**For the lane-7 reject case:** the packet is not committed, but it is not clean
either. Measured 4/4: `packet_active_r` is left **1** and `packet_word_length_r`
is left **13**, i.e. the FIFO is stuck with an **open packet** whose
`write_target_addr` = 56 will never be reached. The corrupted words are also
**readable through the AHB RX aperture** (the `+READABLE` annotation: the trial's
unique tag was present in the read-back), because the FC writes land in the SRAM
as they arrive and the aperture reads the SRAM at `read_ptr` — there is no
"expose only committed data" guard. So a polling driver can read data that the
FIFO never accepted. Credit is **not** consumed, so the receiver never advances
past the stuck packet — the open-packet state is not self-clearing on this path.
(`underrun` reads 1 here too, but it is the bench's own drain artefact, not a
fault signal — see the note above.)

**For the framing lanes (0, 1, 2, 4):** the link is left degraded (`s2m` dead
while `m2s` still works, both FCSMs still reading a healthy-looking state 4).
This is F14-B reached from a single stuck lane.

#### 4.6 Why the CRC is off — and why re-enabling it is not a one-line fix

`disable_crc` is not left at its generated default. The compiled FCSM is a **SoC
Labs local override** (`flists/tidelink_fpga_v2.flist:270` selects
`src/rtl/local_overrides/WlinkGenericFCSM_6.v` in place of the deps file), and
that override changes the **reset value** of the bit from `1'h0` to `1'h1`:

```
src/rtl/local_overrides/WlinkGenericFCSM_6.v:1159-1167
  always @(posedge clock or posedge reset) begin
    if (reset) begin
      // SoC Labs 2026-06-14: default disable_crc=1 (GPIO-speed deployment).
      // Silicon-confirmed: V2 long DATA packets arrive but header-CRC fails
      // (crc_errors saturates) -> FCSM SEND_NACK -> no enqueue. At 6.25 MHz the
      // BER is negligible so CRC is pure overhead (REGISTER_MAP.md "key register
      // for GPIO-speed deployments"). Default-on also sidesteps die_b's
      // hardware-unwritable SM Control reg. SW can still re-enable via bit[16].
      out_prepend_swi_disable_crc <= 1'h1;
```

Confirmed by measurement (`VERDICT[S3d_disable_crc_timeline]`): the bit reads
`X` at t0 and **`1` immediately after `tb.reset()`**, on **both** dies, before any
bring-up write — it is the reset value, not a configuration write.

Three things follow, and they are the substance of the tapeout argument:

1. **The check was disabled because it was failing on GOOD traffic.** The comment
   is explicit: correct long DATA packets were failing the header CRC and being
   NACKed. That is a real, unfixed CRC/framing defect; disabling the comparison
   hid it. **Re-enabling the CRC will re-expose it**, so "just clear bit[16]" is
   not a fix on its own — the underlying mismatch has to be root-caused first.
   (This bench did not attempt that root-cause; it is the natural next lane.)
2. **The stated justification does not survive to the ASIC.** *"At 6.25 MHz the
   BER is negligible so CRC is pure overhead"* is an argument about **random bit
   errors on a slow FPGA link**. It says nothing about the failure this program
   has actually been chasing — a **stuck or marginal lane** — which is not a BER
   phenomenon and which §3.1 shows is committed silently. The v1 ASIC target is a
   100 MHz GPIO PHY, 16× that rate.
3. **The SW escape hatch may not exist on one die.** The same comment notes the
   default "sidesteps die_b's **hardware-unwritable SM Control reg**". Taken at
   face value (this bench did **not** independently verify that claim), software
   **cannot re-enable the CRC on die_b**, so "SW can still re-enable via bit[16]"
   is not a usable mitigation on a real pair.

**Scope of the override.** It is not FPGA-only. `local_overrides/WlinkGenericFCSM_6.v`
is selected by **all four** flists, including both ASIC ones:
`flists/tidelink_fpga.flist`, `flists/tidelink_fpga_v2.flist`,
`flists/tidelink_top_full_asic.flist`, `flists/tidelink_top_full_asic_v2.flist`.
**As things stand, the taped-out part powers up with its link-layer integrity
check disabled.**

#### 4.7 Revised severity statement for F14-A — precisely scoped

**Proven, in simulation, EPOCH_PROFILE=zero, V2 pair harness, N=4 per cell,
drained + uniquely tagged, classified on RTL commit signals:**

* The FC link-layer CRC is **disabled by reset default** in every TideLink flist,
  FPGA and ASIC (`WlinkGenericFCSM_6.v:1167`, measured `disable_crc=1` on both
  dies post-reset). With it disabled, `crc_corrupt`, `crc_errors`,
  `io_rx_crc_err`, `valid_rx_pkt_crc_err` and the corrupt-packet NACK are all
  dead by construction. **There is no data-path integrity check.**
* Corrupting **any single lane that carries only payload bytes** (lanes 5, 6, and
  lane 7 under stuck-0) causes the RX to **commit a corrupted packet** with
  *every* status interface reading normal. 4/4 per cell, both directions.
* Corrupting the lane that carries the **ECC byte and CRC[7:0]** (lane 3) has
  **no effect at all** — byte-exact delivery, 4/4. Neither the header ECC nor the
  CRC is enforced.
* The **only** thing that ever rejects a corrupted packet is an accidental
  side effect: the RX FIFO's write-completion address match
  (`tidelink_fifo_ctrl.sv:103,239`) fails when the corruption lands inside
  TideLink's own length field (bits [31:20] of the header word). That rejects
  lane-7 flip/stuck-1 — while leaving the FIFO with a **stuck open packet**
  (`packet_active_r=1`, `packet_word_length_r=13`) whose uncommitted words are
  still **readable through the AHB aperture**.

**NOT proven / explicitly out of scope — do not quote these as measured:**

* That the CRC *would* catch these corruptions if enabled. The coverage analysis
  says it should (the CRC spans the whole 56-bit data field, §4.2), but the
  override's own comment says the CRC currently **fails on good packets**, so
  enabling it may simply break the link instead. **Untested.**
* The claim that die_b's SM Control register is hardware-unwritable. Quoted from
  the override comment; not verified here.
* Anything about **multi-lane** corruption, **stuck-X**, or **skewed**
  (`EPOCH_PROFILE != zero`) configurations — this sweep is single-lane, three
  modes, zero skew only.
* Silicon behaviour. Everything here is simulation.
* The `+DISTURBED` cells (framing lanes 0/1/2/4) are single-trial, because the
  harness cannot re-bring-up in-sim (§3.1 note). Their **class** is consistent
  across 3 modes × 2 directions, but they are **N=1 per cell**, not N=4.

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

### F14-A — tapeout recommendation

**GATE the tape-out on a decision about `disable_crc`, not on a fix to a lane.**
The v1 ASIC as currently configured ships with its link-layer integrity check
disabled by reset default in both ASIC flists, and the sweep shows what that
costs: a single stuck or marginal payload lane — precisely the field failure this
programme has spent months chasing — delivers corrupted data into the RX FIFO with
`packet_committed_irq` set, credit correctly consumed, `PKT_WORD_LEN` reading 0
and every error register at 0, i.e. **indistinguishable from correct operation on
every interface the design exposes to software**. The one mechanism that ever
rejects a corrupt packet is an accident of the FIFO's length-match and it leaves a
stuck open packet behind. Because the CRC was disabled to work around a *real*
CRC-fails-on-good-traffic bug, and because the escape hatch (SM Control bit[16])
is reportedly unwritable on die_b, the actionable ask is not "clear the bit": it
is (1) root-cause the header-CRC mismatch that motivated
`WlinkGenericFCSM_6.v:1159-1167`, (2) re-enable the CRC by default once it passes
clean traffic, (3) make bit[16] reliably writable **and readable** on both dies so
the state is auditable in the field, and (4) if (1) cannot be closed before tape-
out, ship the part with an explicit, documented "**no link-layer data integrity —
end-to-end application checksum is mandatory**" contract and expose a status bit
that tells software the CRC is off. Shipping silently-disabled integrity with no
software-visible indication is the part of this that should not survive review.

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
make MODULE=test_ei_lane7_repro         # the ORIGINAL (superseded) F14-A evidence
make ei_sweep                           # S3c: all 48 cells, one simv run each
make MODULE=test_ei_crc_probe           # S3e: is the CRC even enabled?
# one cell on its own:
make MODULE=test_ei_full_sweep TESTCASE=test_s2m_flip_lane5
```
`ei_sweep` runs each cell as a separate `simv` invocation on purpose — see the
harness note in §3.1. Budget ~10-30 s per cell (~20 min for all 48). Grep the run
for `ROW[` (per-cell histogram) and `VERDICT[`.
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
6. **`PKT_WORD_LEN` (APB 0x2008) is NOT a commit indicator** and must not be used
   as one. It is `packet_word_length_r`, cleared on completion
   (`tidelink_fifo_ctrl.sv:191-194`), so a good packet reads 0 and a non-zero
   read means the write never finished. Classify on `write_ptr_r` /
   `credit_count_r` / `packet_committed_irq_r` instead, and sample them **before**
   any AHB aperture read (a read moves `read_ptr`, `packet_committed_irq` and
   `packet_word_length`). This inverted the original F14-A (§4.1).
7. **Only ONE healthy link is available per simulation.** A second
   `run_bringup_full` does not re-run autocal (`cal=IDLE`, `fcsm=0`, no CR/CRACK).
   Any test that needs a fresh link must be its own `simv` invocation. This also
   means the recovery ladder in `errinj_common.classify_recovery` cannot be
   trusted for more than one wedge per simulation.
8. **The compiled FCSM is a local override, not the deps file.**
   `flists/tidelink_fpga_v2.flist:270` selects
   `src/rtl/local_overrides/WlinkGenericFCSM_6.v`, whose reset values differ from
   `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v` (notably
   `disable_crc`, §4.6). **Read the override when reasoning about reset state** —
   reading the deps copy gives the wrong answer.
