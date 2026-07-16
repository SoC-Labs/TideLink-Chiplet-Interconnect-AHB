/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Performance Monitor Driver — Header
 *
 * CMSIS-style bare-metal driver for the TideLink pipeline performance
 * counters and timestamp capture registers.
 *
 * The performance registers occupy offsets 0x0A0-0x0FC of the TideLink
 * APB config space. There is no auto-generated header for this block;
 * offsets are defined here directly.
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

#ifndef TIDELINK_PERF_H
#define TIDELINK_PERF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── CMSIS-style access qualifiers ─────────────────────────────────────── */

#ifndef __IO
#define __IO volatile
#endif
#ifndef __I
#define __I  volatile const
#endif

/* ── Register Offsets (relative to config base) ────────────────────────── */

#define TL_PERF_CTRL_OFFSET        0x0A0U
#define TL_TX_ORIGIN_NS_OFFSET     0x0A4U
#define TL_TX_ORIGIN_SEC_OFFSET    0x0A8U
#define TL_PERF_STATUS_OFFSET      0x0ACU
#define TL_TX_START_NS_OFFSET      0x0B0U
#define TL_TX_START_SEC_OFFSET     0x0B4U
#define TL_RX_FIRST_NS_OFFSET      0x0B8U
#define TL_RX_FIRST_SEC_OFFSET     0x0BCU
#define TL_RX_DONE_NS_OFFSET       0x0C0U
#define TL_RX_DONE_SEC_OFFSET      0x0C4U
#define TL_TX_PKT_COUNT_OFFSET     0x0C8U
#define TL_RX_PKT_COUNT_OFFSET     0x0CCU
#define TL_TX_WORD_COUNT_OFFSET    0x0D0U
#define TL_RX_WORD_COUNT_OFFSET    0x0D4U
#define TL_TX_STALL_COUNT_OFFSET   0x0D8U
#define TL_RX_STALL_COUNT_OFFSET   0x0DCU
#define TL_LINK_BUSY_COUNT_OFFSET  0x0E0U
#define TL_CREDIT_STARVE_OFFSET    0x0E4U
#define TL_SAMPLE_COUNT_OFFSET     0x0E8U
#define TL_DBG_LIVE_OFFSET         0x0ECU
#define TL_DBG_TX_INFLIGHT_OFFSET  0x0F0U
#define TL_DBG_RX_INFLIGHT_OFFSET  0x0F4U
/*
 * 0x0F8 is PERF_CONG_STATE (tidelink_perf.sv:502), not a scratch register — the
 * congestion state this block exports as `ewma_credit_o`, which tidelink_top
 * carries out as `tl_ewma_credit_o`. The old TL_DBG_SCRATCH_OFFSET name was
 * never usable: region 7 read back 0 wholesale until the apb_region decode fix.
 */
#define TL_PERF_CONG_STATE_OFFSET  0x0F8U
#define TL_PERF_ID_OFFSET          0x0FCU

/* ── PERF_CONG_STATE field definitions (tidelink_perf.sv:503-514) ───────── */
/* CREDIT_W = 13. Bits [15:13] and [31:21] are reserved. */

#define TL_PERF_CONG_EWMA_CREDIT_Pos     0U
#define TL_PERF_CONG_EWMA_CREDIT_Msk     (0x1FFFUL << 0U)   /* [12:0] ewma_q_r  */
#define TL_PERF_CONG_LEVEL_Pos           16U
#define TL_PERF_CONG_LEVEL_Msk           (0x3UL << 16U)     /* [17:16] level    */
#define TL_PERF_CONG_TREND_Pos           18U
#define TL_PERF_CONG_TREND_Msk           (0x3UL << 18U)     /* [19:18] trend    */
#define TL_PERF_CONG_STARVE_STICKY_Pos   20U
#define TL_PERF_CONG_STARVE_STICKY_Msk   (0x1UL << 20U)     /* [20] sticky      */

/* PERF_ID reads this constant ("PF" v1.0) once perf is reachable — use it as the
 * block-presence gate. It read 0 before the apb_region decode fix. */
