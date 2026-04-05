/*-----------------------------------------------------------------------------
 * SoCLabs TideLink PTP Driver — Implementation
 *
 * Bare-metal driver for the TideLink single-phase PTP subsystem
 * and hardware sync initiator. Targets ARM Cortex-M0.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include "tidelink_ptp.h"

/* ── Initialisation ─────────────────────────────────────────────────────── */

void tidelink_ptp_init(tidelink_ptp_t *ptp, uint32_t cfg_base)
{
    /* PTP registers start at offset 0x034 from the config base */
    ptp->ptp = (TIDELINK_PTP_TypeDef *)(cfg_base + 0x034U);
}

/* ── Hardware Sync Initiator ────────────────────────────────────────────── */

void tidelink_ptp_hw_sync_enable(tidelink_ptp_t *ptp, uint32_t interval_ns)
{
    /* Set interval first, then enable */
    ptp->ptp->HW_SYNC_INTERVAL = interval_ns;
    ptp->ptp->HW_SYNC_CTRL = TIDELINK_HW_SYNC_CTRL_ENABLE_Msk;
}

void tidelink_ptp_hw_sync_disable(tidelink_ptp_t *ptp)
{
    ptp->ptp->HW_SYNC_CTRL = 0U;
}

/* ── Weak IRQ Handler Stub ──────────────────────────────────────────────── */

__attribute__((weak)) void TIDELINK_PTP_IRQHandler(void)
{
    /* Default: no-op. Override in application code. */
}
