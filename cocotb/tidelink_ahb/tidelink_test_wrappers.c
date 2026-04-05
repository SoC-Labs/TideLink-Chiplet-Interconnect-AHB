/*-----------------------------------------------------------------------------
 * TideLink Test Wrappers — Export Inline Functions for ctypes
 *
 * Build: gcc -shared -fPIC -DHAL_TEST_MODE -O0 -include hal_io.h \
 *        -I../../src/sw tidelink_test_wrappers.c ../../src/sw/tidelink.c \
 *        -o libtidelink_driver.so
 *---------------------------------------------------------------------------*/

#include "tidelink.h"
#include <stddef.h>

/* ── Struct Layout Assertions ───────────────────────────────────────────── */

_Static_assert(sizeof(TIDELINK_REGS_TypeDef) == 0x034,
               "TIDELINK_REGS_TypeDef size mismatch");
_Static_assert(offsetof(TIDELINK_REGS_TypeDef, PAIR_BASE_ADDR) == 0x000,
               "PAIR_BASE_ADDR offset mismatch");
_Static_assert(offsetof(TIDELINK_REGS_TypeDef, STATUS) == 0x010,
               "STATUS offset mismatch");
_Static_assert(offsetof(TIDELINK_REGS_TypeDef, CTRL) == 0x01C,
               "CTRL offset mismatch");
_Static_assert(offsetof(TIDELINK_REGS_TypeDef, RELEASED_CREDITS_ACC) == 0x020,
               "RELEASED_CREDITS_ACC offset mismatch");
_Static_assert(offsetof(TIDELINK_REGS_TypeDef, PAIR_CREDIT_COUNTER_EN) == 0x030,
               "PAIR_CREDIT_COUNTER_EN offset mismatch");

/* ── 64-bit safe init wrapper ───────────────────────────────────────────── */

void tidelink_init_host(tidelink_t *tl, void *cfg_ptr, void *fifo_ptr)
{
    tl->cfg  = (TIDELINK_REGS_TypeDef *)cfg_ptr;
    tl->fifo = (uint32_t *)fifo_ptr;
}

/* ── Exported Wrappers for static inline Functions ──────────────────────── */

void tidelink_set_pair_base_wrap(tidelink_t *tl, uint32_t addr)
{
    tidelink_set_pair_base(tl, addr);
}

uint32_t tidelink_get_pair_base_wrap(tidelink_t *tl)
{
    return tidelink_get_pair_base(tl);
}

void tidelink_set_threshold_wrap(tidelink_t *tl, uint32_t thresh)
{
    tidelink_set_threshold(tl, thresh);
}

uint32_t tidelink_get_threshold_wrap(tidelink_t *tl)
{
    return tidelink_get_threshold(tl);
}

uint32_t tidelink_get_status_wrap(tidelink_t *tl)
{
    return tidelink_get_status(tl);
}

uint32_t tidelink_is_busy_wrap(tidelink_t *tl)
{
    return tidelink_is_busy(tl);
}

uint32_t tidelink_packet_committed_wrap(tidelink_t *tl)
{
    return tidelink_packet_committed(tl);
}

uint32_t tidelink_get_credit_count_wrap(tidelink_t *tl)
{
    return tidelink_get_credit_count(tl);
}

uint32_t tidelink_get_pkt_word_len_wrap(tidelink_t *tl)
{
    return tidelink_get_pkt_word_len(tl);
}

void tidelink_doorbell_wrap(tidelink_t *tl)
{
    tidelink_doorbell(tl);
}

uint32_t tidelink_read_released_wrap(tidelink_t *tl)
{
    return tidelink_read_released(tl);
}

uint32_t tidelink_read_doorbell_resp_wrap(tidelink_t *tl)
{
    return tidelink_read_doorbell_resp(tl);
}

uint32_t tidelink_get_pair_credits_wrap(tidelink_t *tl)
{
    return tidelink_get_pair_credits(tl);
}

void tidelink_consume_credits_wrap(tidelink_t *tl, uint32_t n)
{
    tidelink_consume_credits(tl, n);
}

void tidelink_set_pair_credit_en_wrap(tidelink_t *tl, uint32_t en)
{
    tidelink_set_pair_credit_en(tl, en);
}
