/* ===========================================================================
 * td_tput.c — the TideLink TX throughput instrument.
 *
 * WHY C AND NOT PYTHON
 *   sustained_data_soak.sh's Python sender reports ~24k words/s. That number
 *   is NOT the channel: the same ctypes store loop into ANONYMOUS memory (no
 *   AXI, no link) tops out at ~96k words/s on this PS. The link word clock is
 *   2.343 MHz. So the Python instrument's own ceiling sits ~24x BELOW the
 *   link's theoretical rate -- it can never saturate the channel, and any
 *   "throughput" it prints is a property of CPython, not of TideLink.
 *
 *   This does volatile 32-bit stores straight into the mmap'd TX aperture from
 *   compiled C. On a 650 MHz Zynq-7 PS a store to a device-mapped GP port
 *   costs ~0.1-0.2 us, i.e. ~5-10M words/s -- comfortably ABOVE the 2.343 MHz
 *   link. That inequality is the whole point: only an instrument faster than
 *   the DUT can measure the DUT.
 *
 * WHAT IT MEASURES
 *   Once the FC adapter's skid/replay FIFO fills, an AHB store into the TX
 *   aperture BLOCKS (HREADYOUT low) until the link drains a word. So for a
 *   burst long enough to saturate that skid, the store rate IS the link's
 *   word-acceptance rate. Short bursts are absorbed by the FIFO and measure
 *   the PS store rate instead -- hence the --sweep, which shows the rate
 *   bending from PS-limited down to link-limited as the burst grows.
 *
 * FRAME LAYOUT — byte-identical to sustained_data_soak.sh's TX_PY, so its
 * Python receiver can score C-sent traffic word-for-word:
 *   word0 = (n & 0xFFF)<<20 | 1<<18   (length, pkt_type=1 PKT_WR_REQ)
 *   word1 = 0x0                        (dest_addr)
 *   word[2+i] = ((seed+p)<<16) | i     (payload)
 *
 * SAFETY
 *   Total words offered stays under the 4096-word RX FIFO credit. With no
 *   concurrent drainer, exceeding it exhausts credit and the sender parks in
 *   an uninterruptible kernel store until TX_STALL_TIMEOUT -- which has
 *   wedged the marginal die before. The caller enforces the budget; main()
 *   refuses anything over 2048 words.
 *
 * BUILD (on the board):  gcc -O2 -o td_tput td_tput.c
 * USAGE:                 sudo ./td_tput <payload_words> <packets> <seed_hex>
 *                        sudo ./td_tput --sweep
 * ===========================================================================
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define TXBASE   0x84000000UL
/* APB STATUS. Read-only, already polled by sustained_data_soak.sh's receiver,
 * and NOT one of the 0x...1AC/1B0/1B4 registers that SIGBUS-wedge the PS. */
#define STATUS   0x44032010UL
#define MAPLEN   (64UL * 1024UL)   /* 16384 words: covers any burst we allow */
#define FIFO_WORDS 4096
#define MAX_WORDS  2048            /* half the FIFO; see SAFETY above */

static volatile uint32_t *tx;

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

/* Send k packets of n payload words back-to-back. Returns elapsed seconds.
 * The store loop is deliberately trivial and free of per-word allocation so
 * that what we time is the bus, not the language. */
static double blast(int n, int k, unsigned seed, long *words_out)
{
    long words = 0;
    double t0, t1;
    int p, i;

    t0 = now_s();
    for (p = 0; p < k; p++) {
        tx[0] = ((uint32_t)(n & 0xFFF) << 20) | (1u << 18);
        tx[1] = 0x0u;
        for (i = 0; i < n; i++)
            tx[2 + i] = ((uint32_t)(seed + p) << 16) | (uint32_t)i;
        words += n + 2;
    }
    t1 = now_s();
    *words_out = words;
    return t1 - t0;
}

