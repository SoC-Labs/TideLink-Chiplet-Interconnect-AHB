/*-----------------------------------------------------------------------------
 * SoCLabs Wlink Chiplet Controller — Register Definitions (Header-Only)
 *
 * Register addresses and bit definitions for the Wlink chiplet controller
 * (axi-chiplet-controller). These registers occupy the lower half of the
 * unified APB space (0x0000-0x1FFF) accessible via the TideLink config
 * AHB slave port.
 *
 * Based on python/tidelink/regs.py and Wlink Scala source.
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

#ifndef WLINK_H
#define WLINK_H

#include <stdint.h>

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

/* ═══════════════════════════════════════════════════════════════════════════
 * PHY Registers (0x0000-0x01FF)
 * ═══════════════════════════════════════════════════════════════════════════*/

#define WLINK_PHY_BASE                0x0000U

#define WLINK_PHY_GENERAL_CTRL        (WLINK_PHY_BASE + 0x00U)
#define WLINK_PHY_PRE_DIVIDER         (WLINK_PHY_BASE + 0x04U)
#define WLINK_PHY_POST_DIVIDER        (WLINK_PHY_BASE + 0x08U)
#define WLINK_PHY_PLL_CTRL            (WLINK_PHY_BASE + 0x0CU)

/* PHY General Controls (0x00) */
#define WLINK_PHY_PRE_COUNT_Pos       0U
#define WLINK_PHY_PRE_COUNT_Msk       (0xFFUL << 0U)
#define WLINK_PHY_POST_COUNT_Pos      8U
#define WLINK_PHY_POST_COUNT_Msk      (0xFFUL << 8U)
#define WLINK_PHY_RX_POLARITY_Pos     16U
#define WLINK_PHY_RX_POLARITY_Msk     (1UL << 16U)

/* PHY PLL Enable/Lock (0x0C) */
#define WLINK_PHY_PLL_ENABLE_Pos      0U
#define WLINK_PHY_PLL_ENABLE_Msk      (1UL << 0U)
#define WLINK_PHY_PLL_LOCKED_Pos      8U
#define WLINK_PHY_PLL_LOCKED_Msk      (1UL << 8U)

/* ═══════════════════════════════════════════════════════════════════════════
 * Link Registers (0x0200-0x03FF)
 * ═══════════════════════════════════════════════════════════════════════════*/

#define WLINK_LINK_BASE               0x0200U

#define WLINK_LINK_CAPABILITIES       (WLINK_LINK_BASE + 0x00U)
#define WLINK_LINK_PHY_VERSION        (WLINK_LINK_BASE + 0x04U)
#define WLINK_LINK_ENABLE_RESET       (WLINK_LINK_BASE + 0x08U)
#define WLINK_LINK_ACTIVE_LANES       (WLINK_LINK_BASE + 0x10U)
#define WLINK_LINK_PSTATE_CTRL        (WLINK_LINK_BASE + 0x30U)
#define WLINK_LINK_STATUS             (WLINK_LINK_BASE + 0x34U)
#define WLINK_LINK_ERROR_INJECT       (WLINK_LINK_BASE + 0x3CU)
#define WLINK_LINK_INTERRUPTS         (WLINK_LINK_BASE + 0x40U)

/* Link Enable/Reset (0x08) */
#define WLINK_LINK_SWI_ENABLE_Pos     0U
#define WLINK_LINK_SWI_ENABLE_Msk     (1UL << 0U)
#define WLINK_LINK_LL_TX_ENABLE_Pos   1U
#define WLINK_LINK_LL_TX_ENABLE_Msk   (1UL << 1U)
#define WLINK_LINK_LL_RX_ENABLE_Pos   2U
#define WLINK_LINK_LL_RX_ENABLE_Msk   (1UL << 2U)
#define WLINK_LINK_SW_RESET_Pos       3U
#define WLINK_LINK_SW_RESET_Msk       (1UL << 3U)
#define WLINK_LINK_MAX_SP_ID_Pos      8U
#define WLINK_LINK_MAX_SP_ID_Msk      (0xFFUL << 8U)
#define WLINK_LINK_PREQ_DATA_ID_Pos   16U
#define WLINK_LINK_PREQ_DATA_ID_Msk   (0xFFUL << 16U)

