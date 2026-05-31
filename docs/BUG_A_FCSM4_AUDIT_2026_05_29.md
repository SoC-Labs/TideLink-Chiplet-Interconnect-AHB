# Bug A FCSM_4 Audit — 2026-05-29

Auditor: Claude Opus 4.7 (offline, READ-ONLY).

## 1. Verdict

- **FCSM_4 is INSTANTIATED** in the TideLink RTL build, as `wlink_axirFC`
  inside `AXI4ToWlink axi2wl` — it is the AXI **read-response** FC channel.
  Reference: `deps/axi-chiplet-controller/logical/wlink/AXI4ToWlink.v:681`
  and `src/rtl/local_overrides/Wlink.v:1340`.
- **Bug A symptom DOES NOT manifest on FCSM_4 today**, because the shared
  `WlinkRxLinkLayer llrx` decodes packet DataID and per-channel routes the
  `rx_in_valid` strobe (`rxrouter_auto_out_*`). Bug A traffic is *TideLink*
  long-packet DataIDs — those are routed to `tl2wl` (FCSM_6), never to
  `wlink_axirFC` (FCSM_4). FCSM_4 only sees `rx_in_valid` when AXI-read
  response packets arrive on the wire (i.e. after AXI master initiates
  reads), which does not happen in the Bug A bring-up window.
- **However the RTL gap is IDENTICAL.** FCSM_4 has the same LINK_IDLE
  gate, the same `send_nack_req` latch, the same `isNotExpPacket` decode
  on its FIFO. It carries an exposure that will trigger whenever the
  AXI-r channel actually starts moving traffic, AND it never received the
  L7 patch — only `src/rtl/local_overrides/WlinkGenericFCSM_6.v` has the
  `socl_l7_*` signals.

**Recommendation:** Do not port the L8 fix into FCSM_4 right now. Instead,
the real fix belongs upstream of FCSM at the producer-side gate (`_GEN_60`
and `send_nack_req` write equations). Plan to either (a) regenerate FCSM_4
from a corrected Chisel source so all seven FCSMs land the fix once, or
(b) hand-port the L7 latch + L8 consumer drain into FCSM_4 once Bug A's
L8 patch is sim-proven on FCSM_6. See §6.

## 2. State encoding comparison

Both files are FIRRTL-elaborated siblings of the same Chisel FC.scala
class — only the `link_ack_addr` width differs (FIFO depth parameter).

| Item                  | FCSM_4                              | FCSM_6                              |
|-----------------------|-------------------------------------|-------------------------------------|
| State register width  | `reg [2:0] state` @ FC.scala 143:91 | `reg [2:0] state` @ FC.scala 143:91 |
| State 0               | RESET / wait (`_ack_seen_before_T = state == 3'h0`) | same |
| State 1, 2            | LINK_INIT / CR / CR-ACK (transitions via `crack_pkt_seen` etc.) | same |
| State 3               | LINK_EN handshake (FC.scala 491:61) | same |
| **State 4 = LINK_IDLE** | FC.scala 501:58 (`state == 3'h4`)  | FC.scala 501:58 (`state == 3'h4`)  |
| **State 5 = LINK_DATA** | FC.scala 534:58 (`state == 3'h5`)  | FC.scala 534:58 (`state == 3'h5`)  |
| State 6               | NACK / replay (FC.scala 578:57)     | same |
| State 7               | LINK_DONE / drain (FC.scala 571:58) | same |
| `link_ack_addr` width | 6-bit (`ack_nack_fifo_io_rdata[5:0]`) | 5-bit (`ack_nack_fifo_io_rdata[4:0]`) |

State numbering, transitions, and gating are otherwise identical.

## 3. LINK_IDLE → LINK_DATA gate in FCSM_4

```
WlinkGenericFCSM_4.v:274  wire _T_59 = a2l_fc_replay_link_valid & ~fe_rx_is_full;  // FC.scala 523:45
WlinkGenericFCSM_4.v:282  wire [2:0] _GEN_60 = a2l_fc_replay_link_valid & ~fe_rx_is_full ? 3'h5 : state;  // FC.scala 523:63
```

