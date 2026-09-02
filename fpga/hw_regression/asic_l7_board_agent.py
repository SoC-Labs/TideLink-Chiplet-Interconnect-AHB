#!/usr/bin/env python3
"""asic_l7_board_agent.py - RUNS ON THE KR260, as root. Staged by
fpga/hw_regression/asic_l7_starvation_hwtest.py; not useful on its own.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors

David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)

===========================================================================
WHAT THIS IS FOR
===========================================================================
The host driver uses this agent to ask whether the FIVE AXI flow-control
state machines - WlinkGenericFCSM{,_1.._4} = AW/W/B/AR/R - recover from the
state-7 (SEND_NACK) emit starvation that
cocotb/tidelink_top_pair_v2/test_asic_l7_starvation_backstop.py drives in
simulation. On the FPGA file set the TL-033 watchdog forces the exit; on the
file set that TAPES OUT the exit term does not exist.

READ THIS BEFORE TRUSTING ANY OUTPUT OF THIS AGENT
--------------------------------------------------
`state` of those five nodes is NOT observable on hardware. Verified on this
branch, not assumed: neither deps/.../WlinkGenericFCSM*.v nor
src/rtl/local_overrides/WlinkGenericFCSM*.v declares any io_obs_* port, and
the only FCSM state published to APB - 0x2108[19:17] - comes from
Wlink.v:1951 .io_obs_fcsm_state(...) on the `tl2wl` instance, i.e.
TideLinkToWlink -> WlinkGenericFCSM_6. FCSM_6 is taken from
src/rtl/local_overrides in BOTH flists and carries 130 socl_ hits including
the L7 watchdog, so 0x2108[19:17] is the ONE FCSM state you can read and it
is the ONE FCSM that does NOT differ between the two file sets.

Consequence: this agent CANNOT report "AW is in state 7". Everything below is
a BEHAVIOURAL proxy - did the AXI data path stop, and did it come back - read
through the two marker-gated observability words that do exist:

  0x21E0 OBS_AXI_NODES  (marker 0xAD, src/rtl/tidelink_axinode_obs.sv:66-76)
      [4:0]   target    live stall {r,ar,b,w,aw}
      [9:5]   initiator live stall {r,ar,b,w,aw}
      [14:10] target    WEDGE-STICKY  (channel stalled >= 2**12 app_clk)
      [19:15] initiator WEDGE-STICKY
      [22]    any live stall
      [23]    data_nodes_healthy
  0x21EC FCEMIT_STAT    (marker 0xE1, src/rtl/tidelink_fcemit_obs.sv:56-64)
      [4:0]   axi_sop_seen   {R,AR,B,W,AW} sticky - node ever presented SOP
      [12:8]  axi_grant_seen {R,AR,B,W,AW} sticky - node ever granted+advanced
      [17]    out_advance_ever

"presented but never granted" = sop_seen & ~grant_seen. That is the emit
starvation signature the sim test forces with auto_tx_out_advance=0.

===========================================================================
SAFETY - three hazards, all of which have cost real board time
===========================================================================
 1. UNDECODED READ. On ZynqMP a read of an address the PL does not decode
    hangs the AXI bus with NO timeout: JTAG POR to recover. This agent
    touches ONLY the apertures the kr260-pair-onchip image decodes, taken
    from fpga/targets/kr260-pair-onchip/addrmap.tcl, and refuses anything
    else by construction (_guard).
 2. HARD-STALL OFFSETS. APB 0x21AC / 0x21B0 / 0x21B4 stall the CPU thread.
    Never accessed; refused explicitly.
 3. AHB_SUB / AHB_TX HANG. A read or write of the peer window when the link
    is not up hangs the PS on HREADY from a wedged FC adapter. So EVERY
    access to ahb_sub runs inside a short-lived WORKER subprocess under a
    parent-enforced wall clock (the kr260_onchip_smoke.py pattern), and the
    caller must have proven fcsm==4 && cal==1 first. A worker that does not
    return is reported as WEDGED - which is a RESULT, not a crash.

    Best-effort, stated plainly: a wedged AXI read can leave the worker in an
    uninterruptible kernel read. The parent stops waiting; the board is NOT
    thereby un-wedged.

Every subcommand prints EXACTLY ONE line of JSON containing the key
"tl_asic_l7". The host requires that key before it will call anything a
result - a command that produced no marker did not run, whatever its exit
code.
"""
import ctypes
import json
import mmap
import os
import struct
import subprocess
import sys
import time