/* Link Status (0x34) */
#define WLINK_LINK_SB_RESET_Pos       0U
#define WLINK_LINK_SB_RESET_Msk       (1UL << 0U)
#define WLINK_LINK_SB_RESET_MUX_Pos   1U
#define WLINK_LINK_SB_RESET_MUX_Msk   (1UL << 1U)
#define WLINK_LINK_IN_ERROR_Pos        2U
#define WLINK_LINK_IN_ERROR_Msk        (1UL << 2U)
#define WLINK_LINK_TX_READY_Pos        3U
#define WLINK_LINK_TX_READY_Msk        (1UL << 3U)
#define WLINK_LINK_RX_DATA_VALID_Pos   4U
#define WLINK_LINK_RX_DATA_VALID_Msk   (1UL << 4U)

/* Link Interrupts (0x40) */
#define WLINK_LINK_CRC_ERRORS_Pos           0U
#define WLINK_LINK_CRC_ERRORS_Msk           (1UL << 0U)
#define WLINK_LINK_CRC_ERRORS_EN_Pos        1U
#define WLINK_LINK_CRC_ERRORS_EN_Msk        (1UL << 1U)
#define WLINK_LINK_ECC_CORRECTED_Pos        8U
#define WLINK_LINK_ECC_CORRECTED_Msk        (1UL << 8U)
#define WLINK_LINK_ECC_CORRECTED_EN_Pos     9U
#define WLINK_LINK_ECC_CORRECTED_EN_Msk     (1UL << 9U)
#define WLINK_LINK_ECC_CORRUPTED_Pos        16U
#define WLINK_LINK_ECC_CORRUPTED_Msk        (1UL << 16U)
#define WLINK_LINK_ECC_CORRUPTED_EN_Pos     17U
#define WLINK_LINK_ECC_CORRUPTED_EN_Msk     (1UL << 17U)

/* ═══════════════════════════════════════════════════════════════════════════
 * Flow Control (FC) Node Registers (0x1000-0x17FF)
 *
 * 7 FC nodes, each with a fixed register stride. Per-node SM Control
 * register at offset 0x14 within each node's block.
 * ═══════════════════════════════════════════════════════════════════════════*/

#define WLINK_FC_BASE                 0x1000U
#define WLINK_FC_NODE_STRIDE          0x0100U

/* FC Node base addresses */
#define WLINK_FC_AXI_AW_BASE         (WLINK_FC_BASE + 0x000U)
#define WLINK_FC_AXI_W_BASE          (WLINK_FC_BASE + 0x100U)
#define WLINK_FC_AXI_B_BASE          (WLINK_FC_BASE + 0x200U)
#define WLINK_FC_AXI_AR_BASE         (WLINK_FC_BASE + 0x300U)
#define WLINK_FC_AXI_R_BASE          (WLINK_FC_BASE + 0x400U)
#define WLINK_FC_GENERAL_BASE         (WLINK_FC_BASE + 0x600U)
#define WLINK_FC_TIDELINK_BASE        (WLINK_FC_BASE + 0x700U)

/* Per-node register offsets (relative to node base) */
#define WLINK_FC_ID_CONTROL           0x00U
#define WLINK_FC_DATA_ID_CONTROL      0x04U
#define WLINK_FC_TX_FIFO_STATUS       0x08U
#define WLINK_FC_ACK_NACK_FIFO        0x10U
#define WLINK_FC_SM_CONTROL           0x14U
#define WLINK_FC_CRC_ERRORS           0x20U

