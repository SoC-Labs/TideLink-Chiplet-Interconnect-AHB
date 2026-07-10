#!/usr/bin/env python3
"""EMIO off-fabric debug-word reader (warm-up-gated instrument, 2026-07-10).

Reads the Zynq-7000 PS EMIO GPIO *input* bank register DATA_RO_2 at 0xE000_A068
with a SINGLE aligned 32-bit access. This register lives in the PS GPIO block
and NEVER traverses the PL AXI fabric, so it SURVIVES the master's PS->PL wedge
(every 0x4403_xxxx / 0x84xx aperture returns external abort 0x018 when wedged).
This script must only ever touch 0xE000_A000 (one PS GPIO page) — no PL address.

EMIO GPIO word map -- MUST match src/rtl/tidelink_top.sv `dbg_emio_o` + the two
block designs' xlconcat_emio (In0=dbg_emio_o[23:0], In1=locked, In2=aresetn,
In3=const6):

  bit    name              meaning
  ---    ----              -------
  31:26  0                 xlconstant pad (const 0)
  25     aresetn           proc_sys_reset peripheral_aresetn  LIVE (==hresetn; 1=out of reset)
  24     locked            clk_wiz_0/locked                   LIVE (1=MMCM locked)
  23:16  hb                free-running hclk heartbeat (byte CHANGES between two
                           reads ~1 s apart IFF hclk is alive; frozen => clk dead)
  15     warm              warm-up gate done (~0.9 s after config).
                           **MUST read 1 in any sane baseline** — every sticky
                           below is qualified by it, so warm=0 means the die is
                           either just-configured or its hclk is dead.
  14     STK locked_low    sticky: clk_wiz locked EVER low AFTER warm-up
                           (a TRANSIENT MMCM unlock — the bit EMIO could not
                           settle before; a live [24] tap alone cannot catch it)
  13     STK hresetn_low   sticky: hresetn EVER low after warm-up
  12     STK role_lost     sticky: role_is_master EVER 0 after warm-up
                           (MASTER die only; on the SLAVE this is always 1)
  11     STK apb_pslverr   sticky: apb_pslverr EVER high after warm-up
  10     STK ahb_tx_hresp  sticky: ahb_tx_hresp EVER high after warm-up
  9:5    0                 reserved
  4      fch_active        fch sequencer owns the tidelink APB   (live)
  3      fc_cfg_psel       FC adapter owns the tidelink APB      (live)
  2      role_is_master    role_is_master                       (live)
  1      role_locked       role_locked                          (live)
  0      d2d_reset         controller self-reset                (live)

Usage:
  sudo python3 emio2.py             # one read + full decode
  sudo python3 emio2.py --raw       # just the 32-bit hex word
  sudo python3 emio2.py --watch N   # N reads ~0.5 s apart; flags a frozen heartbeat
"""
import ctypes
import mmap
import os
import sys
import time

EMIO_DATA_RO_2 = 0xE000A068   # PS GPIO bank-2 input data (EMIO[31:0]); PS-only
PAGE = 0x1000


def read_word():
    """One SINGLE aligned 32-bit load from the PS GPIO EMIO input register."""
    base = EMIO_DATA_RO_2 & ~(PAGE - 1)
    off = EMIO_DATA_RO_2 - base
    assert (EMIO_DATA_RO_2 & 0x3) == 0, "address not 32-bit aligned"
    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        mem = mmap.mmap(fd, PAGE, mmap.MAP_SHARED,
                        mmap.PROT_READ | mmap.PROT_WRITE, offset=base)
    finally:
        os.close(fd)
    try:
        reg = ctypes.c_uint32.from_buffer(mem, off)  # 32-bit view into the page
        val = reg.value                              # single aligned 32-bit read
        del reg                                      # drop export before close
    finally:
        mem.close()
    return val


def decode(w):
    def b(i):
        return (w >> i) & 1

    hb = (w >> 16) & 0xFF
    return [
        ("aresetn        [25] live", b(25)),
        ("locked         [24] live", b(24)),
        ("hb             [23:16]  ", "0x%02x" % hb),
        ("warm           [15]     ", b(15)),
        ("STK locked_low [14]     ", b(14)),
        ("STK hresetn_low[13]     ", b(13)),
        ("STK role_lost  [12]     ", b(12)),
        ("STK apb_pslverr[11]     ", b(11)),
        ("STK ahb_hresp  [10]     ", b(10)),
        ("fch_active     [4]      ", b(4)),
        ("fc_cfg_psel    [3]      ", b(3)),
        ("role_is_master [2]      ", b(2)),
        ("role_locked    [1]      ", b(1)),
        ("d2d_reset      [0]      ", b(0)),
    ]


def verdict(w):
    warm = (w >> 15) & 1
    resv = (w >> 5) & 0x1F
    notes = []
    if warm == 0:
        notes.append("WARM=0: die not warmed up (just-configured OR hclk dead) "
                     "-- stickies not yet meaningful; re-read after ~1 s")
    if resv != 0:
        notes.append("RESERVED[9:5]=0x%x nonzero: word map mismatch -- check the "
                     "bitstream matches this reader" % resv)
    stk = (w >> 10) & 0x1F  # [14:10]
    if warm and stk:
        names = {14: "locked_low", 13: "hresetn_low", 12: "role_master_lost",
                 11: "apb_pslverr", 10: "ahb_tx_hresp"}
        fired = [names[i] for i in (14, 13, 12, 11, 10) if (w >> i) & 1]
        notes.append("STICKY FIRED after warm-up: " + ", ".join(fired)
                     + "  (role_master_lost is MASTER-only; on the SLAVE die it "
                       "is always 1 and carries no info)")
    if warm and stk == 0:
        notes.append("all post-warm-up stickies clear")
    return notes


def main():
    args = sys.argv[1:]
    if args and args[0] == "--raw":
        print("0x%08x" % read_word())
        return
    if args and args[0] == "--watch":
        n = int(args[1]) if len(args) > 1 else 4
        prev_hb = None
        for k in range(n):
            w = read_word()
            hb = (w >> 16) & 0xFF
            moved = "" if prev_hb is None else (
                " hb %s" % ("MOVED (hclk alive)" if hb != prev_hb
                            else "FROZEN (hclk DEAD?)"))
            print("[%d] 0x%08x warm=%d hb=0x%02x%s"
                  % (k, w, (w >> 15) & 1, hb, moved))
            prev_hb = hb
            if k + 1 < n:
                time.sleep(0.5)
        return

    w = read_word()
    print("EMIO 0xE000_A068 = 0x%08x" % w)
    for name, val in decode(w):
        print("  %s = %s" % (name, val))
    print("  --")
    for note in verdict(w):
        print("  %s" % note)


if __name__ == "__main__":
    main()
