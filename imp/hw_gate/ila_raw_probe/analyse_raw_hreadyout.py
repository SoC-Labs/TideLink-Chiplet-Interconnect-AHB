#!/usr/bin/env python3
"""analyse_raw_hreadyout.py -- decode the die_a ILA CSV for the TL-042
xhb_sub_hreadyout_raw question (2026-08-13).

VACUITY GUARD RUNS FIRST and its verdict is printed before any probe is
interpreted, per imp/hw_gate/PREREG_RAW_HREADYOUT_PROBE_2026_08_13.md.

HEX-FIRST PARSING IS MANDATORY. Vivado writes multi-bit probes as UNPREFIXED
HEX; row 2 of the CSV is a literal `Radix - UNSIGNED,...,HEX,HEX,...` line that
states this. A base-10-first parser turns 0x1600 into 1600 and fabricated 100
fake counter drops earlier today. This parser is hex-only for probe columns and
SKIPS the Radix row (DictReader would otherwise ingest it as data).

  usage: analyse_raw_hreadyout.py <ila_capture.csv>
"""
import csv, sys, collections

PROBES = ['xhb_sub_hreadyout_raw', 'sub_stall_busy', 'sub_stall_ctr_r', 'wr_hold_r',
          'sub_rd_os_r', 'synth_b_pending', 'sub_err1_r', 'sub_err2_r',
          'ext_is_nonseq', 'pipe_valid_r', 'rd_pipe_r', 'sub_wr_os_ctr',
          # vacuity cross-check: known-live signals, as the round-1 capture used
          'dbg_fcsm_state', 'dbg_cr_seen']

rows = list(csv.reader(open(sys.argv[1])))
hdr = rows[0]
# Drop the Radix row and any blank trailing rows.
data = [r for r in rows[1:] if r and not r[0].startswith('Radix') and len(r) == len(hdr)]

def col(name):
    """Exact leaf match on the hierarchical column name, so that a substring of
    one probe cannot silently select another (e.g. *hreadyout* matches BOTH
    dbg_tx_hreadyout and xhb_sub_hreadyout_raw)."""
    hits = []
    for i, c in enumerate(hdr):
        leaf = c.split('/')[-1].split('[')[0]
        if leaf == name:
            hits.append(i)
    return hits

def hexval(s):
    s = str(s).strip().strip("'")
    if s.lower().startswith('0x'):
        s = s[2:]
    try:
        return int(s, 16)          # HEX FIRST, and hex ONLY.
    except ValueError:
        return None

series = {}
missing = []
for p in PROBES:
    idx = col(p)
    if len(idx) != 1:
        missing.append('%s(hits=%d)' % (p, len(idx)))
        continue
    i = idx[0]
    series[p] = [hexval(r[i]) for r in data]

trig_i = hdr.index('TRIGGER') if 'TRIGGER' in hdr else None
trig = [int(r[trig_i]) for r in data] if trig_i is not None else []

print('samples=%d   columns=%d' % (len(data), len(hdr)))
if missing:
    print('PROBES MISSING/AMBIGUOUS:', missing)

# ---------------- VACUITY GUARD (must be read before anything else) --------
sc = series.get('sub_stall_ctr_r') or []
wh = series.get('wr_hold_r') or []
fc = series.get('dbg_fcsm_state') or []
cr = series.get('dbg_cr_seen') or []
sc_d = len(set(sc)); sc_min = min(sc) if sc else None; sc_max = max(sc) if sc else None
wh_ones = sum(1 for v in wh if v)
fc_set = sorted(set(fc)); cr_set = sorted(set(cr))

g_ramp   = sc_d > 1
g_hold   = bool(wh) and all(v == 1 for v in wh)
g_live   = (4 in fc_set) or (1 in cr_set)
print()
print('===== VACUITY GUARD =====')
print('  sub_stall_ctr_r : min=%s max=%s distinct=%s   -> ramp %s'
      % (sc_min, sc_max, sc_d, 'PRESENT' if g_ramp else 'ABSENT'))
print('  wr_hold_r       : ones=%d/%d               -> %s'
      % (wh_ones, len(wh), 'HELD 1 (wedge state)' if g_hold else 'NOT held 1'))
print('  dbg_fcsm_state  : values=%s   dbg_cr_seen values=%s -> known-live %s'
      % (fc_set, cr_set, 'YES' if g_live else 'NO'))
verdict_valid = g_ramp and g_hold and g_live
print('  VERDICT: %s' % ('CAPTURE VALID -- safe to interpret'
                         if verdict_valid else
                         'VOID -- guard failed; this run reports NOTHING'))

# ---------------- per-probe window summary --------------------------------
print()
print('===== PER-PROBE WINDOW SUMMARY (hex-parsed) =====')
print('  %-24s %-8s %-8s %-8s %-8s' % ('probe', 'min', 'max', 'ones', 'distinct'))
for p in PROBES:
    v = series.get(p)
    if not v:
        continue
    vv = [x for x in v if x is not None]
    print('  %-24s %-8s %-8s %-8s %-8s'
          % (p, min(vv), max(vv), sum(1 for x in vv if x), len(set(vv))))

if trig:
    ti = [i for i, t in enumerate(trig) if t]
    print('  TRIGGER column: asserted at sample index %s' % (ti if ti else 'NEVER (forced capture window)'))

# ---------------- the answer ----------------------------------------------
raw = series.get('xhb_sub_hreadyout_raw') or []
print()
print('===== xhb_sub_hreadyout_raw =====')
if raw:
    c = collections.Counter(raw)
    print('  value histogram: %s' % dict(c))
    print('  first sample=%s  last sample=%s' % (raw[0], raw[-1]))
    if len(set(raw)) == 1:
        print('  FROZEN VALUE = %d across all %d samples' % (raw[0], len(raw)))

# ---------------- P3: the N1 coincidence check ----------------------------
sb = series.get('synth_b_pending') or []
e1 = series.get('sub_err1_r') or []
ro = series.get('sub_rd_os_r') or []
print()
print('===== P3 / N1 COINCIDENCE =====')
if sb and e1 and ro:
    hits = [i for i in range(len(sb)) if sb[i] == 1 and e1[i] == 0 and ro[i] == 0]
    print('  samples with synth_b_pending=1 AND sub_err1_r=0 AND sub_rd_os_r=0: %d' % len(hits))
    if hits:
        print('  sample indices (first 10): %s' % hits[:10])
else:
    print('  one or more of synth_b_pending / sub_err1_r / sub_rd_os_r unreadable')

# ---------------- transition census, for the frozen-vs-live question -------
print()
print('===== TRANSITION CENSUS (how static is the window?) =====')
for p in PROBES:
    v = series.get(p)
    if not v:
        continue
    tr = sum(1 for i in range(1, len(v)) if v[i] != v[i - 1])
    print('  %-24s transitions=%d' % (p, tr))
