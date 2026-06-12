# v37 Final Diagnosis — the one remaining defect, fully isolated (2026-06-12)

**Bottom line: the V2 (new-PHY) TideLink system is ONE well-specified RTL fix
from a bilateral working link. Every other layer is verified working on
silicon. The fix lives in `deps/tidelink-phy` (the shared PHY component):
cross-lane word-EPOCH deskew, which the V2 component lacks.**

Meanwhile: the V1 system remains the working TideLink system today (v33:
bilateral LINK_IDLE + M→S data crossing, reproduced 3×).

## Verified-working on silicon (v37, bridge1)

| Layer | Evidence |
|---|---|
| Serdes eye, both directions | bilateral 8/8 lane lock, 0 faults |
| Link rate (6.25 MHz) | timing-clean builds (WNS +0.4); matches proven BIST |
| Per-lane word-phase | word_pin=5 forced on z2_02 → perfect training lock (`lk=ff`); the wp sweep showed 5 is the unique correct window |
| Calibrators | **bilateral S_HOLD with `lk=ff/ff`** under the wp5+thresh5+hold recipe — first time ever |
| Freeze (S_CANCEL latch) | per-lane slip/phase latches persist; training drops; LLs release |
| A→B packet path end-to-end | B decodes A's CR **instantly, every attempt** (5/5 bootstraps, all prior runs) |
| FCSM/M12 bootstrap mechanics | behave exactly per v33 |

## The defect (B→A only, deterministic)

With everything above held: z2_02's LL receives **valid, framed short
packets** (`llrx_valid=1, is_short_pkt=1` continuously) from z2_03, but they
**never decode as CR** (`pkt_is_cr=0`, sticky `cr=0`). Eliminated tonight by
direct experiment:

- NOT eye margin (rate already 4× down; lane lock perfect)
- NOT per-lane word-phase (wp=5 forced and proven via training lock)
- NOT a byte-align lottery (20 LL-reset re-rolls → bit-identical state)
- NOT handshake ordering (5 simultaneous M12 bootstraps → bit-identical)
- NOT calibrator coordination (bilateral S_HOLD achieved; latches persist)

**The only mechanism consistent with all evidence: cross-lane word-EPOCH skew
on z2_02's RX.** Each lane's 16-bit framing is correct (training proves it),
but lanes deliver different word *epochs* into the 128-bit assembly — so
multi-byte packet fields straddle epochs and decode wrong, while per-lane
training (constant pattern, epoch-blind) locks perfectly. z2_02 is the
historically skewed side (3–7 word inter-lane skew, the V1 DEPTH_LOG saga).

## Why V1 worked and V2 doesn't

- V1's `tidelink_lane_deskew` (local_overrides) was **content-anchored**: TX
  inserted SYNC delimiter words; RX deskew aligned all lanes' epochs to the
  SYNC, and the LL framer could re-hunt on SYNC (c4fe5d2).
- The V2 component's `tidelink_lane_deskew` is **occupancy-only**
  ("prime-and-continuous": equalizes FIFO cushions, assumes frequency-locked
  lanes) — it cannot correct whole-word epoch offsets. The V2 TX inserts **no
  SYNC** (`sync_det=0` on the wire, confirmed; the V2 WavD2DGpio fork has no
  sync insertion).
- The BIST never caught this: its PRBS payloads and checkers are **per-lane**
  — cross-lane word coherence of the assembled 128-bit bus was never
  validated on skewed hardware.

## The fix (deps/tidelink-phy — coordinate with the calibrator-rewrite owner)

Add cross-lane epoch alignment to the V2 RX. Two designs, either works:

1. **Training-anchored epoch priming (recommended — zero TX change):** during
   training, every lane receives the same 16-bit pattern *simultaneously
   from the TX*. Each lane's deskew write-side records its word-counter value
   at training-pattern match; the read controller equalizes offsets so all
   lanes present the same epoch (exactly what the V1 deskew did with SYNC,
   using the training word as the anchor). Prime once per training window;
   hold latched through data mode.
2. **Port the V1 mechanism wholesale:** restore SYNC-word insertion in the V2
   TX (the V1 `c4fe5d2` delimiter, or the BIST's `tidelink_phy_sync_insert`)
   plus the V1 content-anchored deskew. More moving parts; also restores LL
   framer self-healing as a bonus.

Validation: a sim test that injects **per-lane word-epoch offsets** (not just
bit skew) between the pair — the existing `pad_skid` differential-skew hooks
in `cocotb/tidelink_top_pair` can be extended to whole-word offsets; the
current suites would not have caught this class.

## Reproducing the stable failure state (for ILA, if direct confirmation wanted)

```
deploy v37 both → 0x44032160=0x55555555 both → A:0x44032104=0x15000000
→ slot0 0x1 → 0x3 → 0x1 both (wait: bilateral calst=6, lk=ff/ff)
→ slot0 0x2 both (freeze) → A receives B's framed-but-undecodable packets
```
ILA target: z2_02 post-deskew 128-bit bus + per-lane deskew occupancy/epoch
counters — one capture confirms the epoch interleave directly.

## Status of "a working TideLink system"

- **Today, working:** V1 (v33 artefacts staged on mapstone-dev) — bilateral
  link + data crossing, silicon-proven.
- **V2, one fix away:** everything integrated, gated, timing-clean, and
  silicon-verified except cross-lane epoch deskew. With fix design #1 above,
  no TX change and no protocol change is needed; rebuild and the existing
  wp5/hold/freeze recipe (or full autonomy once seeded) should complete.
