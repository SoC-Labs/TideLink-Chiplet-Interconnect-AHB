/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Driver — Header
 *
 * CMSIS-style bare-metal driver for the TideLink chiplet interconnect
 * mailbox FIFO, credit-flow control, and doorbell subsystem.
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

/* ── Hardware parameters ────────────────────────────────────────────────── */

#define TIDELINK_RAM_ADDR_W       14U
#define TIDELINK_MAX_CREDITS      (1U << (TIDELINK_RAM_ADDR_W - 2)) /* 4096 */
#define TIDELINK_FIFO_SIZE_BYTES  (1U << TIDELINK_RAM_ADDR_W)      /* 16384 */

/* ── Unified APB address space bases ────────────────────────────────────── */

#define TIDELINK_WLINK_BASE       0x0000U
#define TIDELINK_APB_BASE         0x2000U

/* ── Configuration Register Map (TIDELINK_CFG_TypeDef) ──────────────────
 *
 * Based on tidelink_apb_regs.sv and python/tidelink/regs.py.
 * All offsets relative to the TideLink config AHB slave base address
 * (which bridges to APB base + 0x2000 internally).
 * ----------------------------------------------------------------------- */

typedef struct {
    __IO uint32_t PAIR_BASE;           /* 0x000 RW  Paired instance APB base   */
    __IO uint32_t REL_THRESHOLD;       /* 0x004 RW  Release threshold (def 20) */
    __I  uint32_t PKT_WORD_LEN;        /* 0x008 RO  Current packet word length */
    __I  uint32_t CREDIT_COUNT;        /* 0x00C RO  Available FIFO credits     */
    __I  uint32_t STATUS;              /* 0x010 RO  Status + sticky errors     */
    __O  uint32_t DOORBELL;            /* 0x014 WO  Self-clearing doorbell     */
    __I  uint32_t REL_ACC;             /* 0x018 RO  Pending unreleased credits */
    __IO uint32_t CTRL;                /* 0x01C RW  [0]=EN [1]=FLUSH           */
    __IO uint32_t RELEASED_ACC;        /* 0x020 W-add/R-clear                  */
    __IO uint32_t DOORBELL_RESP_ACC;   /* 0x024 W-add/R-clear                  */
    __I  uint32_t PAIR_CREDIT_CTR;     /* 0x028 RO  Pair credit counter        */
    __O  uint32_t PAIR_CREDIT_CONSUME; /* 0x02C WO  Consume pair credits       */
    __IO uint32_t PAIR_CREDIT_EN;      /* 0x030 RW  [0]=counter enable         */
} TIDELINK_CFG_TypeDef;

/* ── STATUS register bit positions (offset 0x010) ──────────────────────── */

#define TIDELINK_STATUS_RETURNER_BUSY_Pos    0U
#define TIDELINK_STATUS_RETURNER_BUSY_Msk    (1UL << TIDELINK_STATUS_RETURNER_BUSY_Pos)

#define TIDELINK_STATUS_OVERRUN_Pos          1U
#define TIDELINK_STATUS_OVERRUN_Msk          (1UL << TIDELINK_STATUS_OVERRUN_Pos)

#define TIDELINK_STATUS_UNDERRUN_Pos         2U
#define TIDELINK_STATUS_UNDERRUN_Msk         (1UL << TIDELINK_STATUS_UNDERRUN_Pos)

#define TIDELINK_STATUS_MASTER_ERROR_Pos     3U
#define TIDELINK_STATUS_MASTER_ERROR_Msk     (1UL << TIDELINK_STATUS_MASTER_ERROR_Pos)

#define TIDELINK_STATUS_PACKET_COMMITTED_Pos 4U
#define TIDELINK_STATUS_PACKET_COMMITTED_Msk (1UL << TIDELINK_STATUS_PACKET_COMMITTED_Pos)

/* ── CTRL register bit positions (offset 0x01C) ────────────────────────── */

#define TIDELINK_CTRL_EN_Pos                 0U
#define TIDELINK_CTRL_EN_Msk                 (1UL << TIDELINK_CTRL_EN_Pos)

#define TIDELINK_CTRL_FLUSH_Pos              1U
#define TIDELINK_CTRL_FLUSH_Msk              (1UL << TIDELINK_CTRL_FLUSH_Pos)

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_CFG_TypeDef *cfg;    /* Config register base (AHB cfg slave)  */
    __IO uint32_t        *fifo;   /* FIFO data window base (AHB FIFO slave)*/
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
    tl->cfg->PAIR_BASE = addr;
}

/** Get the paired TideLink instance's APB base address. */
static inline uint32_t tidelink_get_pair_base(tidelink_t *tl)
{
    return tl->cfg->PAIR_BASE;
}

/** Set the release threshold (0 = immediate release). */
static inline void tidelink_set_threshold(tidelink_t *tl, uint32_t thresh)
{
    tl->cfg->REL_THRESHOLD = thresh;
}

/** Get the current release threshold. */
static inline uint32_t tidelink_get_threshold(tidelink_t *tl)
{
    return tl->cfg->REL_THRESHOLD;
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
    return tl->cfg->PKT_WORD_LEN;
}

/** Read the pending unreleased credit accumulator (debug). */
static inline uint32_t tidelink_get_release_acc(tidelink_t *tl)
{
    return tl->cfg->REL_ACC;
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
    return tl->cfg->RELEASED_ACC;
}

/**
 * Read and clear the doorbell response accumulator.
 * Reading clears the register and deasserts doorbell_irq.
 */
static inline uint32_t tidelink_read_doorbell_resp(tidelink_t *tl)
{
    return tl->cfg->DOORBELL_RESP_ACC;
}

/** Read the pair credit counter (no side effects). */
static inline uint32_t tidelink_get_pair_credits(tidelink_t *tl)
{
    return tl->cfg->PAIR_CREDIT_CTR;
}

/** Consume N credits from the pair credit counter. */
static inline void tidelink_consume_credits(tidelink_t *tl, uint32_t n)
{
    tl->cfg->PAIR_CREDIT_CONSUME = n;
}

/** Enable or disable the pair credit counter. */
static inline void tidelink_set_pair_credit_en(tidelink_t *tl, uint32_t en)
{
    tl->cfg->PAIR_CREDIT_EN = en & 1U;
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
