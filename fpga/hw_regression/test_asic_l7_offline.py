#!/usr/bin/env python3
"""test_asic_l7_offline.py - offline unit test for the ASIC-file-set L7
starvation probe. NO BOARD, NO NETWORK. Run it anywhere.

A joint work commissioned on behalf of SoC Labs, under Arm Academic Access
license.

Contributors

David Mapstone (d.a.mapstone@soton.ac.uk)

Copyright (C) 2026, SoC Labs (www.soclabs.org)

WHY THIS FILE EXISTS
--------------------
"Prove a diagnostic CAN fail before trusting it." Five diagnostics were found
in one day that could not report the thing they existed to report, and three
of those failed toward "fine". A wedge detector that can only ever say
"healthy" would turn this whole test into a machine for producing false
greens about the file set that tapes out.

So every decoder here is exercised in BOTH polarities against synthetic
register words built from the RTL's own bit layout, and the marker gating is
exercised against a word with the wrong marker. If any assertion below fails,
the hardware probe is not trustworthy and must not be run.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asic_l7_board_agent as A          # noqa: E402
import asic_l7_starvation_hwtest as H    # noqa: E402

FAILS = []


def check(name, cond, detail=""):
    if cond:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s  %s" % (name, detail))
        FAILS.append(name)


# --- 0x21E0 OBS_AXI_NODES, layout from src/rtl/tidelink_axinode_obs.sv:66-76
def axi_word(tgt_live=0, ini_live=0, tgt_wedge=0, ini_wedge=0,
             healthy=1, marker=0xAD):
    return ((marker & 0xFF) << 24) | ((healthy & 1) << 23) | \
           ((ini_wedge & 0x1F) << 15) | ((tgt_wedge & 0x1F) << 10) | \
           ((ini_live & 0x1F) << 5) | (tgt_live & 0x1F)


# --- 0x21EC FCEMIT_STAT, layout from src/rtl/tidelink_fcemit_obs.sv:56-64
def fcemit_word(sop=0, grant=0, marker=0xE1, out_adv=1):
    return ((marker & 0xFF) << 24) | ((out_adv & 1) << 17) | \
           ((grant & 0x1F) << 8) | (sop & 0x1F)


print("== marker gating ==")
d = A.decode_axi_nodes(axi_word(marker=0x00))
check("0x21E0 wrong marker -> present False", d["present"] is False)
check("0x21E0 wrong marker -> no verdict fields", "wedge_any" not in d)
d = A.decode_axi_nodes(axi_word())
check("0x21E0 right marker -> present True", d["present"] is True)
d = A.decode_fcemit(fcemit_word(marker=0x00))
check("0x21EC wrong marker -> present False", d["present"] is False)

print("== the wedge detector CAN report a wedge (both polarities) ==")
healthy = A.decode_axi_nodes(axi_word())
check("clean word -> wedge_any 0", healthy["wedge_any"] == 0)
check("clean word -> healthy 1", healthy["data_nodes_healthy"] == 1)

# AW is channel bit 0 in {r,ar,b,w,aw}
wedged_ini = A.decode_axi_nodes(axi_word(ini_wedge=0b00001, healthy=0))
check("initiator AW wedge -> wedge_any 1", wedged_ini["wedge_any"] == 1)
check("initiator AW wedge -> AW bit set", wedged_ini["ini_wedge"]["AW"] == 1)
check("initiator AW wedge -> R bit clear", wedged_ini["ini_wedge"]["R"] == 0)
check("initiator AW wedge -> healthy 0", wedged_ini["data_nodes_healthy"] == 0)

wedged_tgt = A.decode_axi_nodes(axi_word(tgt_wedge=0b10000, healthy=0))
check("target R wedge -> R bit set", wedged_tgt["tgt_wedge"]["R"] == 1)
check("target R wedge -> AW bit clear", wedged_tgt["tgt_wedge"]["AW"] == 0)

print("== the starvation detector CAN report starvation ==")
flowing = A.decode_fcemit(fcemit_word(sop=0b11111, grant=0b11111))
check("sop+grant everywhere -> starved_any 0", flowing["starved_any"] == 0)
starved = A.decode_fcemit(fcemit_word(sop=0b00001, grant=0b00000))
check("AW presented, never granted -> starved_any 1", starved["starved_any"] == 1)
check("AW presented, never granted -> AW starved", starved["starved"]["AW"] == 1)
check("AW presented, never granted -> W not starved", starved["starved"]["W"] == 0)
quiet = A.decode_fcemit(fcemit_word(sop=0b00000, grant=0b00000))
check("node never presented -> NOT called starved", quiet["starved_any"] == 0)

print("== wedge_signature composes them without laundering ==")
clean_die = {"axi_nodes": A.decode_axi_nodes(axi_word()),
             "fcemit": A.decode_fcemit(fcemit_word(sop=0b11111, grant=0b11111))}
sig = H.wedge_signature(clean_die)
check("clean die -> signature absent", sig["present"] == 0)

bad_die = {"axi_nodes": A.decode_axi_nodes(axi_word(ini_wedge=1, healthy=0)),
           "fcemit": A.decode_fcemit(fcemit_word(sop=0b00001, grant=0))}
sig = H.wedge_signature(bad_die)
check("wedged die -> signature present", sig["present"] == 1)

nomarker_die = {"axi_nodes": A.decode_axi_nodes(axi_word(marker=0)),
                "fcemit": A.decode_fcemit(fcemit_word())}
check("absent marker -> signature is None, NOT 'clean'",
      H.wedge_signature(nomarker_die) is None)

print("== ssh classification: proof of execution beats transport guessing ==")
check("rc=124 -> TIMEOUT", H.Ssh.classify(124, "", "") == H.TIMEOUT)
check("rc=255, no marker -> TRANSPORT_ERROR",
      H.Ssh.classify(255, "", "Connection reset by peer") == H.TRANSPORT_ERROR)
# The marker must be PASSED for proof-of-execution to outrank the transport
# signature - exactly as the caller does. Without it, a real board failure
# that also tripped an ssh error string would be retried as "transport" and
# the failure silently swallowed. This case asserts both halves.
check("rc=255 WITH marker -> RAN (a real board failure, not transport)",
      H.Ssh.classify(255, '{"tl_asic_l7":1,"ok":false}', "Connection reset",
                     marker=H.MARKER_KEY) == H.RAN)
check("rc=255, marker EXPECTED but absent -> TRANSPORT_ERROR",
      H.Ssh.classify(255, "", "Connection reset", marker=H.MARKER_KEY)
      == H.TRANSPORT_ERROR)
check("rc=0 with marker -> OK",
      H.Ssh.classify(0, '{"tl_asic_l7":1}', "") == H.OK)
check("rc=1 no marker, no transport signature -> RAN",
      H.Ssh.classify(1, "boom", "") == H.RAN)

print("== a result line without the marker is NOT a result ==")
r = H.Res(0, '{"ok": true}\n', "", H.OK, 1, "h", "c")
check("unmarked JSON -> json() is None", r.json() is None)
r = H.Res(0, 'noise\n{"tl_asic_l7":1,"ok":true}\nnoise\n', "", H.OK, 1, "h", "c")
check("marked JSON among noise -> parsed", (r.json() or {}).get("ok") is True)
r = H.Res(0, "", "", H.OK, 1, "h", "c")
check("empty stdout -> describe() says the command did not run",
      "did not run" in r.describe())

print("== the address guard refuses what would wedge the PS ==")
def refused(addr, allow=False):
    try:
        A._guard(addr, allow)
        return False
    except A.Refused:
        return True

check("APB die_a 0x2108 allowed", not refused(0x84030000 + 0x2108))
check("APB die_b 0x2108 allowed", not refused(0x8C030000 + 0x2108))
check("hard-stall 0x21AC REFUSED", refused(0x84030000 + 0x21AC))
check("hard-stall 0x21B0 REFUSED", refused(0x84030000 + 0x21B0))
check("hard-stall 0x21B4 REFUSED", refused(0x84030000 + 0x21B4))
check("ahb_sub REFUSED unless explicitly allowed", refused(0x80001000))
check("ahb_sub allowed when explicitly allowed", not refused(0x80001000, True))
# 0x8888_8888 is INSIDE die_b's ahb_sub (0x8800_0000 + 64 MB), so it must be
# ALLOWED when ahb_sub is allowed - asserting it here keeps the window bounds
# honest rather than assuming a big-looking address is out of range.
check("0x88888888 is inside die_b ahb_sub -> allowed", not refused(0x88888888, True))
check("0x8C000000 is past die_b ahb_sub end -> REFUSED", refused(0x8C000000, True))
check("undecoded 0xB0000000 REFUSED", refused(0xB0000000, True))
check("undecoded 0x90000000 REFUSED", refused(0x90000000, True))
check("ahb_tx 0xA4000000 REFUSED (this test never writes the TX aperture)",
      refused(0xA4000000, True))
check("PS periph 0xFD000000 REFUSED", refused(0xFD000000, True))
check("DDR 0x00100000 REFUSED", refused(0x00100000, True))
check("eth-chiplet-style 0x4403_2108 REFUSED (wrong SoC map)",
      refused(0x44032108))

print("")
if FAILS:
    print("OFFLINE TEST FAILED (%d): %s" % (len(FAILS), ", ".join(FAILS)))
    print("The hardware probe is NOT trustworthy. Do not run it on a board.")
    sys.exit(1)
print("OFFLINE TEST PASSED - every detector was shown to report BOTH polarities,")
print("marker gating yields no-result (not 'clean'), and the address guard")
print("refuses every wedge-prone address it was given.")
