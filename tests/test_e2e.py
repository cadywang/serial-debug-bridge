#!/usr/bin/env python3
"""
End-to-end test for devctl.py against a serial agent's mock device.

By default it starts agent/serial_agent.py (--mock) on a loopback port and
drives cli/devctl.py against it. Pass --target HOST:PORT to test against an
already-running agent (e.g. a serial_agent.ps1 on another machine).

    python3 test_e2e.py
    python3 test_e2e.py --target 127.0.0.1:17800
"""
from __future__ import annotations

import argparse
import hashlib
import os
import random
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PYTHON = sys.executable
PASS = 0
FAIL = 0


def check(name, ok, detail=''):
    global PASS, FAIL
    if ok:
        PASS += 1
        print('  [PASS] %s' % name)
    else:
        FAIL += 1
        print('  [FAIL] %s   %s' % (name, detail))


def devctl(args):
    cmd = [PYTHON, os.path.join(ROOT, 'cli', 'devctl.py'), '--tcp', TARGET] + args
    pr = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return pr.returncode, pr.stdout, pr.stderr


def port_busy(host, port):
    """True when something already answers on host:port."""
    try:
        s = socket.create_connection((host, port), timeout=1)
        s.close()
        return True
    except OSError:
        return False


def wait_port(host, port, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        try:
            s = socket.create_connection((host, port), timeout=1)
            s.close()
            return True
        except OSError:
            time.sleep(0.2)
    return False


def main():
    global TARGET
    ap = argparse.ArgumentParser()
    ap.add_argument('--target', default='')
    ap.add_argument('--port', type=int, default=0,
                    help='port for the agent this test starts (default: pick a free one)')
    ap.add_argument('--agent', default=os.path.join(ROOT, 'agent', 'serial_agent.py'))
    ap.add_argument('--agent-args', default='')
    opts = ap.parse_args()

    proc = None
    if opts.target:
        TARGET = opts.target
        print('testing against external target %s' % TARGET)
    else:
        # The agent binds 0.0.0.0 and on Windows a more specific 127.0.0.1
        # listener wins over it (VS Code forwards the ports it sees), so a fixed
        # default port can send the whole test to a stranger. Ask the OS for a
        # free one instead of guessing.
        if not opts.port:
            probe = socket.socket()
            try:
                probe.bind(('127.0.0.1', 0))
                opts.port = probe.getsockname()[1]
            finally:
                probe.close()
        elif port_busy('127.0.0.1', opts.port):
            print('port %d already answers on 127.0.0.1; pass --port <free port>'
                  % opts.port)
            return 2
        TARGET = '127.0.0.1:%d' % opts.port
        print('starting agent: %s (--mock) on port %d' % (opts.agent, opts.port))
        extra = opts.agent_args.split() if opts.agent_args else []
        proc = subprocess.Popen([PYTHON, opts.agent, '--mock', '--tcp-port', str(opts.port)] + extra,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not wait_port('127.0.0.1', opts.port):
            print('agent did not start')
            proc.kill()
            return 1

    tmp = os.path.join(ROOT, '.tmp-e2e')
    os.makedirs(tmp, exist_ok=True)
    try:
        rc, out, err = devctl(['info'])
        check('info reports mock device', b'mock=True' in out, out[:200])

        rc, out, err = devctl(['exec', 'uname -a'])
        check('exec captures output', b'Linux mock' in out, out[:200])

        rc, out, err = devctl(['exec', 'nonexistent-cmd-xyz'])
        check('exec exit code 127 propagated', rc == 127, 'rc=%d' % rc)

        # binary round trip
        data = bytes(random.Random(7).randrange(256) for _ in range(4096))
        src = os.path.join(tmp, 'payload.bin')
        with open(src, 'wb') as fh:
            fh.write(data)
        rc, out, err = devctl(['push', src, '/tmp/payload.bin'])
        check('push verified=True', b'verified=True' in err, err[:200])

        dst = os.path.join(tmp, 'payload.out')
        rc, out, err = devctl(['pull', '/tmp/payload.bin', dst])
        same = os.path.isfile(dst) and open(dst, 'rb').read() == data
        check('pull byte-identical', same)

        rc, out, err = devctl(['md5', '/tmp/payload.bin'])
        check('md5 matches', out.strip().decode() == hashlib.md5(data).hexdigest(), out[:80])

        # text round trip
        text = '\n'.join('line %d : the quick brown fox' % i for i in range(400)).encode()
        t1 = os.path.join(tmp, 'text.txt')
        open(t1, 'wb').write(text)
        t2 = os.path.join(tmp, 'text.out')
        devctl(['push', t1, '/tmp/text.txt'])
        devctl(['pull', '/tmp/text.txt', t2])
        check('text round trip', os.path.isfile(t2) and open(t2, 'rb').read() == text)

        rc, out, err = devctl(['reset'])
        check('reset accepted', rc == 0, 'rc=%d' % rc)

        # Only when this test started the agent: an external --target one
        # belongs to whoever started it.
        if proc:
            rc, out, err = devctl(['shutdown'])
            check('shutdown acknowledged', rc == 0, err[:200])
            gone = False
            end = time.time() + 10
            while time.time() < end:
                if proc.poll() is not None:
                    gone = True
                    break
                time.sleep(0.2)
            check('the agent exits after shutdown', gone)
            free = False
            try:
                s = socket.create_connection(('127.0.0.1', opts.port), timeout=1)
                s.close()
            except OSError:
                free = True
            check('the TCP port is released with it', free)
    finally:
        if proc:
            proc.kill()
        print('')
        print('RESULT: %d passed, %d failed' % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == '__main__':
    sys.exit(main())