/* SM Control absolute addresses (convenience, matches regs.py) */
#define WLINK_FC_AW_SM_CONTROL        (WLINK_FC_AXI_AW_BASE  + WLINK_FC_SM_CONTROL)
#define WLINK_FC_W_SM_CONTROL         (WLINK_FC_AXI_W_BASE   + WLINK_FC_SM_CONTROL)
#define WLINK_FC_B_SM_CONTROL         (WLINK_FC_AXI_B_BASE   + WLINK_FC_SM_CONTROL)
#define WLINK_FC_AR_SM_CONTROL        (WLINK_FC_AXI_AR_BASE  + WLINK_FC_SM_CONTROL)
#define WLINK_FC_R_SM_CONTROL         (WLINK_FC_AXI_R_BASE   + WLINK_FC_SM_CONTROL)
#define WLINK_FC_GENERAL_SM_CONTROL   (WLINK_FC_GENERAL_BASE  + WLINK_FC_SM_CONTROL)
#define WLINK_FC_TIDELINK_SM_CONTROL  (WLINK_FC_TIDELINK_BASE + WLINK_FC_SM_CONTROL)

/* SM Control bit positions */
#define WLINK_FC_SM_IDLE_CYCLES_Pos        0U
#define WLINK_FC_SM_IDLE_CYCLES_Msk        (0xFFUL << 0U)
#define WLINK_FC_SM_ACK_INTERVAL_Pos       8U
#define WLINK_FC_SM_ACK_INTERVAL_Msk       (0xFFUL << 8U)
#define WLINK_FC_SM_DISABLE_CRC_Pos        16U
#define WLINK_FC_SM_DISABLE_CRC_Msk        (1UL << 16U)

/* ── TideLink FC node data IDs ──────────────────────────────────────────── */

#define WLINK_FC_TIDELINK_DATA_ID     0xA1U
#define WLINK_FC_PTP_DATA_ID          0xA2U

/* ── Inline convenience helpers ─────────────────────────────────────────── */

/**
 * Read a Wlink register via the unified APB space.
 *
 * @param apb_base  Physical base of the unified APB slave (Wlink at 0x0000).
 * @param offset    Register offset (e.g., WLINK_FC_TIDELINK_SM_CONTROL).
 */
static inline uint32_t wlink_read(uint32_t apb_base, uint32_t offset)
{
    return *((__I uint32_t *)(apb_base + offset));
}

/**
 * Write a Wlink register via the unified APB space.
 */
static inline void wlink_write(uint32_t apb_base, uint32_t offset,
                                uint32_t value)
{
    *((__IO uint32_t *)(apb_base + offset)) = value;
}

/**
 * Disable CRC checking on a specific FC node (saves bandwidth at GPIO speeds).
 *
 * @param apb_base      Physical base of the unified APB slave.
 * @param sm_ctrl_addr  SM Control register address (e.g., WLINK_FC_TIDELINK_SM_CONTROL).
 */
static inline void wlink_fc_disable_crc(uint32_t apb_base,
                                         uint32_t sm_ctrl_addr)
{
    __IO uint32_t *reg = (__IO uint32_t *)(apb_base + sm_ctrl_addr);
    *reg |= WLINK_FC_SM_DISABLE_CRC_Msk;
}

/**
 * Enable CRC checking on a specific FC node.
 */
static inline void wlink_fc_enable_crc(uint32_t apb_base,
                                        uint32_t sm_ctrl_addr)
{
    __IO uint32_t *reg = (__IO uint32_t *)(apb_base + sm_ctrl_addr);
    *reg &= ~WLINK_FC_SM_DISABLE_CRC_Msk;
}

/**
 * Disable CRC on all 7 FC nodes at once.
 */
static inline void wlink_fc_disable_all_crc(uint32_t apb_base)
{
    wlink_fc_disable_crc(apb_base, WLINK_FC_AW_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_W_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_B_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_AR_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_R_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_GENERAL_SM_CONTROL);
    wlink_fc_disable_crc(apb_base, WLINK_FC_TIDELINK_SM_CONTROL);
}

/**
 * Check if the Wlink PLL is locked.
 */
static inline uint32_t wlink_pll_locked(uint32_t apb_base)
{
    return wlink_read(apb_base, WLINK_PHY_PLL_CTRL) & WLINK_PHY_PLL_LOCKED_Msk;
}

/**
 * Check if the Wlink link TX is ready.
 */
static inline uint32_t wlink_tx_ready(uint32_t apb_base)
{
    return wlink_read(apb_base, WLINK_LINK_STATUS) & WLINK_LINK_TX_READY_Msk;
}

#ifdef __cplusplus
}
#endif

#endif /* WLINK_H */
