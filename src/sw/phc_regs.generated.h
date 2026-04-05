/*-----------------------------------------------------------------------------
 * Auto-generated from SystemRDL — do not edit
 *
 * Source addrmap: phc_regs
 * Generator:     scripts/rdl2c.py
 *-----------------------------------------------------------------------------*/

#ifndef PHC_REGS_GENERATED_H
#define PHC_REGS_GENERATED_H

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

#define PHC_REGS_CTRL_OFFSET  0x000U
#define PHC_REGS_STATUS_OFFSET  0x004U
#define PHC_REGS_NS_INCR_OFFSET  0x008U
#define PHC_REGS_NS_INCR_FRAC_OFFSET  0x00CU
#define PHC_REGS_SET_SECONDS_LO_OFFSET  0x010U
#define PHC_REGS_SET_SECONDS_HI_OFFSET  0x014U
#define PHC_REGS_SET_NANOSECONDS_OFFSET  0x018U
#define PHC_REGS_INT_EN_OFFSET  0x01CU
#define PHC_REGS_CAP_SECONDS_LO_OFFSET  0x020U
#define PHC_REGS_CAP_SECONDS_HI_OFFSET  0x024U
#define PHC_REGS_CAP_NANOSECONDS_OFFSET  0x028U
#define PHC_REGS_CAP_NS_FRAC_OFFSET  0x02CU
#define PHC_REGS_ALARM_SECONDS_LO_OFFSET  0x030U
#define PHC_REGS_ALARM_SECONDS_HI_OFFSET  0x034U
#define PHC_REGS_ALARM_NANOSECONDS_OFFSET  0x038U
#define PHC_REGS_ALARM_CTRL_OFFSET  0x03CU
#define PHC_REGS_HW_CAP_SECONDS_LO_OFFSET  0x040U
#define PHC_REGS_HW_CAP_SECONDS_HI_OFFSET  0x044U
#define PHC_REGS_HW_CAP_NANOSECONDS_OFFSET  0x048U
#define PHC_REGS_HW_CAP_NS_FRAC_OFFSET  0x04CU

