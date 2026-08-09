/* ===========================================================================
 * cov_die_b_mbox_isr_stub.c — MINIMAL die_b (CPU1 / chip_core) firmware STUB for
 *   the first cross-die ISR-DELIVERY proof (coverage backlog #8). PSEUDOCODE-level
 *   Cortex-M0+ app: enable the IPC mailbox slot-0 interrupt, enable it in the NVIC,
 *   and in the ISR clear the source (W1C) and bump a flag word the dev host reads
 *   back over the eth_ss_0 backdoor. It proves an interrupt was actually DELIVERED
 *   to a far-die core's ISR — not merely that a source bit latched (that is the
 *   firmware-free proof in cov_mbox_doorbell_irq.py).
 *
 * PAIR WITH: cov_cross_die_isr_harness.sh (loads this, fires die_a's doorbell,
 *            reads the flag back) and cov_cross_die_isr_plan.md (prerequisites).
 *
 * STAGED — this cannot run on the CURRENT bitstream. Both M0 cores are boot-gated
 * in the PS flow, and there is no SWD firmware-load path in the shipped image. See
 * cov_cross_die_isr_plan.md "Prerequisites (NOT yet in the bitstream)". This file
 * is the design the harness targets once those land; treat the CMSIS specifics
 * (vector table symbol, ISER intrinsic) as placeholders for the nanosoc M0 BSP.
 *
 * MEMORY MAP (die_b, CPU1 view == PS-local view over the backdoor):
 *   ipc_mailbox_0 base .......... 0x23000000
 *     +0x000..0x00C  slot0 data (RO to us; die_a wrote it)
 *     +0x028  IRQ_STATUS   [0]=slot0_msg  R/W1C
 *     +0x02C  IRQ_ENABLE   [0]=slot0_msg enable (gates cpu1_irq -> NVIC)
 *   shared_sram_0 base .......... 0x2D000000   (PS-readable at 0x4_2D00_xxxx)
 *
 * NVIC: the mailbox slot0 message line is CPU1 external interrupt IRQ0
 *       (per docs/CROSS_DIE_INTERRUPTS.md: "ipc_mailbox_0 ... -> CPU1 IRQ0").
 *
 * Copyright (C) 2026, SoC Labs (www.soclabs.org)
 * =========================================================================== */
#include <stdint.h>

#define MBOX_BASE          0x23000000u
#define MBOX_SLOT0_DATA0   (*(volatile uint32_t *)(MBOX_BASE + 0x000u))
#define MBOX_IRQ_STATUS    (*(volatile uint32_t *)(MBOX_BASE + 0x028u))
#define MBOX_IRQ_ENABLE    (*(volatile uint32_t *)(MBOX_BASE + 0x02Cu))
#define IRQ_SLOT0_MSG      (1u << 0)

/* The ISR "ran" flag + a copy of the payload it saw. Placed in shared_sram_0 so
 * the dev host can read it back with a LOCAL (wedge-safe) read at 0x4_2D00_1F00 —
 * no peer read-round-trip needed to confirm delivery.
 *   0x2D001F00 : run-count  (incremented once per ISR entry; 0 => ISR never ran)
 *   0x2D001F04 : last payload word 0 the ISR observed (sanity: matches die_a's)
 *   0x2D001F08 : signature 0xD00DFEED written by main() at startup (liveness) */
#define ISR_FLAG_BASE      0x2D001F00u
#define ISR_RUN_COUNT      (*(volatile uint32_t *)(ISR_FLAG_BASE + 0x00u))
#define ISR_LAST_PAYLOAD   (*(volatile uint32_t *)(ISR_FLAG_BASE + 0x04u))
#define ISR_ALIVE_SIG      (*(volatile uint32_t *)(ISR_FLAG_BASE + 0x08u))
#define ALIVE_SIGNATURE    0xD00DFEEDu

/* --- NVIC (Cortex-M0+ core peripherals) — placeholder if no CMSIS header ---- */
#define NVIC_ISER          (*(volatile uint32_t *)0xE000E100u)
#define MBOX_SLOT0_IRQn    0u          /* CPU1 external IRQ0 = mailbox slot0 msg */

/* ---------------------------------------------------------------------------
 * ISR: the mailbox slot-0 message interrupt handler. Name it whatever the
 * nanosoc M0 vector table binds IRQ0 to (e.g. IRQ0_Handler / Interrupt0_Handler).
 * Keep it tiny: clear the source (W1C) so it does not re-enter, record that it ran.
 * ------------------------------------------------------------------------- */
void IRQ0_Handler(void)          /* <- rename to the BSP's IRQ0 vector symbol */
{
    uint32_t st = MBOX_IRQ_STATUS;
    if (st & IRQ_SLOT0_MSG) {
        ISR_LAST_PAYLOAD = MBOX_SLOT0_DATA0;   /* capture what die_a sent */
        ISR_RUN_COUNT    = ISR_RUN_COUNT + 1u; /* 0 -> 1 on the very first delivery */
        MBOX_IRQ_STATUS  = IRQ_SLOT0_MSG;      /* W1C: ack the source (edge-set reg) */
    }
    /* returning re-enables interrupts; a fresh far-die doorbell edge re-fires us. */
}

int main(void)
{
    /* startup liveness marker (host can confirm the core actually booted this app) */
    ISR_RUN_COUNT   = 0u;
    ISR_LAST_PAYLOAD = 0u;
    ISR_ALIVE_SIG   = ALIVE_SIGNATURE;

    /* clear any stale latched source, then unmask slot0 at the mailbox AND the NVIC.
     * (irq_enable[0] gates cpu1_irq; the source bit latches regardless, but delivery
     *  to THIS ISR requires both the mailbox enable and the NVIC ISER bit.) */
    MBOX_IRQ_STATUS = IRQ_SLOT0_MSG;           /* W1C any stale edge */
    MBOX_IRQ_ENABLE = IRQ_SLOT0_MSG;           /* enable slot0 msg -> cpu1_irq */
    NVIC_ISER       = (1u << MBOX_SLOT0_IRQn);  /* enable IRQ0 in the NVIC */

    for (;;) {
        __asm volatile ("wfi");                /* sleep; the ISR does the work */
    }
    return 0;
}
