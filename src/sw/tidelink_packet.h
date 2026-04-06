/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Packet Encoding — 2-Word Packed Header
 *
 * Packet format for the TideLink mailbox FIFO.
 * Mirrors python/tidelink/packet.py.
 *
 * Packet layout (32-bit words):
 *   Word 0: length[31:20] | pkt_type[19:18] | src_id[17:13] |
 *           dest_id[12:8] | tag[7:0]
 *   Word 1: dest_addr[31:0]
 *   Words 2..N+1: Data payload (type-specific)
 *
 * length (N) = payload word count; total FIFO occupancy = N + 2.
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

#ifndef TIDELINK_PACKET_H
#define TIDELINK_PACKET_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Packet type constants (2 bits, Word 0 [19:18]) ───────────────────── */

#define TIDELINK_PKT_RD_REQ    0x0U   /* Read request                     */
#define TIDELINK_PKT_WR_REQ    0x1U   /* Write request                    */
#define TIDELINK_PKT_RSP       0x2U   /* Response (read data / write ack) */
#define TIDELINK_PKT_RESERVED  0x3U   /* Reserved for future use          */

/* ── Burst descriptor constants (RD_REQ payload, N=1) ──────────────────── */
/* beat_count[31:3] | size[2:0]                                             */

#define TIDELINK_SIZE_BYTE       0x0U
#define TIDELINK_SIZE_HALFWORD   0x1U
#define TIDELINK_SIZE_WORD       0x2U

/* ── Header word count ─────────────────────────────────────────────────── */

#define TIDELINK_PKT_HEADER_WORDS  2U   /* Word 0 (packed) + Word 1 (addr) */

/* ── Word 0 field positions ────────────────────────────────────────────── */

#define TIDELINK_PKT_W0_LENGTH_Pos    20U
#define TIDELINK_PKT_W0_LENGTH_Msk    (0xFFFUL << 20U)
#define TIDELINK_PKT_W0_PKT_TYPE_Pos  18U
#define TIDELINK_PKT_W0_PKT_TYPE_Msk  (0x3UL << 18U)
#define TIDELINK_PKT_W0_SRC_ID_Pos    13U
#define TIDELINK_PKT_W0_SRC_ID_Msk    (0x1FUL << 13U)
#define TIDELINK_PKT_W0_DEST_ID_Pos    8U
#define TIDELINK_PKT_W0_DEST_ID_Msk   (0x1FUL << 8U)
#define TIDELINK_PKT_W0_TAG_Pos        0U
#define TIDELINK_PKT_W0_TAG_Msk       (0xFFUL << 0U)

/* ── Burst descriptor field positions (payload word for RD_REQ N=1) ───── */

#define TIDELINK_PKT_BURST_COUNT_Pos   3U
#define TIDELINK_PKT_BURST_COUNT_Msk  (0x1FFFFFFFUL << 3U)
#define TIDELINK_PKT_BURST_SIZE_Pos    0U
#define TIDELINK_PKT_BURST_SIZE_Msk   (0x7UL << 0U)

/* ── Decoded Word 0 fields ─────────────────────────────────────────────── */

typedef struct {
    uint16_t length;
    uint8_t  pkt_type;
    uint8_t  src_id;
    uint8_t  dest_id;
    uint8_t  tag;
} tidelink_pkt_hdr_t;

/* ── Inline encoding helpers ───────────────────────────────────────────── */

/**
 * Encode Word 0 from its constituent fields.
 */
static inline uint32_t tidelink_pkt_encode_word0(
    uint32_t length, uint32_t pkt_type, uint32_t src_id,
    uint32_t dest_id, uint32_t tag)
{
    return ((length   & 0xFFFU) << 20U) |
           ((pkt_type & 0x3U)   << 18U) |
           ((src_id   & 0x1FU)  << 13U) |
           ((dest_id  & 0x1FU)  <<  8U) |
           ((tag      & 0xFFU)  <<  0U);
}

/**
 * Decode Word 0 into its constituent fields.
 */
static inline void tidelink_pkt_decode_word0(uint32_t word,
                                              tidelink_pkt_hdr_t *hdr)
{
    hdr->length   = (uint16_t)((word >> 20U) & 0xFFFU);
    hdr->pkt_type = (uint8_t)((word >> 18U) & 0x3U);
    hdr->src_id   = (uint8_t)((word >> 13U) & 0x1FU);
    hdr->dest_id  = (uint8_t)((word >>  8U) & 0x1FU);
    hdr->tag      = (uint8_t)((word >>  0U) & 0xFFU);
}

/**
 * Encode a burst read descriptor payload word (for RD_REQ with N=1).
 */
static inline uint32_t tidelink_pkt_encode_burst(uint32_t beat_count,
                                                  uint32_t size)
{
    return ((beat_count & 0x1FFFFFFFU) << 3U) | (size & 0x7U);
}

/**
 * Decode a burst read descriptor payload word.
 */
static inline void tidelink_pkt_decode_burst(uint32_t word,
                                              uint32_t *beat_count,
                                              uint32_t *size)
{
    *beat_count = (word >> 3U) & 0x1FFFFFFFU;
    *size       = word & 0x7U;
}

/* ── Convenience: build a complete packet header ─────────────────────── */

/**
 * Build a 2-word header into buf[0..1].
 */
static inline void tidelink_pkt_build_header(
    uint32_t *buf,
    uint32_t length, uint32_t pkt_type, uint32_t src_id,
    uint32_t dest_id, uint32_t tag, uint32_t dest_addr)
{
    buf[0] = tidelink_pkt_encode_word0(length, pkt_type, src_id,
                                        dest_id, tag);
    buf[1] = dest_addr;
}

/**
 * Parse a 2-word header from buf[0..1].
 */
static inline void tidelink_pkt_parse_header(
    const uint32_t *buf,
    tidelink_pkt_hdr_t *hdr, uint32_t *dest_addr)
{
    tidelink_pkt_decode_word0(buf[0], hdr);
    *dest_addr = buf[1];
}

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PACKET_H */
