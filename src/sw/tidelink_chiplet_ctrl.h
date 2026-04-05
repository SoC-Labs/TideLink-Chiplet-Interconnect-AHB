/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Chiplet Controller Driver — Header
 *
 * CMSIS-style bare-metal driver for the generic chiplet controller
 * (axi_chiplet_controller) role selection and I2C sideband configuration.
 *
 * The controller registers occupy Region 4 of the TideLink APB space
 * (offsets 0x2080-0x208F from the unified APB base).
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

#ifndef TIDELINK_CHIPLET_CTRL_H
#define TIDELINK_CHIPLET_CTRL_H

#include <stdint.h>
#include <stdbool.h>

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

/* ── Controller Role Register Struct (Region 4, base + 0x2080) ──────────── */

typedef struct {
    __IO uint32_t ROLE_CFG;         /* 0x2080: [0]=role [1]=role_lock (W1S)   */
    __I  uint32_t ROLE_STATUS;      /* 0x2084: [0]=eff_role [1]=locked ...    */
    __IO uint32_t I2C_SLV_ADDR;     /* 0x2088: [6:0]=I2C slave device addr   */
    __IO uint32_t I2C_PRESCALE;     /* 0x208C: [15:0]=I2C master prescaler   */
} TIDELINK_CTRL_TypeDef;

/* ── ROLE_CFG (0x2080) bit definitions ──────────────────────────────────── */

#define TIDELINK_CTRL_ROLE_CFG_ROLE_Pos          0U
#define TIDELINK_CTRL_ROLE_CFG_ROLE_Msk          (1UL << 0U)
#define TIDELINK_CTRL_ROLE_CFG_LOCK_Pos          1U
#define TIDELINK_CTRL_ROLE_CFG_LOCK_Msk          (1UL << 1U)

/* ── ROLE_STATUS (0x2084) bit definitions ───────────────────────────────── */

#define TIDELINK_CTRL_ROLE_STATUS_EFF_ROLE_Pos   0U
#define TIDELINK_CTRL_ROLE_STATUS_EFF_ROLE_Msk   (1UL << 0U)
#define TIDELINK_CTRL_ROLE_STATUS_LOCKED_Pos     1U
#define TIDELINK_CTRL_ROLE_STATUS_LOCKED_Msk     (1UL << 1U)
#define TIDELINK_CTRL_ROLE_STATUS_I2C_BUSY_Pos   2U
#define TIDELINK_CTRL_ROLE_STATUS_I2C_BUSY_Msk   (1UL << 2U)
#define TIDELINK_CTRL_ROLE_STATUS_I2C_ADDR_Pos   3U
#define TIDELINK_CTRL_ROLE_STATUS_I2C_ADDR_Msk   (1UL << 3U)

/* ── I2C_SLV_ADDR (0x2088) bit definitions ─────────────────────────────── */

#define TIDELINK_CTRL_I2C_SLV_ADDR_Pos           0U
#define TIDELINK_CTRL_I2C_SLV_ADDR_Msk           (0x7FUL << 0U)

/* ── I2C_PRESCALE (0x208C) bit definitions ──────────────────────────────── */

#define TIDELINK_CTRL_I2C_PRESCALE_Pos           0U
#define TIDELINK_CTRL_I2C_PRESCALE_Msk           (0xFFFFUL << 0U)

/* ── Role values ────────────────────────────────────────────────────────── */

#define TIDELINK_ROLE_MASTER   0U
#define TIDELINK_ROLE_SLAVE    1U

/* ── Unified APB offset for controller region ───────────────────────────── */

#define TIDELINK_CTRL_APB_OFFSET   0x2080U

/* ── Driver handle ──────────────────────────────────────────────────────── */

typedef struct {
    TIDELINK_CTRL_TypeDef *ctrl;      /* Controller role register base        */
    __IO uint32_t         *wlink;     /* Wlink register base (offset 0x0000)  */
    __IO uint32_t         *tl_cfg;    /* TideLink config base (offset 0x2000) */
} tidelink_ctrl_t;

/* ── Wlink link register offsets (from wlink base) ──────────────────────── */

#define WLINK_LINK_BASE              0x0200U
#define WLINK_REG_ENABLE_RESET       (WLINK_LINK_BASE + 0x08U)
#define WLINK_REG_LINK_STATUS        (WLINK_LINK_BASE + 0x34U)

#define WLINK_LINK_STATUS_ERROR_Pos     2U
#define WLINK_LINK_STATUS_ERROR_Msk     (1UL << 2U)
#define WLINK_LINK_STATUS_TX_ACTIVE_Pos 3U
#define WLINK_LINK_STATUS_TX_ACTIVE_Msk (1UL << 3U)
#define WLINK_LINK_STATUS_RX_VALID_Pos  4U
#define WLINK_LINK_STATUS_RX_VALID_Msk  (1UL << 4U)

/* ── TideLink config register offsets (from tl_cfg base) ────────────────── */

#define TL_REG_PAIR_BASE              0x000U
#define TL_REG_DOORBELL               0x014U
#define TL_REG_PAIR_CREDIT_EN         0x030U

/* ═══════════════════════════════════════════════════════════════════════════
 * API
 * ═══════════════════════════════════════════════════════════════════════════*/

/**
 * Initialise chiplet controller driver handle.
 *
 * @param ctx       Pointer to caller-allocated tidelink_ctrl_t.
 * @param apb_base  Physical base address of the unified APB port.
 */
void tidelink_ctrl_init(tidelink_ctrl_t *ctx, uint32_t apb_base);

/** Read the effective role (0=master, 1=slave). */
uint32_t tidelink_ctrl_get_role(const tidelink_ctrl_t *ctx);

/** Returns true if the role is locked and Wlink is active. */
bool tidelink_ctrl_is_locked(const tidelink_ctrl_t *ctx);

/**
 * Set role before locking. Returns 0 on success, -1 if already locked.
 */
int tidelink_ctrl_set_role(const tidelink_ctrl_t *ctx, uint32_t role);

/**
 * Lock the role and release Wlink from reset.
 * Returns 0 on success, -1 if already locked.
 */
int tidelink_ctrl_lock_role(const tidelink_ctrl_t *ctx);

/**
 * Set role + lock in a single write. Returns 0 on success, -1 if locked.
 */
int tidelink_ctrl_configure_and_lock(const tidelink_ctrl_t *ctx,
                                      uint32_t role);

/** Set the I2C slave device address (7-bit, slave mode). */
void tidelink_ctrl_set_i2c_addr(const tidelink_ctrl_t *ctx, uint8_t addr);

/** Set the I2C master clock prescaler (master mode). */
void tidelink_ctrl_set_i2c_prescale(const tidelink_ctrl_t *ctx,
                                     uint16_t prescale);

/**
 * Wait for Wlink link to become active (TX+RX).
 * Returns 0 on success, -1 on error or timeout.
 */
int tidelink_ctrl_wait_link_up(const tidelink_ctrl_t *ctx,
                                uint32_t timeout_cycles);

/**
 * Full link bring-up sequence:
 *   1. Set role and lock (releases Wlink from POR hold)
 *   2. Wait for PHY link training
 *   3. Configure TideLink pair base address
 *   4. Enable pair credit counter
 *   5. Ring doorbell to send initial credits
 *
 * Returns 0 on success, -1 on failure.
 */
int tidelink_ctrl_link_bringup(const tidelink_ctrl_t *ctx,
                                uint32_t role,
                                uint32_t pair_base_addr,
                                uint32_t timeout_cycles);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_CHIPLET_CTRL_H */