MARKER_KEY = "tl_asic_l7"

# --- kr260-pair-onchip map. Source: fpga/targets/kr260-pair-onchip/addrmap.tcl
#     inst1 = inst0 | 0x0800_0000 on EVERY aperture (the OR convention is
#     asserted by that file's own self-check).
INST_STRIDE = 0x08000000
APB_BASE_0      = 0x84030000   # 32 KB TideLink APB (Wlink + chiplet ctrl)
AHB_SUB_BASE_0  = 0x80000000   # 64 MB cross-die peer window  <- AXI nodes
AHB_SUB_RANGE   = 0x04000000

def apb(inst):     return APB_BASE_0     | (inst * INST_STRIDE)
def ahb_sub(inst): return AHB_SUB_BASE_0 | (inst * INST_STRIDE)

# --- APB offsets actually read here. All marker-gated where a marker exists.
OFF_STATUS       = 0x2108   # [7:0] lane_locked [16] cal [19:17] fcsm(FCSM_6!)
OFF_EPOCH_STATUS = 0x2140   # [0] reanchored [6:1] span
OFF_FC_CREDIT    = 0x219C   # marker 0xFC [7:0] credit_max [16] is_full
OFF_AXI_NODES    = 0x21E0   # marker 0xAD - the wedge word
OFF_FCEMIT_STAT  = 0x21EC   # marker 0xE1 - the sop/grant word
OFF_FCEMIT_IDCNT = 0x21F0   # marker 0xE2
OFF_AUTO_ANCHOR  = 0x21F4
OFF_XHB_SUB_OBS  = 0x21F8   # marker 0xB5

MARKERS = {OFF_FC_CREDIT: 0xFC, OFF_AXI_NODES: 0xAD,
           OFF_FCEMIT_STAT: 0xE1, OFF_FCEMIT_IDCNT: 0xE2,
           OFF_XHB_SUB_OBS: 0xB5}

# Wlink per-node FC registers. Bases are offsets inside the same APB bank
# (pynq_host/scripts/kr260_eth_bringup.py:126-130).
FC_AXI_NODES = (("AW", 0x1000), ("W", 0x1100), ("B", 0x1200),
                ("AR", 0x1300), ("R", 0x1400))
FC_SM_CONTROL      = 0x14   # [16] disable_crc (RW)
FC_CRC_ERRORS      = 0x20   # [15:0] CRC errors seen (RO)
FC_DISABLE_CRC_BIT = 16

# Channel bit order inside 0x21E0 / 0x21EC nibbles: 0=AW 1=W 2=B 3=AR 4=R
CH_ORDER = ("AW", "W", "B", "AR", "R")

# NEVER touch. These stall the CPU thread outright.
FORBIDDEN_OFFSETS = (0x21AC, 0x21B0, 0x21B4)

PAGE = 4096


class Refused(Exception):
    pass


def _guard(addr, allow_ahb_sub=False):
    """Refuse any address outside the apertures this image decodes.

    Deliberately a whitelist. A blacklist would have to enumerate everything
    the PL does not decode, which is the whole 32-bit space minus a few
    windows, and the failure mode of getting it wrong is a JTAG POR."""
    for inst in (0, 1):
        base = apb(inst)
        if base <= addr < base + 0x8000:
            off = addr - base
            if off in FORBIDDEN_OFFSETS:
                raise Refused("APB offset 0x%04X HARD-STALLS the CPU thread" % off)
            return
        if allow_ahb_sub:
            sb = ahb_sub(inst)
            if sb <= addr < sb + AHB_SUB_RANGE:
                return
    raise Refused("0x%08X is outside every aperture kr260-pair-onchip decodes "
                  "(reading it hangs the PS with no timeout)" % addr)


_fd = None
_maps = {}

def _mm(a):
    global _fd
    if _fd is None:
        _fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    b = a & ~0xFFF
    if b not in _maps:
        _maps[b] = mmap.mmap(_fd, PAGE, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=b)
    return _maps[b], a - b


