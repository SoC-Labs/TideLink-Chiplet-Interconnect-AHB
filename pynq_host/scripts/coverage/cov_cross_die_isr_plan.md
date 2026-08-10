# Cross-die ISR-delivery test plan (coverage backlog #8)

**Goal:** the first proof on silicon that a cross-die interrupt is actually
*delivered to a far-die core's ISR* — not merely that a source bit latched. die_a
fires the IPC mailbox doorbell; die_b's CPU1 takes the interrupt, runs an ISR, and
the ISR leaves a flag the dev host reads back over the `eth_ss_0` backdoor.

This closes the last rung of the interrupt ladder. Per the V-plan: *"No interrupt
has EVER been observed asserting on hardware — not a line, not an ISR, not even a
confirmed source-latch high."* The three coverage tests attack that in order:

| Rung | Proves | Firmware? | Deliverable |
|---|---|---|---|
| **Source latch** | an interrupt SOURCE latches on silicon | no | `cov_mbox_doorbell_irq.py` + `cov_mbox_irq_source.py` |
| **PS line** | a fabric line reaches the PS GIC | no | `cov_ps_irq_observe.py` |
| **ISR delivery** (this doc) | a far-die core's ISR actually RUNS | **yes** | `cov_die_b_mbox_isr_stub.c` + `cov_cross_die_isr_harness.sh` |

**Status: STAGED.** Both M0 cores are boot-gated in the PS flow, and the shipped
bitstream has no firmware-load path — so this cannot run today. This doc + the stub
+ the harness are the design that executes once the prerequisites below land. The
harness (`cov_cross_die_isr_harness.sh`) deliberately exits **BLOCKED** rather than
faking a pass.

---

## Mechanism (verified against `ipc_mailbox_apb_regs.sv`)

```
die_a PS  --peer write 0x2F.. (CAM 0x2F->0x23)-->  die_b ipc_mailbox_0 @ 0x2300_0000
   payload words 0x00..0x0C, then SLOT0_CTRL[0]=MSG_VALID (0x20)
        |
        v  rising edge of slot0 MSG_VALID
   IRQ_STATUS[0] @ 0x2300_0028  latches (regardless of irq_enable)
        |  AND irq_enable[0] @ 0x2300_002C == 1
        v
   cpu1_irq  ->  CPU1 (chip_core) NVIC IRQ0  ->  IRQ0_Handler() runs
        |
        v  ISR: W1C IRQ_STATUS[0]; RUN_COUNT++ in shared_sram_0 @ 0x2D00_1F00
   dev host reads 0x4_2D00_1F00 (die_b LOCAL read) -> RUN_COUNT >= 1  == DELIVERED
```

Key register facts (RTL, not guesses):
- `IRQ_STATUS` (0x028) is **edge-set** on the MSG_VALID rising edge and **R/W1C**.
  The source latches *regardless of* `irq_enable`; only the NVIC output `cpu1_irq`
  is gated by `irq_enable[0]`. So delivery needs **both** `irq_enable[0]=1` **and**
  the NVIC `ISER` bit set — that is exactly what the stub's `main()` does.
- A repeatable edge needs MSG_VALID de-asserted first (`--mode arm` on die_b), else
  no rising edge and no new latch.
- The mailbox slot0 line is **CPU1 external IRQ0** (`docs/CROSS_DIE_INTERRUPTS.md`).

---

## (a) Firmware stub — `cov_die_b_mbox_isr_stub.c`

Minimal Cortex-M0+ app for die_b CPU1. Full source in the `.c` file; shape:

- `main()`: W1C any stale source, set `irq_enable[0]` (mailbox), set `NVIC_ISER`
  bit 0 (IRQ0), write an alive-signature `0xD00DFEED` to `0x2D00_1F08`, then `WFI`.
- `IRQ0_Handler()`: if `IRQ_STATUS[0]` set — copy `SLOT0_DATA0` to `0x2D00_1F04`,
  `RUN_COUNT++` at `0x2D00_1F00`, then `W1C IRQ_STATUS[0]` to ack (edge reg, so no
  tail-chain). Return.

