#!/usr/bin/env python3
"""Prove no pre-existing TL-001..TL-035 entry LOST a field or had one silently
changed. Reports, per entry: keys removed, keys added, and leaf values changed.
Also verifies TL-036..TL-042 each carry their own complete field set.
"""
import sys
import yaml

pre_path, post_path = sys.argv[1], sys.argv[2]


def load(p):
    with open(p) as fh:
        docs = list(yaml.safe_load_all(fh.read()))
    out = {}
    for d in docs:
        if isinstance(d, dict) and isinstance(d.get("bugs"), list):
            for b in d["bugs"]:
                if isinstance(b, dict) and "id" in b:
                    out[b["id"]] = b
    return out


pre, post = load(pre_path), load(post_path)

# Keys intentionally renamed during the merge (old -> new); not a loss.
RENAMED = {
    "TL-035": {
        "verification": "verification_superseded_2026_08_09",
        "signoff": "signoff_superseded_2026_08_09",
    },
}

print("=" * 78)
print("PART 1 — pre-existing entries: did anything get LOST or silently CHANGED?")
print("=" * 78)
lost_any = False
for bid in sorted(pre):
    a, b = pre[bid], post.get(bid)
    if b is None:
        print("  %s: *** ENTRY VANISHED ***" % bid)
        lost_any = True
        continue
    ren = RENAMED.get(bid, {})
    removed = []
    for k in a:
        if k in b:
            continue
        if ren.get(k) in b:
            continue  # renamed, content preserved (verified below)
        removed.append(k)
    added = [k for k in b if k not in a]
    changed = []
    for k in a:
        if k in b and b[k] != a[k]:
            changed.append(k)
        elif k not in b and ren.get(k) in b:
            if b[ren[k]] != a[k]:
                changed.append("%s->%s (CONTENT DIFFERS)" % (k, ren[k]))
            else:
                added_note = "%s -> %s (renamed, content byte-identical)" % (k, ren[k])
                changed.append(added_note) if False else None
    if removed:
        lost_any = True
    if removed or added or changed:
        print("\n  %s" % bid)
        if removed:
            print("    LOST KEYS      : %s   <-- PROBLEM" % ", ".join(removed))
        if changed:
            print("    CHANGED VALUES : %s" % ", ".join(changed))
        if added:
            print("    ADDED KEYS     : %s" % ", ".join(added))
        for k, nk in ren.items():
            if k in a and nk in b:
                same = "byte-identical" if b[nk] == a[k] else "*** DIFFERS ***"
                print("    RENAMED        : %s -> %s (%s)" % (k, nk, same))
                if b[nk] != a[k]:
                    lost_any = True

if not lost_any:
    print("\n  RESULT: no pre-existing entry lost a field. "
          "(Renames preserved content byte-identically.)")
else:
    print("\n  RESULT: *** FIELD LOSS DETECTED ***")

print()
print("=" * 78)
print("PART 2 — new entries TL-036..TL-042 carry their OWN complete fields")
print("=" * 78)
NEW = ["TL-036", "TL-037", "TL-038", "TL-039", "TL-040", "TL-041", "TL-042"]
CORE = ["id", "title", "severity", "area", "status", "summary",
        "verification", "signoff"]
ok = True
for bid in NEW:
    e = post.get(bid)
    if e is None:
        print("  %s: *** MISSING ***" % bid)
        ok = False
        continue
    missing = [k for k in CORE if k not in e]
    ver = e.get("verification")
    sig = e.get("signoff")
    flag = ""
    if missing:
        flag = "  MISSING: %s" % ", ".join(missing)
        ok = False
    print("  %-7s status=%-11s keys=%-2d verification=%-6s signoff=%-6s%s" % (
        bid, e.get("status"), len(e),
        "OK" if isinstance(ver, dict) and ver else "EMPTY",
        "OK" if isinstance(sig, dict) and sig else "EMPTY", flag))

print()
print("  --- TL-041 deep check (the entry that was silently shadowed before) ---")
t41 = post.get("TL-041", {})
v41, s41 = t41.get("verification"), t41.get("signoff")
print("    verification keys : %s" % (sorted(v41) if isinstance(v41, dict) else v41))
print("    signoff keys      : %s" % (sorted(s41) if isinstance(s41, dict) else s41))
print("    verification.sim_test starts: %r" % (str(v41.get("sim_test"))[:60]
                                                if isinstance(v41, dict) else None))
print("    signoff.claude_verdict starts: %r" % (str(s41.get("claude_verdict"))[:60]
                                                 if isinstance(s41, dict) else None))
tl35_leak = isinstance(s41, dict) and "TL-035" in str(s41.get("claude_verdict", ""))
print("    TL-035 text leaked into TL-041 signoff? %s" % ("YES *** BUG ***" if tl35_leak else "no"))

print()
print("  --- TL-042 correction check ---")
t42 = post.get("TL-042", {})
print("    status                        : %s" % t42.get("status"))
print("    rejected_candidate block      : %s" % (
    "present (%d keys)" % len(t42["rejected_candidate_2026_08_13"])
    if isinstance(t42.get("rejected_candidate_2026_08_13"), dict) else "MISSING"))
print("    cites REJECTED result doc     : %s" % (
    "yes" if "TL042_HW_RESULT_REJECTED_2026_08_13.md" in yaml.dump(t42) else "NO"))
print("    claims fixed?                 : %s" % (
    "NO (good)" if t42.get("status") in ("open",) else "CHECK"))

sys.exit(0 if (not lost_any and ok) else 1)
