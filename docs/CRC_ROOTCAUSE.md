# Link-layer header CRC — root-cause investigation

**Date:** 2026-07-19 · **Bench:** `cocotb/crc_diag/` · **RTL:** `integ/consolidation-2026-07`
**Config:** `TIDELINK_PHY_V2=1`, `EPOCH_PROFILE=zero`, VCS, `flists/tidelink_fpga_v2.flist`

## Summary

The link-layer CRC ships **disabled** because of this note in
`src/rtl/local_overrides/WlinkGenericFCSM_6.v:1159-1167`:

> Silicon-confirmed: V2 long DATA packets arrive but header-CRC fails
> (crc_errors saturates) -> FCSM SEND_NACK -> no enqueue. […] Default-on also
> sidesteps die_b's hardware-unwritable SM Control reg.

**On current `integ` RTL I could not reproduce the false-fire.** With the CRC
re-enabled on both dies, 12/12 packets across a full 2x2 matrix — including the
exact V2 silicon configuration (4-lane mask `0xE4` + `SWI_SYNC_FORCE_ALWAYS`) —
were delivered **byte-exact with zero `crc_corrupt` cycles and `crc_errors = 0`**.

Two claims in the override comment are **refuted**, and one is **unconfirmed**:

| Claim | Verdict |
|---|---|
| `FC.scala:157` forces `crc_corrupt = false` unconditionally | **REFUTED** — it is the else-arm of a `Mux` gated on the `disable_crc` CSR |
| die_b's SM Control register is hardware-unwritable | **REFUTED in sim** — bit[16] cleared over APB on **both** dies |
| Good long V2 DATA packets fail the header CRC | **NOT REPRODUCED** on current RTL |

There is **no TX/RX CRC asymmetry**. The recommendation is therefore *not* an RTL
fix: it is **re-enable the register and re-test on silicon**.

---

## 1. CRC datapath — TX vs RX coverage

Both directions instantiate the **same** generator over the **same** field, so
coverage is symmetric by construction.

| | TX | RX |
|---|---|---|
| Instance | `WlinkGenericFCSM_6.v:1030` `WlinkCrcGen_8 bundleOut_0_crc_crcgen` | `WlinkGenericFCSM_6.v:933` `WlinkCrcGen_8 rx_crc_computed_crcgen` |
| Input | `WlinkGenericFCSM_6.v:1124` `= link_data` (56 b) | `WlinkGenericFCSM_6.v:1070` `= auto_rx_in_data` (56 b) |
| Chisel | `FC.scala:630` `ll_tx.crc := WlinkCrcGen(ll_tx.data)` | `FC.scala:155` `rx_crc_computed = WlinkCrcGen(ll_rx.data)` |

**Generator** (`LinkLayer.scala:1193-1266`): 16-bit CRC, seed `0xFFFF`
(`crcMap(i) += -1` at `:1217`, emitted as the `1'h1` XOR terms), taps at bit
positions 3/10/15 (`:1233-1235`) — CRC-16/CCITT. Fully unrolled combinational
XOR tree, no bit/byte-order stage, so **order cannot differ between the two
instances**: they are the same module fed the same-width bus.

**Wire format** — 13 bytes, `wordCountSize = txWlinkDataWidth/8 = 56/8 = 7`
(`FC.scala:71,74`; `word_count = 16'h7`, `WlinkGenericFCSM_6.v:759`):

```
byte 0      data_id (0xa1)
byte 1..2   word_count = 7
byte 3      ECC over the 24-bit header      <- SEC-DED, NOT the CRC
byte 4..10  ll.data[55:0] = {48b app data, 8b FC pkt num}   <- the CRC's ONLY coverage
byte 11..12 CRC-16
```

TX places the CRC at `ll.word_count + 4/5` (`LinkLayer.scala:460-461`); RX reads
it from `byte_index_crc + 4/5` with `byte_index_crc = word_count`
(`LinkLayer.scala:688,795`). Both resolve to bytes 11/12. TX emits data bytes at
`ll_byte_index(i+4)` for `i < numBytes-6 = 7` (`:454-456`); RX reconstructs
`ll.data` from `ll_byte_index(i+4)` (`:789-793`). **Identical spans.**

The CRC covers the 56-bit data field and **nothing else** — the header is
protected only by the ECC byte, and the comparison is gated on
`data_id === swi_data_id` (`FC.scala:157`).

### Why "long packets" is not the clue it appears to be

`crc_corrupt` is gated on `ll_rx.data_id === swi_data_id` (the DATA id, `0xa1`).
DATA packets are the **only** packet type above `swi_short_packet_max`, i.e. the
only *long* packets — CR/CRACK/ACK/NACK are all short and carry no CRC at all
(`LinkLayer.scala:367` "crc not valid on short packet"). So **"the CRC only
fails on long packets" is a tautology: long DATA packets are the only packets
whose CRC is ever evaluated.** The qualifier carries no length information, and
there is no length variable to overflow — `word_count` is the constant 7 for
every DATA packet.

