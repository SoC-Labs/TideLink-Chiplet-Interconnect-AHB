/*-----------------------------------------------------------------------------
 * SoCLabs PTP Hardware Clock (PHC) Driver — Implementation
 *
 * Bare-metal driver for the PTP Hardware Clock.
 * Targets ARM Cortex-M0.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include "phc.h"

/* ── Initialisation ────────────────────────────────────────────────────── */

void phc_init(phc_t *phc, uint32_t base)
{
    phc->regs = (PHC_REGS_TypeDef *)(uintptr_t)base;

    /* Enable the clock counter */
    phc->regs->CTRL = PHC_CTRL_EN_Msk;
}

/* ── Time Set ──────────────────────────────────────────────────────────── */

void phc_set_time(phc_t *phc, uint32_t sec_lo, uint16_t sec_hi, uint32_t ns)
{
    /* Load the set registers first, then pulse SET_TIME */
    phc->regs->SET_SECONDS_LO  = sec_lo;
    phc->regs->SET_SECONDS_HI  = (uint32_t)sec_hi & 0xFFFFU;
    phc->regs->SET_NANOSECONDS = ns & 0x3FFFFFFFU;

    /* Pulse SET_TIME (self-clearing); keep EN asserted */
    phc->regs->CTRL = PHC_CTRL_EN_Msk | PHC_CTRL_SET_TIME_Msk;
}

/* ── Software Capture ──────────────────────────────────────────────────── */

void phc_capture(phc_t *phc)
{
    /* Pulse CAPTURE (self-clearing); keep EN asserted */
    phc->regs->CTRL = PHC_CTRL_EN_Msk | PHC_CTRL_CAPTURE_Msk;
}

void phc_get_captured_time(phc_t *phc, phc_time_t *out)
{
    out->sec_lo  = phc->regs->CAP_SECONDS_LO;
    out->sec_hi  = (uint16_t)(phc->regs->CAP_SECONDS_HI & 0xFFFFU);
    out->ns      = phc->regs->CAP_NANOSECONDS & 0x3FFFFFFFU;
    out->ns_frac = phc->regs->CAP_NS_FRAC;
}

/* ── Hardware Capture ──────────────────────────────────────────────────── */

void phc_get_hw_captured_time(phc_t *phc, phc_time_t *out)
{
    out->sec_lo  = phc->regs->HW_CAP_SECONDS_LO;
    out->sec_hi  = (uint16_t)(phc->regs->HW_CAP_SECONDS_HI & 0xFFFFU);
    out->ns      = phc->regs->HW_CAP_NANOSECONDS & 0x3FFFFFFFU;
    out->ns_frac = phc->regs->HW_CAP_NS_FRAC;
}

/* ── Frequency Adjustment ──────────────────────────────────────────────── */

void phc_adjust_freq(phc_t *phc, uint8_t ns_incr, uint32_t ns_incr_frac)
{
    phc->regs->NS_INCR      = (uint32_t)ns_incr & 0xFFU;
    phc->regs->NS_INCR_FRAC = ns_incr_frac;
}

/* ── Alarm ─────────────────────────────────────────────────────────────── */

void phc_set_alarm(phc_t *phc, uint32_t sec_lo, uint16_t sec_hi,
                   uint32_t ns, uint32_t auto_disarm)
{
    /* Program the alarm match value */
    phc->regs->ALARM_SECONDS_LO  = sec_lo;
    phc->regs->ALARM_SECONDS_HI  = (uint32_t)sec_hi & 0xFFFFU;
    phc->regs->ALARM_NANOSECONDS = ns & 0x3FFFFFFFU;

    /* Arm the alarm; optionally enable auto-disarm */
    phc->regs->ALARM_CTRL = PHC_ALARM_CTRL_ARM_Msk
                           | (auto_disarm ? PHC_ALARM_CTRL_AUTO_DISARM_Msk : 0U);
}
