/*-----------------------------------------------------------------------------
 * Auto-generated from SystemRDL — do not edit
 *
 * Source addrmap: wlink_regs
 * Generator:     scripts/rdl2c.py
 *-----------------------------------------------------------------------------*/

#ifndef WLINK_REGS_GENERATED_H
#define WLINK_REGS_GENERATED_H

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

#define WLINK_REGS_PHY_GENERAL_CONTROLS_OFFSET  0x000U
#define WLINK_REGS_PHY_PRE_DIVIDER_OFFSET  0x004U
#define WLINK_REGS_PHY_POST_DIVIDER_OFFSET  0x008U
#define WLINK_REGS_PHY_PLL_OFFSET  0x00CU
#define WLINK_REGS_LINK_CAPABILITIES_OFFSET  0x200U
#define WLINK_REGS_LINK_PHY_VERSION_OFFSET  0x204U
#define WLINK_REGS_LINK_ENABLE_RESET_OFFSET  0x208U
#define WLINK_REGS_LINK_ACTIVE_LANES_OFFSET  0x210U
#define WLINK_REGS_LINK_PSTATE_CONTROL_OFFSET  0x230U
#define WLINK_REGS_LINK_STATUS_OFFSET  0x234U
#define WLINK_REGS_LINK_ERROR_INJECTION_OFFSET  0x23CU
#define WLINK_REGS_LINK_INTERRUPTS_OFFSET  0x240U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_OFFSET  0x1000U
#define WLINK_REGS_FC_AXI_AW_DATA_ID_CONTROL_OFFSET  0x1004U
#define WLINK_REGS_FC_AXI_AW_TX_FIFO_OFFSET  0x1008U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_OFFSET  0x1010U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_OFFSET  0x1014U
#define WLINK_REGS_FC_AXI_AW_CRC_ERRORS_OFFSET  0x1020U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_OFFSET  0x1100U
#define WLINK_REGS_FC_AXI_W_DATA_ID_CONTROL_OFFSET  0x1104U
#define WLINK_REGS_FC_AXI_W_TX_FIFO_OFFSET  0x1108U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_OFFSET  0x1110U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_OFFSET  0x1114U
#define WLINK_REGS_FC_AXI_W_CRC_ERRORS_OFFSET  0x1120U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_OFFSET  0x1200U
#define WLINK_REGS_FC_AXI_B_DATA_ID_CONTROL_OFFSET  0x1204U
#define WLINK_REGS_FC_AXI_B_TX_FIFO_OFFSET  0x1208U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_OFFSET  0x1210U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_OFFSET  0x1214U
#define WLINK_REGS_FC_AXI_B_CRC_ERRORS_OFFSET  0x1220U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_OFFSET  0x1300U
#define WLINK_REGS_FC_AXI_AR_DATA_ID_CONTROL_OFFSET  0x1304U
#define WLINK_REGS_FC_AXI_AR_TX_FIFO_OFFSET  0x1308U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_OFFSET  0x1310U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_OFFSET  0x1314U
#define WLINK_REGS_FC_AXI_AR_CRC_ERRORS_OFFSET  0x1320U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_OFFSET  0x1400U
#define WLINK_REGS_FC_AXI_R_DATA_ID_CONTROL_OFFSET  0x1404U
#define WLINK_REGS_FC_AXI_R_TX_FIFO_OFFSET  0x1408U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_OFFSET  0x1410U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_OFFSET  0x1414U
#define WLINK_REGS_FC_AXI_R_CRC_ERRORS_OFFSET  0x1420U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_OFFSET  0x1600U
#define WLINK_REGS_FC_GENERAL_DATA_ID_CONTROL_OFFSET  0x1604U
#define WLINK_REGS_FC_GENERAL_TX_FIFO_OFFSET  0x1608U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_OFFSET  0x1610U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_OFFSET  0x1614U
#define WLINK_REGS_FC_GENERAL_CRC_ERRORS_OFFSET  0x1620U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_OFFSET  0x1700U
#define WLINK_REGS_FC_TIDELINK_DATA_ID_CONTROL_OFFSET  0x1704U
#define WLINK_REGS_FC_TIDELINK_TX_FIFO_OFFSET  0x1708U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_OFFSET  0x1710U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_OFFSET  0x1714U
#define WLINK_REGS_FC_TIDELINK_CRC_ERRORS_OFFSET  0x1720U

