/*-----------------------------------------------------------------------------
 * Auto-generated from SystemRDL — do not edit
 *
 * Source addrmap: tidelink_regs
 * Generator:     scripts/rdl2c.py
 *-----------------------------------------------------------------------------*/

#ifndef TIDELINK_REGS_GENERATED_H
#define TIDELINK_REGS_GENERATED_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CMSIS-style access qualifiers */
#ifndef __IO
#define __IO volatile
#endif
#ifndef __I
#define __I  volatile const
#endif
#ifndef __O
#define __O  volatile
#endif

/* ========================================================================= */
/* Register Offsets
 * ========================================================================= */

#define TIDELINK_REGS_PAIR_BASE_ADDR_OFFSET  0x000U
#define TIDELINK_REGS_RELEASE_THRESHOLD_OFFSET  0x004U
#define TIDELINK_REGS_PACKET_WORD_LENGTH_OFFSET  0x008U
#define TIDELINK_REGS_CREDIT_COUNT_OFFSET  0x00CU
#define TIDELINK_REGS_STATUS_OFFSET  0x010U
#define TIDELINK_REGS_DOORBELL_OFFSET  0x014U
#define TIDELINK_REGS_RELEASE_ACC_OFFSET  0x018U
#define TIDELINK_REGS_CTRL_OFFSET  0x01CU
#define TIDELINK_REGS_RELEASED_CREDITS_ACC_OFFSET  0x020U
#define TIDELINK_REGS_DOORBELL_RESPONSE_ACC_OFFSET  0x024U
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_OFFSET  0x028U
#define TIDELINK_REGS_PAIR_CREDIT_CONSUME_OFFSET  0x02CU
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_EN_OFFSET  0x030U

