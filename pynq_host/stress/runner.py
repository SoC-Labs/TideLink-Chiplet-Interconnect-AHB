#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# TideLink FPGA Stress Suite - Time-bounded orchestrator
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Usage:
#   python3 -m pynq.stress.runner --solo [--budget S] [--tests t1 t2 ...]
#   python3 -m pynq.stress.runner --pair [--peer-ssh USER@HOST]
#                                        [--peer-proxy HOST]
#                                        [--local-role die_a|die_b]
#                                        [--peer-role  die_a|die_b]
#                                        [--pair-id ID]
#                                        [--budget S] [--tests ...]
#   python3 -m pynq.stress.runner --list
#-----------------------------------------------------------------------------

import argparse
import json
import logging
import os
import subprocess
import sys
import time
import traceback

_HERE   = os.path.dirname(os.path.abspath(__file__))
_PYNQ   = os.path.dirname(_HERE)
_ROOT   = os.path.dirname(_PYNQ)
for _p in (_ROOT, _PYNQ, _HERE):
    if _p not in sys.path:
        sys.path.insert(0, _p)

try:
    from .bridge_tests import ALL_TESTS, DEFAULT_BUDGETS
    from .tidelink_hw  import TidelinkHw
    from .pair_state   import PairState
except ImportError:
    from bridge_tests import ALL_TESTS, DEFAULT_BUDGETS
    from tidelink_hw  import TidelinkHw
    from pair_state   import PairState

# Lazy overlay import with bare-metal fallback. The framework-backed
# overlay (pynq_host.overlay) needs the system PYNQ Python package
# installed on the board; minimal PYNQ images don't ship it. When
# that import fails, fall back to pynq_host.bare_overlay which uses
# /dev/mem + /sys/class/fpga_manager directly and has the same API
# surface (it's in-tree exactly for this purpose).
TidelinkOverlay = None
_overlay_import_error = None
try:
    from pynq_host.overlay import TidelinkOverlay  # noqa: F811
except ImportError as _e:
    _framework_err = repr(_e)
    try:
        from pynq_host.bare_overlay import TidelinkBareOverlay as TidelinkOverlay  # noqa: F811
    except ImportError as _e2:
        _overlay_import_error = (
            'pynq_host.overlay failed: %s; '
            'pynq_host.bare_overlay failed: %s' % (_framework_err, repr(_e2))
        )

log = logging.getLogger('stress.runner')

LOGS_DIR = os.path.join(_HERE, 'logs')


# ── Peer proxy ───────────────────────────────────────────────────────────────

class PeerProxy:
    """JSON-lines RPC client connected to peer_agent over SSH subprocess."""

    def __init__(self, ssh_target, proxy=None, peer_role='die_b'):
        self._next_id = 0
        # Test-rig SSH options: bypass host-key checking on both this hop
        # and the proxy hop. Authentication is still gated by the per-board
        # key trust set up by provision_pynq_peer_keys.sh.
        ssh_opts = [
            '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'LogLevel=ERROR',
        ]
        # The runner is launched under `sudo -E` on the board, so $HOME is
        # /root and the default key search misses xilinx's keypair. Point
        # ssh at xilinx's identity explicitly when present (PYNQ default
        # path) so the proxy hop can authenticate as the trusted xilinx@board
        # identity rather than as root.
        xilinx_key = '/home/xilinx/.ssh/id_ed25519'
        if os.path.exists(xilinx_key):
            ssh_opts += ['-i', xilinx_key, '-o', 'IdentitiesOnly=yes']
        cmd = ['ssh', *ssh_opts]
        if proxy:
            # Use ProxyCommand (not ProxyJump) so we can pass -o flags into
            # the inner ssh — ProxyJump's child ssh ignores `-o` set on the
            # outer command line and falls back to strict host-key checking,
            # which fails on a fresh board with empty known_hosts.
            inner = ['ssh', '-W', '%h:%p', *ssh_opts, proxy]
            cmd += ['-o', 'ProxyCommand=' + ' '.join(inner)]
        # Run the peer agent from the deployed overlay directory so
        # `python3 -m pynq_host.*` finds the package on PYTHONPATH (`.`).
        # The peer agent itself doesn't need sudo/MMIO access for the SSH
        # handshake — it only loads the overlay once tests start, so we
        # can run it as the xilinx user. (When tests need MMIO, peer_agent
        # internally re-execs sudo for the relevant subcommand.)
        remote_cmd = (
            'cd /home/xilinx/tidelink_overlay && '
            'sudo -E -n python3 -m pynq_host.stress.peer_agent '
            f'--role {peer_role}'
        )
        cmd += [ssh_target, remote_cmd]
        log.info('Spawning peer agent: %s', ' '.join(cmd))
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        # Wait for ready event
        for _ in range(20):
            line = self._proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line)
                if msg.get('event') == 'ready':
                    log.info('Peer agent ready (role=%s)', msg.get('role'))
                    break
            except json.JSONDecodeError:
                pass

    def call(self, method, **params):
        req_id = self._next_id
        self._next_id += 1
        req = json.dumps({'id': req_id, 'method': method, 'params': params})
        self._proc.stdin.write(req + '\n')
        self._proc.stdin.flush()
        for _ in range(50):
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError('peer agent closed stdout')
            try:
                resp = json.loads(line)
            except json.JSONDecodeError:
                continue
            if resp.get('id') == req_id:
                if 'error' in resp:
                    raise RuntimeError(f'peer RPC error: {resp["error"]}')
                return resp.get('result')
        raise TimeoutError(f'no response from peer for {method!r}')

    def get_credit_count(self):
        return self.call('get_credit_count')

    def flush(self):
        return self.call('flush')

    def wait_returner_idle(self, timeout_ms=200):
        return self.call('wait_returner_idle', timeout_ms=timeout_ms)

    def close(self):
        try:
            self._proc.stdin.close()
            self._proc.wait(timeout=5)
        except Exception:
            self._proc.kill()


