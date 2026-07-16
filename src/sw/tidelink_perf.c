/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Performance Monitor Driver — Implementation
 *
 * Bare-metal driver for the TideLink pipeline performance counters and
 * timestamp capture registers. Targets ARM Cortex-M0.
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include "tidelink_perf.h"

#include <stdio.h>   /* printf (tl_perf_dump only) */

/* ── Register access helpers ───────────────────────────────────────────── */

static inline uint32_t perf_read(const tl_perf_t *perf, uint32_t offset)
{
    return perf->base[offset >> 2];
}

static inline void perf_write(const tl_perf_t *perf,
                               uint32_t offset, uint32_t val)
{
    perf->base[offset >> 2] = val;
}

/* ── Nanosecond-aware timestamp difference ─────────────────────────────
 *
 * Computes (a - b) in nanoseconds for timestamps where ns < 1e9.
 * Returns the result truncated to 32 bits (sufficient for sub-second
 * pipeline measurements).
 * ----------------------------------------------------------------------- */

#define NS_PER_SEC  1000000000UL

static uint32_t ts_diff_ns(const tl_timestamp_t *a, const tl_timestamp_t *b)
{
    uint32_t sec_diff;
    uint32_t ns_a = a->ns;
    uint32_t ns_b = b->ns;

    sec_diff = a->sec - b->sec;

    if (ns_a >= ns_b) {
        return sec_diff * NS_PER_SEC + (ns_a - ns_b);
    } else {
        /* Nanosecond borrow: 1 second -> 1e9 ns */
        return (sec_diff - 1U) * NS_PER_SEC + (NS_PER_SEC + ns_a - ns_b);
    }
}

/* ── Initialisation ────────────────────────────────────────────────────── */

void tl_perf_init(tl_perf_t *perf, uint32_t cfg_base)
{
    perf->base = (__IO uint32_t *)(uintptr_t)cfg_base;

    /* Enable the monitor, clearing all counters and timestamps */
    perf_write(perf, TL_PERF_CTRL_OFFSET,
               TL_PERF_CTRL_ENABLE_Msk
               | TL_PERF_CTRL_CLEAR_COUNTERS_Msk
               | TL_PERF_CTRL_CLEAR_TS_Msk);
}

/* ── Control ───────────────────────────────────────────────────────────── */

void tl_perf_enable(tl_perf_t *perf)
{
    perf_write(perf, TL_PERF_CTRL_OFFSET, TL_PERF_CTRL_ENABLE_Msk);
}

void tl_perf_disable(tl_perf_t *perf)
{
    perf_write(perf, TL_PERF_CTRL_OFFSET, 0U);
}

void tl_perf_clear_counters(tl_perf_t *perf)
{
    uint32_t ctrl = perf_read(perf, TL_PERF_CTRL_OFFSET);
    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl | TL_PERF_CTRL_CLEAR_COUNTERS_Msk);
}

void tl_perf_clear_timestamps(tl_perf_t *perf)
{
    uint32_t ctrl = perf_read(perf, TL_PERF_CTRL_OFFSET);
    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl | TL_PERF_CTRL_CLEAR_TS_Msk);
}

/* ── Origin Timestamp ──────────────────────────────────────────────────── */

void tl_perf_set_origin_ts(tl_perf_t *perf, const tl_timestamp_t *ts)
{
    perf_write(perf, TL_TX_ORIGIN_NS_OFFSET,  ts->ns);
    perf_write(perf, TL_TX_ORIGIN_SEC_OFFSET, ts->sec);
}

/* ── Counter Readout ───────────────────────────────────────────────────── */