int main(int argc, char **argv)
{
    int fd, n, k, sweep = 0, busref = 0;
    unsigned seed = 0xa2b0;
    long words;
    double secs;

    if (argc >= 2 && strcmp(argv[1], "--busref") == 0) {
        busref = 1;
    } else if (argc >= 2 && strcmp(argv[1], "--sweep") == 0) {
        sweep = 1;
    } else if (argc >= 4) {
        n = atoi(argv[1]);
        k = atoi(argv[2]);
        seed = (unsigned)strtoul(argv[3], NULL, 16);
    } else {
        fprintf(stderr, "usage: %s <payload_words> <packets> <seed_hex>\n"
                        "       %s --sweep\n"
                        "       %s --busref\n", argv[0], argv[0], argv[0]);
        return 2;
    }

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (need sudo)"); return 1; }

    if (busref) {
        /* CONTROL for the --sweep plateau.
         *
         * --sweep plateaus at ~20.5 us/word. Two explanations fit that number
         * equally well on paper, and they are NOT the same conclusion:
         *   (a) the LINK is gating each store (back-pressure) => 20.48 us =
         *       48.0 link UIs of 426.67 ns. This is a real channel result.
         *   (b) a PS<->PL access on this SoC just costs ~20 us => the plateau
         *       is the BRIDGE and says nothing about TideLink.
         * They alias because 48 link UIs and 2048 hclk (100 MHz) are the same
         * interval -- the link clock is derived from hclk -- so arithmetic
         * alone cannot separate them.
         *
         * This times a NON-LINK PS->PL access: a read of the APB STATUS
         * register, which crosses the same AXI GP port and the same AHB
         * bridge but never touches the FC adapter or the serialiser. A read is
         * non-posted (full round trip), so it OVER-states what a posted store
         * costs -- making this a conservative bound on (b).
         *
         * If busref << 20.5 us, generic PS<->PL latency cannot explain the
         * plateau and (a) stands. */
        volatile uint32_t *st;
        unsigned long base = STATUS & ~(4096UL - 1);
        double t0, t1;
        int i; volatile uint32_t sink = 0;
        const int NR = 20000;

        st = (volatile uint32_t *)mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, base);
        if (st == MAP_FAILED) { perror("mmap STATUS"); return 1; }
        t0 = now_s();
        for (i = 0; i < NR; i++)
            sink ^= st[(STATUS - base) / 4];
        t1 = now_s();
        (void)sink;
        printf("BUSREF non-link PS->PL read (APB STATUS 0x%08lx, non-posted): "
               "%d reads in %.6f s = %.2f us/access\n",
               STATUS, NR, t1 - t0, 1e6 * (t1 - t0) / (double)NR);
        printf("  Compare against the --sweep plateau (~20.5 us/word). If this\n"
               "  is far smaller, the plateau is LINK back-pressure, not bus cost.\n");
        return 0;
    }
    tx = (volatile uint32_t *)mmap(NULL, MAPLEN, PROT_READ | PROT_WRITE,
                                   MAP_SHARED, fd, TXBASE);
    if (tx == MAP_FAILED) { perror("mmap TX aperture"); return 1; }

    if (sweep) {
        /* One packet per size. The bend in this curve is the result: while the
         * RX FIFO absorbs the burst we are measuring the PS; once the skid
         * saturates we are measuring the link. */
        int sizes[] = {4, 16, 64, 256, 1024, 2040};
        unsigned i;
        printf("payload_words,total_words,secs,words_per_sec,ns_per_word\n");
        for (i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++) {
            if (sizes[i] + 2 > MAX_WORDS) continue;
            secs = blast(sizes[i], 1, 0xc000 + i, &words);
            printf("%d,%ld,%.6f,%.0f,%.1f\n", sizes[i], words, secs,
                   (double)words / secs, 1e9 * secs / (double)words);
            fflush(stdout);
            /* Let the link drain and the RX FIFO be reclaimed between points,
             * so the next size starts from full credit rather than inheriting
             * the previous burst's backlog (which would understate its rate). */
            usleep(400000);
        }
        return 0;
    }

    if ((long)k * (n + 2) > MAX_WORDS) {
        fprintf(stderr, "refusing: %ld words > %d (half the %d-word RX FIFO; "
                        "no concurrent drainer => credit exhaustion => stall)\n",
                (long)k * (n + 2), MAX_WORDS, FIFO_WORDS);
        return 3;
    }
    secs = blast(n, k, seed, &words);
    printf("TPUT words=%ld packets=%d secs=%.6f words_per_sec=%.0f "
           "ns_per_word=%.1f payload_Bps=%.0f\n",
           words, k, secs, (double)words / secs, 1e9 * secs / (double)words,
           (double)k * n * 4.0 / secs);
    return 0;
}