The one place packet length *does* matter is beat count:
`beats = ceil((word_count+6)/bytesPerCycle) = ceil(13/bytesPerCycle)`.
At 8 lanes `bytesPerCycle=16` → **1 beat**; at the V2 4-lane mask `0xE4`
`bytesPerCycle=8` → **2 beats**. That was the leading hypothesis and it is
tested directly below (cell C/D) — it does not fail.

---

## 2. Reproduction attempt

`cocotb/crc_diag/` — fresh bench, copies of the `tidelink_top_pair_v2` harness
(`tb_top.sv`, `pad_skid.sv`, `pair_v2_common.py`); **no shared RTL modified.**

CRC re-enabled by APB write to the TideLink FC node's SM Control,
**`0x1714` bit[16]** (base `0x1700`, `docs/REGISTER_MAP.md`; `FC.scala:661`),
with a cocotb `Force` fallback that was never needed.

### 2.1 `disable_crc` writability — the die_b claim is REFUTED

`make MODULE=test_crc_enable_probe`

```
VERDICT[static_m]: {'out_prepend_swi_disable_crc': 1, 'swi_data_id_1': 161, ...}
VERDICT[static_s]: {'out_prepend_swi_disable_crc': 1, 'swi_data_id_1': 161, ...}
VERDICT[crc_writability_m]: POR disable_crc=1 apb_sm_control 0x10708->0x708 apb_worked=True
VERDICT[crc_writability_s]: POR disable_crc=1 apb_sm_control 0x10708->0x708 apb_worked=True
VERDICT[smcontrol_asymmetry]: REFUTES the override comment -- SM Control bit[16]
                              is SW-writable on BOTH dies in sim.
```

Both dies POR to `disable_crc=1` (the local override) and **both accept the
clear over APB**. The software escape hatch works on both dies in sim. (This
does not settle the silicon claim — see §5.)

### 2.2 The 2x2 matrix — all cells clean

`make MODULE=test_crc_matrix` — CRC enabled on both dies, fresh bring-up per
cell, 3 packets per cell via the shipping `send_and_check` helper.

| Cell | Lanes | Beats | Beacon | Delivered | `crc_corrupt` | `crc_errors` |
|---|---|---|---|---|---|---|
| A | 8 (`0xFF`) | 1 | OFF | **3/3** | 0 | 0 |
| B | 8 (`0xFF`) | 1 | `FORCE_ALWAYS` | **3/3** | 0 | 0 |
| C | 4 (`0xE4`) | 2 | OFF | **3/3** | 0 | 0 |
| D | 4 (`0xE4`) | 2 | `FORCE_ALWAYS` | **3/3** | 0 | 0 |

**Cell D is the V2 silicon configuration**: lane mask `0xE4` and the documented
bring-up write `R8 = 0x1C`, which sets both bit[2] `sync_insert_en` and bit[3]
`sync_force_always`. It passes.

### 2.3 The SYNC-beacon hypothesis (d593058) — not exercised here

The RTL on this branch already contains the d593058 guard:

```verilog
// src/rtl/local_overrides/WlinkRxLinkLayer.v:393
wire sync_resync_boundary = sync_resync & (state != 2'h1);
```

which suppresses the framer reset at `:1272` (`state`), `:1858` (`word_count`)
and `:1875` (`byte_count`) while a long-packet **body** is being consumed.

I A/B'd it: `cocotb/crc_diag/WlinkRxLinkLayer_prefix.v` is a **local copy** with
the guard reverted to `sync_resync_boundary = sync_resync` (pre-fix behaviour),
selected via a local flist `tidelink_fpga_v2_prefix.flist`. The shared file is
untouched.

```
make MODULE=test_crc_matrix V2_FLIST=$PWD/tidelink_fpga_v2_prefix.flist SIM_BUILD=sim_build_prefix
  -> cells A/B/C/D all 3/3 delivered, crc_corrupt=0   (IDENTICAL to the fixed build)
```

Build was verified structurally (the prefix path appears in
`sim_build_prefix/simv.daidir/debug_dump/src_files_verilog`; the two `simv`
binaries differ).

Direct instrumentation explains why the A/B is a null result — the vulnerable
window is **never entered** in this sim:

```
beacon_while_state1 = 0    # beacon cycles landing mid-long-packet body
guard_blocked       = 0    # cycles where the d593058 guard actually suppressed a reset
resync_fired        = ~128 per window (all in state 0, i.e. on an idle bus)
```

