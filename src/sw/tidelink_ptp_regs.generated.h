/*-----------------------------------------------------------------------------
 * Auto-generated from SystemRDL — do not edit
 *
 * Source addrmap: tidelink_ptp_regs
 * Generator:     scripts/rdl2c.py
 *-----------------------------------------------------------------------------*/

#ifndef TIDELINK_PTP_REGS_GENERATED_H
#define TIDELINK_PTP_REGS_GENERATED_H

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

#define TIDELINK_PTP_REGS_PTP_CTRL_OFFSET  0x034U
#define TIDELINK_PTP_REGS_PTP_RX_PAYLOAD_OFFSET  0x038U
#define TIDELINK_PTP_REGS_PTP_STATUS_OFFSET  0x03CU

/* ───────────────────────────────────────────────────────────────────────── */
/* PTP_CTRL (0x034) — Enable, clear, and status bits for the PTP subsystem. Software
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_PTP_REGS_PTP_CTRL_ENABLE_Pos    0U
#define TIDELINK_PTP_REGS_PTP_CTRL_ENABLE_Msk    (0x1UL)

#define TIDELINK_PTP_REGS_PTP_CTRL_CLEAR_Pos    1U
#define TIDELINK_PTP_REGS_PTP_CTRL_CLEAR_Msk    (0x2UL)

#define TIDELINK_PTP_REGS_PTP_CTRL_RX_VALID_Pos    2U
#define TIDELINK_PTP_REGS_PTP_CTRL_RX_VALID_Msk    (0x4UL)

#define TIDELINK_PTP_REGS_PTP_CTRL_RX_MSG_TYPE_Pos    3U
#define TIDELINK_PTP_REGS_PTP_CTRL_RX_MSG_TYPE_Msk    (0x78UL)
#define TIDELINK_PTP_REGS_PTP_CTRL_RX_MSG_TYPE_Wid    4U

/* ───────────────────────────────────────────────────────────────────────── */
/* PTP_RX_PAYLOAD (0x038) — Read-only. Contains the 32-bit payload field from the most recently
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_PTP_REGS_PTP_RX_PAYLOAD_PAYLOAD_Pos    0U
#define TIDELINK_PTP_REGS_PTP_RX_PAYLOAD_PAYLOAD_Msk    (0xFFFFFFFFUL)
#define TIDELINK_PTP_REGS_PTP_RX_PAYLOAD_PAYLOAD_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* PTP_STATUS (0x03C) — Read-only status bits reflecting the current state of the PTP
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_PTP_REGS_PTP_STATUS_TX_IDLE_Pos    0U
#define TIDELINK_PTP_REGS_PTP_STATUS_TX_IDLE_Msk    (0x1UL)

#define TIDELINK_PTP_REGS_PTP_STATUS_TX_PENDING_Pos    1U
#define TIDELINK_PTP_REGS_PTP_STATUS_TX_PENDING_Msk    (0x2UL)

/* ========================================================================= */
/* Register Struct
 * ========================================================================= */

typedef struct {
         uint32_t RESERVED_000[13];
    __IO uint32_t PTP_CTRL;  /* 0x034 */
    __I  uint32_t PTP_RX_PAYLOAD;  /* 0x038 */
    __I  uint32_t PTP_STATUS;  /* 0x03C */
} TIDELINK_PTP_REGS_TypeDef;

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PTP_REGS_GENERATED_H */