/* ───────────────────────────────────────────────────────────────────────── */
/* PAIR_BASE_ADDR (0x000) — Base address of the paired TideLink's APB register space.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_PAIR_BASE_ADDR_PAIR_BASE_Pos    0U
#define TIDELINK_REGS_PAIR_BASE_ADDR_PAIR_BASE_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_PAIR_BASE_ADDR_PAIR_BASE_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* RELEASE_THRESHOLD (0x004) — Minimum number of credits to accumulate before the returner fires
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_RELEASE_THRESHOLD_THRESHOLD_Pos    0U
#define TIDELINK_REGS_RELEASE_THRESHOLD_THRESHOLD_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_RELEASE_THRESHOLD_THRESHOLD_Wid    32U
#define TIDELINK_REGS_RELEASE_THRESHOLD_THRESHOLD_Rst    0x14U

/* ───────────────────────────────────────────────────────────────────────── */
/* PACKET_WORD_LENGTH (0x008) — Read-only sideband from the FIFO controller. Shows the word
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_PACKET_WORD_LENGTH_PKT_WORD_LEN_Pos    0U
#define TIDELINK_REGS_PACKET_WORD_LENGTH_PKT_WORD_LEN_Msk    (0x3FFFUL)
#define TIDELINK_REGS_PACKET_WORD_LENGTH_PKT_WORD_LEN_Wid    14U

/* ───────────────────────────────────────────────────────────────────────── */
/* CREDIT_COUNT (0x00C) — Read-only current count of free credits in this TideLink's FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_CREDIT_COUNT_COUNT_Pos    0U
#define TIDELINK_REGS_CREDIT_COUNT_COUNT_Msk    (0x1FFFUL)
#define TIDELINK_REGS_CREDIT_COUNT_COUNT_Wid    13U

/* ───────────────────────────────────────────────────────────────────────── */
/* STATUS (0x010) — Read-only status and sticky fault flags.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_STATUS_RETURNER_BUSY_Pos    0U
#define TIDELINK_REGS_STATUS_RETURNER_BUSY_Msk    (0x1UL)

#define TIDELINK_REGS_STATUS_OVERRUN_Pos    1U
#define TIDELINK_REGS_STATUS_OVERRUN_Msk    (0x2UL)

#define TIDELINK_REGS_STATUS_UNDERRUN_Pos    2U
#define TIDELINK_REGS_STATUS_UNDERRUN_Msk    (0x4UL)

#define TIDELINK_REGS_STATUS_MASTER_ERROR_Pos    3U
#define TIDELINK_REGS_STATUS_MASTER_ERROR_Msk    (0x8UL)

#define TIDELINK_REGS_STATUS_PACKET_COMMITTED_Pos    4U
#define TIDELINK_REGS_STATUS_PACKET_COMMITTED_Msk    (0x10UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* DOORBELL (0x014) — Write-only, self-clearing. Writing any value triggers the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_DOORBELL_TRIGGER_Pos    0U
#define TIDELINK_REGS_DOORBELL_TRIGGER_Msk    (0x1UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* RELEASE_ACC (0x018) — Read-only debug register. Shows the number of credits that have
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_RELEASE_ACC_ACC_Pos    0U
#define TIDELINK_REGS_RELEASE_ACC_ACC_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_RELEASE_ACC_ACC_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* CTRL (0x01C) — Block enable and flush control. FLUSH is self-clearing and
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_CTRL_EN_Pos    0U
#define TIDELINK_REGS_CTRL_EN_Msk    (0x1UL)

#define TIDELINK_REGS_CTRL_FLUSH_Pos    1U
#define TIDELINK_REGS_CTRL_FLUSH_Msk    (0x2UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* RELEASED_CREDITS_ACC (0x020) — Receives channel-0 delta values from the paired TideLink's
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_RELEASED_CREDITS_ACC_ACC_Pos    0U
#define TIDELINK_REGS_RELEASED_CREDITS_ACC_ACC_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_RELEASED_CREDITS_ACC_ACC_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* DOORBELL_RESPONSE_ACC (0x024) — Receives channel-1 total-credit values from the paired
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_DOORBELL_RESPONSE_ACC_ACC_Pos    0U
#define TIDELINK_REGS_DOORBELL_RESPONSE_ACC_ACC_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_DOORBELL_RESPONSE_ACC_ACC_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* PAIR_CREDIT_COUNTER (0x028) — Running count of available credits on the paired TideLink side.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_COUNT_Pos    0U
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_COUNT_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_COUNT_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* PAIR_CREDIT_CONSUME (0x02C) — Write-only. CPU writes the number of credits being consumed.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_PAIR_CREDIT_CONSUME_CONSUME_Pos    0U
#define TIDELINK_REGS_PAIR_CREDIT_CONSUME_CONSUME_Msk    (0xFFFFFFFFUL)
#define TIDELINK_REGS_PAIR_CREDIT_CONSUME_CONSUME_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* PAIR_CREDIT_COUNTER_EN (0x030) — Bit 0 controls whether the Pair Credit Counter (0x028) is
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_EN_ENABLE_Pos    0U
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_EN_ENABLE_Msk    (0x1UL)
#define TIDELINK_REGS_PAIR_CREDIT_COUNTER_EN_ENABLE_Rst    0x1U

/* ========================================================================= */
/* Register Struct
 * ========================================================================= */

typedef struct {
    __IO uint32_t PAIR_BASE_ADDR;  /* 0x000 */
    __IO uint32_t RELEASE_THRESHOLD;  /* 0x004 */
    __I  uint32_t PACKET_WORD_LENGTH;  /* 0x008 */
    __I  uint32_t CREDIT_COUNT;  /* 0x00C */
    __I  uint32_t STATUS;  /* 0x010 */
    __O  uint32_t DOORBELL;  /* 0x014 */
    __I  uint32_t RELEASE_ACC;  /* 0x018 */
    __IO uint32_t CTRL;  /* 0x01C */
    __IO uint32_t RELEASED_CREDITS_ACC;  /* 0x020 */
    __IO uint32_t DOORBELL_RESPONSE_ACC;  /* 0x024 */
    __I  uint32_t PAIR_CREDIT_COUNTER;  /* 0x028 */
    __O  uint32_t PAIR_CREDIT_CONSUME;  /* 0x02C */
    __IO uint32_t PAIR_CREDIT_COUNTER_EN;  /* 0x030 */
} TIDELINK_REGS_TypeDef;

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_REGS_GENERATED_H */