def rd(a, allow_ahb_sub=False):
    _guard(a, allow_ahb_sub)
    m, o = _mm(a)
    # ctypes.c_uint32.from_buffer, not struct: struct.pack_into compiled to
    # ~5 AHB beats per logical poke on this target (pynq_host/scripts/tl39.py
    # :99-112, "the TX 5x over-advance phantom").
    return ctypes.c_uint32.from_buffer(m, o).value


def wr(a, v, allow_ahb_sub=False):
    _guard(a, allow_ahb_sub)
    m, o = _mm(a)
    ctypes.c_uint32.from_buffer(m, o).value = v & 0xFFFFFFFF


# ---------------------------------------------------------------------------
# Decoders. Every one is marker-gated: an unknown marker yields present=False
# and the host must route that to COULD-NOT-EVALUATE, never to a verdict.
# ---------------------------------------------------------------------------
def _bits(v, n):
    return [(v >> (n + i)) & 1 for i in range(5)]


def decode_axi_nodes(v):
    present = ((v >> 24) & 0xFF) == 0xAD
    d = {"raw": v, "present": present, "marker": (v >> 24) & 0xFF}
    if not present:
        return d
    d["tgt_live"]   = dict(zip(CH_ORDER, _bits(v, 0)))
    d["ini_live"]   = dict(zip(CH_ORDER, _bits(v, 5)))
    d["tgt_wedge"]  = dict(zip(CH_ORDER, _bits(v, 10)))
    d["ini_wedge"]  = dict(zip(CH_ORDER, _bits(v, 15)))
    d["tgt_resperr"] = (v >> 20) & 1
    d["ini_resperr"] = (v >> 21) & 1
    d["any_live_stall"] = (v >> 22) & 1
    d["data_nodes_healthy"] = (v >> 23) & 1
    d["wedge_any"] = int(any(d["tgt_wedge"].values()) or any(d["ini_wedge"].values()))
    return d


def decode_fcemit(v):
    present = ((v >> 24) & 0xFF) == 0xE1
    d = {"raw": v, "present": present, "marker": (v >> 24) & 0xFF}
    if not present:
        return d
    sop   = dict(zip(CH_ORDER, _bits(v, 0)))
    grant = dict(zip(CH_ORDER, _bits(v, 8)))
    d["axi_sop_seen"] = sop
    d["axi_grant_seen"] = grant
    # The emit-starvation signature: the node presented a packet and was never
    # granted an advance. This is what auto_tx_out_advance=0 looks like from
    # outside, and it is the closest hardware analogue of "parked in state 7".
    d["starved"] = {c: int(sop[c] and not grant[c]) for c in CH_ORDER}
    d["starved_any"] = int(any(d["starved"].values()))
    d["out_advance_ever"] = (v >> 17) & 1
    d["router_io_enable"] = (v >> 16) & 1
    return d


def decode_status(v):
    return {"raw": v, "lane_locked": v & 0xFF, "lane_fault": (v >> 8) & 0xFF,
            "cal_done": (v >> 16) & 1,
            # NOTE: this is FCSM_6 (TideLinkToWlink), NOT any of the five
            # divergent AXI nodes. See the module docstring.
            "fcsm6": (v >> 17) & 0x7,
            "cr_seen": (v >> 23) & 1, "crack_seen": (v >> 24) & 1,
            "fe_rx_is_full": (v >> 31) & 1}


def read_die(inst):
    b = apb(inst)
    st = rd(b + OFF_STATUS)
    an = rd(b + OFF_AXI_NODES)
    fe = rd(b + OFF_FCEMIT_STAT)
    cr = rd(b + OFF_FC_CREDIT)
    xh = rd(b + OFF_XHB_SUB_OBS)
    ep = rd(b + OFF_EPOCH_STATUS)
    d = {
        "inst": inst, "apb_base": "0x%08X" % b,
        "status": decode_status(st),
        "axi_nodes": decode_axi_nodes(an),
        "fcemit": decode_fcemit(fe),
        "fc_credit_raw": cr, "fc_credit_present": ((cr >> 24) & 0xFF) == 0xFC,
        "xhb_sub_raw": xh, "xhb_sub_present": ((xh >> 24) & 0xFF) == 0xB5,
        "epoch_reanchored": ep & 1, "epoch_span": (ep >> 1) & 0x3F,
    }
    # link_ok is the precondition for EVERY ahb_sub touch. fcsm==4 is
    # LINK_IDLE (docs/ARCHITECTURE_PHY_LINK.md:241); cal_done gates the PHY.
    d["link_ok"] = int(d["status"]["cal_done"] == 1 and d["status"]["fcsm6"] in (4, 5))
    return d