/* ───────────────────────────────────────────────────────────────────────── */
/* CTRL (0x000) — Clock enable, time set, and capture control.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_CTRL_EN_Pos    0U
#define PHC_REGS_CTRL_EN_Msk    (0x1UL)

#define PHC_REGS_CTRL_SET_TIME_Pos    1U
#define PHC_REGS_CTRL_SET_TIME_Msk    (0x2UL)

#define PHC_REGS_CTRL_CAPTURE_Pos    2U
#define PHC_REGS_CTRL_CAPTURE_Msk    (0x4UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* STATUS (0x004) — Read-only clock status and sticky flags.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_STATUS_RUNNING_Pos    0U
#define PHC_REGS_STATUS_RUNNING_Msk    (0x1UL)

#define PHC_REGS_STATUS_PPS_STICKY_Pos    1U
#define PHC_REGS_STATUS_PPS_STICKY_Msk    (0x2UL)

#define PHC_REGS_STATUS_ALARM_HIT_Pos    2U
#define PHC_REGS_STATUS_ALARM_HIT_Msk    (0x4UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* NS_INCR (0x008) — Integer nanosecond increment applied to the counter each clock
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_NS_INCR_NS_INCR_Pos    0U
#define PHC_REGS_NS_INCR_NS_INCR_Msk    (0xFFUL)
#define PHC_REGS_NS_INCR_NS_INCR_Wid    8U
#define PHC_REGS_NS_INCR_NS_INCR_Rst    0x4U

/* ───────────────────────────────────────────────────────────────────────── */
/* NS_INCR_FRAC (0x00C) — Sub-nanosecond fractional increment accumulator. Each cycle,
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_NS_INCR_FRAC_NS_INCR_FRAC_Pos    0U
#define PHC_REGS_NS_INCR_FRAC_NS_INCR_FRAC_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_NS_INCR_FRAC_NS_INCR_FRAC_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* SET_SECONDS_LO (0x010) — Lower 32 bits of the 48-bit seconds value to load when
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_SET_SECONDS_LO_SET_SECONDS_LO_Pos    0U
#define PHC_REGS_SET_SECONDS_LO_SET_SECONDS_LO_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_SET_SECONDS_LO_SET_SECONDS_LO_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* SET_SECONDS_HI (0x014) — Upper 16 bits of the 48-bit seconds value to load when
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_SET_SECONDS_HI_SET_SECONDS_HI_Pos    0U
#define PHC_REGS_SET_SECONDS_HI_SET_SECONDS_HI_Msk    (0xFFFFUL)
#define PHC_REGS_SET_SECONDS_HI_SET_SECONDS_HI_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* SET_NANOSECONDS (0x018) — 30-bit nanosecond value (0-999,999,999) to load when
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_SET_NANOSECONDS_SET_NANOSECONDS_Pos    0U
#define PHC_REGS_SET_NANOSECONDS_SET_NANOSECONDS_Msk    (0x3FFFFFFFUL)
#define PHC_REGS_SET_NANOSECONDS_SET_NANOSECONDS_Wid    30U

/* ───────────────────────────────────────────────────────────────────────── */
/* INT_EN (0x01C) — Interrupt enable flags. Each bit gates the corresponding
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_INT_EN_PPS_IRQ_EN_Pos    0U
#define PHC_REGS_INT_EN_PPS_IRQ_EN_Msk    (0x1UL)

#define PHC_REGS_INT_EN_ALARM_IRQ_EN_Pos    1U
#define PHC_REGS_INT_EN_ALARM_IRQ_EN_Msk    (0x2UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* CAP_SECONDS_LO (0x020) — Lower 32 bits of seconds latched by ctrl.capture or hw_capture.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_CAP_SECONDS_LO_CAP_SECONDS_LO_Pos    0U
#define PHC_REGS_CAP_SECONDS_LO_CAP_SECONDS_LO_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_CAP_SECONDS_LO_CAP_SECONDS_LO_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* CAP_SECONDS_HI (0x024) — Upper 16 bits of seconds latched by ctrl.capture or hw_capture.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_CAP_SECONDS_HI_CAP_SECONDS_HI_Pos    0U
#define PHC_REGS_CAP_SECONDS_HI_CAP_SECONDS_HI_Msk    (0xFFFFUL)
#define PHC_REGS_CAP_SECONDS_HI_CAP_SECONDS_HI_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* CAP_NANOSECONDS (0x028) — 30-bit nanoseconds latched by ctrl.capture or hw_capture.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_CAP_NANOSECONDS_CAP_NANOSECONDS_Pos    0U
#define PHC_REGS_CAP_NANOSECONDS_CAP_NANOSECONDS_Msk    (0x3FFFFFFFUL)
#define PHC_REGS_CAP_NANOSECONDS_CAP_NANOSECONDS_Wid    30U

/* ───────────────────────────────────────────────────────────────────────── */
/* CAP_NS_FRAC (0x02C) — 32-bit sub-nanosecond fractional part latched by ctrl.capture
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_CAP_NS_FRAC_CAP_NS_FRAC_Pos    0U
#define PHC_REGS_CAP_NS_FRAC_CAP_NS_FRAC_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_CAP_NS_FRAC_CAP_NS_FRAC_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* ALARM_SECONDS_LO (0x030) — Lower 32 bits of the 48-bit alarm match seconds value.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_ALARM_SECONDS_LO_ALARM_SECONDS_LO_Pos    0U
#define PHC_REGS_ALARM_SECONDS_LO_ALARM_SECONDS_LO_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_ALARM_SECONDS_LO_ALARM_SECONDS_LO_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* ALARM_SECONDS_HI (0x034) — Upper 16 bits of the 48-bit alarm match seconds value.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_ALARM_SECONDS_HI_ALARM_SECONDS_HI_Pos    0U
#define PHC_REGS_ALARM_SECONDS_HI_ALARM_SECONDS_HI_Msk    (0xFFFFUL)
#define PHC_REGS_ALARM_SECONDS_HI_ALARM_SECONDS_HI_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* ALARM_NANOSECONDS (0x038) — 30-bit alarm match nanoseconds. Alarm fires when seconds match
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_ALARM_NANOSECONDS_ALARM_NANOSECONDS_Pos    0U
#define PHC_REGS_ALARM_NANOSECONDS_ALARM_NANOSECONDS_Msk    (0x3FFFFFFFUL)
#define PHC_REGS_ALARM_NANOSECONDS_ALARM_NANOSECONDS_Wid    30U

/* ───────────────────────────────────────────────────────────────────────── */
/* ALARM_CTRL (0x03C) — Arm and auto-disarm control for the alarm comparator.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_ALARM_CTRL_ARM_Pos    0U
#define PHC_REGS_ALARM_CTRL_ARM_Msk    (0x1UL)

#define PHC_REGS_ALARM_CTRL_AUTO_DISARM_Pos    1U
#define PHC_REGS_ALARM_CTRL_AUTO_DISARM_Msk    (0x2UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* HW_CAP_SECONDS_LO (0x040) — Lower 32 bits of seconds latched by hw_capture only. Independent
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_HW_CAP_SECONDS_LO_HW_CAP_SECONDS_LO_Pos    0U
#define PHC_REGS_HW_CAP_SECONDS_LO_HW_CAP_SECONDS_LO_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_HW_CAP_SECONDS_LO_HW_CAP_SECONDS_LO_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* HW_CAP_SECONDS_HI (0x044) — Upper 16 bits of seconds latched by hw_capture only.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_HW_CAP_SECONDS_HI_HW_CAP_SECONDS_HI_Pos    0U
#define PHC_REGS_HW_CAP_SECONDS_HI_HW_CAP_SECONDS_HI_Msk    (0xFFFFUL)
#define PHC_REGS_HW_CAP_SECONDS_HI_HW_CAP_SECONDS_HI_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* HW_CAP_NANOSECONDS (0x048) — 30-bit nanoseconds latched by hw_capture only.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_HW_CAP_NANOSECONDS_HW_CAP_NANOSECONDS_Pos    0U
#define PHC_REGS_HW_CAP_NANOSECONDS_HW_CAP_NANOSECONDS_Msk    (0x3FFFFFFFUL)
#define PHC_REGS_HW_CAP_NANOSECONDS_HW_CAP_NANOSECONDS_Wid    30U

/* ───────────────────────────────────────────────────────────────────────── */
/* HW_CAP_NS_FRAC (0x04C) — 32-bit sub-nanosecond fractional part latched by hw_capture only.
 * ───────────────────────────────────────────────────────────────────────── */

