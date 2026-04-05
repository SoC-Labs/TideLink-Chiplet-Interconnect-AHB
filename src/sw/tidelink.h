/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Driver — Header
 *
 * CMSIS-style bare-metal driver for the TideLink chiplet interconnect
 * mailbox FIFO, credit-flow control, and doorbell subsystem.
 *
 * Register structs and bit definitions are auto-generated from SystemRDL
 * via tidelink_regs.generated.h. This header adds the driver-level API.
 *
 * Target: ARM Cortex-M0 (word-aligned access only, no OS)
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#ifndef TIDELINK_H
#define TIDELINK_H

#include "tidelink_regs.generated.h"  /* TIDELINK_REGS_TypeDef + bit defs */

#ifdef __cplusplus
extern "C" {
#endif

/* ── Hardware parameters ────────────────────────────────────────────────── */

#define TIDELINK_RAM_ADDR_W       14U
#define TIDELINK_MAX_CREDITS      (1U << (TIDELINK_RAM_ADDR_W - 2)) /* 4096 */
#define TIDELINK_FIFO_SIZE_BYTES  (1U << TIDELINK_RAM_ADDR_W)      /* 16384 */

/* ── Unified APB address space bases ────────────────────────────────────── */

#define TIDELINK_WLINK_BASE       0x0000U
#define TIDELINK_APB_BASE         0x2000U

/* ── Convenience aliases for generated bit definitions ──────────────────
 *
 * The generated header uses TIDELINK_REGS_<REG>_<FIELD>_Pos/Msk naming.
 * These shorter aliases match the hand-written driver convention.
 * ----------------------------------------------------------------------- */

#define TIDELINK_STATUS_RETURNER_BUSY_Pos    TIDELINK_REGS_STATUS_RETURNER_BUSY_Pos
#define TIDELINK_STATUS_RETURNER_BUSY_Msk    TIDELINK_REGS_STATUS_RETURNER_BUSY_Msk
#define TIDELINK_STATUS_OVERRUN_Pos          TIDELINK_REGS_STATUS_OVERRUN_Pos
#define TIDELINK_STATUS_OVERRUN_Msk          TIDELINK_REGS_STATUS_OVERRUN_Msk
#define TIDELINK_STATUS_UNDERRUN_Pos         TIDELINK_REGS_STATUS_UNDERRUN_Pos
#define TIDELINK_STATUS_UNDERRUN_Msk         TIDELINK_REGS_STATUS_UNDERRUN_Msk
#define TIDELINK_STATUS_MASTER_ERROR_Pos     TIDELINK_REGS_STATUS_MASTER_ERROR_Pos
#define TIDELINK_STATUS_MASTER_ERROR_Msk     TIDELINK_REGS_STATUS_MASTER_ERROR_Msk
#define TIDELINK_STATUS_PACKET_COMMITTED_Pos TIDELINK_REGS_STATUS_PACKET_COMMITTED_Pos
#define TIDELINK_STATUS_PACKET_COMMITTED_Msk TIDELINK_REGS_STATUS_PACKET_COMMITTED_Msk

#define TIDELINK_CTRL_EN_Pos                 TIDELINK_REGS_CTRL_EN_Pos
#define TIDELINK_CTRL_EN_Msk                 TIDELINK_REGS_CTRL_EN_Msk
#define TIDELINK_CTRL_FLUSH_Pos              TIDELINK_REGS_CTRL_FLUSH_Pos
#define TIDELINK_CTRL_FLUSH_Msk              TIDELINK_REGS_CTRL_FLUSH_Msk

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_REGS_TypeDef *cfg;    /* Config register base (AHB cfg slave)  */
    __IO uint32_t         *fifo;   /* FIFO data window base (AHB FIFO slave)*/
} tidelink_t;

/* ── Initialisation ─────────────────────────────────────────────────────── */

/**
 * Initialise a TideLink driver handle.
 *
 * @param tl         Pointer to caller-allocated tidelink_t.
 * @param cfg_base   Physical base address of the config AHB slave.
 * @param fifo_base  Physical base address of the FIFO data window.
 */
void tidelink_init(tidelink_t *tl, uint32_t cfg_base, uint32_t fifo_base);

/* ── Configuration ──────────────────────────────────────────────────────── */

/** Set the paired TideLink instance's APB base address. */
static inline void tidelink_set_pair_base(tidelink_t *tl, uint32_t addr)
{
    tl->cfg->PAIR_BASE_ADDR = addr;
}

/** Get the paired TideLink instance's APB base address. */
static inline uint32_t tidelink_get_pair_base(tidelink_t *tl)
{
    return tl->cfg->PAIR_BASE_ADDR;
}

/** Set the release threshold (0 = immediate release). */
static inline void tidelink_set_threshold(tidelink_t *tl, uint32_t thresh)
{
    tl->cfg->RELEASE_THRESHOLD = thresh;
}

