/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Address Translator Driver — Header
 *
 * CMSIS-style driver for the TideLink CAM-based address translator.
 *
 * Register structs and bit definitions are auto-generated from SystemRDL
 * via tidelink_addr_translator_regs.generated.h. This header adds the
 * driver-level API.
 *
 * The address translator remaps AHB addresses in the transparent bridge
 * path by:
 *   1. Subtracting BASE_OFFSET to normalise the address.
 *   2. Matching addr[31:24] against enabled CAM rules.
 *   3. Replacing addr[31:24] with the matching rule's replace byte.
 *   4. addr[23:0] passes through unchanged.
 *
 * Two independent channels share the same AHB slave port. Each channel
 * has its own BASE_OFFSET, CTRL, and 8 programmable rules.
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

#ifndef TIDELINK_ADDR_TRANS_H
#define TIDELINK_ADDR_TRANS_H

#include "tidelink_addr_translator_regs.generated.h"  /* bit defs + TypeDef */

#ifdef __cplusplus
extern "C" {
#endif

/* ── CMSIS-style access qualifiers (if not already defined) ─────────────── */

#ifndef __IO
#define __IO volatile
#endif

/* ── Constants ──────────────────────────────────────────────────────────── */

#define TIDELINK_AT_NUM_RULES    8U
#define TIDELINK_AT_NUM_CHANNELS 2U

/* ── Convenience aliases for generated bit definitions ──────────────────── */

#define TIDELINK_AT_CTRL_ENABLE_Pos       TIDELINK_ADDR_TRANSLATOR_REGS_CTRL_ENABLE_Pos
#define TIDELINK_AT_CTRL_ENABLE_Msk       TIDELINK_ADDR_TRANSLATOR_REGS_CTRL_ENABLE_Msk

#define TIDELINK_AT_RULE_ENABLE_Pos       TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_ENABLE_Pos
#define TIDELINK_AT_RULE_ENABLE_Msk       TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_ENABLE_Msk
#define TIDELINK_AT_RULE_MATCH_BYTE_Pos   TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_MATCH_BYTE_Pos
#define TIDELINK_AT_RULE_MATCH_BYTE_Msk   TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_MATCH_BYTE_Msk
#define TIDELINK_AT_RULE_REPLACE_BYTE_Pos TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_REPLACE_BYTE_Pos
#define TIDELINK_AT_RULE_REPLACE_BYTE_Msk TIDELINK_ADDR_TRANSLATOR_REGS_RULE_0_REPLACE_BYTE_Msk

/* ── Per-channel register access struct ─────────────────────────────────
 *
 * The generated TIDELINK_ADDR_TRANSLATOR_REGS_TypeDef is flat (all rules
 * as RULE_0..RULE_7 plus PrimeCell IDs with large padding). For the
 * driver we use a compact per-channel struct with a RULE array.
 * ----------------------------------------------------------------------- */

typedef struct {
    __IO uint32_t BASE_OFFSET;           /* 0x000 RW  Subtracted from input  */
    __IO uint32_t CTRL;                  /* 0x004 RW  [0]=enable             */
         uint32_t RESERVED[2];           /* 0x008-0x00C                      */
    __IO uint32_t RULE[TIDELINK_AT_NUM_RULES]; /* 0x010-0x02C RW             */
} TIDELINK_AT_CH_TypeDef;

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_AT_CH_TypeDef *ch;  /* Channel register block pointer */
} tidelink_at_t;

/* ── Initialisation ─────────────────────────────────────────────────────── */

/**
 * Initialise an address translator channel handle.
 *
 * @param at    Pointer to caller-allocated tidelink_at_t.
 * @param base  Physical base address of the channel's register block.
 */
void tidelink_at_init(tidelink_at_t *at, uint32_t base);

/* ── Global Enable/Disable ──────────────────────────────────────────────── */

/** Enable address translation for this channel. */
static inline void tidelink_at_enable(tidelink_at_t *at)
{
    at->ch->CTRL |= TIDELINK_AT_CTRL_ENABLE_Msk;
}

/** Disable address translation (identity passthrough). */
static inline void tidelink_at_disable(tidelink_at_t *at)
{
    at->ch->CTRL &= ~TIDELINK_AT_CTRL_ENABLE_Msk;
}

/* ── Base Offset ────────────────────────────────────────────────────────── */

/** Set the base offset subtracted from input addresses before matching. */
static inline void tidelink_at_set_base_offset(tidelink_at_t *at,
                                                uint32_t offset)
{
    at->ch->BASE_OFFSET = offset;
}

/** Get the current base offset. */
static inline uint32_t tidelink_at_get_base_offset(tidelink_at_t *at)
{
    return at->ch->BASE_OFFSET;
}

/* ── Rule Management ────────────────────────────────────────────────────── */

/**
 * Program a translation rule.
 *
 * @param at       Driver handle.
 * @param idx      Rule index (0-7, 0 = highest priority).
 * @param match    Upper address byte to match against (addr[31:24]).
 * @param replace  Replacement value for upper address byte.
 */
void tidelink_at_set_rule(tidelink_at_t *at, uint32_t idx,
                           uint8_t match, uint8_t replace);

/**
 * Disable (clear) a translation rule.
 *
 * @param at   Driver handle.
 * @param idx  Rule index (0-7).
 */
void tidelink_at_clear_rule(tidelink_at_t *at, uint32_t idx);

/**
 * Disable all translation rules for this channel.
 */
void tidelink_at_clear_all_rules(tidelink_at_t *at);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_ADDR_TRANS_H */
