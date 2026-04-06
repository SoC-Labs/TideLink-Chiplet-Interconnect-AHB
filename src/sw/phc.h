/*-----------------------------------------------------------------------------
 * SoCLabs PTP Hardware Clock (PHC) Driver — Header
 *
 * CMSIS-style bare-metal driver for the PTP Hardware Clock.
 *
 * Register structs and bit definitions are auto-generated from SystemRDL
 * via phc_regs.generated.h. This header adds the driver-level API.
 *
 * The PHC provides:
 *   - 48-bit seconds + 30-bit nanoseconds + 32-bit fractional ns counter
 *   - Software capture (CTRL.CAPTURE) and hardware capture (hw_capture)
 *   - Programmable alarm with auto-disarm
 *   - Adjustable frequency via NS_INCR / NS_INCR_FRAC
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

#ifndef PHC_H
#define PHC_H

#include "phc_regs.generated.h"  /* PHC_REGS_TypeDef + bit defs */

#ifdef __cplusplus
extern "C" {
#endif

/* ── Convenience aliases for generated bit definitions ──────────────────── */

#define PHC_CTRL_EN_Pos           PHC_REGS_CTRL_EN_Pos
#define PHC_CTRL_EN_Msk           PHC_REGS_CTRL_EN_Msk
#define PHC_CTRL_SET_TIME_Pos     PHC_REGS_CTRL_SET_TIME_Pos
#define PHC_CTRL_SET_TIME_Msk     PHC_REGS_CTRL_SET_TIME_Msk
#define PHC_CTRL_CAPTURE_Pos      PHC_REGS_CTRL_CAPTURE_Pos
#define PHC_CTRL_CAPTURE_Msk      PHC_REGS_CTRL_CAPTURE_Msk

#define PHC_STATUS_RUNNING_Pos    PHC_REGS_STATUS_RUNNING_Pos
#define PHC_STATUS_RUNNING_Msk    PHC_REGS_STATUS_RUNNING_Msk
#define PHC_STATUS_PPS_STICKY_Pos PHC_REGS_STATUS_PPS_STICKY_Pos
#define PHC_STATUS_PPS_STICKY_Msk PHC_REGS_STATUS_PPS_STICKY_Msk
#define PHC_STATUS_ALARM_HIT_Pos  PHC_REGS_STATUS_ALARM_HIT_Pos
#define PHC_STATUS_ALARM_HIT_Msk  PHC_REGS_STATUS_ALARM_HIT_Msk

#define PHC_INT_EN_PPS_Pos        PHC_REGS_INT_EN_PPS_IRQ_EN_Pos
#define PHC_INT_EN_PPS_Msk        PHC_REGS_INT_EN_PPS_IRQ_EN_Msk
#define PHC_INT_EN_ALARM_Pos      PHC_REGS_INT_EN_ALARM_IRQ_EN_Pos
#define PHC_INT_EN_ALARM_Msk      PHC_REGS_INT_EN_ALARM_IRQ_EN_Msk

#define PHC_ALARM_CTRL_ARM_Pos         PHC_REGS_ALARM_CTRL_ARM_Pos
#define PHC_ALARM_CTRL_ARM_Msk         PHC_REGS_ALARM_CTRL_ARM_Msk
#define PHC_ALARM_CTRL_AUTO_DISARM_Pos PHC_REGS_ALARM_CTRL_AUTO_DISARM_Pos
#define PHC_ALARM_CTRL_AUTO_DISARM_Msk PHC_REGS_ALARM_CTRL_AUTO_DISARM_Msk

/* ── Data Structures ───────────────────────────────────────────────────── */

/** Full-precision captured time (seconds + nanoseconds + fractional). */
typedef struct {
    uint32_t sec_lo;   /* Lower 32 bits of 48-bit seconds   */
    uint16_t sec_hi;   /* Upper 16 bits of 48-bit seconds   */
    uint32_t ns;       /* 30-bit nanoseconds (0-999999999)  */
    uint32_t ns_frac;  /* 32-bit sub-nanosecond fraction    */
} phc_time_t;

/* ── Driver handle ─────────────────────────────────────────────────────── */

typedef struct {
    PHC_REGS_TypeDef *regs;  /* PHC register block pointer */
} phc_t;

/* ── Initialisation ────────────────────────────────────────────────────── */

/**
 * Initialise a PHC driver handle and enable the clock.
 *
 * @param phc   Pointer to caller-allocated phc_t.
 * @param base  Physical base address of the PHC register block.
 */
void phc_init(phc_t *phc, uint32_t base);

/* ── Time Set ──────────────────────────────────────────────────────────── */

/**
 * Set the PHC time to a specific value.
 *
 * Writes SET_SECONDS_LO, SET_SECONDS_HI, and SET_NANOSECONDS, then
 * pulses CTRL.SET_TIME (self-clearing) to load the counters.
 *
 * @param phc     Driver handle.
 * @param sec_lo  Lower 32 bits of seconds.
 * @param sec_hi  Upper 16 bits of seconds.
 * @param ns      Nanoseconds (0-999999999).
 */
void phc_set_time(phc_t *phc, uint32_t sec_lo, uint16_t sec_hi, uint32_t ns);

/* ── Software Capture ──────────────────────────────────────────────────── */

/**
 * Trigger a software capture of the current time.
 *
 * Pulses CTRL.CAPTURE (self-clearing). The captured value is latched
 * into CAP_SECONDS_LO/HI, CAP_NANOSECONDS, and CAP_NS_FRAC.
 *
 * @param phc  Driver handle.
 */
void phc_capture(phc_t *phc);

/**
 * Read the software-captured time (CAP_* registers).
 *
 * Call phc_capture() first, then read the result with this function.
 *
 * @param phc  Driver handle.
 * @param out  Pointer to caller-allocated phc_time_t.
 */
void phc_get_captured_time(phc_t *phc, phc_time_t *out);

/* ── Hardware Capture ──────────────────────────────────────────────────── */

/**
 * Read the hardware-captured time (HW_CAP_* registers).
 *
 * The HW_CAP registers are latched by an external hw_capture pulse
 * (e.g. from the TideLink PTP subsystem). This function only reads
 * the stored value; the capture itself is triggered by hardware.
 *
 * @param phc  Driver handle.
 * @param out  Pointer to caller-allocated phc_time_t.
 */
void phc_get_hw_captured_time(phc_t *phc, phc_time_t *out);

/* ── Frequency Adjustment ──────────────────────────────────────────────── */

/**
 * Adjust the clock increment rate.
 *
 * Each clock cycle the PHC adds ns_incr nanoseconds plus
 * ns_incr_frac / 2^32 sub-nanoseconds.
 *
 * Default at 250 MHz: ns_incr=4, ns_incr_frac=0.
 *
 * @param phc         Driver handle.
 * @param ns_incr     Integer nanosecond increment per cycle (8-bit).
 * @param ns_incr_frac Sub-nanosecond fractional increment (32-bit).
 */
void phc_adjust_freq(phc_t *phc, uint8_t ns_incr, uint32_t ns_incr_frac);

/* ── Alarm ─────────────────────────────────────────────────────────────── */

/**
 * Set and arm the alarm comparator.
 *
 * The alarm fires (STATUS.ALARM_HIT = 1) when the PHC counter matches
 * the programmed seconds + nanoseconds value.
 *
 * @param phc          Driver handle.
 * @param sec_lo       Lower 32 bits of alarm seconds.
 * @param sec_hi       Upper 16 bits of alarm seconds.
 * @param ns           Alarm nanoseconds (0-999999999).
 * @param auto_disarm  If non-zero, alarm auto-disarms after first hit.
 */
void phc_set_alarm(phc_t *phc, uint32_t sec_lo, uint16_t sec_hi,
                   uint32_t ns, uint32_t auto_disarm);

/* ── Status ────────────────────────────────────────────────────────────── */

/**
 * Read the raw STATUS register.
 *
 * @param phc  Driver handle.
 * @return STATUS register value (running, pps_sticky, alarm_hit).
 */
static inline uint32_t phc_get_status(phc_t *phc)
{
    return phc->regs->STATUS;
}

/** Return non-zero if the PHC is running. */
static inline uint32_t phc_is_running(phc_t *phc)
{
    return phc->regs->STATUS & PHC_STATUS_RUNNING_Msk;
}

/** Return non-zero if a PPS event has occurred (sticky). */
static inline uint32_t phc_pps_occurred(phc_t *phc)
{
    return phc->regs->STATUS & PHC_STATUS_PPS_STICKY_Msk;
}

/** Return non-zero if the alarm has fired. */
static inline uint32_t phc_alarm_hit(phc_t *phc)
{
    return phc->regs->STATUS & PHC_STATUS_ALARM_HIT_Msk;
}

/* ── Interrupt Enable ──────────────────────────────────────────────────── */

/** Enable the PPS interrupt. */
static inline void phc_enable_pps_irq(phc_t *phc)
{
    phc->regs->INT_EN |= PHC_INT_EN_PPS_Msk;
}

/** Enable the alarm interrupt. */
static inline void phc_enable_alarm_irq(phc_t *phc)
{
    phc->regs->INT_EN |= PHC_INT_EN_ALARM_Msk;
}

/** Disable all PHC interrupts. */
static inline void phc_disable_irqs(phc_t *phc)
{
    phc->regs->INT_EN = 0U;
}

#ifdef __cplusplus
}
#endif

#endif /* PHC_H */