A beacon cycle and a packet-data cycle are **mutually exclusive by
construction** (a given RX cycle carries either a SYNC word or packet bytes), so
`sync_resync` and `is_long_pkt` can never coincide. Under this harness even
`force_always` only ever fires the beacon on an idle bus.

**Conclusion: I can neither confirm nor refute that d593058 was the fix.** My
sim does not create the condition it repairs. That remains the best available
hypothesis for the silicon observation, but it is *not* established by this work.

---

## 3. Bench-artefact warning (the main methodological finding)

Two earlier revisions of this bench reported convincing per-packet corruption in
cell D, including one captured CRC mismatch
(`computed=0x4c5f received=0x0000`). **Those results are VOID.** The bench
pre-drained the RX FIFO with 8 reads against a 4-word packet. Reading an **empty**
RX FIFO pops a phantom zero-length packet that walks `read_ptr` by 2 words
(`project_rxfifo_empty_read_phantom_pop_2026_07_14`), desyncing the read pointer
and wedging the FIFO from the second packet onward.

It was caught by an A/B that turned the beacon **off** and saw the failures
persist (`VERDICT[WEDGED]: beacon_ON 1/8, then beacon_OFF 0/4`) — a link fault
cannot survive removal of its own trigger. Two mechanisms had already been built
on the artefact before that check ran.

`crc_common.drain_rx()` now carries a comment capping the read count, and
`test_crc_matrix.py` avoids draining entirely. **Any future CRC bench must
verify delivery and CRC in the same run, and must A/B the trigger.**

---

## 4. Proposed change (NOT APPLIED)

No RTL defect was identified, so there is **nothing to patch in the datapath**.
The proposal is to restore the upstream reset value and re-qualify on silicon.

```diff
--- a/src/rtl/local_overrides/WlinkGenericFCSM_6.v
+++ b/src/rtl/local_overrides/WlinkGenericFCSM_6.v
@@ -1157,12 +1157,14 @@
   always @(posedge clock or posedge reset) begin
     if (reset) begin
-      // SoC Labs 2026-06-14: default disable_crc=1 (GPIO-speed deployment).
-      // Silicon-confirmed: V2 long DATA packets arrive but header-CRC fails
-      // (crc_errors saturates) -> FCSM SEND_NACK -> no enqueue. At 6.25 MHz the
-      // BER is negligible so CRC is pure overhead (REGISTER_MAP.md "key register
-      // for GPIO-speed deployments"). Default-on also sidesteps die_b's
-      // hardware-unwritable SM Control reg. SW can still re-enable via bit[16].
-      out_prepend_swi_disable_crc <= 1'h1;
+      // SoC Labs 2026-07-19: restored to the upstream default (CRC ENABLED).
+      // The 2026-06-14 default-disable cited a silicon false-fire on V2 long
+      // DATA packets. On integ/consolidation-2026-07 that does NOT reproduce:
+      // cocotb/crc_diag test_crc_matrix delivers 12/12 packets byte-exact with
+      // crc_corrupt=0 across {8,4} lanes x {beacon off, force_always},
+      // INCLUDING the V2 silicon cell (mask 0xE4 + SWI_SYNC_FORCE_ALWAYS).
+      // TX and RX coverage are symmetric by construction (same WlinkCrcGen_8
+      // over the same 56-bit field) -- see docs/CRC_ROOTCAUSE.md.
+      // NOTE: the "die_b SM Control is hardware-unwritable" claim is refuted in
+      // sim (bit[16] clears on both dies); re-verify on silicon before relying
+      // on the SW escape hatch.
+      out_prepend_swi_disable_crc <= 1'h0;
     end else if (out_f_wivalid_6) begin
       out_prepend_swi_disable_crc <= auto_in_pwdata[16];
     end
   end
```

**Where it lands.** `disable_crc`'s reset value comes from the Chisel regmap
(`FC.scala:663`, `WavRW(disable_crc, false.B, ...)`), which **already defaults to
`false` (CRC enabled)**. The `1'h1` exists *only* in the local override. So this
is a **local-override-only revert** — no generator change, no regeneration.
Regenerating `WlinkGenericFCSM_6.v` from Chisel would produce `1'h0` anyway.

**Is `FC.scala:157` also blocking?** **No.** Per the corrected reading, it is

```scala
val crc_corrupt = Mux((ll_rx.sop && ll_rx.valid && (ll_rx.data_id === swi_data_id))
                      & ~disable_crc, (rx_crc_computed =/= ll_rx.crc), false.B)
```

The `false.B` is the **else-arm of a Mux gated by the `disable_crc` CSR**, not an
unconditional suppression. There is no elaboration-time `crcEn` parameter and the
CRC hardware is always emitted. **Clearing the register is sufficient** to restore
end-to-end checking — confirmed empirically: with bit[16] cleared, `crc_corrupt`
is live and the FCSM's `pkt_is_data_pkt` path responds to it.