#define TL_PERF_ID_VALUE           0x50460100U

/* ── PERF_CTRL bit definitions ─────────────────────────────────────────── */
/*
 * Bit positions below are the RTL's, verified against tidelink_perf.sv:
 *   [0] enable         -> perf_enable_r   (:440)   RW, read back at :464
 *   [1] freeze         -> perf_freeze_r   (:441)   RW, read back at :464
 *   [2] clear_counters -> `clear_counters` wire    (:240-241)  W1P (self-clearing)
 *   [3] clear_ts       -> clears *_ts_valid_r      (:146, :174, :205)  W1P
 *   [4] irq_enable     -> perf_irq_en_r   (:442)   RW, read back at :464
 *
 * These were WRONG for bits 1..3 — the old header had CLEAR_COUNTERS=1,
 * CLEAR_TS=2, FREEZE=3, i.e. rotated by one against the RTL, and omitted
 * irq_enable entirely. Writing the old TL_PERF_CTRL_FREEZE_Msk would have
 * cleared the timestamps instead of freezing, and the old
 * TL_PERF_CTRL_CLEAR_COUNTERS_Msk would have frozen the block instead of
 * clearing it. Nothing caught this because PERF_CTRL writes never reached the
 * RTL at all — see the apb_region decode fix in tidelink_apb_regs.sv.
 */

#define TL_PERF_CTRL_ENABLE_Pos          0U
#define TL_PERF_CTRL_ENABLE_Msk          (1UL << 0U)
#define TL_PERF_CTRL_FREEZE_Pos          1U
#define TL_PERF_CTRL_FREEZE_Msk          (1UL << 1U)
#define TL_PERF_CTRL_CLEAR_COUNTERS_Pos  2U
#define TL_PERF_CTRL_CLEAR_COUNTERS_Msk  (1UL << 2U)
#define TL_PERF_CTRL_CLEAR_TS_Pos        3U
#define TL_PERF_CTRL_CLEAR_TS_Msk        (1UL << 3U)
#define TL_PERF_CTRL_IRQ_ENABLE_Pos      4U
#define TL_PERF_CTRL_IRQ_ENABLE_Msk      (1UL << 4U)

/* ── Data Structures ───────────────────────────────────────────────────── */

/** Seconds + nanoseconds timestamp pair. */
typedef struct {
    uint32_t sec;
    uint32_t ns;
} tl_timestamp_t;

/** Snapshot of all performance counters. */
typedef struct {
    uint32_t tx_pkt_count;
    uint32_t rx_pkt_count;
    uint32_t tx_word_count;
    uint32_t rx_word_count;
    uint32_t tx_stall_count;
    uint32_t rx_stall_count;
    uint32_t link_busy_count;
    uint32_t credit_starve_count;
    uint32_t sample_count;
} tl_perf_counters_t;

/** Computed pipeline latency breakdown. */
typedef struct {
    uint32_t sw_latency_ns;    /* TX_ORIGIN  -> TX_START  (software)     */
    uint32_t link_latency_ns;  /* TX_START   -> RX_FIRST  (link + PHY)   */
    uint32_t fifo_time_ns;     /* RX_FIRST   -> RX_DONE   (FIFO drain)   */
    uint32_t total_ns;         /* TX_ORIGIN  -> RX_DONE   (end-to-end)   */
} tl_pipeline_result_t;

/* ── Driver handle ─────────────────────────────────────────────────────── */

typedef struct {
    __IO uint32_t *base;  /* Config register base (same as tidelink cfg) */
} tl_perf_t;

/* ── Initialisation ────────────────────────────────────────────────────── */

/**
 * Initialise a performance monitor driver handle.
 *
 * @param perf      Pointer to caller-allocated tl_perf_t.
 * @param cfg_base  Physical base address of the TideLink config AHB slave.
 */
void tl_perf_init(tl_perf_t *perf, uint32_t cfg_base);

/* ── Control ───────────────────────────────────────────────────────────── */