#define PHC_REGS_HW_CAP_NS_FRAC_HW_CAP_NS_FRAC_Pos    0U
#define PHC_REGS_HW_CAP_NS_FRAC_HW_CAP_NS_FRAC_Msk    (0xFFFFFFFFUL)
#define PHC_REGS_HW_CAP_NS_FRAC_HW_CAP_NS_FRAC_Wid    32U

/* ========================================================================= */
/* Register Struct
 * ========================================================================= */

typedef struct {
    __IO uint32_t CTRL;  /* 0x000 */
    __I  uint32_t STATUS;  /* 0x004 */
    __IO uint32_t NS_INCR;  /* 0x008 */
    __IO uint32_t NS_INCR_FRAC;  /* 0x00C */
    __IO uint32_t SET_SECONDS_LO;  /* 0x010 */
    __IO uint32_t SET_SECONDS_HI;  /* 0x014 */
    __IO uint32_t SET_NANOSECONDS;  /* 0x018 */
    __IO uint32_t INT_EN;  /* 0x01C */
    __I  uint32_t CAP_SECONDS_LO;  /* 0x020 */
    __I  uint32_t CAP_SECONDS_HI;  /* 0x024 */
    __I  uint32_t CAP_NANOSECONDS;  /* 0x028 */
    __I  uint32_t CAP_NS_FRAC;  /* 0x02C */
    __IO uint32_t ALARM_SECONDS_LO;  /* 0x030 */
    __IO uint32_t ALARM_SECONDS_HI;  /* 0x034 */
    __IO uint32_t ALARM_NANOSECONDS;  /* 0x038 */
    __IO uint32_t ALARM_CTRL;  /* 0x03C */
    __I  uint32_t HW_CAP_SECONDS_LO;  /* 0x040 */
    __I  uint32_t HW_CAP_SECONDS_HI;  /* 0x044 */
    __I  uint32_t HW_CAP_NANOSECONDS;  /* 0x048 */
    __I  uint32_t HW_CAP_NS_FRAC;  /* 0x04C */
} PHC_REGS_TypeDef;

#ifdef __cplusplus
}
#endif

#endif /* PHC_REGS_GENERATED_H */
