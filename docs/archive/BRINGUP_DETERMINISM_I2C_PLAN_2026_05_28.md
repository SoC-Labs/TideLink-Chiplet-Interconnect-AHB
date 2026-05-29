# Bring-up determinism via I2C handshake — plan

Date: 2026-05-28
Author: session @ feat/calibrator-eyecenter
Status: design proposal — RTL not started

## Problem

The TideLink HW pair (z2_02 ⇄ z2_03 over GPIO ribbon) is non-deterministic at
bring-up. The hardware itself is sound (the older `feat/l4-option-c` bitstream
reached bilateral LINK_IDLE this session, and the user reproduced bilateral
LINK_IDLE on the same boards yesterday), but a fresh deploy succeeds ~10–30%
of the time. The remaining attempts hang in one of:

- `cal=0, FCSM=1, lane_locked=0x00, lane_fault=0x00` — calibrator stuck mid-sweep
- `cal=1, FCSM=1, cr=0, crack=0` — alignment chosen but CR_PKT can't decode
- Asymmetric: one side locks all 8 lanes, the other locks 0 — direction varies

The root cause is **POR-skew lottery** documented in SHORTCOMINGS-14b
(`pynq_host/scripts/deploy_pair.sh:110`). Master's POR releases first;
slave's POR releases ~3 pad_clks later (or sometimes more, or sometimes less).
By the time slave's RX deserialiser counter starts incrementing from zero,
master's TX has been emitting training bytes for an unknown number of cycles.
The relative phase of master_tx_framing vs slave_rx_counter is therefore a
random number in `{0..15}` × `{0..7}` slip space. The calibrator's per-lane
sweep covers this space (128 (slip, phase) points), but on slow / marginal
hardware the eye margin shrinks fast enough that the search either finds no
valid alignment (worst case) or finds a borderline alignment that decodes
training but not real data.

Today's SW workaround:

```
case "$ROLE" in
    die_a) STRAP=0 ; CTRL=0x2 ; PHASE=0x00000000 ;;   # master, phase=0
    die_b) STRAP=1 ; CTRL=0x3 ; PHASE=0x00060000 ;;   # slave,  phase=3
esac
```

A hardcoded `phase=3` on slave compensates the *expected* mean skew but not
the *boot-to-boot* variance. When the POR delta is 3, this works. When it's
2, 4, or any other value, the calibrator has to take up the slack and
sometimes fails.

## Proposal — I2C-coordinated bring-up

Add a two-stage handshake over the existing I2C bus between the boards
(currently used only for `link_lane_mask` exchange) so that **both sides
release the link layer from reset at a cycle-accurate, coordinated moment**.
This removes the POR-skew variable from the equation and lets the calibrator
operate against a deterministic starting condition.

### Architecture

```
   ┌─────────── Master (die_a) ────────────┐         ┌─────────── Slave (die_b) ──────────┐
   │                                       │         │                                    │
   │  POR ──┐                              │         │  POR ──┐                           │
   │        ▼                              │         │        ▼                           │
   │  ┌─────────────────────┐              │         │  ┌─────────────────────┐           │
   │  │ bringup_handshake_  │  ┌─I2C BUS───┼─────────┼─►│  bringup_handshake_ │           │
   │  │  fsm                │◄─┤ (existing)│         │  │  fsm                │           │
   │  │                     │  │ s_i2c_axi │         │  │                     │           │
   │  │   - WAIT_PEER_RDY   │  │   slave   │         │  │   - WAIT_PEER_RDY   │           │
   │  │   - SEND_GO_BCAST   │  │   port    │         │  │   - WAIT_GO_FROM_M  │           │
   │  │   - HOLD_LINK_RESET │  │           │         │  │   - HOLD_LINK_RESET │           │
   │  │   - RELEASE_GATE    │  │           │         │  │   - RELEASE_GATE    │           │
   │  └────────┬────────────┘  │           │         │  └────────┬────────────┘           │
   │           ▼                              │      │           ▼                        │
   │   bringup_gate_o (= ~link_layer_rst)   │      │   bringup_gate_o (= ~link_layer_rst) │
   │           │                              │      │           │                        │
   │   ┌───────▼─────────┐                  │      │   ┌───────▼─────────┐                │
   │   │ Wlink + WavD2D  │  pad_tx[0..7] ───┼──────┼─► │ Wlink + WavD2D  │                │
   │   │ phy + lane chkr │  pad_clk_tx  ────┼──────┼─► │ phy + lane chkr │                │
   │   │ + calibrator    │  pad_rx[0..7] ◄──┼──────┼── │ + calibrator    │                │
   │   │                 │  pad_clk_rx  ◄───┼──────┼── │                 │                │
   │   └─────────────────┘                  │      │   └─────────────────┘                │
   └───────────────────────────────────────┘         └────────────────────────────────────┘
```