def read_fc_crc(inst):
    b = apb(inst)
    out = {}
    for name, off in FC_AXI_NODES:
        ctl = rd(b + off + FC_SM_CONTROL)
        err = rd(b + off + FC_CRC_ERRORS)
        out[name] = {"sm_control": ctl,
                     "disable_crc": (ctl >> FC_DISABLE_CRC_BIT) & 1,
                     "crc_errors": err & 0xFFFF}
    return out


# ---------------------------------------------------------------------------
# ahb_sub traffic. ALWAYS in a worker subprocess under a wall clock: a hang
# here is the failure this whole test is about, and it must be reported, not
# inherited by the caller.
# ---------------------------------------------------------------------------
def _traffic_worker(inst, n, offset):
    """Cross-die word writes + readback through the peer window.

    This is the path that exercises the FIVE DIVERGENT nodes: an ahb_sub
    access becomes AW/W (+B) for a write and AR/R for a read, through
    XHB500 -> AXI -> Wlink. The tx_gen/RX-FIFO path used by
    kr260_onchip_soak.py does NOT: that is the TideLink sideband channel,
    which is FCSM_6 - identical in both file sets."""
    base = ahb_sub(inst) + offset
    good = bad = 0
    first_bad = None
    for i in range(n):
        a = base + 4 * i
        v = (0xA5A50000 | (i & 0xFFFF)) & 0xFFFFFFFF
        wr(a, v, allow_ahb_sub=True)
        rb = rd(a, allow_ahb_sub=True)
        if rb == v:
            good += 1
        else:
            bad += 1
            if first_bad is None:
                first_bad = {"i": i, "addr": "0x%08X" % a,
                             "wrote": "0x%08X" % v, "read": "0x%08X" % rb}
    return {"words": n, "good": good, "bad": bad, "first_bad": first_bad}


def run_worker_guarded(fn_args, timeout):
    """Run this same file as --worker under a wall clock.

    Returns (result_dict_or_None, wedged_bool, detail)."""
    argv = [sys.executable, os.path.abspath(__file__), "--worker"] + [str(a) for a in fn_args]
    try:
        p = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except Exception as e:
        return None, False, "worker spawn failed: %r" % (e,)
    t0 = time.time()
    while True:
        if p.poll() is not None:
            break
        if time.time() - t0 > timeout:
            try:
                p.kill()
            except Exception:
                pass
            # A worker that will not return inside the wall clock is the
            # WEDGE observation. It is a result.
            return None, True, "worker exceeded %.1fs wall clock" % timeout
        time.sleep(0.01)
    out = (p.stdout.read() or b"").decode("utf-8", "replace").strip()
    err = (p.stderr.read() or b"").decode("utf-8", "replace").strip()
    if p.returncode != 0 or not out:
        # Died without wedging: bus error / undecoded / exception. NOT a
        # wedge, and NOT a pass - the caller must treat it as inconclusive.
        return None, False, "worker rc=%d out=%r err=%r" % (p.returncode, out[:200], err[:400])
    try:
        return json.loads(out), False, ""
    except Exception as e:
        return None, False, "worker emitted unparseable output %r (%r)" % (out[:200], e)


def emit(payload):
    payload[MARKER_KEY] = 1
    sys.stdout.write(json.dumps(payload, sort_keys=True) + "\n")
    sys.stdout.flush()