/* ───────────────────────────────────────────────────────────────────────── */
/* PHY_GENERAL_CONTROLS (0x000) — General controls for the SerDes PHY.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_PHY_GENERAL_CONTROLS_PRE_COUNT_Pos    0U
#define WLINK_REGS_PHY_GENERAL_CONTROLS_PRE_COUNT_Msk    (0xFFUL)
#define WLINK_REGS_PHY_GENERAL_CONTROLS_PRE_COUNT_Wid    8U
#define WLINK_REGS_PHY_GENERAL_CONTROLS_PRE_COUNT_Rst    0x1U

#define WLINK_REGS_PHY_GENERAL_CONTROLS_POST_COUNT_Pos    8U
#define WLINK_REGS_PHY_GENERAL_CONTROLS_POST_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_PHY_GENERAL_CONTROLS_POST_COUNT_Wid    8U
#define WLINK_REGS_PHY_GENERAL_CONTROLS_POST_COUNT_Rst    0x7U

#define WLINK_REGS_PHY_GENERAL_CONTROLS_RX_POLARITY_Pos    16U
#define WLINK_REGS_PHY_GENERAL_CONTROLS_RX_POLARITY_Msk    (0x10000UL)
#define WLINK_REGS_PHY_GENERAL_CONTROLS_RX_POLARITY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* PHY_PRE_DIVIDER (0x004) — Pre divider for SerDes PLL.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_PHY_PRE_DIVIDER_PRE_DIVIDER_Pos    0U
#define WLINK_REGS_PHY_PRE_DIVIDER_PRE_DIVIDER_Msk    (0xFUL)
#define WLINK_REGS_PHY_PRE_DIVIDER_PRE_DIVIDER_Wid    4U
#define WLINK_REGS_PHY_PRE_DIVIDER_PRE_DIVIDER_Rst    0x4U

/* ───────────────────────────────────────────────────────────────────────── */
/* PHY_POST_DIVIDER (0x008) — Post divider for SerDes PLL.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_PHY_POST_DIVIDER_POST_DIVIDER_Pos    0U
#define WLINK_REGS_PHY_POST_DIVIDER_POST_DIVIDER_Msk    (0xFUL)
#define WLINK_REGS_PHY_POST_DIVIDER_POST_DIVIDER_Wid    4U

/* ───────────────────────────────────────────────────────────────────────── */
/* PHY_PLL (0x00C) — PLL enable control and lock status.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_PHY_PLL_PLL_ENABLE_Pos    0U
#define WLINK_REGS_PHY_PLL_PLL_ENABLE_Msk    (0x1UL)

#define WLINK_REGS_PHY_PLL_PLL_LOCKED_Pos    8U
#define WLINK_REGS_PHY_PLL_PLL_LOCKED_Msk    (0x100UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_CAPABILITIES (0x200) — Read-only link capability information.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_CAPABILITIES_MAX_TX_LANES_Pos    0U
#define WLINK_REGS_LINK_CAPABILITIES_MAX_TX_LANES_Msk    (0xFFFFUL)
#define WLINK_REGS_LINK_CAPABILITIES_MAX_TX_LANES_Wid    16U
#define WLINK_REGS_LINK_CAPABILITIES_MAX_TX_LANES_Rst    0x8U

#define WLINK_REGS_LINK_CAPABILITIES_MAX_RX_LANES_Pos    16U
#define WLINK_REGS_LINK_CAPABILITIES_MAX_RX_LANES_Msk    (0xFFFF0000UL)
#define WLINK_REGS_LINK_CAPABILITIES_MAX_RX_LANES_Wid    16U
#define WLINK_REGS_LINK_CAPABILITIES_MAX_RX_LANES_Rst    0x8U

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_PHY_VERSION (0x204) — Read-only PHY implementation version.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_PHY_VERSION_VERSION_Pos    0U
#define WLINK_REGS_LINK_PHY_VERSION_VERSION_Msk    (0xFFFFFFFFUL)
#define WLINK_REGS_LINK_PHY_VERSION_VERSION_Wid    32U

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_ENABLE_RESET (0x208) — Link layer enable, reset, and short packet configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_ENABLE_RESET_SWI_ENABLE_Pos    0U
#define WLINK_REGS_LINK_ENABLE_RESET_SWI_ENABLE_Msk    (0x1UL)
#define WLINK_REGS_LINK_ENABLE_RESET_SWI_ENABLE_Rst    0x1U

#define WLINK_REGS_LINK_ENABLE_RESET_LL_TX_ENABLE_Pos    1U
#define WLINK_REGS_LINK_ENABLE_RESET_LL_TX_ENABLE_Msk    (0x2UL)
#define WLINK_REGS_LINK_ENABLE_RESET_LL_TX_ENABLE_Rst    0x1U

#define WLINK_REGS_LINK_ENABLE_RESET_LL_RX_ENABLE_Pos    2U
#define WLINK_REGS_LINK_ENABLE_RESET_LL_RX_ENABLE_Msk    (0x4UL)
#define WLINK_REGS_LINK_ENABLE_RESET_LL_RX_ENABLE_Rst    0x1U

#define WLINK_REGS_LINK_ENABLE_RESET_SW_RESET_Pos    3U
#define WLINK_REGS_LINK_ENABLE_RESET_SW_RESET_Msk    (0x8UL)

#define WLINK_REGS_LINK_ENABLE_RESET_MAX_SHORT_PACKET_Pos    8U
#define WLINK_REGS_LINK_ENABLE_RESET_MAX_SHORT_PACKET_Msk    (0xFF00UL)
#define WLINK_REGS_LINK_ENABLE_RESET_MAX_SHORT_PACKET_Wid    8U
#define WLINK_REGS_LINK_ENABLE_RESET_MAX_SHORT_PACKET_Rst    0x7FU

#define WLINK_REGS_LINK_ENABLE_RESET_PREQ_DATA_ID_Pos    16U
#define WLINK_REGS_LINK_ENABLE_RESET_PREQ_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_LINK_ENABLE_RESET_PREQ_DATA_ID_Wid    8U
#define WLINK_REGS_LINK_ENABLE_RESET_PREQ_DATA_ID_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_ACTIVE_LANES (0x210) — Number of active TX and RX lanes (value = lanes - 1).
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_TX_LANES_Pos    0U
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_TX_LANES_Msk    (0xFFFFUL)
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_TX_LANES_Wid    16U
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_TX_LANES_Rst    0x8U

#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_RX_LANES_Pos    16U
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_RX_LANES_Msk    (0xFFFF0000UL)
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_RX_LANES_Wid    16U
#define WLINK_REGS_LINK_ACTIVE_LANES_ACTIVE_RX_LANES_Rst    0x8U

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_PSTATE_CONTROL (0x230) — Power state transition timing configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_PSTATE_CONTROL_DELAY_CYCLES_Pos    0U
#define WLINK_REGS_LINK_PSTATE_CONTROL_DELAY_CYCLES_Msk    (0xFFFFUL)
#define WLINK_REGS_LINK_PSTATE_CONTROL_DELAY_CYCLES_Wid    16U
#define WLINK_REGS_LINK_PSTATE_CONTROL_DELAY_CYCLES_Rst    0x6A4U

#define WLINK_REGS_LINK_PSTATE_CONTROL_NUM_P_REQS_Pos    16U
#define WLINK_REGS_LINK_PSTATE_CONTROL_NUM_P_REQS_Msk    (0x70000UL)
#define WLINK_REGS_LINK_PSTATE_CONTROL_NUM_P_REQS_Wid    3U

#define WLINK_REGS_LINK_PSTATE_CONTROL_CYCLES_POST_REQS_Pos    24U
#define WLINK_REGS_LINK_PSTATE_CONTROL_CYCLES_POST_REQS_Msk    (0xFF000000UL)
#define WLINK_REGS_LINK_PSTATE_CONTROL_CYCLES_POST_REQS_Wid    8U
#define WLINK_REGS_LINK_PSTATE_CONTROL_CYCLES_POST_REQS_Rst    0xFFU

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_STATUS (0x234) — Link layer status and sideband reset control.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_STATUS_SB_RESET_Pos    0U
#define WLINK_REGS_LINK_STATUS_SB_RESET_Msk    (0x1UL)

#define WLINK_REGS_LINK_STATUS_SB_RESET_MUX_Pos    1U
#define WLINK_REGS_LINK_STATUS_SB_RESET_MUX_Msk    (0x2UL)

#define WLINK_REGS_LINK_STATUS_IN_ERROR_STATE_Pos    2U
#define WLINK_REGS_LINK_STATUS_IN_ERROR_STATE_Msk    (0x4UL)

#define WLINK_REGS_LINK_STATUS_TX_READY_Pos    3U
#define WLINK_REGS_LINK_STATUS_TX_READY_Msk    (0x8UL)

#define WLINK_REGS_LINK_STATUS_RX_DATA_VALID_Pos    4U
#define WLINK_REGS_LINK_STATUS_RX_DATA_VALID_Msk    (0x10UL)
#define WLINK_REGS_LINK_STATUS_RX_DATA_VALID_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_ERROR_INJECTION (0x23C) — Error injection controls for link-level testing.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_DATA_ID_Pos    0U
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_DATA_ID_Wid    8U

#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BYTE_Pos    8U
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BYTE_Msk    (0xFF00UL)
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BYTE_Wid    8U

#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BIT_Pos    16U
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BIT_Msk    (0x70000UL)
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_BIT_Wid    3U

#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_ENABLE_Pos    24U
#define WLINK_REGS_LINK_ERROR_INJECTION_ERR_INJECT_ENABLE_Msk    (0x1000000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* LINK_INTERRUPTS (0x240) — CRC and ECC error status and interrupt enable bits.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_LINK_INTERRUPTS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_LINK_INTERRUPTS_CRC_ERRORS_Msk    (0x1UL)

#define WLINK_REGS_LINK_INTERRUPTS_CRC_ERRORS_INT_EN_Pos    1U
#define WLINK_REGS_LINK_INTERRUPTS_CRC_ERRORS_INT_EN_Msk    (0x2UL)
#define WLINK_REGS_LINK_INTERRUPTS_CRC_ERRORS_INT_EN_Rst    0x1U

#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRECTED_Pos    8U
#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRECTED_Msk    (0x100UL)

#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRECTED_INT_EN_Pos    9U
#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRECTED_INT_EN_Msk    (0x200UL)

#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRUPTED_Pos    16U
#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRUPTED_Msk    (0x10000UL)

#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRUPTED_INT_EN_Pos    17U
#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRUPTED_INT_EN_Msk    (0x20000UL)
#define WLINK_REGS_LINK_INTERRUPTS_ECC_CORRUPTED_INT_EN_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_ID_CONTROL (0x1000) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AW_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_DATA_ID_CONTROL (0x1004) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_AXI_AW_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AW_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AW_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_TX_FIFO (0x1008) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_AW_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_AW_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_ACK_NACK_FIFO (0x1010) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_AW_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_SM_CONTROL (0x1014) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_AXI_AW_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AW_CRC_ERRORS (0x1020) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AW_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_AXI_AW_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_AXI_AW_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_ID_CONTROL (0x1100) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_AXI_W_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_AXI_W_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_W_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_DATA_ID_CONTROL (0x1104) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_AXI_W_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_W_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_W_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_TX_FIFO (0x1108) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_W_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_W_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_ACK_NACK_FIFO (0x1110) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_W_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_SM_CONTROL (0x1114) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_AXI_W_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_AXI_W_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_AXI_W_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_W_CRC_ERRORS (0x1120) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_W_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_AXI_W_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_AXI_W_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_ID_CONTROL (0x1200) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_AXI_B_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_AXI_B_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_B_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_DATA_ID_CONTROL (0x1204) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_AXI_B_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_B_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_B_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_TX_FIFO (0x1208) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_B_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_B_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_ACK_NACK_FIFO (0x1210) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_B_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_SM_CONTROL (0x1214) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_AXI_B_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_AXI_B_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_AXI_B_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_B_CRC_ERRORS (0x1220) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_B_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_AXI_B_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_AXI_B_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_ID_CONTROL (0x1300) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AR_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_DATA_ID_CONTROL (0x1304) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_AXI_AR_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AR_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_AR_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_TX_FIFO (0x1308) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_AR_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_AR_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_ACK_NACK_FIFO (0x1310) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_AR_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_SM_CONTROL (0x1314) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_AXI_AR_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_AR_CRC_ERRORS (0x1320) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_AR_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_AXI_AR_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_AXI_AR_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_ID_CONTROL (0x1400) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_AXI_R_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_AXI_R_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_R_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_DATA_ID_CONTROL (0x1404) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_AXI_R_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_R_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_AXI_R_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_TX_FIFO (0x1408) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_R_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_R_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_ACK_NACK_FIFO (0x1410) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_AXI_R_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_SM_CONTROL (0x1414) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_AXI_R_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_AXI_R_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_AXI_R_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_AXI_R_CRC_ERRORS (0x1420) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_AXI_R_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_AXI_R_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_AXI_R_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_ID_CONTROL (0x1600) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_GENERAL_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_GENERAL_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_GENERAL_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_DATA_ID_CONTROL (0x1604) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_GENERAL_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_GENERAL_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_GENERAL_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_TX_FIFO (0x1608) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_GENERAL_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_GENERAL_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_ACK_NACK_FIFO (0x1610) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_GENERAL_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_SM_CONTROL (0x1614) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_GENERAL_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_GENERAL_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_GENERAL_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_GENERAL_CRC_ERRORS (0x1620) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_GENERAL_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_GENERAL_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_GENERAL_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_ID_CONTROL (0x1700) — Data IDs used for credit negotiation and acknowledgement packets.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ID_Pos    0U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ID_Wid    8U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ID_Rst    0x8U

#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ACK_ID_Pos    8U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ACK_ID_Msk    (0xFF00UL)
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ACK_ID_Wid    8U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_CREDIT_ACK_ID_Rst    0x9U

#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_ACK_DATA_ID_Pos    16U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_ACK_DATA_ID_Msk    (0xFF0000UL)
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_ACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_ACK_DATA_ID_Rst    0xAU

#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_NACK_DATA_ID_Pos    24U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_NACK_DATA_ID_Msk    (0xFF000000UL)
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_NACK_DATA_ID_Wid    8U
#define WLINK_REGS_FC_TIDELINK_ID_CONTROL_NACK_DATA_ID_Rst    0xBU

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_DATA_ID_CONTROL (0x1704) — Data ID for long (data) packets on this FC channel.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_DATA_ID_CONTROL_DATA_ID_Pos    0U
#define WLINK_REGS_FC_TIDELINK_DATA_ID_CONTROL_DATA_ID_Msk    (0xFFUL)
#define WLINK_REGS_FC_TIDELINK_DATA_ID_CONTROL_DATA_ID_Wid    8U
#define WLINK_REGS_FC_TIDELINK_DATA_ID_CONTROL_DATA_ID_Rst    0x80U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_TX_FIFO (0x1708) — Status of the TX-side flow control FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_TX_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_TIDELINK_TX_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_TIDELINK_TX_FIFO_EMPTY_Rst    0x1U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_ACK_NACK_FIFO (0x1710) — Status of the ACK/NACK tracking FIFO.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_EMPTY_Pos    0U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_EMPTY_Msk    (0x1UL)
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_EMPTY_Rst    0x1U

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_FULL_Pos    1U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_FULL_Msk    (0x2UL)

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_HALF_FULL_Pos    2U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_HALF_FULL_Msk    (0x4UL)

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_Pos    3U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_Msk    (0x8UL)

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_Pos    4U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_Msk    (0x10UL)

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_LVL_Pos    8U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_LVL_Msk    (0x700UL)
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_LVL_Wid    3U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_FULL_LVL_Rst    0x6U

#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Pos    16U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Msk    (0x70000UL)
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Wid    3U
#define WLINK_REGS_FC_TIDELINK_ACK_NACK_FIFO_ALMOST_EMPTY_LVL_Rst    0x2U

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_SM_CONTROL (0x1714) — Flow control state machine configuration.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_LINK_EN_WAIT_Pos    0U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_LINK_EN_WAIT_Msk    (0xFFUL)
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_LINK_EN_WAIT_Wid    8U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_LINK_EN_WAIT_Rst    0x8U

#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_ACK_DLY_COUNT_Pos    8U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_ACK_DLY_COUNT_Msk    (0xFF00UL)
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_ACK_DLY_COUNT_Wid    8U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_ACK_DLY_COUNT_Rst    0x7U

#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_DISABLE_CRC_Pos    16U
#define WLINK_REGS_FC_TIDELINK_SM_CONTROL_DISABLE_CRC_Msk    (0x10000UL)

/* ───────────────────────────────────────────────────────────────────────── */
/* FC_TIDELINK_CRC_ERRORS (0x1720) — Count of CRC errors observed on this FC node.
 * ───────────────────────────────────────────────────────────────────────── */