Why the flag lives in **shared_sram_0** (`0x2D00_1F00`): the dev host reads it back
with a **die_b LOCAL** `/dev/mem` read at `0x4_2D00_1F00` — no peer read-round-trip,
so the delivery verdict itself is wedge-safe. `RUN_COUNT == 0` ⇒ the ISR never ran;
`ALIVE_SIG != 0xD00DFEED` ⇒ the core never booted the app (isolate load vs delivery).

CMSIS placeholders to resolve against the nanosoc M0 BSP: the IRQ0 vector symbol
name and the `NVIC_ISER`/`__NVIC_EnableIRQ` intrinsic (hard-coded `0xE000E100` in
the stub as a fallback).

## (b) Host harness — `cov_cross_die_isr_harness.sh`

Timeout-wraps every board access (a timeout == PS-bus WEDGE → STAGED JTAG-POR).
Flow: FCSM=4 gate → **PREREQ gate (exits BLOCKED unless `COV_ISR_FORCE=1`)** →
build+load firmware (stubbed) → release boot-gate (stubbed) → die_b `arm` → die_a
`send` (peer writes only) → die_b LOCAL read of the flag → verdict `RUN_COUNT>=1`.

`COV_ISR_FORCE=1` runs the arm/fire/readback wiring as a dry run (ISR won't execute,
so `RUN_COUNT` stays 0 — expected) to validate the plumbing before firmware exists.

---

## Prerequisites (NOT yet in the bitstream) — why this is staged

1. **SWD / firmware-load path to die_b CPU1.** The shipped image has no on-board
   probe or loader. Options: (i) OpenOCD over the DAP (`docs/CROSS_DIE_DEBUG_PLAN.md`
   describes the one-probe-both-dies path, itself staged behind the `0b`+`0c` RTL);
   (ii) backdoor-write die_b IMEM over the `eth_ss_0` window from die_b's own PS
   *before* releasing the core. (ii) is the lower-lift path and avoids the cross-die
   debug RTL entirely — recommended for the first bring-up.
2. **Boot-gate release for die_b CPU1.** Both M0 cores are boot-gated in the PS
   flow. Delivery needs the core running with its vector table + `ISER` set. Needs
   the reset_ctrl release sequence exposed to the PS (or done by the loader in (1)).
3. **Confirm mailbox slot0 → CPU1 NVIC IRQ0 on silicon.** The map is `CROSS_DIE_
   INTERRUPTS.md`-documented and RTL-consistent, but has never been exercised
   (no ISR has ever run). The stub's `RUN_COUNT` is the confirmation.

None require a link change; (1)(ii)+(2) are the minimum. Prototype in
`nanosoc-multicore-system/cocotb/soc_d2d_loopback` first (it already masters
`d2d_ahb_s` through the real matrix into the mailbox) to de-risk the NVIC hookup
before spending a silicon session.

---

## Success criteria & ladder

1. **Liveness:** after load+release, `ALIVE_SIG @ 0x4_2D00_1F08 == 0xD00DFEED`
   (core booted the app). `RUN_COUNT == 0` at this point (no doorbell yet).
2. **Delivery:** die_b `arm` → die_a `send` → `RUN_COUNT @ 0x4_2D00_1F00 == 1` and
   `LAST_PAYLOAD == 0xC0FFEE01`. **This is the first cross-die ISR delivery proof.**
3. **Repeat / re-arm:** arm + send again → `RUN_COUNT == 2` (edge re-fires cleanly;
   confirms the W1C ack in the ISR works — no stuck level).
4. **Isolation (optional):** with `irq_enable[0]=0` (or NVIC masked), the source
   still latches (`cov_mbox_doorbell_irq.py recv` PASS) but `RUN_COUNT` stays 0 —
   proves the enable/NVIC gating, separating "source" from "delivery".

## Wedge-safety recap (mandatory)

- The only peer traversal is die_a's `send` (peer WRITES; return via HREADY).
- The delivery verdict is a die_b **LOCAL** read of shared_sram_0 — never a peer
  read (the intermittent read-return wedge, `docs/CROSS_DIE_WEDGE_ROOTCAUSE.md`,
  cannot bite the verifier).
- Refuses unless both dies FCSM=4. JTAG-POR STAGED (from mapstone-dev), never auto.
- Never touches the bare-link `0x8403`/`0xA400`/`0x8000` map.
- **ATTENDED**, one pair, ready to JTAG-POR.