# ── Helpers ──────────────────────────────────────────────────────────────────

def _setup_logging(verbose):
    fmt = '%(asctime)s.%(msecs)03d %(name)s %(levelname)s %(message)s'
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO,
                        format=fmt, datefmt='%H:%M:%S')
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass


def _load_overlay(role='die_a'):
    if TidelinkOverlay is None:
        raise ImportError(
            'TidelinkOverlay not importable from pynq_host.overlay; '
            'underlying error: %s' % (_overlay_import_error or 'unknown')
        )
    overlay = TidelinkOverlay()
    # Bring the link out of POR. fpga_manager firmware reload clears
    # role_lock (W1S, POR-only clear), so without this every stress run
    # starts with the link held in reset → returner stays busy → every
    # test fails fast on wait_returner_idle. lock_role() also writes
    # swi_phase_offset for the slave side (SHORTCOMINGS-14b fix).
    if hasattr(overlay, 'lock_role') and overlay.strap is not None:
        cfg = overlay.lock_role(role)
        log.info('Locked role=%s, ROLE_CFG=0x%02x (lock=%d, cfg=%d)',
                 role, cfg, (cfg >> 1) & 1, cfg & 1)
    return overlay


def _scale_budgets(total_s, selected):
    raw = {t: DEFAULT_BUDGETS.get(t, 60) for t in selected}
    raw_total = sum(raw.values()) or 1
    return {t: max(15.0, total_s * v / raw_total) for t, v in raw.items()}


def _jsonl_append(path, record):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, 'a') as f:
            f.write(json.dumps(record) + '\n')
    except OSError as exc:
        log.warning('could not append to log: %s', exc)


class _TestTimeout(Exception):
    """Raised when a test exceeds its per-test budget."""


def _alarm_handler(signum, frame):
    raise _TestTimeout(f'exceeded budget')


def _run_test(entry, local_hw, peer, budget_s, log_path):
    """Execute one test entry; return summary dict."""
    name = entry['id']
    tags = entry['tags']

    if 'skip' in tags:
        log.info('SKIP %s (tagged skip)', name)
        record = dict(name=name, started_at=time.time(), duration_s=0.0,
                      ok=None, skipped=True, errors=[], counters={})
        _jsonl_append(log_path, record)
        return record

    started_at = time.time()
    log.info('BEGIN %s (budget=%.0fs tags=%s)', name, budget_s, tags)
    ok = False
    errors = []
    counters = {}
    # Per-test wall-clock cap via SIGALRM. Tests that wait on hardware
    # state (e.g. wait_returner_idle on a stuck FCSM) can otherwise spin
    # forever and risk wedging the AXI subsystem on the PS. Round up to
    # 1s minimum; alarm() takes integer seconds.
    import signal
    cap_s = max(1, int(budget_s) + 1)
    prev_handler = signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(cap_s)
    try:
        ok, errors, counters = entry['fn'](local_hw, peer)
    except _TestTimeout:
        errors.append(f'TestTimeout: exceeded {budget_s:.0f}s budget')
        log.error('TIMEOUT %s after %.0fs', name, budget_s)
    except Exception as exc:             # noqa: BLE001
        errors.append(f'{type(exc).__name__}: {exc}')
        log.error('TRACEBACK %s:\n%s', name, traceback.format_exc())
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, prev_handler)
    duration_s = time.time() - started_at
    record = dict(name=name, started_at=started_at, duration_s=round(duration_s, 3),
                  ok=ok, errors=errors, counters=counters)
    _jsonl_append(log_path, record)
    log.info('END %s ok=%s duration=%.1fs errors=%d',
             name, ok, duration_s, len(errors))
    if not ok and errors:
        for err in errors:
            log.error('  err: %s', err)
    return record