void tl_perf_get_counters(tl_perf_t *perf, tl_perf_counters_t *out)
{
    uint32_t ctrl;

    /* Freeze counters for a consistent snapshot */
    ctrl = perf_read(perf, TL_PERF_CTRL_OFFSET);
    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl | TL_PERF_CTRL_FREEZE_Msk);

    /* Read all counters */
    out->tx_pkt_count        = perf_read(perf, TL_TX_PKT_COUNT_OFFSET);
    out->rx_pkt_count        = perf_read(perf, TL_RX_PKT_COUNT_OFFSET);
    out->tx_word_count       = perf_read(perf, TL_TX_WORD_COUNT_OFFSET);
    out->rx_word_count       = perf_read(perf, TL_RX_WORD_COUNT_OFFSET);
    out->tx_stall_count      = perf_read(perf, TL_TX_STALL_COUNT_OFFSET);
    out->rx_stall_count      = perf_read(perf, TL_RX_STALL_COUNT_OFFSET);
    out->link_busy_count     = perf_read(perf, TL_LINK_BUSY_COUNT_OFFSET);
    out->credit_starve_count = perf_read(perf, TL_CREDIT_STARVE_OFFSET);
    out->sample_count        = perf_read(perf, TL_SAMPLE_COUNT_OFFSET);

    /* Unfreeze: restore the previous CTRL value (without FREEZE) */
    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl & ~TL_PERF_CTRL_FREEZE_Msk);
}

uint32_t tl_perf_get_utilisation(tl_perf_t *perf)
{
    uint32_t ctrl;
    uint32_t busy;
    uint32_t total;

    /* Freeze for a consistent pair of reads */
    ctrl = perf_read(perf, TL_PERF_CTRL_OFFSET);
    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl | TL_PERF_CTRL_FREEZE_Msk);

    busy  = perf_read(perf, TL_LINK_BUSY_COUNT_OFFSET);
    total = perf_read(perf, TL_SAMPLE_COUNT_OFFSET);

    perf_write(perf, TL_PERF_CTRL_OFFSET, ctrl & ~TL_PERF_CTRL_FREEZE_Msk);

    if (total == 0U)
        return 0U;

    return (busy * 100U) / total;
}

/* ── Pipeline Latency ──────────────────────────────────────────────────── */

void tl_perf_get_pipeline_ns(tl_perf_t *perf, tl_pipeline_result_t *out)
{
    tl_timestamp_t origin;
    tl_timestamp_t tx_start;
    tl_timestamp_t rx_first;
    tl_timestamp_t rx_done;

    /* Read all four timestamp pairs */
    origin.ns    = perf_read(perf, TL_TX_ORIGIN_NS_OFFSET);
    origin.sec   = perf_read(perf, TL_TX_ORIGIN_SEC_OFFSET);

    tx_start.ns  = perf_read(perf, TL_TX_START_NS_OFFSET);
    tx_start.sec = perf_read(perf, TL_TX_START_SEC_OFFSET);

    rx_first.ns  = perf_read(perf, TL_RX_FIRST_NS_OFFSET);
    rx_first.sec = perf_read(perf, TL_RX_FIRST_SEC_OFFSET);

    rx_done.ns   = perf_read(perf, TL_RX_DONE_NS_OFFSET);
    rx_done.sec  = perf_read(perf, TL_RX_DONE_SEC_OFFSET);

    /* Compute pipeline stage durations */
    out->sw_latency_ns   = ts_diff_ns(&tx_start, &origin);
    out->link_latency_ns = ts_diff_ns(&rx_first, &tx_start);
    out->fifo_time_ns    = ts_diff_ns(&rx_done,  &rx_first);
    out->total_ns        = ts_diff_ns(&rx_done,  &origin);
}

/* ── Debug ─────────────────────────────────────────────────────────────── */

uint32_t tl_perf_get_id(tl_perf_t *perf)
{
    return perf_read(perf, TL_PERF_ID_OFFSET);
}

uint32_t tl_perf_get_cong_state(tl_perf_t *perf)
{
    return perf_read(perf, TL_PERF_CONG_STATE_OFFSET);
}

uint32_t tl_perf_get_ewma_credit(tl_perf_t *perf)
{
    return (perf_read(perf, TL_PERF_CONG_STATE_OFFSET) &
            TL_PERF_CONG_EWMA_CREDIT_Msk) >> TL_PERF_CONG_EWMA_CREDIT_Pos;
}

