# eth_ptp_chain — measured transcripts

All runs: `EPOCH_PROFILE=zero`, `TIDELINK_PHY_V2=1`, VCS, cocotb.

```
cd cocotb/eth_ptp_chain
source ../../set_env.sh
source ~/SoCLabs/nanoSoC-refactor/ethernet-subsystem-ahb/set_env.sh
export TIDELINK_PHY_V2=1
make MODULE=test_ptp_chain
```

---

## Run 0 — `test_smoke_mii_loop` — PASS 1/1

Proves the MII-loopback tb edits elaborate and the TideLink bring-up is
unaffected by connecting the MAC datapath.

```
[tb_top] EPOCH_ANCHOR_EN: master=1 slave=1 (deskew: m=0 s=0)
113040ns  [after to_data_mode] M/S: cal_done=1 cal=DONE fcsm=4 cr=1 crack=1
137040ns  [smoke] link up with MII loopback wired
137040ns  [smoke] mii_tx_frames=0 (expected 0 -- no frame driven yet)
 ** TESTS=1 PASS=1 FAIL=0 SKIP=0 **
```

---

## Run 1 — `test_ptp_chain`, `BIG_ENDIAN_DMA_WORDS=True` — FAIL (TRUE NEGATIVE)

The first guess at DMA-word byte order. Recorded because it is the run that
justifies the wire recorder.

```
147240ns  [chain] MAC.MODER cold read = 0x0000a000 (golden 0x0000a000)
311080ns  [chain] HA1588 zero-init done (32 registers, all across the link)
385520ns  [chain] HA1588 RTC witness: ns 4256 -> 12256  TICKING
442280ns  [chain] TSU depth BEFORE any frame: rx=0 tx=0
585500ns  [chain] scratch_tx readback: [0]=0x011b1900  [3]=0x88f70002
604860ns  [chain] MII observer: frames=1 nibbles=128  FRAME ON THE WIRE

1004860ns [chain] MII wire bytes (first 32):
          55 55 55 55 55 55 55 d5 00 19 1b 01 1a 00 00 00 5e 4d 3c 2b 02 00 f7 88 ...
1004860ns [chain] wire frame starts at byte 8: EtherType=0x0200 NOT PTP
1009820ns [chain] HA1588 TX TSU depth = 0
1014820ns [chain] HA1588 RX TSU depth = 0
 ** TESTS=1 PASS=0 FAIL=1 **
```

Staged `0x011b1900` came out as `00 19 1b 01`: **every DMA word byte-reversed**.
The OpenCores MAC emits the LSB of each 32-bit DMA word first. HA1588's parser
correctly refused a non-`0x88F7` frame — depth 0 was a *true negative*.

Without the recorder this is indistinguishable from "HA1588 cannot timestamp".

---

## Run 2 — `BIG_ENDIAN_DMA_WORDS=False` — capture achieved, pop stalls

```
1004860ns [chain] MII wire bytes (first 32):
          55 55 55 55 55 55 55 d5 01 1b 19 00 00 00 00 1a 2b 3c 4d 5e 88 f7 00 02 ...
1004860ns [chain] wire frame starts at byte 8: DA=01 1b 19 00 00 00
          SA=00 1a 2b 3c 4d 5e EtherType=0x88f7 == PTP (0x88f7) OK
1009820ns [chain] HA1588 TX TSU depth = 1  <-- A TIMESTAMP WAS CAPTURED
1029800ns [chain]   TX.DATA3(pre-pop) @0x4000107c = 0x032a0042

1246080ns [chain]   TX.DATA0(post-pop) @0x40001070 STALLED (no HREADY within 8000 cycles)
1406120ns [chain]   TX.DATA1(post-pop) @0x40001074 STALLED (no HREADY within 8000 cycles)
```

An earlier variant of this run showed a single post-pop read consuming the full
**60000-cycle** harness timeout — a genuine bus hang. See gap doc §1.7.

---

## Run 3 — FINAL — `test_ptp_chain` — **PASS 1/1**

Pop disabled (`POP_TSU_QUEUE=False`); identity read pre-pop.

