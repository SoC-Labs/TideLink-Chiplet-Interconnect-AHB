#-----------------------------------------------------------------------------
# TideLink FPGA Stress Suite - Per-run pair state tracker
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Persists pair-run health state across invocations. Tracks lease validity,
# ribbon lane error counts, and peer reachability so a second run can skip
# bringup steps that already succeeded and resume from a known-good state.
#
# Adapted from ahb_qspi/pynq/stress/sector_state.py.
#-----------------------------------------------------------------------------

import json
import os
import time

DEFAULT_STATE_PATH = os.path.expanduser('~/.tidelink_pair_state.json')


class PairState:
    """Persistent health snapshot for one local+peer FPGA pair.

    Fields
    ------
    peer_reachable      : bool  — last SSH probe to peer succeeded
    local_lease_ok      : bool  — fpgahub lease still valid locally
    ribbon_lane_errors  : int   — cumulative lane-error count (sticky)
    bringup_order       : str   — 'die_a_first' | 'die_b_first' | 'simultaneous'
    last_run_id         : str   — ISO timestamp of the last completed run
    run_count           : int   — total stress runs logged
    """

    def __init__(self, state_path=DEFAULT_STATE_PATH):
        self.state_path       = state_path
        self.peer_reachable   = False
        self.local_lease_ok   = False
        self.ribbon_lane_errors = 0
        self.bringup_order    = 'simultaneous'
        self.last_run_id      = ''
        self.run_count        = 0
        self._load()

    # ── persistence ──────────────────────────────────────────────────────────

    def _load(self):
        try:
            with open(self.state_path) as f:
                d = json.load(f)
            self.peer_reachable     = bool(d.get('peer_reachable', False))
            self.local_lease_ok     = bool(d.get('local_lease_ok', False))
            self.ribbon_lane_errors = int(d.get('ribbon_lane_errors', 0))
            self.bringup_order      = str(d.get('bringup_order', 'simultaneous'))
            self.last_run_id        = str(d.get('last_run_id', ''))
            self.run_count          = int(d.get('run_count', 0))
        except (FileNotFoundError, ValueError, KeyError):
            pass  # first run or corrupted state — defaults are fine

    def save(self):
        try:
            with open(self.state_path, 'w') as f:
                json.dump({
                    'peer_reachable':     self.peer_reachable,
                    'local_lease_ok':     self.local_lease_ok,
                    'ribbon_lane_errors': self.ribbon_lane_errors,
                    'bringup_order':      self.bringup_order,
                    'last_run_id':        self.last_run_id,
                    'run_count':          self.run_count,
                }, f, indent=2)
        except OSError:
            pass  # non-fatal

    # ── mutators ─────────────────────────────────────────────────────────────

    def record_run_start(self, run_id=None):
        """Mark a new run beginning. Returns the run_id string."""
        if run_id is None:
            run_id = time.strftime('%Y%m%dT%H%M%S')
        self.last_run_id = run_id
        self.run_count  += 1
        self.save()
        return run_id

    def record_lane_errors(self, n):
        """Accumulate lane error count (sticky — never decrements)."""
        self.ribbon_lane_errors += n
        self.save()

    def reset(self):
        """Clear all state back to factory defaults."""
        self.peer_reachable     = False
        self.local_lease_ok     = False
        self.ribbon_lane_errors = 0
        self.bringup_order      = 'simultaneous'
        self.last_run_id        = ''
        self.run_count          = 0
        self.save()