uint32_t tl_perf_get_live(tl_perf_t *perf)
{
    return perf_read(perf, TL_DBG_LIVE_OFFSET);
}

uint32_t tl_perf_get_tx_inflight(tl_perf_t *perf)
{
    return perf_read(perf, TL_DBG_TX_INFLIGHT_OFFSET);
}

uint32_t tl_perf_get_rx_inflight(tl_perf_t *perf)
{
    return perf_read(perf, TL_DBG_RX_INFLIGHT_OFFSET);
}

void tl_perf_dump(tl_perf_t *perf)
{
    tl_perf_counters_t  ctr;
    tl_pipeline_result_t pl;

    tl_perf_get_counters(perf, &ctr);
    tl_perf_get_pipeline_ns(perf, &pl);

    printf("=== TideLink Performance Monitor ===\n");
    printf("PERF_CTRL       : 0x%08lX\n", (unsigned long)perf_read(perf, TL_PERF_CTRL_OFFSET));
    printf("PERF_STATUS     : 0x%08lX\n", (unsigned long)perf_read(perf, TL_PERF_STATUS_OFFSET));
    printf("PERF_ID         : 0x%08lX\n", (unsigned long)perf_read(perf, TL_PERF_ID_OFFSET));
    printf("--- Counters ---\n");
    printf("TX packets      : %lu\n", (unsigned long)ctr.tx_pkt_count);
    printf("RX packets      : %lu\n", (unsigned long)ctr.rx_pkt_count);
    printf("TX words        : %lu\n", (unsigned long)ctr.tx_word_count);
    printf("RX words        : %lu\n", (unsigned long)ctr.rx_word_count);
    printf("TX stalls       : %lu\n", (unsigned long)ctr.tx_stall_count);
    printf("RX stalls       : %lu\n", (unsigned long)ctr.rx_stall_count);
    printf("Link busy       : %lu\n", (unsigned long)ctr.link_busy_count);
    printf("Credit starve   : %lu\n", (unsigned long)ctr.credit_starve_count);
    printf("Sample count    : %lu\n", (unsigned long)ctr.sample_count);
    printf("Utilisation     : %lu%%\n", (unsigned long)tl_perf_get_utilisation(perf));
    printf("--- Pipeline Latency ---\n");
    printf("SW latency      : %lu ns\n", (unsigned long)pl.sw_latency_ns);
    printf("Link latency    : %lu ns\n", (unsigned long)pl.link_latency_ns);
    printf("FIFO time       : %lu ns\n", (unsigned long)pl.fifo_time_ns);
    printf("Total           : %lu ns\n", (unsigned long)pl.total_ns);
    printf("--- Debug ---\n");
    printf("Live            : 0x%08lX\n", (unsigned long)perf_read(perf, TL_DBG_LIVE_OFFSET));
    printf("TX in-flight    : %lu\n", (unsigned long)perf_read(perf, TL_DBG_TX_INFLIGHT_OFFSET));
    printf("RX in-flight    : %lu\n", (unsigned long)perf_read(perf, TL_DBG_RX_INFLIGHT_OFFSET));
    {
        uint32_t cong = perf_read(perf, TL_PERF_CONG_STATE_OFFSET);
        printf("Cong EWMA credit: %lu\n",
               (unsigned long)((cong & TL_PERF_CONG_EWMA_CREDIT_Msk) >>
                               TL_PERF_CONG_EWMA_CREDIT_Pos));
        printf("Cong level/trend: %lu / %lu%s\n",
               (unsigned long)((cong & TL_PERF_CONG_LEVEL_Msk) >> TL_PERF_CONG_LEVEL_Pos),
               (unsigned long)((cong & TL_PERF_CONG_TREND_Msk) >> TL_PERF_CONG_TREND_Pos),
               (cong & TL_PERF_CONG_STARVE_STICKY_Msk) ? "  [credit-starve sticky]" : "");
    }
}
