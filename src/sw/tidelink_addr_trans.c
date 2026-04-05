/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Address Translator Driver — Implementation
 *
 * Bare-metal driver for the TideLink CAM-based address translator.
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

#include "tidelink_addr_trans.h"

/* ── Initialisation ─────────────────────────────────────────────────────── */

void tidelink_at_init(tidelink_at_t *at, uint32_t base)
{
    at->ch = (TIDELINK_ADDR_TRANS_CH_TypeDef *)base;
}

/* ── Rule Management ────────────────────────────────────────────────────── */

void tidelink_at_set_rule(tidelink_at_t *at, uint32_t idx,
                           uint8_t match, uint8_t replace)
{
    if (idx >= TIDELINK_AT_NUM_RULES)
        return;

    at->ch->RULE[idx] = TIDELINK_AT_RULE_ENABLE_Msk
                       | ((uint32_t)match   << TIDELINK_AT_RULE_MATCH_BYTE_Pos)
                       | ((uint32_t)replace << TIDELINK_AT_RULE_REPLACE_BYTE_Pos);
}

void tidelink_at_clear_rule(tidelink_at_t *at, uint32_t idx)
{
    if (idx >= TIDELINK_AT_NUM_RULES)
        return;

    at->ch->RULE[idx] = 0U;
}

void tidelink_at_clear_all_rules(tidelink_at_t *at)
{
    uint32_t i;

    for (i = 0U; i < TIDELINK_AT_NUM_RULES; i++) {
        at->ch->RULE[i] = 0U;
    }
}
