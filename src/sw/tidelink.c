/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Driver — Implementation
 *
 * Bare-metal driver for TideLink mailbox FIFO, credit-flow control,
 * and doorbell subsystem. Targets ARM Cortex-M0.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include "tidelink.h"

/* ── Initialisation ─────────────────────────────────────────────────────── */

void tidelink_init(tidelink_t *tl, uint32_t cfg_base, uint32_t fifo_base)
{
    tl->cfg  = (TIDELINK_REGS_TypeDef *)cfg_base;
    tl->fifo = (__IO uint32_t *)fifo_base;
}

/* ── Control ────────────────────────────────────────────────────────────── */

void tidelink_flush(tidelink_t *tl)
{
    /* EN must be 0 before flushing */
    tl->cfg->CTRL = 0U;
    tl->cfg->CTRL = TIDELINK_CTRL_FLUSH_Msk;
}

int tidelink_wait_idle(tidelink_t *tl, uint32_t timeout)
{
    uint32_t count = timeout;

    while (tl->cfg->STATUS & TIDELINK_STATUS_RETURNER_BUSY_Msk) {
        if (timeout != 0U) {
            if (count == 0U)
                return -1;
            count--;
        }
    }
    return 0;
}

/* ── FIFO Packet I/O ────────────────────────────────────────────────────── */

void tidelink_write_packet(tidelink_t *tl, const uint32_t *data, uint32_t len)
{
    uint32_t i;

    /* Word 0: packet length (number of data words that follow) */
    tl->fifo[0] = len;

    /* Words 1..N: data payload */
    for (i = 0U; i < len; i++) {
        tl->fifo[i + 1U] = data[i];
    }
}

int tidelink_read_packet(tidelink_t *tl, uint32_t *buf, uint32_t max_len)
{
    uint32_t pkt_len;
    uint32_t i;

    /* Reading FIFO address 0 triggers the length capture in hardware */
    (void)tl->fifo[0];

    /* Read the captured packet word length from the config register */
    pkt_len = tl->cfg->PACKET_WORD_LENGTH;

    if (pkt_len > max_len) {
        return -1;
    }

    for (i = 0U; i < pkt_len; i++) {
        buf[i] = tl->fifo[i + 1U];
    }

    return (int)pkt_len;
}

/* ── Weak IRQ Handler Stubs ─────────────────────────────────────────────── */

__attribute__((weak)) void TIDELINK_ReleasedCredits_IRQHandler(void)
{
    /* Default: no-op. Override in application code. */
}

__attribute__((weak)) void TIDELINK_Doorbell_IRQHandler(void)
{
    /* Default: no-op. Override in application code. */
}

__attribute__((weak)) void TIDELINK_PacketCommitted_IRQHandler(void)
{
    /* Default: no-op. Override in application code. */
}