def main():
    argv = sys.argv[1:]

    # --- worker mode: no marker, plain JSON, parent parses it -------------
    if argv and argv[0] == "--worker":
        inst, n, offset = int(argv[1]), int(argv[2]), int(argv[3], 0)
        try:
            sys.stdout.write(json.dumps(_traffic_worker(inst, n, offset)) + "\n")
        except Refused as e:
            sys.stdout.write(json.dumps({"refused": str(e)}) + "\n")
            sys.exit(4)
        return

    cmd = argv[0] if argv else "obs"
    try:
        if cmd == "obs":
            emit({"cmd": "obs", "ok": True,
                  "die_a": read_die(0), "die_b": read_die(1)})

        elif cmd == "fc_crc":
            emit({"cmd": "fc_crc", "ok": True,
                  "die_a": read_fc_crc(0), "die_b": read_fc_crc(1)})

        elif cmd == "fc_crc_set":
            # fc_crc_set <inst> <NODE|all> <disable_crc 0|1>
            inst = int(argv[1]); node = argv[2].upper(); dis = int(argv[3])
            b = apb(inst)
            touched = []
            for name, off in FC_AXI_NODES:
                if node != "ALL" and name != node:
                    continue
                a = b + off + FC_SM_CONTROL
                v = rd(a)
                nv = (v | (1 << FC_DISABLE_CRC_BIT)) if dis else (v & ~(1 << FC_DISABLE_CRC_BIT))
                wr(a, nv)
                touched.append({"node": name, "before": v, "after": rd(a)})
            emit({"cmd": "fc_crc_set", "ok": True, "inst": inst,
                  "node": node, "disable_crc": dis, "touched": touched})

        elif cmd == "traffic":
            # traffic <inst> <nwords> <byte_offset> <timeout_s>
            inst = int(argv[1]); n = int(argv[2])
            offset = int(argv[3], 0); tmo = float(argv[4])
            # HARD PRECONDITION. Never touch ahb_sub on a link that is not up.
            pre = read_die(inst)
            if not pre["link_ok"]:
                emit({"cmd": "traffic", "ok": False, "refused": True,
                      "why": "link not up (cal_done=%d fcsm6=%d) - an ahb_sub "
                             "access would hang the PS" %
                             (pre["status"]["cal_done"], pre["status"]["fcsm6"]),
                      "pre": pre})
                return
            res, wedged, detail = run_worker_guarded([inst, n, offset], tmo)
            post_a, post_b = read_die(0), read_die(1)
            emit({"cmd": "traffic", "ok": res is not None, "wedged": wedged,
                  "detail": detail, "result": res,
                  "pre": pre, "post_die_a": post_a, "post_die_b": post_b})

        elif cmd == "selftest":
            # Prove the INSTRUMENT before the DUT. Reports facts only; the
            # host decides. Never returns a verdict of its own.
            a, b = read_die(0), read_die(1)
            missing = []
            for tag, d in (("die_a", a), ("die_b", b)):
                if not d["axi_nodes"]["present"]:
                    missing.append("%s 0x21E0 marker=0x%02X want 0xAD" %
                                   (tag, d["axi_nodes"]["marker"]))
                if not d["fcemit"]["present"]:
                    missing.append("%s 0x21EC marker=0x%02X want 0xE1" %
                                   (tag, d["fcemit"]["marker"]))
                if not d["fc_credit_present"]:
                    missing.append("%s 0x219C marker missing" % tag)
                if not d["xhb_sub_present"]:
                    missing.append("%s 0x21F8 marker missing" % tag)
            # Reader liveness: two reads of a register that must not be
            # all-ones/all-zeros on a live design. A dead /dev/mem mapping
            # reads 0xFFFFFFFF or 0x00000000 for everything, which would make
            # every "bit clear" verdict below vacuous.
            raws = [a["axi_nodes"]["raw"], b["axi_nodes"]["raw"],
                    a["fcemit"]["raw"], b["fcemit"]["raw"]]
            reader_dead = all(r in (0x00000000, 0xFFFFFFFF) for r in raws)
            emit({"cmd": "selftest", "ok": not missing and not reader_dead,
                  "missing_markers": missing, "reader_dead": reader_dead,
                  "die_a": a, "die_b": b})

        else:
            emit({"cmd": cmd, "ok": False, "why": "unknown subcommand"})

    except Refused as e:
        emit({"cmd": cmd, "ok": False, "refused": True, "why": str(e)})
        sys.exit(4)
    except Exception as e:  # never die silently: the marker must still appear
        emit({"cmd": cmd, "ok": False, "why": "exception: %r" % (e,)})
        sys.exit(5)


if __name__ == "__main__":
    main()
