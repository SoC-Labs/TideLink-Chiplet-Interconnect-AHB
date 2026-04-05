/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Chiplet Controller Driver — Implementation
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include "tidelink_chiplet_ctrl.h"

/* ── Register helpers ──────────────────────────────────────────────────── */

static inline uint32_t wlink_read(const tidelink_ctrl_t *ctx, uint32_t offset)
{
    return ctx->wlink[offset >> 2];
}

static inline void tl_write(const tidelink_ctrl_t *ctx,
                             uint32_t offset, uint32_t val)
{
    ctx->tl_cfg[offset >> 2] = val;
}

/* ── API implementation ────────────────────────────────────────────────── */

void tidelink_ctrl_init(tidelink_ctrl_t *ctx, uint32_t apb_base)
{
    ctx->wlink  = (__IO uint32_t *)(uintptr_t)(apb_base + 0x0000U);
    ctx->tl_cfg = (__IO uint32_t *)(uintptr_t)(apb_base + 0x2000U);
    ctx->ctrl   = (TIDELINK_CTRL_TypeDef *)(uintptr_t)(apb_base
                                                        + TIDELINK_CTRL_APB_OFFSET);
}

uint32_t tidelink_ctrl_get_role(const tidelink_ctrl_t *ctx)
{
    return (ctx->ctrl->ROLE_STATUS & TIDELINK_CTRL_ROLE_STATUS_EFF_ROLE_Msk)
           >> TIDELINK_CTRL_ROLE_STATUS_EFF_ROLE_Pos;
}

bool tidelink_ctrl_is_locked(const tidelink_ctrl_t *ctx)
{
    return (ctx->ctrl->ROLE_STATUS & TIDELINK_CTRL_ROLE_STATUS_LOCKED_Msk) != 0U;
}

int tidelink_ctrl_set_role(const tidelink_ctrl_t *ctx, uint32_t role)
{
    if (tidelink_ctrl_is_locked(ctx))
        return -1;

    uint32_t cfg = ctx->ctrl->ROLE_CFG;
    cfg = (cfg & ~TIDELINK_CTRL_ROLE_CFG_ROLE_Msk)
        | ((role << TIDELINK_CTRL_ROLE_CFG_ROLE_Pos) & TIDELINK_CTRL_ROLE_CFG_ROLE_Msk);
    ctx->ctrl->ROLE_CFG = cfg;
    return 0;
}

int tidelink_ctrl_lock_role(const tidelink_ctrl_t *ctx)
{
    if (tidelink_ctrl_is_locked(ctx))
        return -1;

    ctx->ctrl->ROLE_CFG = ctx->ctrl->ROLE_CFG | TIDELINK_CTRL_ROLE_CFG_LOCK_Msk;
    return 0;
}

int tidelink_ctrl_configure_and_lock(const tidelink_ctrl_t *ctx,
                                      uint32_t role)
{
    if (tidelink_ctrl_is_locked(ctx))
        return -1;

    ctx->ctrl->ROLE_CFG = ((role << TIDELINK_CTRL_ROLE_CFG_ROLE_Pos)
                            & TIDELINK_CTRL_ROLE_CFG_ROLE_Msk)
                          | TIDELINK_CTRL_ROLE_CFG_LOCK_Msk;
    return 0;
}

void tidelink_ctrl_set_i2c_addr(const tidelink_ctrl_t *ctx, uint8_t addr)
{
    ctx->ctrl->I2C_SLV_ADDR = (uint32_t)addr & TIDELINK_CTRL_I2C_SLV_ADDR_Msk;
}

void tidelink_ctrl_set_i2c_prescale(const tidelink_ctrl_t *ctx,
                                     uint16_t prescale)
{
    ctx->ctrl->I2C_PRESCALE = (uint32_t)prescale & TIDELINK_CTRL_I2C_PRESCALE_Msk;
}

int tidelink_ctrl_wait_link_up(const tidelink_ctrl_t *ctx,
                                uint32_t timeout_cycles)
{
    for (uint32_t i = 0; i < timeout_cycles; i++) {
        uint32_t status = wlink_read(ctx, WLINK_REG_LINK_STATUS);

        if ((status & WLINK_LINK_STATUS_TX_ACTIVE_Msk)
            && (status & WLINK_LINK_STATUS_RX_VALID_Msk))
            return 0;

        if (status & WLINK_LINK_STATUS_ERROR_Msk)
            return -1;
    }
    return -1;  /* timeout */
}

int tidelink_ctrl_link_bringup(const tidelink_ctrl_t *ctx,
                                uint32_t role,
                                uint32_t pair_base_addr,
                                uint32_t timeout_cycles)
{
    int rc;

    /* 1. Set role and lock — releases Wlink from POR hold */
    rc = tidelink_ctrl_configure_and_lock(ctx, role);
    if (rc != 0)
        return rc;

    /* 2. Wait for PHY link training to complete */
    rc = tidelink_ctrl_wait_link_up(ctx, timeout_cycles);
    if (rc != 0)
        return rc;

    /* 3. Configure TideLink pair base address */
    tl_write(ctx, TL_REG_PAIR_BASE, pair_base_addr);

    /* 4. Enable pair credit counter */
    tl_write(ctx, TL_REG_PAIR_CREDIT_EN, 1U);

    /* 5. Ring doorbell to send initial credits to peer */
    tl_write(ctx, TL_REG_DOORBELL, 1U);

    return 0;
}