vs. FCSM_6's `_GEN_60` at `deps/.../WlinkGenericFCSM_6.v:297` (Bug A's
original gate, same line in Chisel). The gate is **bit-identical**.
Producer-side gap = same on both files: `state` only leaves 4 → 5 when
the local channel's `a2l_fc_replay_link_valid` is high AND the local RX
isn't full. Peer's `tl_fc_a2l_valid` does not advance the consumer side.

## 4. L7 fix presence

L7 latch (`socl_l7_reached_link_data`, `socl_l7_bringup_forgive`,
`isNotExpPacket_l7`, `send_nack_req <= ... & ~socl_l7_bringup_forgive`)
is present **only** in `src/rtl/local_overrides/WlinkGenericFCSM_6.v`
(lines 376–388, 1063–1088).

`WlinkGenericFCSM_4.v` (both upstream and ipshared copies) has **no
L7 markers**. The send_nack_req writes at lines 884–894 are the
unmodified upstream form:
```
send_nack_req <= send_nack_req | (crcCorruptSeen | isNotExpPacket);
```

## 5. RX wedge analysis

The Bug A surface (consumer latches `send_nack_req` → bounces 5 → 4) is
formally present in FCSM_4 RTL: identical `isNotExpPacket` derived from
`ack_nack_fifo_io_rdata[18:16] == 3'h1`, identical `send_nack_req` set
equation. **But** the trigger never fires today, because:

1. `pkt_is_data_pkt` requires `rx_in_valid` from llrx's per-channel
   router. The router (`rxrouter_auto_out_5_valid` for `axirFC`) only
   asserts when an *AXI-read response* DataID is decoded on the wire.
2. Bug A's master never sends AXI-r DataID packets during the L7/L8
   bring-up window — it only emits TideLink long-packet DataIDs, which
   route to FCSM_6 (`tl2wl`) exclusively.

So FCSM_4 sits parked at state 4 with `send_nack_req=0` throughout the
Bug A failure mode. The RTL gap is latent, not active.

## 6. Recommendation

- **Short term (Bug A fix landing on FCSM_6 only):** safe. FCSM_4 is
  quiet during bring-up; no patch needed to unblock the current link.
- **Medium term:** once the L8 consumer-drain pattern is sim-verified on
  FCSM_6, port the same L7+L8 patch into a `local_overrides/WlinkGenericFCSM_4.v`
  for AXI-r, AND apply analogously to FCSM_1/_2/_3 (axiw/axib/axiar) —
  same FIRRTL gate, same latent wedge. Otherwise the moment Wlink starts
  carrying real AXI traffic the wedge will reappear on whichever AXI FC
  channel runs the offending sequence.
- **Long term (correct location of the fix):** the bug is in FC.scala
  (the Chisel source that emits all seven FCSMs). Lines FC.scala 505,
  523, 531 — the producer-side IDLE→DATA gate and the send_nack_req set
  equation — should both be corrected at the Chisel level so all seven
  FIRRTL siblings (`WlinkGenericFCSM.v` through `WlinkGenericFCSM_6.v`)
  are regenerated with the fix. Doing the patch at FC.scala also covers
  GeneralBus's FCSM_5, which today is unused but lives in the same flist.
- **Decode path:** `WlinkRxLinkLayer` is shared but is not the bug site —
  it correctly routes packets; the wedge is purely inside each FCSM's
  consumer state machine.

## File references

- `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_4.v:148,156,191,238,274-282,884-894`
- `deps/axi-chiplet-controller/logical/wlink/WlinkGenericFCSM_6.v:163,171,206,253,297` (upstream)
- `src/rtl/local_overrides/WlinkGenericFCSM_6.v:376-388, 1063-1088` (L7 patch site)
- `deps/axi-chiplet-controller/logical/wlink/AXI4ToWlink.v:681` (FCSM_4 instantiation)
- `deps/axi-chiplet-controller/logical/wlink/TideLinkToWlink.v:86` (FCSM_6 instantiation)
- `deps/axi-chiplet-controller/logical/wlink/Wlink.v:1280,1468` (axi2wl + tl2wl wiring; line 1778 = axirFC route assign)