```
137040ns  [chain] link up (cal+CR/CRACK); eth subsystem behind die_b ahb_mng
142220ns  [chain] map: peer 0x30000100 -> ahb_mng 0x30000100 (delta=0x0; IDENTITY)
147240ns  [chain] MAC.MODER cold read = 0x0000a000 (golden 0x0000a000)
311080ns  [chain] HA1588 zero-init done (32 registers, all across the link)
385520ns  [chain] HA1588 RTC witness: ns 4256 -> 12256  TICKING
432320ns  [chain] TSU armed: rx_mask=0x01 tx_mask=0x01 (bit0 = PTP Sync), queues reset
442280ns  [chain] TSU depth BEFORE any frame: rx=0 tx=0
498600ns  [chain] MAC configured (MODER target 0x0000a423), TX/RX still off
498600ns  [chain] staging 60-byte L2 PTP Sync (seq_id=0x0042) into eth_scratch_tx
                  @0x38000000 as 15 words, across the link
585500ns  [chain] scratch_tx readback: [0]=0x00191b01  [3]=0x0200f788   (both match)
595740ns  [chain] TX BD armed: word0=0x003cf800 ptr=0x38000000
600860ns  [chain] MODER=0x0000a423 written -- TXEN asserted, MAC released
604860ns  [chain] MII observer: frames=1 (was 0) nibbles=128  FRAME ON THE WIRE

1004860ns [chain] MII wire bytes (first 32):
          55 55 55 55 55 55 55 d5 01 1b 19 00 00 00 00 1a 2b 3c 4d 5e 88 f7 00 02 ...
1004860ns [chain] wire frame starts at byte 8: DA=01 1b 19 00 00 00
          SA=00 1a 2b 3c 4d 5e EtherType=0x88f7 == PTP (0x88f7) OK

1009820ns [chain] HA1588 TX TSU depth = 1  <-- A TIMESTAMP WAS CAPTURED
1029800ns [chain] TX TSU entry ACROSS THE LINK:
                  d0=0x00000000 d1=0x00000000 d2=0x00000000 d3=0x032a0042
1029800ns [chain]   -> msg_id=0 seq_id=0x0042 (expected 0x0042)

1034780ns [chain] HA1588 RX TSU depth = 1  <-- A TIMESTAMP WAS CAPTURED
1054760ns [chain] RX TSU entry ACROSS THE LINK:
                  d0=0x00000000 d1=0x00000000 d2=0x00000000 d3=0x032a0042
1054760ns [chain]   -> msg_id=0 seq_id=0x0042 (expected 0x0042)

1054760ns [chain] NOTE: timestamp value words DATA0..2 = 0 0 0
                  (zero pre-pop; the pop that loads them stalls -- §1.7)

1054760ns [chain] PASS: a REAL L2 PTP Sync frame was staged from die_a across the
          TideLink pair into die_b's eth_scratch_tx, DMA'd out by the MAC's own bus
          master, transmitted by the real MII TX FSM (EtherType 0x88f7 confirmed on
          the wire), looped back into the MII RX FSM, and TIMESTAMPED IN HARDWARE by
          HA1588's TSU -- then die_a read the captured entry's PTP identity
          (messageType=Sync, sequenceId=0x0042, matching what die_a itself staged)
          back ACROSS THE LINK.
1054760ns [chain] GAP 1 CLOSED AT THE CAPTURE STEP. Remaining and precisely located:
          the 80-bit timestamp VALUE is only loaded into the readable DATA registers
          by the queue-pop, and that pop stalls the cross-link read (gap doc §1.7).
          This bench does NOT claim the timestamp value has been read.

 ** TESTS=1 PASS=1 FAIL=0 SKIP=0     1054760.00 ns **
```

### What this transcript does and does not establish

**Does:**
- A real PTP frame, staged entirely by die_a across the die-to-die link, was
  DMA'd out of far-die memory by the MAC's own bus master and put on the MII
  wire (EtherType `0x88F7` confirmed byte-by-byte by a non-bus observer).
- **BOTH** the TX and RX TSUs captured (`depth = 1` each). The RX capture is the
  stronger one: it can only happen if the frame completed the loopback and was
  re-parsed by the real MII RX FSM.
- A TSU entry requires `ptp_found && eop` (`tsu.v:348`), so the captures are
  hardware timestamps of a genuine PTP event — not bus artefacts.
- die_a read the captured entries' PTP identity (`msg_id=0` Sync,
  `seq_id=0x0042`) back across the link, matching what die_a itself staged.

**Does not:**
- Read the 80-bit timestamp **value** (blocked, §1.7).
- Prove anything about an *independent* time source — this is a loopback, so a
  systematic offset common to both directions is undetectable. M2 (physical PHY)
  remains the real 1588 proof point.
- Touch the PHC. Gap 2 is unaddressed by this transcript; see the gap doc.