/** Get the current release threshold. */
static inline uint32_t tidelink_get_threshold(tidelink_t *tl)
{
    return tl->cfg->RELEASE_THRESHOLD;
}

/* ── Status ─────────────────────────────────────────────────────────────── */

/** Read the full STATUS register. */
static inline uint32_t tidelink_get_status(tidelink_t *tl)
{
    return tl->cfg->STATUS;
}

/** Return non-zero if the returner is busy. */
static inline uint32_t tidelink_is_busy(tidelink_t *tl)
{
    return tl->cfg->STATUS & TIDELINK_STATUS_RETURNER_BUSY_Msk;
}

/** Return non-zero if a packet has been committed to the FIFO. */
static inline uint32_t tidelink_packet_committed(tidelink_t *tl)
{
    return tl->cfg->STATUS & TIDELINK_STATUS_PACKET_COMMITTED_Msk;
}

/** Read the current local FIFO credit count. */
static inline uint32_t tidelink_get_credit_count(tidelink_t *tl)
{
    return tl->cfg->CREDIT_COUNT;
}

/** Read the current packet word length from the FIFO controller. */
static inline uint32_t tidelink_get_pkt_word_len(tidelink_t *tl)
{
    return tl->cfg->PACKET_WORD_LENGTH;
}

/** Read the pending unreleased credit accumulator (debug). */
static inline uint32_t tidelink_get_release_acc(tidelink_t *tl)
{
    return tl->cfg->RELEASE_ACC;
}

/* ── Control ────────────────────────────────────────────────────────────── */

/**
 * Flush the FIFO: resets pointers, clears sticky errors.
 * CTRL.EN must be 0 before flushing.
 */
void tidelink_flush(tidelink_t *tl);

/**
 * Poll until the returner is idle.
 *
 * @param tl       Driver handle.
 * @param timeout  Loop iteration limit (0 = infinite).
 * @return 0 on success, -1 on timeout.
 */
int tidelink_wait_idle(tidelink_t *tl, uint32_t timeout);

/* ── Doorbell ───────────────────────────────────────────────────────────── */

/** Trigger a doorbell to the paired TideLink. */
static inline void tidelink_doorbell(tidelink_t *tl)
{
    tl->cfg->DOORBELL = 1U;
}

/* ── Credit Management ──────────────────────────────────────────────────── */

/**
 * Read and clear the released credits accumulator.
 * Reading clears the register and deasserts released_credits_irq.
 */
static inline uint32_t tidelink_read_released(tidelink_t *tl)
{
    return tl->cfg->RELEASED_CREDITS_ACC;
}

/**
 * Read and clear the doorbell response accumulator.
 * Reading clears the register and deasserts doorbell_irq.
 */
static inline uint32_t tidelink_read_doorbell_resp(tidelink_t *tl)
{
    return tl->cfg->DOORBELL_RESPONSE_ACC;
}

/** Read the pair credit counter (no side effects). */
static inline uint32_t tidelink_get_pair_credits(tidelink_t *tl)
{
    return tl->cfg->PAIR_CREDIT_COUNTER;
}

/** Consume N credits from the pair credit counter. */
static inline void tidelink_consume_credits(tidelink_t *tl, uint32_t n)
{
    tl->cfg->PAIR_CREDIT_CONSUME = n;
}

/** Enable or disable the pair credit counter. */
static inline void tidelink_set_pair_credit_en(tidelink_t *tl, uint32_t en)
{
    tl->cfg->PAIR_CREDIT_COUNTER_EN = en & 1U;
}

/* ── FIFO Packet I/O ────────────────────────────────────────────────────── */

/**
 * Write a packet into the remote FIFO via the TX aperture.
 *
 * Writes the length word at FIFO offset 0x0000, then data words at
 * sequential word-aligned offsets.
 *
 * @param tl    Driver handle.
 * @param data  Array of 32-bit data words.
 * @param len   Number of data words.
 */
void tidelink_write_packet(tidelink_t *tl, const uint32_t *data, uint32_t len);

/**
 * Read a packet from the local RX FIFO.
 *
 * Reads FIFO offset 0x0000 to trigger length capture, then reads data words.
 *
 * @param tl       Driver handle.
 * @param buf      Buffer to receive data words.
 * @param max_len  Maximum words to read (buffer capacity).
 * @return Number of words actually read, or -1 if packet exceeds max_len.
 */
int tidelink_read_packet(tidelink_t *tl, uint32_t *buf, uint32_t max_len);

/* ── IRQ Handler Stubs (weak, user-overridable) ─────────────────────────── */

void TIDELINK_ReleasedCredits_IRQHandler(void);
void TIDELINK_Doorbell_IRQHandler(void);
void TIDELINK_PacketCommitted_IRQHandler(void);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_H */