/**
 * Enable the performance monitor, clearing all counters and timestamps.
 */
void tl_perf_enable(tl_perf_t *perf);

/**
 * Disable the performance monitor (counters stop incrementing).
 */
void tl_perf_disable(tl_perf_t *perf);

/**
 * Clear all performance counters (self-clearing bit).
 */
void tl_perf_clear_counters(tl_perf_t *perf);

/**
 * Clear all pipeline timestamps (self-clearing bit).
 */
void tl_perf_clear_timestamps(tl_perf_t *perf);

/* ── Origin Timestamp ──────────────────────────────────────────────────── */

/**
 * Set the TX origin timestamp (software-recorded transmit time).
 *
 * @param perf  Driver handle.
 * @param ts    Timestamp to write to TX_ORIGIN_NS / TX_ORIGIN_SEC.
 */
void tl_perf_set_origin_ts(tl_perf_t *perf, const tl_timestamp_t *ts);

/* ── Counter Readout ───────────────────────────────────────────────────── */

/**
 * Read all performance counters into a snapshot struct.
 *
 * Freezes the counters before reading, then unfreezes.
 *
 * @param perf  Driver handle.
 * @param out   Pointer to caller-allocated tl_perf_counters_t.
 */
void tl_perf_get_counters(tl_perf_t *perf, tl_perf_counters_t *out);

/**
 * Compute link utilisation as a percentage (0-100).
 *
 * @param perf  Driver handle.
 * @return Utilisation percentage, or 0 if sample_count is zero.
 */
uint32_t tl_perf_get_utilisation(tl_perf_t *perf);

/* ── Pipeline Latency ──────────────────────────────────────────────────── */

/**
 * Read all four pipeline timestamps and compute the latency breakdown.
 *
 * @param perf  Driver handle.
 * @param out   Pointer to caller-allocated tl_pipeline_result_t.
 */
void tl_perf_get_pipeline_ns(tl_perf_t *perf, tl_pipeline_result_t *out);

/* ── Debug ─────────────────────────────────────────────────────────────── */

/**
 * Read the PERF_ID register.
 *
 * @param perf  Driver handle.
 * @return 32-bit identification value.
 */
uint32_t tl_perf_get_id(tl_perf_t *perf);

/**
 * Read PERF_CONG_STATE (0x0F8) raw.
 *
 * Decode with the TL_PERF_CONG_* masks above. [12:0] is the EWMA credit —
 * the same value tidelink_top exports as `tl_ewma_credit_o`.
 *
 * Replaces tl_perf_get_scratch()/tl_perf_set_scratch(), which were built on a
 * misreading of this address. 0x0F8 is a read-only congestion-state register,
 * not a scratch register: the RTL has no write path for perf region 7 at all,
 * so tl_perf_set_scratch() wrote into the void, and tl_perf_get_scratch()
 * returned congestion state under a misleading name. Neither had any caller.
 *
 * @param perf  Driver handle.
 * @return Raw PERF_CONG_STATE value.
 */
uint32_t tl_perf_get_cong_state(tl_perf_t *perf);

/**
 * Read just the EWMA credit field of PERF_CONG_STATE.
 *
 * Requires perf to be enabled (TL_PERF_CTRL_ENABLE_Msk) — the EWMA only
 * advances while perf_active is high, so this reads 0 on a disabled block.
 *
 * @param perf  Driver handle.
 * @return 13-bit EWMA credit.
 */
uint32_t tl_perf_get_ewma_credit(tl_perf_t *perf);

/**
 * Read the debug live status register.
 */
uint32_t tl_perf_get_live(tl_perf_t *perf);

/**
 * Read the TX in-flight count (debug).
 */
uint32_t tl_perf_get_tx_inflight(tl_perf_t *perf);

/**
 * Read the RX in-flight count (debug).
 */
uint32_t tl_perf_get_rx_inflight(tl_perf_t *perf);

/**
 * Dump all performance registers to stdout via printf.
 * Intended for debug builds only.
 */
void tl_perf_dump(tl_perf_t *perf);

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PERF_H */