#define WLINK_REGS_FC_TIDELINK_CRC_ERRORS_CRC_ERRORS_Pos    0U
#define WLINK_REGS_FC_TIDELINK_CRC_ERRORS_CRC_ERRORS_Msk    (0xFFFFUL)
#define WLINK_REGS_FC_TIDELINK_CRC_ERRORS_CRC_ERRORS_Wid    16U

/* ========================================================================= */
/* Register Struct
 * ========================================================================= */

typedef struct {
    __IO uint32_t PHY_GENERAL_CONTROLS;  /* 0x000 */
    __IO uint32_t PHY_PRE_DIVIDER;  /* 0x004 */
    __IO uint32_t PHY_POST_DIVIDER;  /* 0x008 */
    __IO uint32_t PHY_PLL;  /* 0x00C */
         uint32_t RESERVED_010[124];
    __I  uint32_t LINK_CAPABILITIES;  /* 0x200 */
    __I  uint32_t LINK_PHY_VERSION;  /* 0x204 */
    __IO uint32_t LINK_ENABLE_RESET;  /* 0x208 */
         uint32_t RESERVED_20C[1];
    __IO uint32_t LINK_ACTIVE_LANES;  /* 0x210 */
         uint32_t RESERVED_214[7];
    __IO uint32_t LINK_PSTATE_CONTROL;  /* 0x230 */
    __IO uint32_t LINK_STATUS;  /* 0x234 */
         uint32_t RESERVED_238[1];
    __IO uint32_t LINK_ERROR_INJECTION;  /* 0x23C */
    __IO uint32_t LINK_INTERRUPTS;  /* 0x240 */
         uint32_t RESERVED_244[879];
    __IO uint32_t FC_AXI_AW_ID_CONTROL;  /* 0x1000 */
    __IO uint32_t FC_AXI_AW_DATA_ID_CONTROL;  /* 0x1004 */
    __I  uint32_t FC_AXI_AW_TX_FIFO;  /* 0x1008 */
         uint32_t RESERVED_100C[1];
    __IO uint32_t FC_AXI_AW_ACK_NACK_FIFO;  /* 0x1010 */
    __IO uint32_t FC_AXI_AW_SM_CONTROL;  /* 0x1014 */
         uint32_t RESERVED_1018[2];
    __I  uint32_t FC_AXI_AW_CRC_ERRORS;  /* 0x1020 */
         uint32_t RESERVED_1024[55];
    __IO uint32_t FC_AXI_W_ID_CONTROL;  /* 0x1100 */
    __IO uint32_t FC_AXI_W_DATA_ID_CONTROL;  /* 0x1104 */
    __I  uint32_t FC_AXI_W_TX_FIFO;  /* 0x1108 */
         uint32_t RESERVED_110C[1];
    __IO uint32_t FC_AXI_W_ACK_NACK_FIFO;  /* 0x1110 */
    __IO uint32_t FC_AXI_W_SM_CONTROL;  /* 0x1114 */
         uint32_t RESERVED_1118[2];
    __I  uint32_t FC_AXI_W_CRC_ERRORS;  /* 0x1120 */
         uint32_t RESERVED_1124[55];
    __IO uint32_t FC_AXI_B_ID_CONTROL;  /* 0x1200 */
    __IO uint32_t FC_AXI_B_DATA_ID_CONTROL;  /* 0x1204 */
    __I  uint32_t FC_AXI_B_TX_FIFO;  /* 0x1208 */
         uint32_t RESERVED_120C[1];
    __IO uint32_t FC_AXI_B_ACK_NACK_FIFO;  /* 0x1210 */
    __IO uint32_t FC_AXI_B_SM_CONTROL;  /* 0x1214 */
         uint32_t RESERVED_1218[2];
    __I  uint32_t FC_AXI_B_CRC_ERRORS;  /* 0x1220 */
         uint32_t RESERVED_1224[55];
    __IO uint32_t FC_AXI_AR_ID_CONTROL;  /* 0x1300 */
    __IO uint32_t FC_AXI_AR_DATA_ID_CONTROL;  /* 0x1304 */
    __I  uint32_t FC_AXI_AR_TX_FIFO;  /* 0x1308 */
         uint32_t RESERVED_130C[1];
    __IO uint32_t FC_AXI_AR_ACK_NACK_FIFO;  /* 0x1310 */
    __IO uint32_t FC_AXI_AR_SM_CONTROL;  /* 0x1314 */
         uint32_t RESERVED_1318[2];
    __I  uint32_t FC_AXI_AR_CRC_ERRORS;  /* 0x1320 */
         uint32_t RESERVED_1324[55];
    __IO uint32_t FC_AXI_R_ID_CONTROL;  /* 0x1400 */
    __IO uint32_t FC_AXI_R_DATA_ID_CONTROL;  /* 0x1404 */
    __I  uint32_t FC_AXI_R_TX_FIFO;  /* 0x1408 */
         uint32_t RESERVED_140C[1];
    __IO uint32_t FC_AXI_R_ACK_NACK_FIFO;  /* 0x1410 */
    __IO uint32_t FC_AXI_R_SM_CONTROL;  /* 0x1414 */
         uint32_t RESERVED_1418[2];
    __I  uint32_t FC_AXI_R_CRC_ERRORS;  /* 0x1420 */
         uint32_t RESERVED_1424[119];
    __IO uint32_t FC_GENERAL_ID_CONTROL;  /* 0x1600 */
    __IO uint32_t FC_GENERAL_DATA_ID_CONTROL;  /* 0x1604 */
    __I  uint32_t FC_GENERAL_TX_FIFO;  /* 0x1608 */
         uint32_t RESERVED_160C[1];
    __IO uint32_t FC_GENERAL_ACK_NACK_FIFO;  /* 0x1610 */
    __IO uint32_t FC_GENERAL_SM_CONTROL;  /* 0x1614 */
         uint32_t RESERVED_1618[2];
    __I  uint32_t FC_GENERAL_CRC_ERRORS;  /* 0x1620 */
         uint32_t RESERVED_1624[55];
    __IO uint32_t FC_TIDELINK_ID_CONTROL;  /* 0x1700 */
    __IO uint32_t FC_TIDELINK_DATA_ID_CONTROL;  /* 0x1704 */
    __I  uint32_t FC_TIDELINK_TX_FIFO;  /* 0x1708 */
         uint32_t RESERVED_170C[1];
    __IO uint32_t FC_TIDELINK_ACK_NACK_FIFO;  /* 0x1710 */
    __IO uint32_t FC_TIDELINK_SM_CONTROL;  /* 0x1714 */
         uint32_t RESERVED_1718[2];
    __I  uint32_t FC_TIDELINK_CRC_ERRORS;  /* 0x1720 */
} WLINK_REGS_TypeDef;

#ifdef __cplusplus
}
#endif

#endif /* WLINK_REGS_GENERATED_H */
