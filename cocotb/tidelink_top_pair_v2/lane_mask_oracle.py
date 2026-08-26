"""Pure verdict logic for the lane-mask byte-exact oracle.

Split out of test_v2_lane_mask_sweep.py on 2026-08-26 (false-green register B3)
so the verdict can be exercised against invented specimens WITHOUT a simulator.
No cocotb import, no DUT: give it a received word list and an expected word
list and it tells you every way the pair is wrong.

The defect this replaces:

    ok, got, words = await _send_strict(...)      # `ok` never read again
    corrupted = [w ^ 0xFFFFFFFF for w in words]
    false_ok = all(got[i] == corrupted[i] for i in range(4))
    assert not false_ok
    zeros_ok = all(0 == words[i] for i in range(4))   # <-- compares EXPECTED
    assert not zeros_ok                                #     against zero

`ok` — the actual byte-exact verdict — was computed and thrown away, and
`zeros_ok` tested the EXPECTED packet, which has a nonzero header, so it was a
compile-time False and `assert not zeros_ok` could never fire. On the all-zeros
RX signature this file's own docstring names (silicon 0xE5: link trains,
payload never lands), test_00 PASSED.

Control: scripts/ci/tests/test_lane_mask_oracle.py
"""

MASK32 = 0xFFFFFFFF


def expectation_is_discriminating(words):
    """Failures that make the EXPECTED packet unfit to be an oracle at all.

    Checked separately from the RX verdict because these are INSTRUMENT faults,
    not DUT faults: if the expected packet is all zeros then an all-zeros RX
    would satisfy a byte-exact compare, and the suite would be decoration.
    """
    problems = []
    if not words:
        problems.append(
            "ORACLE FAULT: the expected packet is empty — nothing to compare")
        return problems
    if all(w == 0 for w in words):
        problems.append(
            "ORACLE FAULT: the expected packet is itself all-zeros, so an "
            "all-zeros RX would byte-exact match and false-pass")
    if len(set(words)) == 1 and len(words) > 1:
        problems.append(
            "ORACLE FAULT: every expected word is identical (0x%08x) — a "
            "rotated or repeated gather could not be distinguished" % words[0])
    return problems


def oracle_verdict(got, words):
    """Return a list of failure strings. Empty list == byte-exact and sound.

    Three independent verdicts, kept separate so a green run means all three
    held and a red run says which one broke:
      1. INSTRUMENT — the expected packet must be able to discriminate.
      2. INSTRUMENT — RX must not match a bit-inverted expectation (that would
         mean the comparison is not comparing).
      3. DUT        — RX must be byte-exact, and an all-zeros RX is called out
         by name because it is the signature this suite exists to catch.
    """
    problems = list(expectation_is_discriminating(words))

    if got is None or len(got) != len(words):
        problems.append(
            "COULD-NOT-EVALUATE: received %s words, expected %d — the read "
            "path did not produce a comparable result, which is NOT a pass"
            % ("no" if got is None else str(len(got)), len(words)))
        return problems

    inverted = [(w ^ MASK32) & MASK32 for w in words]
    if words and all(got[i] == inverted[i] for i in range(len(words))):
        problems.append(
            "ORACLE FAULT: RX matched a bit-inverted expectation — the "
            "comparison is not actually comparing anything")

    byte_exact = all(got[i] == words[i] for i in range(len(words)))
    if not byte_exact:
        if all(g == 0 for g in got):
            problems.append(
                "RX IS ALL ZEROS — the silicon 0xE5 signature (link trains, "
                "payload never lands). sent=[%s] got=[%s]"
                % (", ".join("0x%08x" % w for w in words),
                   ", ".join("0x%08x" % g for g in got)))
        else:
            problems.append(
                "RX NOT BYTE-EXACT. sent=[%s] got=[%s]"
                % (", ".join("0x%08x" % w for w in words),
                   ", ".join("0x%08x" % g for g in got)))

    return problems


# --- deliberate-specimen injection for the self-test ------------------------
# test_00 exists to prove the oracle can go RED. On a healthy DUT it never
# will, so the only way to demonstrate that is to hand it a specimen. Set
# TIDELINK_ORACLE_SELFTEST_INJECT to one of these in a THROWAWAY run; the
# suite must then FAIL. It is unset in every gate invocation.
INJECTIONS = ("zeros", "inverted", "shifted", "truncated")


def inject_specimen(kind, got, words):
    """Return a deliberately wrong `got` for the named specimen."""
    if kind == "zeros":
        return [0] * len(words)
    if kind == "inverted":
        return [(w ^ MASK32) & MASK32 for w in words]
    if kind == "shifted":
        return list(words[1:]) + [0]
    if kind == "truncated":
        return list(words[:-1])
    raise ValueError(
        "unknown TIDELINK_ORACLE_SELFTEST_INJECT=%r (want one of %s)"
        % (kind, ", ".join(INJECTIONS)))
