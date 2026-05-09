#!/usr/bin/env python3
#-----------------------------------------------------------------------------
# TideLink FPGA Stress Suite - Peer board agent (JSON-lines RPC over SSH)
# A joint work commissioned on behalf of SoC Labs, under Arm Academic Access license.
#
# Contributors
#
# David Mapstone (d.a.mapstone@soton.ac.uk)
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
#-----------------------------------------------------------------------------
# Minimal long-running process invoked over SSH on the peer board.
# Reads JSON-lines RPC from stdin, writes responses to stdout.
#
# Invoke:
#   ssh user@peer python3 -m pynq_host.stress.peer_agent --role die_b
#
# RPC methods:
#   mmio_read(aperture, offset)
#   mmio_write(aperture, offset, value)
#   wait_returner_idle(timeout_ms=100)
#   get_credit_count()
#   flush()
#   set_role(role)
#   ping()
#-----------------------------------------------------------------------------

import json
import os
import sys

# Ensure pynq/ parent is importable when invoked as a module or script.
_HERE   = os.path.dirname(os.path.abspath(__file__))
_PYNQ   = os.path.dirname(_HERE)
_ROOT   = os.path.dirname(_PYNQ)
for _p in (_ROOT, _PYNQ, _HERE):
    if _p not in sys.path:
        sys.path.insert(0, _p)

try:
    from pynq_host.stress.tidelink_hw import TidelinkHw, TidelinkTimeout
except ImportError:
    from tidelink_hw import TidelinkHw, TidelinkTimeout

# Lazy overlay import with bare-metal fallback. See pynq_host/stress/
# runner.py for the rationale.
TidelinkOverlay = None
try:
    from pynq_host.overlay import TidelinkOverlay  # noqa: F811
except ImportError:
    try:
        from pynq_host.bare_overlay import TidelinkBareOverlay as TidelinkOverlay  # noqa: F811
    except ImportError:
        pass


def _get_aperture(hw, name):
    overlay = hw.overlay
    if name == 'apb':
        return overlay.apb
    if name == 'ahb_tx':
        return overlay.ahb_tx
    if name == 'ahb_fifo':
        return overlay.ahb_fifo
    if name == 'ahb_ptp':
        return overlay.ahb_ptp
    if name == 'strap':
        return overlay.strap
    raise ValueError(f"unknown aperture: {name!r}")


def _respond(req_id, result=None, error=None):
    rec = {'id': req_id}
    if error is not None:
        rec['error'] = str(error)
    else:
        rec['result'] = result
    print(json.dumps(rec), flush=True)


def _dispatch(hw, method, params):
    if method == 'ping':
        return 'pong'

    if method == 'mmio_read':
        aperture = _get_aperture(hw, params['aperture'])
        return aperture.read(params['offset'])

    if method == 'mmio_write':
        aperture = _get_aperture(hw, params['aperture'])
        aperture.write(params['offset'], params['value'])
        return None

    if method == 'wait_returner_idle':
        timeout_ms = params.get('timeout_ms', 100)
        hw.wait_returner_idle(timeout_ms=timeout_ms)
        return None

    if method == 'get_credit_count':
        return hw.read_credit_count()

    if method == 'flush':
        hw.flush()
        return None

    if method == 'set_role':
        # Write role strap via strap aperture (Wave C1 convention)
        role = params.get('role', 'die_b')
        hw.overlay.strap.write(0, 1 if role == 'die_b' else 0)
        return None

    raise ValueError(f"unknown method: {method!r}")


def main():
    import argparse
    ap = argparse.ArgumentParser(description='TideLink peer agent (JSON-RPC over stdin/stdout)')
    ap.add_argument('--role', default=os.environ.get('FPGAHUB_LOCAL_ROLE', 'die_b'),
                    choices=['die_a', 'die_b'],
                    help='Local role for this board (default: $FPGAHUB_LOCAL_ROLE or die_b)')
    args = ap.parse_args()

    # Load overlay
    if TidelinkOverlay is None:
        sys.stderr.write('[peer_agent] ERROR: TidelinkOverlay not available\n')
        sys.exit(1)

    sys.stderr.write(f'[peer_agent] loading overlay (role={args.role})\n')
    overlay = TidelinkOverlay()
    # Bring the link out of POR + apply SHORTCOMINGS-14b phase fix on the
    # slave side. fpga_manager firmware reload clears role_lock, so the
    # peer must lock its role here too — otherwise the returner is wedged
    # before any test starts. Mirrors runner.py:_load_overlay().
    if hasattr(overlay, 'lock_role') and overlay.strap is not None:
        cfg = overlay.lock_role(args.role)
        sys.stderr.write(
            f'[peer_agent] locked role={args.role} ROLE_CFG=0x{cfg:02x}\n')
    hw = TidelinkHw(overlay, role=args.role)
    sys.stderr.write('[peer_agent] ready\n')
    sys.stderr.flush()

    # Signal readiness
    print(json.dumps({'id': None, 'event': 'ready', 'role': args.role}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            _respond(None, error=f'json decode: {exc}')
            continue

        req_id = req.get('id')
        method = req.get('method', '')
        params = req.get('params', {})
        try:
            result = _dispatch(hw, method, params)
            _respond(req_id, result=result)
        except TidelinkTimeout as exc:
            _respond(req_id, error=f'timeout: {exc}')
        except Exception as exc:          # noqa: BLE001
            _respond(req_id, error=f'{type(exc).__name__}: {exc}')


if __name__ == '__main__':
    main()
