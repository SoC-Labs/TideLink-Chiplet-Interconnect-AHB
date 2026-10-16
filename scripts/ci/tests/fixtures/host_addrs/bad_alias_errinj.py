"""FIXTURE (must FAIL check_host_addrs): the historical TL-038 bug.

A KR260 error-injection tool addressed LINK_ERROR_INJECTION as TLAPB+0x003C.  0x3C is unmapped in the Wlink PHY
region; the write is dropped and the CRC counter of an untouched design reads 0 ("0 errors, all exact").
The real register is 0x023C.  Both spellings below must be rejected (rule R2).
"""
_TLAPB = 0x2E030000
REG_ERR_INJECT = _TLAPB + 0x003C          # the exact historical form
ERRINJ = 0x003C                           # the same value as a plain constant


def arm(wr):
    wr(REG_ERR_INJECT, 0x01000000 | 0xA1)