# ── CLI entry point ──────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description='TideLink bridge stress runner')
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--solo',   action='store_true',
                      help='Load overlay locally; run solo-tagged tests')
    mode.add_argument('--pair',   action='store_true',
                      help='Load overlay + spawn peer_agent; run pair-tagged tests')
    mode.add_argument('--list',   action='store_true',
                      help='Print test catalogue and exit')

    ap.add_argument('--peer-ssh',    default=None,
                    help='user@host for peer board SSH (or $FPGAHUB_PEER_HOST_SSH)')
    ap.add_argument('--peer-proxy',  default=None,
                    help='ProxyJump host (or $FPGAHUB_PEER_HOST_PROXY)')
    ap.add_argument('--local-role',  default=None,
                    choices=['die_a', 'die_b'],
                    help='Local role (or $FPGAHUB_LOCAL_ROLE)')
    ap.add_argument('--peer-role',   default=None,
                    choices=['die_a', 'die_b'],
                    help='Peer role (or $FPGAHUB_PEER_ROLE)')
    ap.add_argument('--pair-id',     default=None,
                    help='Pair ID (or $FPGAHUB_PAIR_ID)')
    ap.add_argument('--budget',      type=float, default=None,
                    help='Total budget in seconds')
    ap.add_argument('--tests',       nargs='+',  default=None,
                    help='Subset of tests (default: all matching tag)')
    ap.add_argument('--run-skipped', action='store_true',
                    help='Run tests tagged "skip" as well')
    ap.add_argument('--fail-fast',   action='store_true',
                    help='Stop after the first failed test (useful when each '
                         'failure may risk wedging the board).')
    ap.add_argument('--log-dir',     default=LOGS_DIR,
                    help='Directory for .jsonl run logs')
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()

    if args.list:
        print(f"{'ID':<30} {'TAGS':<20} DESCRIPTION")
        print('-' * 80)
        for entry in ALL_TESTS.values():
            print(f"{entry['id']:<30} {','.join(entry['tags']):<20} {entry['description']}")
        return 0

    _setup_logging(args.verbose)

    # Resolve env fallbacks
    peer_ssh   = args.peer_ssh   or os.environ.get('FPGAHUB_PEER_HOST_SSH',  '')
    peer_proxy = args.peer_proxy or os.environ.get('FPGAHUB_PEER_HOST_PROXY', '')
    local_role = args.local_role or os.environ.get('FPGAHUB_LOCAL_ROLE', 'die_a')
    peer_role  = args.peer_role  or os.environ.get('FPGAHUB_PEER_ROLE',  'die_b')
    pair_id    = args.pair_id    or os.environ.get('FPGAHUB_PAIR_ID',
                                                    time.strftime('%Y%m%dT%H%M%S'))

    # Filter catalogue
    tag_filter = 'pair' if args.pair else 'solo'
    candidate_ids = [e['id'] for e in ALL_TESTS.values()
                     if tag_filter in e['tags']
                     and (args.run_skipped or 'skip' not in e['tags'])]
    if args.tests:
        unknown = set(args.tests) - set(ALL_TESTS)
        if unknown:
            log.error('Unknown test(s): %s', unknown)
            return 2
        selected = [t for t in args.tests if t in candidate_ids]
    else:
        selected = candidate_ids

    if not selected:
        log.warning('No tests to run for tag=%s', tag_filter)
        return 0

    total_budget = args.budget if args.budget is not None \
        else sum(DEFAULT_BUDGETS.get(t, 60) for t in selected)
    budgets = _scale_budgets(total_budget, selected)
    log.info('Mode=%s role=%s tests=%d budget=%.0fs pair_id=%s',
             tag_filter, local_role, len(selected), total_budget, pair_id)

    # Load overlay
    try:
        overlay = _load_overlay(local_role)
    except ImportError as exc:
        log.error('Overlay unavailable: %s', exc)
        return 2
    local_hw = TidelinkHw(overlay, role=local_role)

    # Spawn peer agent if needed
    peer = None
    if args.pair:
        if not peer_ssh:
            log.error('--pair requires --peer-ssh or $FPGAHUB_PEER_HOST_SSH')
            return 2
        peer = PeerProxy(peer_ssh, proxy=peer_proxy or None, peer_role=peer_role)

    state = PairState()
    run_id = state.record_run_start(pair_id)
    log_path = os.path.join(args.log_dir, f'{run_id}.jsonl')
    os.makedirs(args.log_dir, exist_ok=True)
    log.info('Run log: %s', log_path)

    overall_ok = True
    summary = []
    overall_start = time.time()

    try:
        for name in selected:
            entry = ALL_TESTS[name]
            rec = _run_test(entry, local_hw, peer, budgets[name], log_path)
            summary.append(rec)
            if rec.get('ok') is False:
                overall_ok = False
                if args.fail_fast:
                    log.error('FAIL-FAST: stopping after first failure (%s)', rec.get('name'))
                    break
    finally:
        if peer is not None:
            peer.close()

    elapsed = time.time() - overall_start
    n_ok   = sum(1 for r in summary if r.get('ok') is True)
    n_fail = sum(1 for r in summary if r.get('ok') is False)
    n_skip = sum(1 for r in summary if r.get('skipped'))
    log.info('DONE pair_id=%s elapsed=%.1fs ok=%d fail=%d skip=%d',
             run_id, elapsed, n_ok, n_fail, n_skip)
    return 0 if overall_ok else 1


if __name__ == '__main__':
    sys.exit(main())
