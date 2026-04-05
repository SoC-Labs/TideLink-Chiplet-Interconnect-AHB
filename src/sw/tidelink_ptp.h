/*-----------------------------------------------------------------------------
 * SoCLabs TideLink PTP Driver — Header
 *
 * CMSIS-style driver for the TideLink single-phase PTP subsystem
 * and hardware sync initiator. Register definitions from
 * src/rdl/tidelink_ptp_regs.rdl.
 *
 * NOTE: PTP registers (0x034-0x048) are defined in RDL but occupy
 * Region 1 upper slots of the unified TideLink APB space. They share
 * the same AHB config slave as the core TideLink registers.
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

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── CMSIS-style access qualifiers ──────────────────────────────────────── */

#ifndef __IO
#define __IO volatile
#endif
#ifndef __I
#define __I  volatile const
#endif
#ifndef __O
#define __O  volatile
#endif

/* ── PTP Message Types ──────────────────────────────────────────────────── */

#define TIDELINK_PTP_MSG_SYNC       0x0U
#define TIDELINK_PTP_MSG_DELAY_REQ  0x1U

/* ── PTP Register Map (extension of TIDELINK_CFG_TypeDef) ───────────────
 *
 * These registers sit at offsets 0x034-0x048 relative to the TideLink
 * config AHB slave base, immediately after the core registers (0x000-0x030).
 *
 * Access via a TIDELINK_PTP_TypeDef pointer cast to (cfg_base + 0x034),
 * or use the tidelink_ptp_t handle which computes this automatically.
 * ----------------------------------------------------------------------- */

typedef struct {
    __IO uint32_t PTP_CTRL;            /* 0x034 RW/RO mixed                 */
    __I  uint32_t PTP_RX_PAYLOAD;      /* 0x038 RO (clears rx_valid on read)*/
    __I  uint32_t PTP_STATUS;          /* 0x03C RO                          */
    __IO uint32_t HW_SYNC_CTRL;        /* 0x040 RW                          */
    __IO uint32_t HW_SYNC_INTERVAL;    /* 0x044 RW  Interval in nanoseconds */
    __I  uint32_t HW_SYNC_STATUS;      /* 0x048 RO                          */
} TIDELINK_PTP_TypeDef;

/* ── PTP_CTRL register bit positions (offset 0x034) ─────────────────────── */

#define TIDELINK_PTP_CTRL_ENABLE_Pos       0U
#define TIDELINK_PTP_CTRL_ENABLE_Msk       (1UL << 0U)

#define TIDELINK_PTP_CTRL_CLEAR_Pos        1U
#define TIDELINK_PTP_CTRL_CLEAR_Msk        (1UL << 1U)

#define TIDELINK_PTP_CTRL_RX_VALID_Pos     2U
#define TIDELINK_PTP_CTRL_RX_VALID_Msk     (1UL << 2U)

#define TIDELINK_PTP_CTRL_RX_MSG_TYPE_Pos  3U
#define TIDELINK_PTP_CTRL_RX_MSG_TYPE_Msk  (0xFUL << 3U)

/* ── PTP_STATUS register bit positions (offset 0x03C) ───────────────────── */

#define TIDELINK_PTP_STATUS_TX_IDLE_Pos    0U
#define TIDELINK_PTP_STATUS_TX_IDLE_Msk    (1UL << 0U)

#define TIDELINK_PTP_STATUS_TX_PENDING_Pos 1U
#define TIDELINK_PTP_STATUS_TX_PENDING_Msk (1UL << 1U)

/* ── HW_SYNC_CTRL register bit positions (offset 0x040) ─────────────────── */

#define TIDELINK_HW_SYNC_CTRL_ENABLE_Pos   0U
#define TIDELINK_HW_SYNC_CTRL_ENABLE_Msk   (1UL << 0U)

#define TIDELINK_HW_SYNC_CTRL_SEQ_CLR_Pos  1U
#define TIDELINK_HW_SYNC_CTRL_SEQ_CLR_Msk  (1UL << 1U)

#define TIDELINK_HW_SYNC_CTRL_FORCE_EN_Pos 2U
#define TIDELINK_HW_SYNC_CTRL_FORCE_EN_Msk (1UL << 2U)

/* ── HW_SYNC_STATUS register bit positions (offset 0x048) ───────────────── */

#define TIDELINK_HW_SYNC_STATUS_ACTIVE_Pos     0U
#define TIDELINK_HW_SYNC_STATUS_ACTIVE_Msk     (1UL << 0U)

#define TIDELINK_HW_SYNC_STATUS_BUSY_Pos       1U
#define TIDELINK_HW_SYNC_STATUS_BUSY_Msk       (1UL << 1U)

#define TIDELINK_HW_SYNC_STATUS_SEQ_NUM_Pos    2U
#define TIDELINK_HW_SYNC_STATUS_SEQ_NUM_Msk    (0xFFFFUL << 2U)

#define TIDELINK_HW_SYNC_STATUS_PHC_LOCKED_Pos 18U
#define TIDELINK_HW_SYNC_STATUS_PHC_LOCKED_Msk (1UL << 18U)

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_PTP_TypeDef *ptp;   /* PTP register block (cfg_base + 0x034)  */
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

/* ── Hardware Sync Initiator ────────────────────────────────────────────── */

/**
 * Enable the hardware sync initiator.
 *
 * @param ptp          Driver handle.
 * @param interval_ns  SYNC message interval in nanoseconds.
 */
void tidelink_ptp_hw_sync_enable(tidelink_ptp_t *ptp, uint32_t interval_ns);

/** Disable the hardware sync initiator. */
void tidelink_ptp_hw_sync_disable(tidelink_ptp_t *ptp);

/** Clear the HW sync sequence counter (self-clearing). */
static inline void tidelink_ptp_hw_sync_seq_clear(tidelink_ptp_t *ptp)
{
    ptp->ptp->HW_SYNC_CTRL |= TIDELINK_HW_SYNC_CTRL_SEQ_CLR_Msk;
}

/** Read the full HW_SYNC_STATUS register. */
static inline uint32_t tidelink_ptp_hw_sync_status(tidelink_ptp_t *ptp)
{
    return ptp->ptp->HW_SYNC_STATUS;
}

/** Get the current HW sync sequence number. */
static inline uint32_t tidelink_ptp_hw_sync_seq_num(tidelink_ptp_t *ptp)
{
    return (ptp->ptp->HW_SYNC_STATUS & TIDELINK_HW_SYNC_STATUS_SEQ_NUM_Msk)
           >> TIDELINK_HW_SYNC_STATUS_SEQ_NUM_Pos;
}

/** Return non-zero if the PHC is locked (reported by HW sync). */
static inline uint32_t tidelink_ptp_phc_locked(tidelink_ptp_t *ptp)
{
    return ptp->ptp->HW_SYNC_STATUS & TIDELINK_HW_SYNC_STATUS_PHC_LOCKED_Msk;
}

/* ── IRQ Handler Stub (weak, user-overridable) ──────────────────────────── */

void TIDELINK_PTP_IRQHandler(void);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PTP_H */