**Lower-risk alternative:** leave the reset value at `1` and clear bit[16] from
the bring-up recipe. Same datapath effect, no RTL change, trivially revertible in
the field — preferable if silicon re-qualification cannot be scheduled before
tapeout.

---

## 5. Is re-enabling safe? What depends on the CRC being off?

**The NACK/replay path is the real risk, and it is live.** `crc_corrupt` feeds:

* `valid_rx_pkt_crc_err` (`WlinkGenericFCSM_6.v:457`) → `ack_nack_fifo` tag `3'h4`
  → `crcCorruptSeen` (`:535`) → **latches `send_nack_req`** (`:1567-1573`) → FCSM
  → `SEND_NACK` (state 7). This is exactly the saturation path the override
  comment describes.
* `pkt_is_data_pkt = ... & ~crc_corrupt` (`:440`) — a CRC error **suppresses
  enqueue**, so a false-fire drops good data rather than merely counting it.
* `socl_l7_real_crc_seen` (`:630`) is a **sticky** bit: one real CRC error
  permanently **disarms the state-7 NACK watchdog** (`:634`), removing the
  recovery escape that currently protects against a wedge at state 7.

So re-enabling is **not free**: if a false-fire does occur on silicon, the
failure mode is a latched NACK plus a permanently disarmed watchdog — worse than
a counter ticking. That is presumably what was seen in June.

**Recommended sequencing:**

1. Re-enable at runtime first (write `0x1714` bit[16] = 0), **not** by changing
   the reset value — keep the POR-safe default until silicon confirms.
2. Watch `crc_errors` (`0x1720`) **and** FCSM `state` together. `crc_errors`
   alone is a weak instrument: it is forced to 0 on every `io_rx_clk` edge where
   `en_ff2_rx_demet_io_out` is low (`WlinkGenericFCSM_6.v:1171-1183`), so an
   enable dip erases the evidence. Latch `crc_corrupt` continuously instead.
3. Confirm the die_b writability claim on hardware before depending on the
   escape hatch.
4. Only after a clean silicon soak, land the reset-value revert in §4.

---

## 6. What this sim can and cannot prove

**Can:** TX and RX CRC coverage are symmetric by construction — same module,
same 56-bit field, same byte positions; there is no asymmetry defect to find.
`disable_crc` is SW-clearable on both dies in sim. With the CRC enabled, current
`integ` RTL passes clean long-packet traffic in all four lane/beacon cells,
including the V2 silicon configuration.

**Cannot:**

* **Rate.** The silicon report is at 6.25 MHz with real IDELAY/eye behaviour;
  this sim runs the `EPOCH_PROFILE=zero` harness at a different rate with ideal
  pads. A CRC failure driven by marginal sampling (a genuinely corrupted byte
  the CRC correctly rejects) would **not** appear here — and that remains a
  live possibility: nothing in this work shows the silicon CRC errors were
  *false*. "Packets arrive" was asserted in the comment, not demonstrated
  byte-exact alongside the CRC reading.
* **Build vintage.** I tested current `integ`. The June observation was on a
  build from before d593058 and before an unknown set of other fixes. The
  behaviour may have been repaired by any of them.
* **d593058 specifically.** Its guard is not exercised by this harness
  (`beacon_while_state1 = 0`), and reverting it changes nothing here (§2.3).
* **die_b's SM Control on silicon.** Refuted in sim only; the comment's claim is
  about hardware and is untested here.

**Bottom line:** re-enable the CRC at runtime and re-measure on silicon, with
`crc_corrupt` latched continuously and delivery checked byte-exact in the same
run. If it is clean there, land the §4 revert. If it fires, the next question is
whether the packets are *genuinely* corrupt — which the June note never
established.

---

## Bench inventory — `cocotb/crc_diag/`

| File | Purpose |
|---|---|
| `Makefile` | VCS + V2 flist, `EPOCH_PROFILE=zero` |
| `tb_top.sv`, `pad_skid.sv`, `pair_v2_common.py` | verbatim copies of the `tidelink_top_pair_v2` harness |
| `crc_common.py` | APB offsets, `enable_crc()`, `CrcMonitor` (latches `crc_corrupt` every cycle) |
| `test_crc_enable_probe.py` | POR value + per-die APB writability of bit[16] |
| `test_crc_matrix.py` | **the result** — clean 2x2 lane x beacon matrix |
| `test_crc_beacon_ab.py` | first beacon/lane sweep — *contains the drain artefact, see §3* |
| `test_crc_rootcause.py`, `test_crc_mechanism.py` | instrumented framer traces; both hypotheses refuted by their own instruments |
| `WlinkRxLinkLayer_prefix.v`, `tidelink_fpga_v2_prefix.flist` | local guard-reverted copy for the d593058 A/B (shared RTL untouched) |
