# Bug A — slave RX NACK predicate sim instrumentation (2026-06-01)

Goal: replace the blocked Build #9 ILA capture (`.ltx` mismatch) with sim
evidence identifying which of the FCSM RX predicates fires first when a
master AHB write fails to land in the slave RX FIFO.

## 1. Test file path

`/home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair/test_buga_nack_predicates.py`

Run command (single test, ~5 min wall, ~10.4 ms sim time):

```
source /home/dam1n19/SoCLabs/tidelink/set_env.sh
cd /home/dam1n19/SoCLabs/tidelink/cocotb/tidelink_top_pair
timeout 900 make MODULE=test_buga_nack_predicates \
    SIM_BUILD=sim_build_nack_probes TB_TOP_NO_DUMP=1
```

## 2. Hierarchical refs used

All 8 probes resolve from `dut.u_slave.u_chiplet_controller.u_wlink.tl2wl.wlink_tidelinktl`
(the `WlinkGenericFCSM_6` instance). Confirmed by an `All 8 NACK predicate
probes resolved.` log line.

| Probe | Decl | Path suffix |
|---|---|---|
| `pkt_is_data_pkt` | FCSM_6.v:347 wire | `.pkt_is_data_pkt` |
| `isExpPacket` | FCSM_6.v:393 wire | `.isExpPacket` |
| `crcCorruptSeen` | FCSM_6.v:397 wire | `.crcCorruptSeen` |
| `send_nack_req` | FCSM_6.v:441 reg | `.send_nack_req` |
| `socl_l7_reached_link_data` | FCSM_6.v:455 reg | `.socl_l7_reached_link_data` |
| `socl_l7_bringup_forgive` | FCSM_6.v:456 wire | `.socl_l7_bringup_forgive` |
| `isNotExpPacket_l7` | FCSM_6.v:462 wire | `.isNotExpPacket_l7` |
| `_T_54` | FCSM_6.v:491 wire | `._id("_T_54", extended=False)` |

(The leading underscore on `_T_54` needs `_id()` access — cocotb DeprecationWarning is benign.)

## 3. Run result

Single test, no assertion failures.

```
test_buga_nack_predicates.test_buga_nack_predicate_trace   PASS    10423820.00 ns    296.83 s
```

- All 8 hierarchical refs resolved
- `S.REG_PKT_WORD_LEN = 0x00000000` (slave RX FIFO empty post-AHB — the
  Bug A symptom is reproduced)
- `S.state = 4` (LINK_DATA) both pre and post — slave does NOT bounce to
  state 7, contrary to the prior hypothesis

## 4. Timing trace

Cycles relative to the start of the master AHB write (`hclk` ticks; 50 MHz):

```
signal                       first_high_cy   total_high_cy
---------------------------- -------------   -------------
pkt_is_data_pkt                         48              26
isExpPacket                             71              25
crcCorruptSeen                          -1               0
send_nack_req                           -1               0
socl_l7_reached_link_data                1             523   (already sticky pre-AHB)
socl_l7_bringup_forgive                 -1               0
isNotExpPacket_l7                       -1               0
_T_54                                    1             433
```

Pre-AHB FCSM snapshot:
- `S.state=4`, `pkt_is_data_pkt=0`, `isExpPacket=0`, `crcCorruptSeen=0`,
  `send_nack_req=0`, `socl_l7_reached_link_data=1`,
  `socl_l7_bringup_forgive=0`, `isNotExpPacket_l7=0`, `_T_54=1`.

Pre-AHB bringup snapshot (from PairTB.snapshot):
- `M: fcsm=4 cr=1 crack=1 pcc=0`
- `S: fcsm=4 cr=1 crack=1 pcc=0`

`send_nack_req` rising-edge log: empty. **It never rose during the
500 cy observation window.**

`pkt_is_data_pkt` fired 26 times. **`isExpPacket` matched 25 of them**
(the FIFO drain is one cycle behind, expected). Zero `crcCorruptSeen`,
zero `isNotExpPacket_l7`.

## 5. Verdict

**`VERDICT: NO_SEND_NACK_REQ_RAISED`** — the slave's RX framer is
**not** the failure point. Every predicate result is consistent with a
healthy RX-side framer:

