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

/* ── HW Sync register offsets (relative to cfg_base) ────────────────────
 *
 * These are not yet in the PTP RDL (which only covers 0x034-0x03C).
 * Access via pointer arithmetic until the RDL is extended.
 * ----------------------------------------------------------------------- */

#define HW_SYNC_CTRL_OFF      0x040U
#define HW_SYNC_INTERVAL_OFF  0x044U
#define HW_SYNC_CTRL_ENABLE   (1UL << 0U)

/* ── Initialisation ─────────────────────────────────────────────────────── */

void tidelink_ptp_init(tidelink_ptp_t *ptp, uint32_t cfg_base)
{
    /* PTP registers start at offset 0x034 from the config base */
    ptp->ptp = (TIDELINK_PTP_REGS_TypeDef *)(cfg_base + 0x034U);
}

/* ── Hardware Sync Initiator ────────────────────────────────────────────
 *
 * HW sync registers sit at cfg_base + 0x040/0x044/0x048, which is
 * 3 words past the end of the TIDELINK_PTP_REGS_TypeDef struct
 * (which ends at 0x03C). Access via the pointer base.
 * ----------------------------------------------------------------------- */

static inline __IO uint32_t *hw_sync_reg(tidelink_ptp_t *ptp, uint32_t off)
{
    /* ptp->ptp points at cfg_base + 0x034; add relative offset */
    return (__IO uint32_t *)((uint8_t *)ptp->ptp + (off - 0x034U));
}

void tidelink_ptp_hw_sync_enable(tidelink_ptp_t *ptp, uint32_t interval_ns)
{
    /* Set interval first, then enable */
    *hw_sync_reg(ptp, HW_SYNC_INTERVAL_OFF) = interval_ns;
    *hw_sync_reg(ptp, HW_SYNC_CTRL_OFF)     = HW_SYNC_CTRL_ENABLE;
}

void tidelink_ptp_hw_sync_disable(tidelink_ptp_t *ptp)
{
    *hw_sync_reg(ptp, HW_SYNC_CTRL_OFF) = 0U;
}

/* ── Weak IRQ Handler Stub ──────────────────────────────────────────────── */

__attribute__((weak)) void TIDELINK_PTP_IRQHandler(void)
{
    /* Default: no-op. Override in application code. */
}
