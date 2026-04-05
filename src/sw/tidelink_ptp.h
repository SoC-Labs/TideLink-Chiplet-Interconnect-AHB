/*-----------------------------------------------------------------------------
 * SoCLabs TideLink PTP Driver — Header
 *
 * CMSIS-style driver for the TideLink single-phase PTP subsystem
 * and hardware sync initiator.
 *
 * Register structs and bit definitions are auto-generated from SystemRDL
 * via tidelink_ptp_regs.generated.h. This header adds the driver-level API.
 *
 * NOTE: PTP registers (0x034-0x03C) occupy Region 1 upper slots of the
 * unified TideLink APB space. They share the same AHB config slave as
 * the core TideLink registers.
 *
 * Timestamps are NOT stored in these registers — they live in the
 * external PHC (PTP Hardware Clock) HW_CAP_* registers.
 *
 * Target: ARM Cortex-M0
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#ifndef TIDELINK_PTP_H
#define TIDELINK_PTP_H

#include "tidelink_ptp_regs.generated.h"  /* TIDELINK_PTP_REGS_TypeDef + bit defs */

#ifdef __cplusplus
extern "C" {
#endif

/* ── PTP Message Types ──────────────────────────────────────────────────── */

#define TIDELINK_PTP_MSG_SYNC       0x0U
#define TIDELINK_PTP_MSG_DELAY_REQ  0x1U

/* ── Convenience aliases for generated bit definitions ──────────────────── */

#define TIDELINK_PTP_CTRL_ENABLE_Pos       TIDELINK_PTP_REGS_PTP_CTRL_ENABLE_Pos
#define TIDELINK_PTP_CTRL_ENABLE_Msk       TIDELINK_PTP_REGS_PTP_CTRL_ENABLE_Msk
#define TIDELINK_PTP_CTRL_CLEAR_Pos        TIDELINK_PTP_REGS_PTP_CTRL_CLEAR_Pos
#define TIDELINK_PTP_CTRL_CLEAR_Msk        TIDELINK_PTP_REGS_PTP_CTRL_CLEAR_Msk
#define TIDELINK_PTP_CTRL_RX_VALID_Pos     TIDELINK_PTP_REGS_PTP_CTRL_RX_VALID_Pos
#define TIDELINK_PTP_CTRL_RX_VALID_Msk     TIDELINK_PTP_REGS_PTP_CTRL_RX_VALID_Msk
#define TIDELINK_PTP_CTRL_RX_MSG_TYPE_Pos  TIDELINK_PTP_REGS_PTP_CTRL_RX_MSG_TYPE_Pos
#define TIDELINK_PTP_CTRL_RX_MSG_TYPE_Msk  TIDELINK_PTP_REGS_PTP_CTRL_RX_MSG_TYPE_Msk

#define TIDELINK_PTP_STATUS_TX_IDLE_Pos    TIDELINK_PTP_REGS_PTP_STATUS_TX_IDLE_Pos
#define TIDELINK_PTP_STATUS_TX_IDLE_Msk    TIDELINK_PTP_REGS_PTP_STATUS_TX_IDLE_Msk
#define TIDELINK_PTP_STATUS_TX_PENDING_Pos TIDELINK_PTP_REGS_PTP_STATUS_TX_PENDING_Pos
#define TIDELINK_PTP_STATUS_TX_PENDING_Msk TIDELINK_PTP_REGS_PTP_STATUS_TX_PENDING_Msk

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_PTP_REGS_TypeDef *ptp;  /* PTP register block (cfg_base + 0x034) */
} tidelink_ptp_t;

/* ── Initialisation ─────────────────────────────────────────────────────── */

/**
 * Initialise a TideLink PTP driver handle.
 *
 * @param ptp       Pointer to caller-allocated tidelink_ptp_t.
 * @param cfg_base  Physical base address of the TideLink config AHB slave
 *                  (same base used for tidelink_init). PTP registers are
 *                  at cfg_base + 0x034.
 */
void tidelink_ptp_init(tidelink_ptp_t *ptp, uint32_t cfg_base);

/* ── PTP Control ────────────────────────────────────────────────────────── */

/** Enable the PTP subsystem (timestamp capture + IRQ on RX). */
static inline void tidelink_ptp_enable(tidelink_ptp_t *ptp)
{
    ptp->ptp->PTP_CTRL |= TIDELINK_PTP_CTRL_ENABLE_Msk;
}

/** Disable the PTP subsystem. */
static inline void tidelink_ptp_disable(tidelink_ptp_t *ptp)
{
    ptp->ptp->PTP_CTRL &= ~TIDELINK_PTP_CTRL_ENABLE_Msk;
}

/** Clear rx_valid and tx_pending (self-clearing). */
static inline void tidelink_ptp_clear(tidelink_ptp_t *ptp)
{
    ptp->ptp->PTP_CTRL |= TIDELINK_PTP_CTRL_CLEAR_Msk;
}

/** Return non-zero if a PTP message has been received. */
static inline uint32_t tidelink_ptp_rx_valid(tidelink_ptp_t *ptp)
{
    return ptp->ptp->PTP_CTRL & TIDELINK_PTP_CTRL_RX_VALID_Msk;
}

/** Get the message type of the last received PTP message. */
static inline uint32_t tidelink_ptp_get_rx_msg_type(tidelink_ptp_t *ptp)
{
    return (ptp->ptp->PTP_CTRL & TIDELINK_PTP_CTRL_RX_MSG_TYPE_Msk)
           >> TIDELINK_PTP_CTRL_RX_MSG_TYPE_Pos;
}

/** Read the PTP RX payload (clears rx_valid). */
static inline uint32_t tidelink_ptp_get_rx_payload(tidelink_ptp_t *ptp)
{
    return ptp->ptp->PTP_RX_PAYLOAD;
}

/* ── PTP Status ─────────────────────────────────────────────────────────── */

/** Return non-zero if the Wlink TX router is idle. */
static inline uint32_t tidelink_ptp_tx_idle(tidelink_ptp_t *ptp)
{
    return ptp->ptp->PTP_STATUS & TIDELINK_PTP_STATUS_TX_IDLE_Msk;
}

/** Return non-zero if a PTP TX is pending (stalled on router). */
static inline uint32_t tidelink_ptp_tx_pending(tidelink_ptp_t *ptp)
{
    return ptp->ptp->PTP_STATUS & TIDELINK_PTP_STATUS_TX_PENDING_Msk;
}

/* ── Hardware Sync Initiator ────────────────────────────────────────────
 *
 * NOTE: HW sync registers (0x040-0x048) are not yet in the PTP RDL.
 * These functions are declared here but the registers are not yet
 * in the generated header. They will use direct pointer offsets
 * until the RDL is extended.
 * ----------------------------------------------------------------------- */

/**
 * Enable the hardware sync initiator.
 *
 * @param ptp          Driver handle.
 * @param interval_ns  SYNC message interval in nanoseconds.
 */
void tidelink_ptp_hw_sync_enable(tidelink_ptp_t *ptp, uint32_t interval_ns);

/** Disable the hardware sync initiator. */
void tidelink_ptp_hw_sync_disable(tidelink_ptp_t *ptp);

/* ── IRQ Handler Stub (weak, user-overridable) ──────────────────────────── */

void TIDELINK_PTP_IRQHandler(void);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PTP_H */