- DATA packets are decoded (`pkt_is_data_pkt` fires 26x)
- Their pktnums match `exp_pkt_num` (`isExpPacket` fires 25x — drain
  lag of 1)
- No CRC errors (`crcCorruptSeen=0`)
- No expected-pktnum mismatches (`isNotExpPacket_l7=0`)
- No NACK ever latched (`send_nack_req=0` for the full 500 cy)
- L7 forgive logic is correctly steady-state-disarmed
  (`reached_link_data=1`, `forgive=0`) before the AHB write

The earlier hypothesis "slave RX framer NACK-rejects master's DATA →
`send_nack_req` latches → FCSM bounces 5→7→4 → RX never written" is
**falsified by sim**. The slave never leaves state 4 and never asserts
`send_nack_req`. The Build #9 audit's surface signal — slave Wlink FCSM
stuck at state 4 — IS reproduced here but the proposed cause is wrong.

But the symptom `REG_PKT_WORD_LEN = 0` (no RX FIFO landing) and
`PAIR_CREDIT_COUNTER = 0` on both sides at end of bringup IS
reproduced.

What the 26 `pkt_is_data_pkt` / 25 `isExpPacket` pulses likely represent
is the master's bringup-phase reset / CR/CRACK probing, NOT the user
AHB write — the master's `m.fcsm=4 pcc=0` pre-AHB means it has no
credits to TX the AHB write at all. The slave's data-pkt decodes are
the CR/CRACK echoes and any FC noise on the wire; once the master
actually attempts to TX the AHB packet, the master FCSM's own credit
check blocks it before the wire transaction ever happens.

## 6. Proposed fix direction

The bug lives **upstream of the slave RX NACK path**, in one of two
places:

**(a) Master TX credit ledger / PAIR_CREDIT_COUNTER never populates.**
Both sides report `pcc=0` after `to_data_mode` + 5000 cy. Per the FCSM
spec, the CR packet exchange should have populated each side's
`fe_tx_credit_max` from the peer's CR; if that path is broken the
master cannot dequeue the AHB packet from the TX replay FIFO and never
puts a DATA packet on the wire. This matches Bug A's surface symptom
(slave RX never sees the user AHB data) AND the slave's clean
predicate trace (no DATA pkt from master ever arrives at the slave RX
framer).

**Next step:** probe master-side `fe_tx_credit_max`, `cr_pkt_seen_rx`,
`pkt_is_cr_pkt` rising edges, and the slave-side TX path that emits
the CR — i.e. trace `auto_tx_out_advance & sop` while `state==1` on
the slave. The L6 producer-side gate
(`socl_l6_cr_emit_count >= SOCL_L6_MIN_CR_EMITS`, FCSM_6.v:449) is
suspect: if `socl_l6_cr_emit_count` never reaches the threshold, state
exit 1→2 is blocked and the master never receives any CR packet,
leaving `fe_tx_credit_max=0` forever.

**(b) AHB packet does enqueue but the master's L2A-replay-to-link
pipeline stalls.** Less likely because the master FCSM is also parked
at state 4 (LINK_DATA), but worth ruling out with a master-side
`a2l_fc_replay_link_valid` + `auto_tx_out_advance` probe.

Recommend writing a follow-up test
`test_buga_master_tx_credit_probes.py` that mirrors this one but
samples the master-side credit-ledger and CR-emit signals during
bringup. The L9 sticky / pktnum-resync gymnastics in the current FCSM
override are addressing a downstream symptom; the real upstream bug is
in the credit / CR exchange.

## 7. Notes for the next agent

- `pad_skid.sv` did not need a symlink workaround on this run.
- `TB_TOP_NO_DUMP=1` kept the run under 5 min wall and avoided VCD OOM.
- `SIM_BUILD=sim_build_nack_probes` keeps this directory isolated from
  other in-flight test sweeps.
- `_T_54` (count==0) was high 433/500 cycles, which is normal idle —
  the FCSM is not transmitting, so the per-state count register stays
  at 0.
- `socl_l7_reached_link_data` is already sticky high before the AHB
  write — confirms L7 is fully disarmed in steady state, the bringup
  forgive window is closed, and any future NACK would be a real (post-
  bringup) NACK.
