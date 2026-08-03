# TideLink / Wlink header-ECC investigation — is the packet-header ECC inert?

Date: 2026-08-03
Branch: `wip/axirec-header-ecc-probe` (worktree off `fix/axi-datanode-recovery`)
Scope: the packet-**header** ECC that should catch a single-bit error in a Wlink
packet header (`data_id` / `word_count` / the ECC byte). Separate from the
already-fixed byte-0 (`data_id`) AXI silent-drop bug and from the CRC/NACK
recovery path.

Method follows the lab rule **verify the instrument before theorizing about the
DUT**: the header ECC and its observability counters are proven (or disproven)
from the RTL net *and* from a simulation whose control input MUST move a live
ECC signal, before any claim about the DUT.

---

## 1. Verdict (definitive)

1. **The header ECC is INERT — hardwired off, not merely mis-wired.**
   `WlinkEccSyndrome.v` has an explicit bring-up patch that ties the decoder
   outputs to constants:

   ```verilog
   // deps/axi-chiplet-controller/logical/wlink/WlinkEccSyndrome.v:299-308
   // SoC Labs bring-up patch (2026-05-05): force ECC bypass.
   assign corrected_ph = ph_in;   // RX frames from the RAW header, never corrected
   assign corrected    = 1'h0;    // never claims a correction
   assign corrupted    = 1'h0;    // never flags a corruption
   ```

   Added by commit `030908d` ("wlink: bring-up bypass for WlinkEccSyndrome",
   dam1n19, 2026-05-05) in the `axi-chiplet-controller` submodule. **Every**
   simulation and FPGA/ASIC flist compiles this file (all five
   `flists/tidelink_*` reference `logical/wlink/WlinkEccSyndrome.v`; the
   generated copies under `wav-wlink-hw/output_*` that still contain the real
   Hamming(33,24) decoder are NOT in any flist). So there is no header-error
   correction and no header-error detection anywhere on the RX path.

2. **The obs instrument is LIVE-but-BLIND — correctly wired to a constant 0.**
   The counters are connected exactly as designed, all the way to the tied-off
   ECC output, so they can never move:

   ```
   WlinkEccSyndrome.corrupted = 1'h0
     -> WlinkRxLinkLayer: io_ecc_corrupted = ecc_check_corrupted   (:1215)
     -> Wlink.v:1656      .io_ecc_corrupted(llrx_io_ecc_corrupted)
     -> Wlink.v:1107-1108 obs_ecc_corrupted_cnt_q += llrx_io_ecc_corrupted
   ```

   (and identically for `corrected`). A zero on `obs_ecc_corrected_cnt_q` /
   `obs_ecc_corrupted_cnt_q` therefore proves **nothing** about corruption — it
   is a constant. The instrument is not broken; the thing it measures is a wire
   tied to 0.

3. **The byte-1 (`word_count`) wedge is real, header-ECC-shaped, and NOT covered
   by the CRC layer.** A large single-bit `word_count` flip desyncs the RX byte
   framer so badly the FC node never receives a checkable packet, so the packet
   CRC never fires and cannot recover it — the link wedges **with CRC enabled as
   well as disabled** (§3). The header ECC — the only layer that inspects the
   header *before* the framer commits to a length — does nothing (obs deltas 0
   in every case).

4. **This is a genuine silicon integrity gap, not a fault-injection artifact.**
   The TX computes the ECC byte over the *uncorrupted* header and the injector
   flips a header wire *independently* (§4), so an injected single-bit header
   error is bit-for-bit what a real SEU / crosstalk / marginal-lane bit-flip
   would present to the RX. A live single-error-correcting header ECC would
   repair all of byte-0/1/2/3 single-bit flips; the bypassed one repairs none.

---

## 2. Instrument-verification evidence (the byte-3 control)

