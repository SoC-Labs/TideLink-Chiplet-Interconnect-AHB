/*-----------------------------------------------------------------------------
 * Auto-generated from SystemRDL — do not edit
 *
 * Source addrmap: tidelink_addr_translator_regs
 * Generator:     scripts/rdl2c.py
 *-----------------------------------------------------------------------------*/

#ifndef TIDELINK_ADDR_TRANSLATOR_REGS_GENERATED_H
#define TIDELINK_ADDR_TRANSLATOR_REGS_GENERATED_H

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

#define TIDELINK_ADDR_TRANSLATOR_REGS_BASE_OFFSET_OFFSET  0x000U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CTRL_OFFSET  0x004U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_OFFSET  0x010U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_OFFSET  0x014U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_OFFSET  0x018U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_OFFSET  0x01CU
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_OFFSET  0x020U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_OFFSET  0x024U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_OFFSET  0x028U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_OFFSET  0x02CU
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR4_OFFSET  0xFD0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR5_OFFSET  0xFD4U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR6_OFFSET  0xFD8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR7_OFFSET  0xFDCU
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR0_OFFSET  0xFE0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR1_OFFSET  0xFE4U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR2_OFFSET  0xFE8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR3_OFFSET  0xFECU
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR0_OFFSET  0xFF0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR1_OFFSET  0xFF4U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR2_OFFSET  0xFF8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR3_OFFSET  0xFFCU

/* ───────────────────────────────────────────────────────────────────────── */
/* BASE_OFFSET (0x000) — 32-bit value subtracted from the input AHB address before the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_BASE_OFFSET_BASE_OFFSET_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_BASE_OFFSET_BASE_OFFSET_Msk    (0xFFFFFFFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_BASE_OFFSET_BASE_OFFSET_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* CTRL (0x004) — Global translation control. When enable is 0, all addresses
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_CTRL_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CTRL_ENABLE_Msk    (0x1UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_0 (0x010) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_1 (0x014) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_1_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_2 (0x018) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_2_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_3 (0x01C) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_3_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_4 (0x020) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_4_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_5 (0x024) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_5_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_6 (0x028) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_6_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* RULE_7 (0x02C) — Programmable address translation rule. When enabled, if the
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_ENABLE_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_ENABLE_Msk    (0x1UL)

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_MATCH_BYTE_Pos    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_MATCH_BYTE_Msk    (0xFF00UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_MATCH_BYTE_Wid    8U

#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_REPLACE_BYTE_Pos    16U
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_REPLACE_BYTE_Msk    (0xFF0000UL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_RULE_7_REPLACE_BYTE_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR4 (0xFD0) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR4_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR4_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR4_PID_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR5 (0xFD4) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR5_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR5_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR5_PID_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR6 (0xFD8) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR6_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR6_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR6_PID_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR7 (0xFDC) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR7_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR7_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR7_PID_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR0 (0xFE0) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR0_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR0_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR0_PID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR0_PID_Rst    0x59U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR1 (0xFE4) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR1_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR1_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR1_PID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR1_PID_Rst    0x16U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR2 (0xFE8) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR2_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR2_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR2_PID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR2_PID_Rst    0x15U

/* ───────────────────────────────────────────────────────────────────────── */
/* PIDR3 (0xFEC) — Read-only ARM PrimeCell peripheral identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR3_PID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR3_PID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_PIDR3_PID_Wid    8U

/* ───────────────────────────────────────────────────────────────────────── */
/* CIDR0 (0xFF0) — Read-only ARM PrimeCell component identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR0_CID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR0_CID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR0_CID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR0_CID_Rst    0x50U

/* ───────────────────────────────────────────────────────────────────────── */
/* CIDR1 (0xFF4) — Read-only ARM PrimeCell component identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR1_CID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR1_CID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR1_CID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR1_CID_Rst    0x51U

/* ───────────────────────────────────────────────────────────────────────── */
/* CIDR2 (0xFF8) — Read-only ARM PrimeCell component identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR2_CID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR2_CID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR2_CID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR2_CID_Rst    0x4CU

/* ───────────────────────────────────────────────────────────────────────── */
/* CIDR3 (0xFFC) — Read-only ARM PrimeCell component identification.
 * ───────────────────────────────────────────────────────────────────────── */

#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR3_CID_Pos    0U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR3_CID_Msk    (0xFFUL)
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR3_CID_Wid    8U
#define TIDELINK_ADDR_TRANSLATOR_REGS_CIDR3_CID_Rst    0x54U

/* ========================================================================= */
/* Register Struct
 * ========================================================================= */

typedef struct {
    __IO uint32_t BASE_OFFSET;  /* 0x000 */
    __IO uint32_t CTRL;  /* 0x004 */
         uint32_t RESERVED_008[2];
    __IO uint32_t RULE_0;  /* 0x010 */
    __IO uint32_t RULE_1;  /* 0x014 */
    __IO uint32_t RULE_2;  /* 0x018 */
    __IO uint32_t RULE_3;  /* 0x01C */
    __IO uint32_t RULE_4;  /* 0x020 */
    __IO uint32_t RULE_5;  /* 0x024 */
    __IO uint32_t RULE_6;  /* 0x028 */
    __IO uint32_t RULE_7;  /* 0x02C */
         uint32_t RESERVED_030[1000];
    __I  uint32_t PIDR4;  /* 0xFD0 */
    __I  uint32_t PIDR5;  /* 0xFD4 */
    __I  uint32_t PIDR6;  /* 0xFD8 */
    __I  uint32_t PIDR7;  /* 0xFDC */
    __I  uint32_t PIDR0;  /* 0xFE0 */
    __I  uint32_t PIDR1;  /* 0xFE4 */
    __I  uint32_t PIDR2;  /* 0xFE8 */
    __I  uint32_t PIDR3;  /* 0xFEC */
    __I  uint32_t CIDR0;  /* 0xFF0 */
    __I  uint32_t CIDR1;  /* 0xFF4 */
    __I  uint32_t CIDR2;  /* 0xFF8 */
    __I  uint32_t CIDR3;  /* 0xFFC */
} TIDELINK_ADDR_TRANSLATOR_REGS_TypeDef;

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_ADDR_TRANSLATOR_REGS_GENERATED_H */