### Handshake protocol

Master (die_a) drives the protocol. Slave (die_b) follows. I2C is open-drain
multi-master, so either side can initiate, but the role-strap makes the
direction unambiguous.

**Phase 0 — POST-POR**. Both sides assert `bringup_gate_o = 0` immediately
after POR releases. This holds:
- `wlink_por_reset = 1` (Wlink link layer in reset)
- `training_mode = 0` (no pattern emitted yet — pad_tx idles to 0)
- `pad_clk_tx` does still run (it's the clk_wiz output, not gated) so the
  peer sees a clock arriving, just no data.

Both sides' calibrator FSMs stay in `S_IDLE` because `role_locked = 0`.

**Phase 1 — DRIVE READY**. Each side writes its own I2C register
`PEER_READY` (slave_addr=0x10, reg=0x40, 1 byte = 0x01) once its
post-POR housekeeping is complete (MMCM lock + clk_wiz stable +
initial-credit-reg populated). This is the "I'm physically capable of
running the link" signal.

**Phase 2 — POLL PEER READY**. Master polls peer's `PEER_READY` register
via I2C reads. When master sees the slave's `PEER_READY = 1`, master
proceeds. Slave doesn't need to poll — it just waits in `WAIT_GO_FROM_M`.

**Phase 3 — SYNC-LOAD MASTER + SLAVE GATE-RELEASE COUNTER**. Master writes
the slave's `BRINGUP_GO_COUNTDOWN` register via I2C (slave_addr=0x10,
reg=0x44, 1 byte = 0xFF — "release in 255 link-clk cycles"). This single
I2C write is acknowledged on the slave by a one-shot loading of the
slave's local countdown to 255.

On the same I2C write completion (master's side: I2C controller's
`xact_done` interrupt), master loads its own countdown to 255.

The countdown takes 255 link-clk cycles = 5.1 us @ 50 MHz to expire.

**Phase 4 — SIMULTANEOUS GATE RELEASE**. Both countdowns expire at
their respective cycle. The countdown latches are clocked by `hclk`,
which is the SAME PHYSICAL CLOCK on both sides (FCLK_CLK0 fans out
on both PYNQ boards from independent PLLs but at nominally the same
frequency). The relative skew between the two sides' countdown
expiry is bounded by:

- Master's "load countdown" event: tied to I2C `xact_done` rising edge,
  registered in `hclk` domain.