The one input that MUST move a live ECC counter is a flip of **byte 3 — the
header-ECC byte itself**. Test: `test_diag_byte0_detection_path` (the DIAG path
in `cocotb/tidelink_axi_datanode_recovery/test_axi_datanode_gaps.py`), which
resolves the two Wlink saturating counters up front and fails loudly if a probe
is dead, then injects `DIAG_BYTE` on the B packet (data_id 0x82) and records the
counter deltas + outcome.

```
DIAG_BYTE=3  probes live, baseline={corrected:0, corrupted:0}
             deltas -> corrected:0  corrupted:0  crc_rose:False  NACK:False  class:RECOVER
```

The probes resolved **live** (the baseline read succeeded — not a dead hierarchy
path), the input that must move a working ECC counter moved **neither**, and the
corrupted-ECC-byte packet was a functional **no-op** (RECOVER). That is a direct
positive proof that the RX ECC decode is inert and the counters are tied to 0 —
it is not that the probe is mis-placed. Instrument verified.

---

## 3. Byte-by-byte blast radius (B node, data_id 0x82, single-shot injector)

Measured with `test_diag_byte0_detection_path`. Every row: `obs_ecc_corrected` /
`obs_ecc_corrupted` deltas were **0** — the header ECC contributed nothing in
every case. "CRC" = the AXI-FC-node packet CRC.

| byte | header field       | bit | CRC | crc_rose | NACK | class     | who (if anyone) caught it |
|------|--------------------|-----|-----|----------|------|-----------|---------------------------|
| 3    | ECC byte           | 0   | on  | no       | no   | RECOVER   | nobody — no-op (RX ignores `rx_ecc`) |
| 0    | `data_id`          | 0   | on  | no       | no   | **WEDGE** | nobody — silent mis-route/drop (known byte-0 AXI bug) |
| 1    | `word_count[7:0]`  | 0   | on  | **yes**  | **yes** | RECOVER | **CRC** → NACK → replay |
| 1    | `word_count[7:0]`  | 0   | off | no       | no   | RECOVER   | framer tolerated the ±1-word error |
| 1    | `word_count[7:0]`  | 6   | off | no       | no   | **WEDGE** | nobody — framer length desync |
| 1    | `word_count[7:0]`  | 7   | off | no       | no   | **WEDGE** | nobody — framer length desync |
| 1    | `word_count[7:0]`  | 6   | **on** | no    | no   | **WEDGE** | **nobody — CRC could not recover the desync** |
| 2    | `word_count[15:8]` | 0   | off | no       | no   | **WEDGE** | nobody — framer length desync |

Reading it:

* **byte 3 is benign either way.** Under the bypass the RX never reads `rx_ecc`,
  so flipping the ECC byte is a no-op; under a live ECC a single-bit ECC-byte
  flip is a correctable syndrome, also benign. This resolves the review's own
  flagged ambiguity ("obs stays 0 even when byte 3 is corrupted") to *ECC
  bypassed*, not *probe mis-placed*.
* **byte 0 (`data_id`) WEDGES** with no ECC, no CRC, no NACK — the clean silent
  drop already root-caused as the AXI data-node bug (fixed elsewhere by
  synth-B/OKAY). A live header ECC would have *corrected* the flipped `data_id`
  and the packet would have routed normally.
* **byte 1 (`word_count`) is size-dependent.** A ±1 flip (bit 0) is recovered —
  by CRC/NACK when CRC is on, or tolerated by the framer when CRC is off. A large
  flip (bit 6/7, i.e. +64/+128 words) **WEDGES regardless of CRC**: with CRC ON
  the framer desyncs before the FC node ever sees a coherent packet, so
  `crc_rose=False`, no NACK, the B never returns → hang. **This is the key
  result: the CRC layer sits downstream of framing and cannot recover a
  header-length desync; only a header-level check can.**
* **byte 2 (`word_count[15:8]`) WEDGES** — any flip here is a massive length
  error.

---

