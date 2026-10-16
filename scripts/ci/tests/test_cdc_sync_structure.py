#!/usr/bin/env python3
"""Must-fail controls for scripts/ci/cdc_sync_structure.py (TL-051 / TL-055).

The structural gate is only worth anything if it can go red.  This builds
mutants of the REAL RTL in memory, each one reverting (part of) a CDC fix, and
asserts:
  * the unmodified RTL is green in all three check groups;
  * every mutant is red in exactly the check group(s) it should be, and in no
    other (so a mutant cannot be "caught" by an unrelated accident);
  * every textual mutation actually applied (a no-op mutant would be a fake red).
Pure python, no simulator.  Run by `make selfcheck_gates` (scripts/ci/tests/test_*.py).
"""
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import cdc_sync_structure as G  # noqa: E402

G_I2C, G_CTRL, G_CAL, G_R2 = ("TL-051 i2c pad 2-flop sync",
                              "TL-055 controller swreset single flop",
                              "TL-055 calibrator swreset_sync chain",
                              "TL-051 R2 calibrator training-hold 2-flop sync")

RAW_CONSUMERS = lambda s: re.subn(r"(\.i2c_(scl|sda)_i\s*\()\s*i2c_\2_i_sync\s*\)", r"\1i2c_\2_i)", s)


def sub(pattern, repl, flags=0, count_min=1):
    def f(s):
        out, n = re.subn(pattern, repl, s, flags=flags)
        assert n >= count_min, "mutation did not apply: %s" % pattern
        return out
    return f


# name -> (file 'ctrl'|'cal', mutation, expected red groups)
MUTANTS = [
    ("R1 consumers read the raw pads (3 instances x 2 pins)", "ctrl",
     lambda s: (lambda r: (r[0] if r[1] == 6 else (_ for _ in ()).throw(AssertionError("expected 6 consumers, got %d" % r[1]))))(RAW_CONSUMERS(s)),
     {G_I2C}),
    ("R1 only u_autoneg.sda raw (partial revert)", "ctrl",
     sub(r"(u_autoneg\s*\([^;]*?\.i2c_sda_i\s*\()\s*i2c_sda_i_sync\s*\)", r"\1i2c_sda_i)", re.S),
     {G_I2C}),
    ("R1 one flop only: i2c_*_i_sync = first stage", "ctrl",
     sub(r"(wire\s+i2c_(scl|sda)_i_sync\s*=\s*)i2c_\2_s2\s*;", r"\1i2c_\2_s1;", count_min=2),
     {G_I2C}),
    ("R1 synchroniser removed: i2c_*_i_sync = raw pad", "ctrl",
     sub(r"(wire\s+i2c_(scl|sda)_i_sync\s*=\s*)i2c_\2_s2\s*;", r"\1i2c_\2_i;", count_min=2),
     {G_I2C}),
    ("R1 synchroniser on the wrong clock (apb_clk -> hclk)", "ctrl",
     sub(r"(always\s*@\s*\(\s*posedge\s+)apb_clk(\s+or\s+negedge\s+poresetn\s*\)\s*begin\s*if\s*\(\s*!poresetn\s*\)\s*begin\s*i2c_scl_s1)",
         r"\1hclk\2"),
     {G_I2C}),
    ("H30 comb merge back on u_calibrator.swreset", "ctrl",
     sub(r"\.swreset(\s*)\(\s*cal_swreset_q\s*\)",
         r".swreset\1(swi_recal_r | (local_swreset_pulse_w & ~(cal_eye_converged_r | sync_cal_in_hold_1)))"),
     {G_CTRL}),
    ("H30 cal_swreset_q also driven by a continuous assign", "ctrl",
     sub(r"(reg\s+cal_swreset_q\s*;)", r"\1\n    assign cal_swreset_q = swi_recal_r | local_swreset_pulse_w;"),
     {G_CTRL}),
    ("H30 cal_swreset_q flop moved to the wrong clock (apb_clk -> hclk)", "ctrl",
     sub(r"(always_ff\s*@\s*\(\s*posedge\s+)apb_clk(\s+or\s+negedge\s+poresetn\s*\)\s*begin\s*if\s*\(\s*!poresetn\s*\)\s*cal_swreset_q)",
         r"\1hclk\2"),
     {G_CTRL}),
    ("H31/H30 calibrator consumes raw swreset (swreset_sync = swreset)", "cal",
     sub(r"(wire\s+swreset_sync\s*=\s*)swreset_s2\s*;", r"\1swreset;"),
     {G_CAL}),
    ("calibrator swreset_sync = first stage only", "cal",
     sub(r"(wire\s+swreset_sync\s*=\s*)swreset_s2\s*;", r"\1swreset_s1;"),
     {G_CAL}),
    ("calibrator second stage bypassed (s2 <= swreset)", "cal",
     sub(r"swreset_s2(\s*)<=(\s*)swreset_s1\s*;", r"swreset_s2\1<=\2swreset;"),
     {G_CAL}),
    ("R2 mode flop reads the raw hold input (second stage bypassed)", "cal",
     sub(r"(swi_training_mode_r\s*<=\s*)swi_training_hold_s1\s*;", r"\1swi_training_hold_i;"),
     {G_R2}),
    ("R2 FSM consumes the metastable first stage", "cal",
     lambda s: s.replace("&& !swi_training_mode_r) nxt_state = S_VALIDATE",
                         "&& !swi_training_hold_s1) nxt_state = S_VALIDATE", 1) if "&& !swi_training_mode_r) nxt_state = S_VALIDATE" in s else (_ for _ in ()).throw(AssertionError("mutation did not apply: R2 consume")),
     {G_R2}),
]


def evaluate(ctrl_text, cal_text):
    with tempfile.TemporaryDirectory() as d:
        cp, lp = os.path.join(d, "ctrl.sv"), os.path.join(d, "cal.sv")
        open(cp, "w").write(ctrl_text)
        open(lp, "w").write(cal_text)
        return {name: fails for name, fails, _ in G.run(cp, lp)}


def main():
    ctrl_text = open(G.CTRL_DEFAULT, errors="replace").read()
    cal_text = open(G.CAL_DEFAULT, errors="replace").read()
    bad = 0

    base = evaluate(ctrl_text, cal_text)
    red = [k for k, v in base.items() if v]
    if red or len(base) != 4:
        print("CONTROL FAILED: unmodified RTL is not green: %s" % (red or "wrong group count"))
        for k in red:
            for f in base[k]:
                print("    " + f)
        bad += 1
    else:
        print("ok   baseline: unmodified RTL green in all 4 groups")

    for name, which, mut, expect in MUTANTS:
        try:
            if which == "ctrl":
                res = evaluate(mut(ctrl_text), cal_text)
            else:
                res = evaluate(ctrl_text, mut(cal_text))
        except AssertionError as e:
            print("CONTROL FAILED: %s: %s" % (name, e))
            bad += 1
            continue
        got = {k for k, v in res.items() if v}
        if got == expect:
            first = [f for k in sorted(got) for f in res[k]][0]
            print("ok   mutant RED  %-62s -> %s" % (name, first[:110]))
        else:
            bad += 1
            print("CONTROL FAILED: %s: red groups %s, expected %s" % (name, sorted(got), sorted(expect)))
    print("test_cdc_sync_structure: %s" % ("FAIL (%d)" % bad if bad else "PASS (baseline green + %d mutants red)" % len(MUTANTS)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
