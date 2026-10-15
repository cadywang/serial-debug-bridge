#!/usr/bin/env python3
"""
devctl -- remote control for the serial debug bridge agent (cross-platform).

Run this on the *server* (e.g. 172.21.44.42). It talks to serial_agent.py /
serial_agent.ps1, which runs on the *client* (the machine the embedded device
UART is plugged into), over TCP or over SSH(stdio):

    server: devctl.py ...  --TCP/SSH-->  client serial_agent  --UART-->  device

Commands
    exec  <command>            run a shell command on the device, print output
    push  <local> <remote>     upload a local file to the device
    pull  <remote> <local>     download a file from the device
    md5   <remote>             device-side md5 of a file
    reset                      reset the board via DTR
    info                       show agent / device information
    shell                      interactive console (TCP transport only)

Transport (choose one)
    --tcp HOST[:PORT]          connect to an agent that is listening on TCP
    --ssh USER@HOST            launch the agent on the client through SSH(stdio)

Examples
    devctl.py --tcp 172.21.5.10:7801 exec "uname -a"
    devctl.py --tcp 172.21.5.10:7801 push ./firmware.bin /tmp/firmware.bin
    devctl.py --tcp 172.21.5.10:7801 pull /etc/config.txt ./config.txt
    devctl.py --ssh root@172.21.5.10 --remote-agent /opt/serial_agent.py \
              --port /dev/ttyUSB0 --baud 115200 exec "ls -l /"
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import select
import shlex
import socket
import subprocess
import sys
import time

STDIN = sys.stdin.buffer
STDOUT = sys.stdout.buffer
STDERR = sys.stderr.buffer


def info(msg: str) -> None:
    if not QUIET:
        STDERR.write((msg + '\n').encode('utf-8', 'replace'))
        STDERR.flush()


QUIET = False


class Agent:
    """A framed request/response channel to a serial agent."""

    def __init__(self, rfile, wfile, sock=None, proc=None):
        self.r = rfile
        self.w = wfile
        self.sock = sock
        self.proc = proc

    def _read_line(self):
        line = self.r.readline()
        if not line:
            return None
        return line.decode('ascii', 'replace').rstrip('\r\n')

    def _read_exact(self, n: int) -> bytes:
        out = bytearray()
        while len(out) < n:
            chunk = self.r.read(n - len(out))
            if not chunk:
                raise IOError('agent closed the connection')
            out += chunk
        return bytes(out)

    def request(self, op: str, body: bytes = b'', **kv):
        head = op
        for k, v in kv.items():
            head += ' %s=%s' % (k, v)
        head += ' len=%d\n' % len(body)
        self.w.write(head.encode('ascii'))
        if body:
            self.w.write(body)
        self.w.flush()

        line = self._read_line()
        if line is None:
            raise IOError('agent closed the connection')
        parts = line.split(' ')
        status = parts[0]
        meta = {}
        for t in parts[1:]:
            if '=' in t:
                k, v = t.split('=', 1)
                meta[k] = v
        n = int(meta.get('len', '0') or '0')
        data = self._read_exact(n)
        return status, meta, data

    def close(self):
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.kill()
        except Exception:
            pass
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass


def connect_tcp(spec: str) -> Agent:
    host, port = spec, 7801
    if ':' in spec:
        host, _, p = spec.rpartition(':')
        port = int(p)
    sock = socket.create_connection((host, port), timeout=15)
    sock.settimeout(None)   # blocking from here on; the agent enforces its own timeout
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    info('connected to tcp:%s:%d' % (host, port))
    return Agent(sock.makefile('rb'), sock.makefile('wb'), sock=sock)


def connect_ssh(host: str, opts) -> Agent:
    if opts.remote_kind == 'ps':
        remote = '%s -NoProfile -ExecutionPolicy Bypass -File %s -Stdio -Port %s -Baud %d'
        remote = remote % (opts.remote_python, opts.remote_agent, opts.port, opts.baud)
    else:
        remote = '%s %s --stdio --port %s --baud %d'
        remote = remote % (opts.remote_python, opts.remote_agent, opts.port, opts.baud)
    cmd = ['ssh', '-T', '-o', 'BatchMode=yes']
    if opts.ssh_port:
        cmd += ['-p', str(opts.ssh_port)]
    if opts.identity:
        cmd += ['-i', opts.identity]
    cmd += [host, remote]
    info('ssh %s -> %s' % (host, remote))
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    return Agent(proc.stdout, proc.stdin, proc=proc)

def cmd_info(ag, args):
    st, meta, body = ag.request('INFO')
    if st != 'OK':
        info('ERR: ' + body.decode('utf-8', 'replace'))
        return 1
    STDOUT.write(body)
    if body and not body.endswith(b'\n'):
        STDOUT.write(b'\n')
    STDOUT.flush()
    return 0


def cmd_reset(ag, args):
    st, meta, body = ag.request('RESET')
    if st != 'OK':
        info('ERR: ' + body.decode('utf-8', 'replace'))
        return 1
    info('reset sent')
    return 0


def cmd_exec(ag, args):
    cmd_text = args[0] if args else ''
    st, meta, body = ag.request('EXEC', cmd_text.encode('utf-8'), timeout=TIMEOUT)
    if st != 'OK':
        if body:
            STDOUT.write(body)
            STDOUT.flush()
        info('ERR: ' + st)
        return 124
    STDOUT.write(body)
    if body and not body.endswith(b'\n'):
        STDOUT.write(b'\n')
    STDOUT.flush()
    return int(meta.get('rc', '0'))


def cmd_push(ag, args):
    if len(args) < 2:
        info('usage: push <local> <remote>')
        return 2
    local, remote = args[0], args[1]
    if not os.path.isfile(local):
        info('local file not found: ' + local)
        return 2
    with open(local, 'rb') as fh:
        data = fh.read()
    body = base64.b64encode(remote.encode('utf-8')) + b'\n' + data
    st, meta, resp = ag.request('PUSH', body, timeout=TIMEOUT)
    if st != 'OK':
        info('ERR: ' + resp.decode('utf-8', 'replace'))
        return 1
    verified = meta.get('verified', '')
    info('pushed %s -> %s (%d bytes, md5=%s, verified=%s)'
         % (local, remote, len(data), meta.get('md5', ''), verified))
    if verified != 'True':
        if resp:
            STDOUT.write(resp + b'\n')
            STDOUT.flush()
        info('WARNING: device-side md5 does NOT match; transfer may be corrupt')
        return 1
    return 0


def cmd_pull(ag, args):
    if len(args) < 2:
        info('usage: pull <remote> <local>')
        return 2
    remote, local = args[0], args[1]
    st, meta, body = ag.request('PULL', base64.b64encode(remote.encode('utf-8')), timeout=TIMEOUT)
    if st != 'OK':
        info('ERR: ' + body.decode('utf-8', 'replace'))
        return 1
    d = os.path.dirname(os.path.abspath(local))
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    with open(local, 'wb') as fh:
        fh.write(body)
    md5 = hashlib.md5(body).hexdigest()
    info('pulled %s -> %s (%d bytes, md5=%s)' % (remote, local, len(body), md5))
    if meta.get('md5') and meta.get('md5') != md5:
        info('WARNING: md5 mismatch between device and saved file')
        return 1
    return 0


def cmd_md5(ag, args):
    if not args:
        info('usage: md5 <remote>')
        return 2
    st, meta, body = ag.request('MD5', base64.b64encode(args[0].encode('utf-8')))
    if st != 'OK':
        info('ERR: ' + body.decode('utf-8', 'replace'))
        return 1
    STDOUT.write(body + b'\n')
    STDOUT.flush()
    return 0


def cmd_shell(ag, args):
    if ag.sock is None:
        info('shell is only supported with --tcp transport')
        return 2
    st, meta, body = ag.request('SHELL')
    if st != 'OK':
        info('ERR: ' + body.decode('utf-8', 'replace'))
        return 1
    info('entering interactive console (Ctrl+] to quit)')
    sock = ag.sock
    sock.setblocking(False)
    while True:
        r, _, _ = select.select([sock, STDIN], [], [], 0.05)
        if sock in r:
            data = sock.recv(4096)
            if not data:
                break
            STDOUT.write(data)
            STDOUT.flush()
        if STDIN in r:
            data = os.read(STDIN.fileno(), 4096)
            if not data:
                break
            sock.sendall(data)
    return 0


def main() -> int:
    global QUIET, TIMEOUT
    ap = argparse.ArgumentParser(
        prog='devctl.py', description='Remote control for the serial debug bridge agent.',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tcp', metavar='HOST[:PORT]', help='connect to an agent listening on TCP (default port 7801)')
    ap.add_argument('--ssh', metavar='USER@HOST', help='launch the agent on the client through SSH(stdio)')
    ap.add_argument('--ssh-port', type=int, default=0, help='SSH port (default 22)')
    ap.add_argument('-i', '--identity', default='', help='SSH private key file')
    ap.add_argument('--remote-kind', choices=['py', 'ps'], default='py',
                    help='which agent runs on the client: py (serial_agent.py) or ps (serial_agent.ps1)')
    ap.add_argument('--remote-python', default='python3', help='interpreter on the client (py: python3, ps: powershell.exe)')
    ap.add_argument('--remote-agent', default='/opt/serial-debug-bridge/serial_agent.py', help='agent path on the client')
    ap.add_argument('--port', default='/dev/ttyUSB0', help='serial device on the client (SSH transport)')
    ap.add_argument('--baud', type=int, default=115200, help='serial baud rate (SSH transport)')
    ap.add_argument('--timeout', type=int, default=30000, help='per-command timeout in milliseconds')
    ap.add_argument('--token', default='', help='auth token if the agent was started with --auth')
    ap.add_argument('-q', '--quiet', action='store_true', help='suppress diagnostic messages')
    ap.add_argument('command', choices=['exec', 'push', 'pull', 'md5', 'reset', 'info', 'shell'])
    ap.add_argument('args', nargs=argparse.REMAINDER)
    opts = ap.parse_args()

    QUIET = opts.quiet
    TIMEOUT = opts.timeout

    if not (opts.tcp or opts.ssh):
        info('error: choose a transport: --tcp HOST[:PORT] or --ssh USER@HOST')
        return 2

    ag = connect_tcp(opts.tcp) if opts.tcp else connect_ssh(opts.ssh, opts)
    try:
        if opts.token:
            st, meta, body = ag.request('AUTH', opts.token.encode('utf-8'))
            if st != 'OK':
                info('ERR: authentication failed')
                return 3
        table = {
            'info': cmd_info, 'reset': cmd_reset, 'exec': cmd_exec,
            'push': cmd_push, 'pull': cmd_pull, 'md5': cmd_md5, 'shell': cmd_shell,
        }
        return table[opts.command](ag, opts.args)
    finally:
        ag.close()


TIMEOUT = 30000

if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (IOError, OSError) as exc:
        sys.stderr.write('devctl: %s\n' % exc)
        sys.exit(1)