## 4. Why the injection faithfully models a silicon single-bit header error

TX side (`WlinkTxLinkLayer.v`):

* the ECC byte is computed over the **clean** header:
  `ecc_check_ph_in = {auto_in_word_count, auto_in_data_id}` (:931), and byte 3
  on the wire is `ll_byte_index_3 = calc_ecc` (:77) — note the ECC `calc_ecc`
  output is still computed correctly; the 2026-05-05 bypass only killed the
  *decode* outputs (`corrected_ph`/`corrected`/`corrupted`), not `calc_ecc`;
* the injector XORs `(1 << err_inj_bit)` into the selected wire byte
  *independently*: byte0 = `data_id ^ mask` (:68), byte1 =
  `word_count[7:0] ^ mask` (:70), byte2 = `word_count[15:8] ^ mask` (:73),
  byte3 = `calc_ecc ^ mask` (:76), byte4+ = payload, and the CRC byte at
  index `word_count+4`.

So for a byte-0/1/2 injection the header byte is flipped while the transmitted
ECC byte is still the correct ECC of the *un-flipped* header. At the RX a live
decoder would compute `syndrome = rx_ecc ^ calc_ecc(corrupted_header) != 0`,
map the non-zero syndrome to the flipped bit, and correct it — the textbook
single-error-correct case. The bypass throws that away: `corrected_ph = ph_in`,
so the corrupted header is framed as-is. The injector is therefore not a
synthetic protocol violation; it is a faithful model of a real one-bit header
wire error — exactly the population the header ECC exists to cover.

---

## 5. The byte-1 (`word_count`) wedge mechanism

`word_count` (header bits [23:8]) is the RX framer's long-packet length. Every
AXI FC node (data_id 0x80-0x84) and the B node (0x82) are **long** packets
(`short_packet_max` defaults to `0x7F` < 0x80), so `word_count` drives framing
for exactly the traffic that matters. On entering long mode the framer loads
`word_count <= corrected_ph[23:8]` (raw header, since ECC is bypassed) and ends
the packet at `byte_count >= word_count + 6`. A wrong `word_count`:

* **inflated (framer waits too long)** → it consumes the *next* packet's bytes
  as this packet's body → `byte_count` desyncs relative to the true stream →
  every subsequent packet (including credit-return ACKs) is mis-framed → the
  credit ring drains → **link wedge**;
* **deflated (framer ends early)** → the tail of the real packet is re-parsed as
  a new header → same desync class.

Two SoC-Labs RX overrides *partially* backstop this, but only for gross
inflation, and neither is the ECC:

* `long_pkt_len_ok = word_count <= LONG_PKT_WORD_MAX(64)` gates state-0→1 entry
  (`WlinkRxLinkLayer.v:275, 1301, 1303`), and
* a state-1 self-recover returns to hunt if `word_count > 64`
  (`WlinkRxLinkLayer.v:1313`).

These guards did **not** save the bit-6/bit-7 cases above (still WEDGE), because
the flip either lands `word_count` in a plausible ≤64 range for that packet, or
desyncs the byte framer before the guard's monotone recovery can re-hunt against
live traffic (and with CRC on, the FC node never gets a coherent packet to NACK).
The header ECC is the layer that would have caught *all* of these — it corrects
the flipped bit before the framer ever sees the length — and it is bypassed.

---

## 6. Recommendation (design only — no large RTL change here)

Priority is set against the two open items from the 2026-08-02 pushback review
(F-1 illegal-AHB ERROR; the read-path R/AR backstop asymmetry).

