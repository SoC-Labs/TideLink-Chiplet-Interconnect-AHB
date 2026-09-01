#!/usr/bin/env python3
"""Induce the production sshd condition on demand.

Board sshd runs OpenSSH defaults: MaxStartups 10:30:100, LoginGraceTime 2m.
Past 10 concurrent UNAUTHENTICATED connections, sshd randomly refuses new ones --
30% at 10, rising linearly to 100% at 100. We open N raw TCP connections to port
22 and send nothing, so each sits in pre-auth for the full grace period, holding
a slot. Any NEW connection then gets refused/reset => ssh exits 255.

Nothing is sent, no auth is attempted, and every socket is closed on exit, so the
slots free immediately. This does not touch the PL or the link.
"""
import socket, subprocess, sys, time

host, port, n = sys.argv[1], 22, int(sys.argv[2])
cmd = sys.argv[3:]

socks, refused = [], 0
for i in range(n):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(4)
    try:
        s.connect((host, port))
        socks.append(s)
    except Exception:
        refused += 1
        try: s.close()
        except Exception: pass
print("[flood] holding %d pre-auth conns to %s:22 (%d refused during setup)"
      % (len(socks), host, refused), flush=True)

rc = None
try:
    if cmd:
        t0 = time.time()
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        rc = p.returncode
        sys.stdout.write(p.stdout)
        if p.stderr.strip():
            sys.stdout.write("---- stderr ----\n" + p.stderr)
        print("[flood] command exited %s after %.1fs" % (rc, time.time() - t0), flush=True)
finally:
    for s in socks:
        try: s.close()
        except Exception: pass
    print("[flood] released %d conns" % len(socks), flush=True)
sys.exit(rc if rc is not None else 0)
