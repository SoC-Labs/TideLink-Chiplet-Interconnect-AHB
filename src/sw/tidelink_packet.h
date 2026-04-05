/*-----------------------------------------------------------------------------
 * SoCLabs TideLink Packet Encoding — Header-Only
 *
 * Descriptor packet format for the TideLink mailbox FIFO.
 * Mirrors python/tidelink/packet.py.
 *
 * Packet layout (32-bit words):
 *   Word 0: FIFO length (N) — number of words that follow
 *   Word 1: Control — pkt_type | src_id | dest_id | tag | status | burst
 *   Word 2: dest_addr[31:0]
 *   Word 3: length[15:3] | size[2:0]
 *   Words 4..N: Data payload (present for WR_REQ and RD_RSP)
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

/* ── Packet type constants (4 bits, Control word [31:28]) ───────────────── */

#define TIDELINK_PKT_RD_REQ   0x1U   /* Read request  — header only        */
#define TIDELINK_PKT_WR_REQ   0x2U   /* Write request — header + payload   */
#define TIDELINK_PKT_RD_RSP   0x3U   /* Read response — header + payload   */
#define TIDELINK_PKT_WR_RSP   0x4U   /* Write response — header only       */
#define TIDELINK_PKT_ERROR    0xFU   /* Error response                     */

/* ── Burst type constants (2 bits, Control word [1:0]) ──────────────────── */

#define TIDELINK_BURST_SINGLE  0x0U
#define TIDELINK_BURST_INCR    0x1U
#define TIDELINK_BURST_WRAP    0x2U

/* ── Status constants (2 bits, Control word [3:2]) ──────────────────────── */

#define TIDELINK_STATUS_OKAY     0x0U
#define TIDELINK_STATUS_ERROR    0x1U
#define TIDELINK_STATUS_TIMEOUT  0x2U

/* ── Size constants (3 bits, Word 3 [2:0] — mirrors AHB HSIZE) ─────────── */

#define TIDELINK_SIZE_BYTE       0x0U
#define TIDELINK_SIZE_HALFWORD   0x1U
#define TIDELINK_SIZE_WORD       0x2U

/* ── Header word count (excludes the FIFO length word) ──────────────────── */

#define TIDELINK_PKT_HEADER_WORDS  3U

/* ── Control word field positions ───────────────────────────────────────── */

#define TIDELINK_PKT_CTRL_PKT_TYPE_Pos   28U
#define TIDELINK_PKT_CTRL_PKT_TYPE_Msk   (0xFUL << 28U)
#define TIDELINK_PKT_CTRL_SRC_ID_Pos     20U
#define TIDELINK_PKT_CTRL_SRC_ID_Msk     (0xFFUL << 20U)
#define TIDELINK_PKT_CTRL_DEST_ID_Pos    12U
#define TIDELINK_PKT_CTRL_DEST_ID_Msk    (0xFFUL << 12U)
#define TIDELINK_PKT_CTRL_TAG_Pos         4U
#define TIDELINK_PKT_CTRL_TAG_Msk        (0xFFUL << 4U)
#define TIDELINK_PKT_CTRL_STATUS_Pos      2U
#define TIDELINK_PKT_CTRL_STATUS_Msk     (0x3UL << 2U)
#define TIDELINK_PKT_CTRL_BURST_Pos       0U
#define TIDELINK_PKT_CTRL_BURST_Msk      (0x3UL << 0U)

/* ── Word 3 field positions ─────────────────────────────────────────────── */

#define TIDELINK_PKT_W3_LENGTH_Pos        3U
#define TIDELINK_PKT_W3_LENGTH_Msk       (0x1FFFUL << 3U)
#define TIDELINK_PKT_W3_SIZE_Pos          0U
#define TIDELINK_PKT_W3_SIZE_Msk         (0x7UL << 0U)

/* ── Decoded control fields ─────────────────────────────────────────────── */

typedef struct {
    uint8_t pkt_type;
    uint8_t src_id;
    uint8_t dest_id;
    uint8_t tag;
    uint8_t status;
    uint8_t burst_type;
} tidelink_pkt_ctrl_t;

/* ── Inline encoding helpers ────────────────────────────────────────────── */

/**
 * Encode the Control word (Word 1) from its constituent fields.
 */
static inline uint32_t tidelink_pkt_encode_control(
    uint32_t pkt_type, uint32_t src_id, uint32_t dest_id,
    uint32_t tag, uint32_t status, uint32_t burst_type)
{
    return ((pkt_type   & 0xFU)  << 28U) |
           ((src_id     & 0xFFU) << 20U) |
           ((dest_id    & 0xFFU) << 12U) |
           ((tag        & 0xFFU) <<  4U) |
           ((status     & 0x3U)  <<  2U) |
           ((burst_type & 0x3U)  <<  0U);
}

/**
 * Decode the Control word (Word 1) into its constituent fields.
 */
static inline void tidelink_pkt_decode_control(uint32_t word,
                                                tidelink_pkt_ctrl_t *ctrl)
{
    ctrl->pkt_type   = (uint8_t)((word >> 28U) & 0xFU);
    ctrl->src_id     = (uint8_t)((word >> 20U) & 0xFFU);
    ctrl->dest_id    = (uint8_t)((word >> 12U) & 0xFFU);
    ctrl->tag        = (uint8_t)((word >>  4U) & 0xFFU);
    ctrl->status     = (uint8_t)((word >>  2U) & 0x3U);
    ctrl->burst_type = (uint8_t)((word >>  0U) & 0x3U);
}

/**
 * Encode Word 3: beat length and transfer size.
 */
static inline uint32_t tidelink_pkt_encode_length_size(uint32_t length,
                                                        uint32_t size)
{
    return ((length & 0x1FFFU) << 3U) | (size & 0x7U);
}

/**
 * Decode Word 3 into beat length and transfer size.
 */
static inline void tidelink_pkt_decode_length_size(uint32_t word,
                                                    uint32_t *length,
                                                    uint32_t *size)
{
    *length = (word >> 3U) & 0x1FFFU;
    *size   = word & 0x7U;
}

/* ── Convenience: build a complete descriptor header ────────────────────── */

/**
 * Build a 3-word descriptor header (Words 1-3) into buf[0..2].
 * The caller is responsible for prepending the FIFO length word (Word 0).
 */
static inline void tidelink_pkt_build_header(
    uint32_t *buf,
    uint32_t pkt_type, uint32_t src_id, uint32_t dest_id,
    uint32_t tag, uint32_t status, uint32_t burst_type,
    uint32_t dest_addr, uint32_t beat_length, uint32_t size)
{
    buf[0] = tidelink_pkt_encode_control(pkt_type, src_id, dest_id,
                                          tag, status, burst_type);
    buf[1] = dest_addr;
    buf[2] = tidelink_pkt_encode_length_size(beat_length, size);
}

/**
 * Parse a 3-word descriptor header from buf[0..2].
 */
static inline void tidelink_pkt_parse_header(
    const uint32_t *buf,
    tidelink_pkt_ctrl_t *ctrl,
    uint32_t *dest_addr, uint32_t *beat_length, uint32_t *size)
{
    tidelink_pkt_decode_control(buf[0], ctrl);
    *dest_addr = buf[1];
    tidelink_pkt_decode_length_size(buf[2], beat_length, size);
}

#ifdef __cplusplus
}
#endif

#endif /* TIDELINK_PACKET_H */