**R1 — (highest of the ECC items) Restore header-error *detection* with
drop-on-uncorrectable; gate it; do NOT naively un-bypass.** The 2026-05-05
comment is the tell: the Hamming decoder flagged *every* header as corrupted at
25 MHz on the bench, so un-bypassing as-is re-breaks bring-up. That symptom is a
TX-compute-vs-RX-check mismatch (syndrome polynomial / bit-order / the `rx_ecc`
byte lane) — the ECC is *wrong*, not merely off. Fix class:
  1. audit the TX `calc_ecc` vs the RX syndrome polynomial (the generated
     `output_*/WlinkEccSyndrome.v` is the un-patched reference) and the byte-3
     lane mapping, in a directed 2-die sim, until an ECC-clean header reads
     `corrupted=0` and a known single-bit flip reads `corrected=1` with the bit
     repaired;
  2. re-enable behind a **default-OFF SWI bit** (mirror `SWI_SYNC_ROBUST_DETECT`)
     so bring-up keeps today's behaviour until the polynomial is proven;
  3. on an *uncorrectable* (multi-bit) header: **drop** the packet and let
     CRC/NACK/replay (or the I5 backstop) recover — never frame from a header the
     ECC calls bad. This closes the byte-1 desync class at its natural layer,
     independently of whether the AXI nodes ship CRC on or off (§3 shows CRC does
     not cover it).
  Copy the file to `src/rtl/local_overrides/WlinkEccSyndrome.v` and re-point the
  flists; do not edit the submodule (project rule).

**R2 — Fix the instrument so a future regression can't hide.** Today
`obs_ecc_*_cnt_q` honestly report a constant. After R1 they become meaningful;
until then, either annotate them "ECC bypassed — always 0" at the APB doc layer,
or (cheap) add a `syndrome != 0` raw-detect tap independent of the correction
enable, so the counter reflects *header errors seen* even while correction is
gated off.

**R3 — Priority vs F-1 / read-path.** F-1 (I5 emits an AHB-illegal ERROR an
upstream bridge may drop → PS hang) and the R/AR single-bit backstop asymmetry
are **live wedge paths on the current build** and should land first — they bound
real hangs today, on the traffic the silicon already runs. The header ECC is a
**latent** integrity gap: a healthy link does not wedge on its own, but the
designed protection against transient single-bit header errors is absent, and
§3 shows that when such an error hits `word_count` the wedge is reachable even on
a CRC-enabled build. Recommended order: **F-1 → read-path backstop → R1 (header
ECC, gated) → R2**. R1 is the correct long-term home for the byte-1 `word_count`
desync that no other layer reliably covers, and it is required for any
deployment that expects the datasheet's header ECC to actually protect the
header.

---

## 7. Repro / how to reproduce

```
cd /home/dam1n19/SoCLabs/tidelink-wip-ecc
source ./set_env.sh && export PATH=$VCS_HOME/bin:$PATH TIDELINK_PHY_V2=1
cd cocotb/tidelink_axi_datanode_recovery
# instrument control (must stay 0 => ECC inert):
DIAG_BYTE=3                        make MODULE=test_axi_datanode_gaps TESTCASE=test_diag_byte0_detection_path SIM_BUILD=sim_build_diag
# byte-0 silent-drop wedge / byte-1 mild CRC-catch:
DIAG_BYTE=0                        make ...   # WEDGE
DIAG_BYTE=1                        make ...   # RECOVER via CRC (crc_rose=1, NACK)
# byte-1 word_count desync (wedges CRC on OR off for a large flip):
DIAG_CRC=off DIAG_BYTE=1 DIAG_BIT=6 make ...  # WEDGE
DIAG_CRC=on  DIAG_BYTE=1 DIAG_BIT=6 make ...  # WEDGE — CRC cannot recover a framer desync
```

`DIAG_CRC` (default `on`) and `DIAG_BIT` (default `0`) are two small,
backward-compatible env knobs added to the existing DIAG test by this
investigation (the byte-3 default path is unchanged). They are diagnostic only
and are NOT wired into `make gaps` / `sim_gate`, so the blocking gate is
unchanged. `run_ecc_diag_sweep.sh` in the same directory runs the byte {3,1,0}
sweep in one compiled build.
