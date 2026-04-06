/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Pipeline Measurement Example
 *
 * Standalone example showing the full Ethernet -> TideLink pipeline
 * latency measurement flow using the PHC and performance monitor APIs.
 *
 * Measurement approach:
 *   1. Initialise PHC and TideLink performance monitor
 *   2. Set the PHC to a known epoch
 *   3. Before transmitting, capture the current PHC time and write it
 *      into the perf monitor's TX_ORIGIN timestamp
 *   4. Transmit a TideLink packet (the hardware records TX_START,
 *      RX_FIRST, and RX_DONE timestamps automatically)
 *   5. After the packet is received, read the pipeline breakdown
 *
 * Pipeline stages measured:
 *   TX_ORIGIN  -> TX_START    Software overhead (packet build + FIFO write)
 *   TX_START   -> RX_FIRST    Link + PHY latency (Wlink serialisation)
 *   RX_FIRST   -> RX_DONE     FIFO drain time (RX FIFO -> AHB slave)
 *   TX_ORIGIN  -> RX_DONE     Total end-to-end latency
 *
 * Target: ARM Cortex-M0 (no OS, no dynamic allocation)
 *
 * A joint work commissioned on behalf of SoC Labs, under Arm Academic
 * Access license.
 *
 * Contributors
 *   David Mapstone (d.a.mapstone@soton.ac.uk)
 *
 * Copyright 2026, SoC Labs (www.soclabs.org)
 *---------------------------------------------------------------------------*/

#include <stdint.h>
#include <stdio.h>

#include "phc.h"
#include "tidelink.h"
#include "tidelink_perf.h"
#include "tidelink_packet.h"

/* ── Example memory-map addresses (platform-specific) ──────────────────── */

#define PHC_BASE              0x40010000UL
#define TIDELINK_CFG_BASE     0x40020000UL
#define TIDELINK_FIFO_BASE    0x40021000UL
#define REMOTE_PAIR_BASE      0x50020000UL

/* ── Example packet parameters ─────────────────────────────────────────── */

#define EXAMPLE_SRC_ID     0U
#define EXAMPLE_DEST_ID    1U
#define EXAMPLE_TAG        0x42U
#define EXAMPLE_DEST_ADDR  0x20000000UL
#define EXAMPLE_PAYLOAD_LEN  4U

/* ── Main ──────────────────────────────────────────────────────────────── */

int main(void)
{
    phc_t       phc;
    tidelink_t  tl;
    tl_perf_t   perf;
    phc_time_t  cap;
    tl_timestamp_t origin;
    tl_pipeline_result_t pipeline;
    tl_perf_counters_t   counters;
    uint32_t payload[EXAMPLE_PAYLOAD_LEN];
    uint32_t word0;
    uint32_t i;

    /* ── Step 1: Initialise all subsystems ─────────────────────────────── */

    /* Initialise the PHC and set it to epoch zero.
     * The PHC is the common time reference for all pipeline timestamps. */
    phc_init(&phc, PHC_BASE);
    phc_set_time(&phc, 0U, 0U, 0U);

    /* Initialise the TideLink driver (FIFO packet I/O) */
    tidelink_init(&tl, TIDELINK_CFG_BASE, TIDELINK_FIFO_BASE);
    tidelink_set_pair_base(&tl, REMOTE_PAIR_BASE);

    /* Initialise the performance monitor (enables and clears counters) */
    tl_perf_init(&perf, TIDELINK_CFG_BASE);

    printf("Pipeline measurement example started\n");

    /* ── Step 2: Prepare a test payload ────────────────────────────────── */

    for (i = 0U; i < EXAMPLE_PAYLOAD_LEN; i++) {
        payload[i] = 0xCAFE0000UL | i;
    }

    /* ── Step 3: Record the TX origin timestamp ────────────────────────── */

    /* Capture the PHC time immediately before building the packet.
     * This marks the start of the software pipeline stage. */
    phc_capture(&phc);
    phc_get_captured_time(&phc, &cap);

    /* Write the captured time into the perf monitor's TX_ORIGIN registers.
     * Only sec_lo and ns are used (32-bit each). */
    origin.sec = cap.sec_lo;
    origin.ns  = cap.ns;
    tl_perf_set_origin_ts(&perf, &origin);

    /* ── Step 4: Build and transmit the packet ─────────────────────────── */

    /* Encode the 2-word header:
     *   Word 0: length | pkt_type | src_id | dest_id | tag
     *   Word 1: destination address */
    word0 = tidelink_pkt_encode_word0(
        EXAMPLE_PAYLOAD_LEN,
        TIDELINK_PKT_WR_REQ,
        EXAMPLE_SRC_ID,
        EXAMPLE_DEST_ID,
        EXAMPLE_TAG
    );

    /* Write the packet into the TX FIFO.
     * Hardware automatically captures TX_START when the first word
     * enters the link layer. */
    tidelink_write_packet(&tl, word0, EXAMPLE_DEST_ADDR,
                          payload, EXAMPLE_PAYLOAD_LEN);

    /* ── Step 5: Wait for the packet to be received ────────────────────── */

    /* In a real system, wait for the packet_committed IRQ or poll.
     * Hardware captures RX_FIRST when the first word arrives at the
     * remote FIFO, and RX_DONE when the full packet is committed. */
    if (tidelink_wait_idle(&tl, 100000U) != 0) {
        printf("ERROR: timed out waiting for returner idle\n");
        return -1;
    }

    /* ── Step 6: Read the pipeline latency breakdown ───────────────────── */

    tl_perf_get_pipeline_ns(&perf, &pipeline);

    printf("--- Pipeline Latency Breakdown ---\n");
    printf("SW overhead   (ORIGIN->TX_START) : %lu ns\n",
           (unsigned long)pipeline.sw_latency_ns);
    printf("Link latency  (TX_START->RX_1ST) : %lu ns\n",
           (unsigned long)pipeline.link_latency_ns);
    printf("FIFO drain    (RX_1ST->RX_DONE)  : %lu ns\n",
           (unsigned long)pipeline.fifo_time_ns);
    printf("Total         (ORIGIN->RX_DONE)  : %lu ns\n",
           (unsigned long)pipeline.total_ns);

    /* ── Step 7: Read performance counters ─────────────────────────────── */

    tl_perf_get_counters(&perf, &counters);

    printf("--- Performance Counters ---\n");
    printf("TX packets      : %lu\n", (unsigned long)counters.tx_pkt_count);
    printf("RX packets      : %lu\n", (unsigned long)counters.rx_pkt_count);
    printf("TX words        : %lu\n", (unsigned long)counters.tx_word_count);
    printf("RX words        : %lu\n", (unsigned long)counters.rx_word_count);
    printf("Link utilisation: %lu%%\n",
           (unsigned long)tl_perf_get_utilisation(&perf));

    /* ── Step 8: Full register dump for debug ──────────────────────────── */

    tl_perf_dump(&perf);

    return 0;
}