- Slave's "load countdown" event: tied to the same I2C write completing
  on the slave (slave's I2C slave port sees the STOP bit), registered
  in `hclk` domain.

The time between master's STOP-detect and slave's STOP-detect is bounded
by the I2C bus's stop-detect-to-register-write latency. For a standard
I2C slave block (e.g., Xilinx AXI IIC), this is 1-2 SCL cycles = 10-20 us
at 100 kHz. After loading, both countdowns run on independent `hclk`s,
so they expire within ±1 cycle of each other after 5.1 us.

Net: gate release on the two sides is within ±20 us of each other, but
the **deterministic countdown N is the same number on both sides**. Each
side's RX deserialiser counter starts at the SAME OFFSET relative to
its own gate release. That eliminates the POR-skew lottery.

### RTL changes

Files to edit (estimated):

```
src/rtl/local_overrides/axi_chiplet_controller.sv  (~150 LOC added)
  - New register block at I2C bus addresses 0x40 (PEER_READY) and 0x44
    (BRINGUP_GO_COUNTDOWN). Both readable from peer's I2C side.
  - bringup_handshake_fsm: 6-state FSM
      S_INIT       → wait for post-POR housekeeping
      S_DRIVE_RDY  → set local PEER_READY = 1
      S_POLL_PEER  → (master only) read peer's PEER_READY via I2C master
      S_LOAD_CD    → load countdown = 255 (both sides)
      S_COUNTDOWN  → countdown decrements every hclk
      S_DONE       → bringup_gate_o = 1 (release Wlink reset)
  - I2C master sequencer: existing axi_chiplet_controller already drives I2C
    for mask negotiation; extend with peer-poll-read state.
  - bringup_gate_o output port

src/rtl/tidelink_top.sv  (~20 LOC)
  - Wire bringup_gate_o → wlink_por_reset_i (replaces current
    `~role_locked | manual_reset` path during bring-up)
  - Keep role_locked write path intact for existing functionality;
    bringup_gate is an ADDITIONAL gate, not a replacement.

src/rtl/tidelink_top.sv (parameter)
  - parameter BRINGUP_HS_ENABLE = 1'b0 (default OFF — preserves cocotb
    tests that don't model I2C). FPGA wrapper override sets it to 1.

fpga/vivado_ip/tidelink_vivado_wrapper.v
  - Pass BRINGUP_HS_ENABLE = 1'b1

pynq_host/scripts/deploy_pair.sh  (~10 LOC)
  - Stop writing `swi_phase_offset = 3` on slave (SHORTCOMINGS-14b workaround
    becomes unnecessary). Keep the swreset toggle sequence but remove the
    hardcoded phase.

cocotb/tidelink_bringup_i2c_hs/             (NEW)
  - tb_top.sv instantiating two axi_chiplet_controller's connected via
    a behavioural I2C bus model
  - test_bringup_handshake.py:
      * test_01: master sees slave PEER_READY rise, sends GO countdown, both
        gates release within ±10 hclk of each other
      * test_02: slave POR delayed by 1000 hclk — handshake still completes
      * test_03: slave POR delayed by 100k hclk — handshake still completes
        (regression for stuck-in-reset case)
```

### Validation in sim

1. New cocotb test: paired-die env with I2C bus model. Confirm:
   - Both sides reach bringup_gate=1
   - Time-to-bring-up is constant regardless of POR delay between sides
   - Calibrator triggers on coordinated gate release, not on independent POR
2. Existing cocotb regression: `tidelink_top_pair*`, `tidelink_chiplet_pair_autocal`
   — all need to still pass with BRINGUP_HS_ENABLE=0 (default-off) preserves
   bit-exact behaviour.

### Build + deploy

- Q3-style FARM build (`make build_pair_farmed FARM_HOST=srv04936`): ~50 min
- Two parallel targets: pynq-z2-pair-all + pynq-z2-pair-flip-all
- Validation: deploy + check `lane_locked = 0xFF` and `FCSM = 4` on BOTH
  sides within 1 s of deploy. Repeat 10 times to characterise success rate.
  Target: ≥9/10 PASS (vs today's ~3/10).

### Risks

1. **I2C bus contention**: today the I2C bus is also used for mask
   negotiation. The new handshake adds a new register block. If the FSMs
   don't arbitrate, one might starve the other. Mitigation: serialise — do
   handshake BEFORE mask negotiation (mask negotiation only happens after
   training_mode drops, which now happens after bringup_gate=1).

2. **No I2C activity from peer**: if the peer's I2C slave port is hung (e.g.
   peer hasn't loaded bitstream yet), master's `S_POLL_PEER` polls forever.
   Mitigation: 1-second timeout in `S_POLL_PEER`. On timeout, fall through
   to S_DONE with a SW-visible `bringup_handshake_timeout` sticky flag, and
   let SW handle (current SW behaviour: deploy + hope).

3. **Cycle accuracy isn't truly cycle-accurate**: master and slave run
   independent PLLs; FCLK_CLK0 on each board can drift up to ±50 ppm. Over
   a 5 us countdown that's 0.25 ns of skew — well below 1 pad_clk
   (20 ns at 50 MHz). Acceptable.

4. **Calibrator still has to find (slip, phase)**: handshake doesn't change
   the bit-alignment problem. It only makes the search space deterministic.
   Today's calibrator (eye-CENTRE or l4-option-c-style margin scoring) is
   still the back-end. If the calibrator itself has bugs, handshake won't
   mask them. The l4-option-c bitstream proves the HW + calibrator CAN reach
   LINK_IDLE, so we're confident this works.

5. **I2C wiring on the board**: check that I2C SCL/SDA actually connect
   between z2_02 and z2_03 on the current ribbon. If the ribbon only has
   the 8 pad_tx + 8 pad_rx data lanes + clock pairs but no SDA/SCL pins,
   I2C handshake is impossible over the current cable. Need to verify
   in `fpga/targets/pynq-z2-pair-all/pynq_z2_tidelink.xdc` (pin map) AND
   physically (jumper continuity).

### Order of work (priority)

1. **Verify I2C wiring** (30 min): inspect xdc + multimeter the ribbon for
   SDA/SCL continuity. If not present, the plan is dead in the water until
   the ribbon is rewired. **DO THIS FIRST.**
2. **Cocotb test infrastructure** (1 day): paired-die I2C bus model + new
   `tidelink_bringup_i2c_hs` test directory. Mock the existing handshake
   behaviour first to confirm the test environment is sound.
3. **Implement `bringup_handshake_fsm`** (2 days): the new register block +
   FSM in `axi_chiplet_controller.sv`. All sim, no HW yet.
4. **Wire `bringup_gate_o`** into tidelink_top + tidelink_vivado_wrapper
   (half day).
5. **Cocotb regression pass** (half day): all existing tests with
   BRINGUP_HS_ENABLE=0 must pass bit-exact. The new test should pass with
   BRINGUP_HS_ENABLE=1.
6. **FPGA build + deploy** (~1 hour incl. validation).
7. **Characterise HW success rate** (~1 hour): 10 reset-and-deploy cycles.
   Expect ≥90% success.

Total estimate: ~4 working days for the RTL + sim, +1 day for HW bring-up
and rate characterisation.

### Alternative if I2C wiring is unavailable

If SDA/SCL are not wired between boards, the SAME PROTOCOL can run over
ONE LANE of the pad_tx/pad_rx data wires reserved as a sync channel. The
trade-off: 1 lane of bandwidth lost; on the upside, no extra physical
infrastructure needed. The lane would carry a low-rate (1 kHz) UART-like
signal driven by the bringup_handshake_fsm directly, bypassing Wlink.
This is structurally similar to the I2C plan but uses a different physical
medium. Total effort: roughly the same.

## Open questions for the user

1. Are SDA/SCL physically jumpered between z2_02 and z2_03? (Verifiable in
   xdc + multimeter; I haven't checked.)
2. Is the I2C controller in `axi_chiplet_controller.sv` capable of acting
   as master AND slave simultaneously? (For mask negotiation today, master
   broadcasts; slave receives. For new handshake, slave also needs to write
   PEER_READY which master reads — so slave is master-mode briefly.)
3. Are you OK with the ~4-day implementation timeline, or do you want a
   smaller-scope first cut (e.g., master-only polling, hardcoded GO
   countdown without protocol)? A skeleton version would take ~1 day and
   give a binary "does the determinism story even work?" answer.
