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
#define TL_DBG_SCRATCH_OFFSET      0x0F8U
#define TL_PERF_ID_OFFSET          0x0FCU

/* ── PERF_CTRL bit definitions ─────────────────────────────────────────── */

#define TL_PERF_CTRL_ENABLE_Pos          0U
#define TL_PERF_CTRL_ENABLE_Msk          (1UL << 0U)
#define TL_PERF_CTRL_CLEAR_COUNTERS_Pos  1U
#define TL_PERF_CTRL_CLEAR_COUNTERS_Msk  (1UL << 1U)
#define TL_PERF_CTRL_CLEAR_TS_Pos        2U
#define TL_PERF_CTRL_CLEAR_TS_Msk        (1UL << 2U)
#define TL_PERF_CTRL_FREEZE_Pos          3U
#define TL_PERF_CTRL_FREEZE_Msk          (1UL << 3U)

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
 * Read the debug scratch register.
 */
uint32_t tl_perf_get_scratch(tl_perf_t *perf);

/**
 * Write the debug scratch register.
 */
void tl_perf_set_scratch(tl_perf_t *perf, uint32_t val);

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
