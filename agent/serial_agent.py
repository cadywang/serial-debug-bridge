#!/usr/bin/env python3
"""
Serial debug bridge agent (cross-platform edition).

Runs on the machine the embedded device's UART is physically attached to and
bridges that console to TCP or stdio, speaking the same tiny
"header line + binary body" protocol as serial_agent.ps1, so any devctl
(devctl.py / devctl.ps1) can drive it:

    remote devctl  <--TCP / SSH-->  this agent  <--UART-->  embedded device

Capabilities: EXEC (run a command), PUSH (upload file), PULL (download file),
MD5, RESET (DTR), SHELL (interactive), INFO, PING.

Dependencies: pyserial is required ONLY when opening a real serial port.
`--mock` runs the built-in fake device and needs nothing but the stdlib.

Examples:
    python3 serial_agent.py --port /dev/ttyUSB0 --baud 115200
    python3 serial_agent.py --stdio --port /dev/ttyUSB0
    python3 serial_agent.py --mock --tcp-port 7801
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import re
import socket
import sys
import time
import uuid

AGENT_VERSION = '1.0.0'
DEFAULT_TCP_PORT = 7801
DEFAULT_TIMEOUT_MS = 30000
MAX_BODY_BYTES = 32 * 1024 * 1024


def log(msg: str, level: str = 'INFO') -> None:
    ts = time.strftime('%Y-%m-%d %H:%M:%S') + ('.%03d' % (time.time() % 1 * 1000))
    line = '[%s] %-5s %s' % (ts, level, msg)
    try:
        sys.stderr.write(line + '\n')
        sys.stderr.flush()
    except Exception:
        pass
    path = LOG_FILE
    if path:
        try:
            with open(path, 'a', encoding='utf-8') as fh:
                fh.write(line + '\n')
        except Exception:
            pass


LOG_FILE = ''

# ---------------------------------------------------------------------------
# built-in mock device (self test only): emulates enough busybox sh for the
# agent's own command shapes (echo/probe, here-doc base64 decode, base64,
# md5sum, ls, cat, ...).
# ---------------------------------------------------------------------------
class MockDevice:
    def __init__(self) -> None:
        self.files = {}          # path -> bytes
        self.cwd = '/'
        self.pending = ''
        self.out = bytearray()
        self.last_rc = 0
        self.here_delim = None
        self.here_cmd = None
        self.here_body = []

    # --- byte plumbing -------------------------------------------------
    def write(self, data: bytes) -> None:
        text = data.decode('latin-1')
        # emulate a tty's ICRNL: bare CR becomes NL
        text = text.replace('\r\n', '\n').replace('\r', '\n')
        self.pending += text
        while '\n' in self.pending:
            line, self.pending = self.pending.split('\n', 1)
            self._handle_line(line)

    def in_waiting(self) -> int:
        return len(self.out)

    def read_available(self, maxb: int) -> bytes:
        chunk = bytes(self.out[:maxb])
        del self.out[:maxb]
        return chunk

    def reset(self, delay_ms: int) -> None:
        log('Mock device: reset ignored.')

    # --- shell emulation ----------------------------------------------
    def _emit(self, s: str) -> None:
        self.out += s.encode('utf-8', 'replace')

    def _handle_line(self, line: str) -> None:
        self._emit(line + '\r\n')                     # terminal echo
        if self.here_delim is not None:
            if line == self.here_delim:
                self._run_heredoc(self.here_cmd, '\n'.join(self.here_body) + '\n')
                self.here_delim = self.here_cmd = None
                self.here_body = []
            else:
                self.here_body.append(line)
            return
        m = re.search(r"<<\s*'([^']+)'", line)
        if m:
            self.here_delim = m.group(1)
            self.here_cmd = line
            self.here_body = []
            return
        self._exec(line)

    def _path(self, p: str) -> str:
        p = p.strip('\'"')
        if p.startswith('./'):
            p = self.cwd.rstrip('/') + p[1:]
        elif not p.startswith('/'):
            p = self.cwd.rstrip('/') + '/' + p
        return p

    def _run_heredoc(self, cmd: str, body: str) -> None:
        m = re.search(r'base64\s+-d\s*>\s*(\S+)\s*<<', cmd)
        if m:
            path = self._path(m.group(1))
            try:
                self.files[path] = base64.b64decode(re.sub(r'\s', '', body))
                self.last_rc = 0
            except Exception:
                self._emit('base64: invalid input\r\n')
                self.last_rc = 1
            return
        m = re.search(r'awk\s+.*?>\s*(\S+)\s*<<', cmd)
        if m:
            path = self._path(m.group(1))
            try:
                self.files[path] = bytes.fromhex(re.sub(r'\s', '', body))
                self.last_rc = 0
            except Exception:
                self._emit('awk: bad input\r\n')
                self.last_rc = 1
            return
        self._emit('sh: syntax error\r\n')
        self.last_rc = 2

    def _exec(self, line: str) -> None:
        t = line.strip()
        if not t:
            self.last_rc = 0
            return
        if t.startswith('#'):
            return
        m = re.match(r'^echo\s+(.*)$', t)
        if m:
            a = m.group(1).strip().strip('"').strip("'")
            a = a.replace('$?', str(self.last_rc))
            self._emit(a + '\r\n')
            self.last_rc = 0
            return
        m = re.match(r"^printf\s+'%s'\s+'(.*)'$", t)
        if m:
            self._emit(m.group(1))
            self.last_rc = 0
            return
        m = re.match(r'^:\s*>\s*(\S+)$', t)
        if m:
            self.files[self._path(m.group(1))] = b''
            self.last_rc = 0
            return
        m = re.match(r'^rm\s+-f\s+(.+)$', t)
        if m:
            for f in m.group(1).split():
                self.files.pop(self._path(f), None)
            self.last_rc = 0
            return
        if t.startswith('if [') and 'md5sum' in t:
            mt = re.search(r'md5sum (\S+)', t)
            mw = re.search(r'= "([0-9a-f]{32})"', t)
            mc = re.search(r'cat (\S+) >> (\S+)', t)
            ms = re.search(r'wc -c < (\S+)\)" = "(\d+)"', t)
            mi = re.search(r"__DEVCTL_A''CK_(\d+)__", t)
            mb = re.search(r"__DEVCTL_BA''D_(\d+)__", t)
            if mt and mw and mc and mi and mb:
                tmp = self._path(mt.group(1)); want = mw.group(1)
                tgt = self._path(mc.group(2))
                ack = '__DEVCTL_ACK_%s__' % mi.group(1)
                bad = '__DEVCTL_BAD_%s__' % mb.group(1)
                ok = hashlib.md5(self.files.get(tmp, b'')).hexdigest() == want
                if ok:
                    self.files[tgt] = self.files.get(tgt, b'') + self.files.get(tmp, b'')
                    if ms:
                        ok = len(self.files[tgt]) == int(ms.group(2))
                self._emit((ack if ok else bad) + '\r\n')
                self.last_rc = 0
                return
        m = re.match(r'^od\s+-v\s+-b\s+(\S+)$', t)
        if m:
            pth = self._path(m.group(1))
            dat = self.files.get(pth)
            if dat is None:
                self._emit('od: %s: No such file or directory\r\n' % m.group(1)); self.last_rc = 1
            else:
                out = []
                for off in range(0, len(dat), 16):
                    out.append('%07o ' % off + ' '.join('%03o' % bb for bb in dat[off:off+16]))
                out.append('%07o' % len(dat))
                self._emit('\r\n'.join(out) + '\r\n')
                self.last_rc = 0
            return
        m = re.match(r'^md5sum\s+(\S+)', t)
        if m:
            p = self._path(m.group(1))
            if p in self.files:
                self._emit(hashlib.md5(self.files[p]).hexdigest() + '  ' + m.group(1) + '\r\n')
                self.last_rc = 0
            else:
                self._emit('md5sum: %s: No such file or directory\r\n' % m.group(1))
                self.last_rc = 1
            return
        m = re.match(r'^base64\s+(\S+)', t)
        if m:
            p = self._path(m.group(1))
            if p in self.files:
                self._emit(base64.b64encode(self.files[p]).decode('ascii') + '\r\n')
                self.last_rc = 0
            else:
                self._emit('base64: %s: No such file or directory\r\n' % m.group(1))
                self.last_rc = 1
            return
        m = re.match(r'^cat\s+(\S+)', t)
        if m:
            p = self._path(m.group(1))
            if p in self.files:
                self._emit(self.files[p].decode('utf-8', 'replace'))
                self.last_rc = 0
            else:
                self._emit('cat: %s: No such file or directory\r\n' % m.group(1))
                self.last_rc = 1
            return
        if re.match(r'^ls', t):
            self._emit('\r\n'.join(sorted(self.files)) + ('\r\n' if self.files else '\r\n'))
            self.last_rc = 0
            return
        if re.match(r'^uname', t):
            self._emit('Linux mock 5.10.0 #1 SMP PREEMPT armv7l GNU/Linux\r\n')
            self.last_rc = 0
            return
        if re.match(r'^date', t):
            self._emit(time.strftime('%a %b %d %H:%M:%S %Y') + '\r\n')
            self.last_rc = 0
            return
        if re.match(r'^pwd', t):
            self._emit(self.cwd + '\r\n')
            self.last_rc = 0
            return
        if re.match(r'^(whoami|id)', t):
            self._emit('root\r\n')
            self.last_rc = 0
            return
        m = re.match(r'^cd\s+(\S+)', t)
        if m:
            self.cwd = self._path(m.group(1))
            self.last_rc = 0
            return
        self._emit('sh: %s: not found\r\n' % t.split()[0])
        self.last_rc = 127
# ---------------------------------------------------------------------------
# real serial device (pyserial) -- imported lazily so --mock needs no deps
# ---------------------------------------------------------------------------
class RealSerial:
    def __init__(self, port, baud, data_bits, parity, stop_bits, handshake):
        import serial  # pyserial
        pmap = {'none': serial.PARITY_NONE, 'odd': serial.PARITY_ODD, 'even': serial.PARITY_EVEN,
                'mark': serial.PARITY_MARK, 'space': serial.PARITY_SPACE}
        smap = {'one': serial.STOPBITS_ONE, 'one_point_five': serial.STOPBITS_ONE_POINT_FIVE,
                'two': serial.STOPBITS_TWO}
        self.sp = serial.Serial(port=port, baudrate=baud, bytesize=int(data_bits),
                                parity=pmap[parity], stopbits=smap[stop_bits], timeout=0.2)
        self.sp.dtr = True
        self.sp.rts = True
        log('Opened serial port %s @ %s %s%s%s' % (port, baud, data_bits, parity[0].upper(), stop_bits))

    def write(self, data: bytes) -> None:
        self.sp.write(data)

    def in_waiting(self) -> int:
        return int(self.sp.in_waiting)

    def read_available(self, maxb: int) -> bytes:
        n = min(maxb, self.sp.in_waiting)
        return self.sp.read(n) if n > 0 else b''

    def reset(self, delay_ms: int) -> None:
        try:
            self.sp.dtr = False
        except Exception:
            pass
        time.sleep(max(50, delay_ms) / 1000.0)
        try:
            self.sp.dtr = True
        except Exception:
            pass

    def close(self) -> None:
        try:
            self.sp.close()
        except Exception:
            pass


def shquote(s: str) -> str:
    return "'" + s.replace("'", "'\\''") + "'"


ANSI_RE = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
PROMPT_RE = re.compile(
    r'^(?:[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+:[^\s]*'
    r'|[A-Za-z0-9_.\-]+@[A-Za-z0-9_.\-]+'
    r'|bash-\d+\.\d+|sh-\d+\.\d+)?\s*[#$>]\s*$')


def _strip_trailing_prompt(s: str) -> str:
    """Drop the shell prompt a device prints after every command."""
    lines = s.split('\n')
    while lines and lines[-1].strip('\r').strip() == '':
        lines.pop()
    if lines and PROMPT_RE.match(lines[-1].strip()):
        lines.pop()
    return '\n'.join(lines)

def run_on_device(dev, text: str, timeout_ms: int):
    """_run_on_device_once, retried when the echo proves the send was corrupted.

    Running the corrupted command would be worse than retrying it: "uname -a"
    silently became "uname" during one observed transfer.
    """
    last = None
    for attempt in range(3):
        last = _run_on_device_once(dev, text, timeout_ms)
        if not last[0] or _LAST_ECHO_OK:
            return last
        log('device echo mismatch on attempt %d; resending' % (attempt + 1), 'WARN')
        time.sleep(0.15)
    return last

def _clean_output(pre: bytes, text: str, probe: str) -> str:
    """Strip the terminal echo from the raw device response."""
    s = pre.decode('latin-1')
    cmd_lines = []
    if text:
        for ln in text.split('\n'):
            c = ln.rstrip('\r')
            if len(c) >= 2:
                cmd_lines.append(c)
    if cmd_lines:
        j = s.find(cmd_lines[0])
        if j >= 0:
            s = s[j + len(cmd_lines[0]):]
    j = s.find(probe)
    if j >= 0:
        s = s[:j] + s[j + len(probe):]
    for c in cmd_lines[1:]:
        j = s.find(c)
        if j >= 0:
            s = s[:j] + s[j + len(c):]
    s = ANSI_RE.sub('', s)
    s = _strip_trailing_prompt(s)
    s = s.strip('\r\n')
    return s.encode('latin-1').decode('utf-8', 'replace')


_LAST_ECHO_OK = True


def _echo_ok(pre: bytes, text: str, probe: str) -> bool:
    """Use the terminal echo as a free integrity check on the send direction.

    The UART can drop bytes while we transmit, which would turn "uname -a"
    into "uname" and run a different command than the caller asked for. When
    echo is enabled every line we sent must appear, in order, before the
    marker; when echo is disabled the check is inconclusive and we accept.
    """
    if not text:
        return True
    s = pre.decode('latin-1')
    if probe not in s:
        return True
    pos = 0
    for ln in text.split('\n'):
        ln = ln.rstrip('\r')
        if len(ln) < 2:
            continue
        k = s.find(ln, pos)
        if k < 0:
            return False
        pos = k + len(ln)
    return True


def _run_on_device_once(dev, text: str, timeout_ms: int):
    """One attempt: send <text> plus an echo-probe and read until the marker.

    Returns (ok, rc, output_text, raw_bytes).
    """
    tok = uuid.uuid4().hex[:12]
    mark = '__DEVCTL_' + tok + '__'
    probe = 'echo "%s $?"' % mark
    payload = ''
    if text:
        payload = text
        if not payload.endswith('\n'):
            payload += '\n'
    payload += probe + '\n'

    _write_payload(dev, payload.encode('utf-8'))

    rx = re.compile(re.escape(mark).encode('ascii') + rb'\s*(\d+)')
    deadline = time.monotonic() + timeout_ms / 1000.0
    buf = bytearray()
    while time.monotonic() < deadline:
        if dev.in_waiting() > 0:
            chunk = dev.read_available(4096)
            if chunk:
                buf += chunk
            m = rx.search(bytes(buf))
            if m:
                global _LAST_ECHO_OK
                rc = int(m.group(1))
                raw_pre = bytes(buf)[:m.start()]
                _LAST_ECHO_OK = _echo_ok(raw_pre, text, probe)
                out = _clean_output(raw_pre, text, probe)
                return True, rc, out, bytes(buf)
        else:
            time.sleep(0.01)
    # Say what the console was printing: a boot banner or a login prompt
    # explains a timeout far better than "device did not respond".
    tail = bytes(buf).decode('latin-1').replace('\r', '').replace('\n', ' | ')
    if len(tail) > 220:
        tail = tail[-220:]
    if tail.strip():
        log('timeout waiting for the marker; console said: %s' % tail, 'WARN')
    _recover(dev)
    return False, -1, buf.decode('utf-8', 'replace'), bytes(buf)


# ---------------------------------------------------------------------------
# protocol framing:  <OP> [k=v ...] len=<n>\n <n raw body bytes>
# ---------------------------------------------------------------------------
def read_line(rfile):
    buf = bytearray()
    while True:
        b = rfile.read(1)
        if not b:
            return None if not buf else buf.decode('ascii', 'replace')
        if b == b'\n':
            break
        if b == b'\r':
            continue
        buf += b
    return buf.decode('ascii', 'replace')


def read_exact(rfile, n: int) -> bytes:
    if n <= 0:
        return b''
    out = bytearray()
    while len(out) < n:
        chunk = rfile.read(n - len(out))
        if not chunk:
            raise IOError('connection closed while reading body')
        out += chunk
    return bytes(out)


def write_message(wfile, status: str, body: bytes = b'', **kv) -> None:
    head = status
    for k, v in kv.items():
        head += ' %s=%s' % (k, v)
    head += ' len=%d\n' % len(body)
    wfile.write(head.encode('ascii'))
    if body:
        wfile.write(body)
    wfile.flush()


CODEC = {'sel': None, 'auto': True}

_CODEC_FILE = "'/tmp/.devctl_probe'"


def _recover(dev) -> None:
    """Send Ctrl-C so a shell left inside a here-document or a partial command
    returns to a prompt before we do anything else."""
    try:
        dev.write(b'\x03\n')
        time.sleep(0.2)
        drained = 0
        while dev.in_waiting() > 0 and drained < 65536:
            b = dev.read_available(4096)
            drained += len(b)
            if not b:
                break
    except Exception:
        pass

def _write_payload(dev, data: bytes) -> None:
    """Write to the device. Large payloads are chunked and the terminal echo is
    drained *between* chunks, so the UART receive buffer cannot overflow and
    swallow the trailing end marker. The final chunk is never drained because
    the device may already be emitting the marker by then."""
    if len(data) <= 8192:
        dev.write(data)
        return
    offsets = list(range(0, len(data), 4096))
    for n, i in enumerate(offsets):
        dev.write(data[i:i + 4096])
        if n == len(offsets) - 1:
            break
        drained = 0
        try:
            while dev.in_waiting() > 0 and drained < 65536:
                b = dev.read_available(8192)
                drained += len(b)
                if not b:
                    break
        except Exception:
            pass


def _decode_with(codec, text: str) -> bytes:
    if codec['name'] == 'hex':
        return _from_od_octal(text)
    return base64.b64decode(re.sub(r'\s', '', text), validate=False)


def _pull_cmd(codec, q: str) -> str:
    return ('od -v -b ' + q) if codec['name'] == 'hex' else (codec['enc'] + ' ' + q)


_AWK_HEX = ('{n=length($0);for(i=1;i<=n;i+=2){h=substr($0,i,2);'
            'a=index("0123456789abcdef",substr(h,1,1))-1;'
            'b=index("0123456789abcdef",substr(h,2,1))-1;'
            'printf "%c",a*16+b}}')
_BLK = "'/tmp/.devctl_blk'"
BLOCK_SIZE = 1024
MAX_RETRY = 8


def wait_any(dev, markers, timeout_ms: int) -> str:
    deadline = time.monotonic() + timeout_ms / 1000.0
    buf = bytearray()
    while time.monotonic() < deadline:
        if dev.in_waiting() > 0:
            chunk = dev.read_available(4096)
            if chunk:
                buf += chunk
                s = buf.decode('latin-1')
                for m in markers:
                    if m in s:
                        return m
        else:
            time.sleep(0.002)
    tail = buf.decode('latin-1').replace('\r', '').replace('\n', ' | ')
    if len(tail) > 220:
        tail = tail[-220:]
    if tail.strip():
        log('marker not seen; console said: %s' % tail, 'WARN')
    return ''


def push_hex(dev, q: str, data: bytes, timeout_ms: int) -> bool:
    """Verified block upload.

    Each block is decoded on the device into a temp file; the DEVICE compares
    that file's md5 with the value we computed and only appends to the target
    when they match. On mismatch we retransmit the block. This makes the upload
    correct even though the UART link occasionally drops a character.
    """
    _write_payload(dev, (': > ' + q + '\n').encode('utf-8'))
    ack_to = min(timeout_ms, 10000)
    nblk = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE
    for i in range(nblk):
        chunk = data[i * BLOCK_SIZE:(i + 1) * BLOCK_SIZE]
        want = hashlib.md5(chunk).hexdigest()
        hexs = chunk.hex()
        lines = [hexs[k:k + 64] for k in range(0, len(hexs), 64)]
        delim = '__DEVCTL_HEOF_%d__' % i
        body = ('awk %s > %s << %s\n%s\n%s\n' % (shquote(_AWK_HEX), _BLK, shquote(delim),
                '\n'.join(lines), delim))
        body += ('if [ "$(md5sum %s | cut -d" " -f1)" = "%s" ] && cat %s >> %s'
                 ' && [ "$(wc -c < %s | tr -d " ")" = "%d" ]; then '
                 "echo __DEVCTL_A''CK_%d__; else echo __DEVCTL_BA''D_%d__; fi"
                 % (_BLK, want, _BLK, q, q, min((i + 1) * BLOCK_SIZE, len(data)), i, i))
        body += '\n'
        ok = False
        for _ in range(MAX_RETRY):
            _write_payload(dev, body.encode('utf-8'))
            hit = wait_any(dev, ['__DEVCTL_ACK_%d__' % i, '__DEVCTL_BAD_%d__' % i], ack_to)
            if hit == '__DEVCTL_ACK_%d__' % i:
                ok = True
                break
            # A corrupted block can leave the shell inside a here-document or an
            # unclosed quote, so every later retry would time out as well.
            log('block %d not acknowledged (%s); recovering and retrying' % (i, hit or 'timeout'), 'WARN')
            _recover(dev)
        if not ok:
            log('push block %d failed after %d tries' % (i, MAX_RETRY), 'WARN')
            return False
    return True


def push_with_codec(dev, codec, q: str, data: bytes, timeout_ms: int) -> bool:
    if codec['name'] == 'hex':
        return push_hex(dev, q, data, timeout_ms)
    ok, rc, _out, _ = run_on_device(dev, _build_push_script(codec, q, data), timeout_ms)
    return bool(ok and rc == 0)

def detect_codec(dev):
    """Pick the first codec that round-trips a 5 byte sample on this device."""
    for codec in CODECS:
        try:
            if not push_with_codec(dev, codec, _CODEC_FILE, b'hello', 8000):
                continue
            ok, rc, out, _ = run_on_device(dev, _pull_cmd(codec, _CODEC_FILE), 8000)
            if not (ok and rc == 0):
                continue
            if _decode_with(codec, out) == b'hello':
                run_on_device(dev, 'rm -f ' + _CODEC_FILE, 4000)
                return codec
        except Exception:
            continue
    return None


def ensure_codec(dev):
    forced = getattr(ARGS, 'codec', 'auto') if ARGS else 'auto'
    if forced != 'auto':
        for c in CODECS:
            if c['name'] == forced:
                if CODEC['sel'] is None:
                    log('codec (forced): %s' % forced)
                CODEC['sel'] = c
                return c
    if CODEC['sel'] is None and not CODEC.get('probed'):
        CODEC['probed'] = True
        CODEC['sel'] = detect_codec(dev)
        log('codec: %s' % (CODEC['sel']['name'] if CODEC['sel'] else 'UNKNOWN (device not responding?)'))
    return CODEC['sel']

CODECS = [
    {'name': 'base64', 'enc': 'base64', 'dec': 'base64 -d'},
    {'name': 'busybox-base64', 'enc': 'busybox base64', 'dec': 'busybox base64 -d'},
    {'name': 'openssl-base64', 'enc': 'openssl base64', 'dec': 'openssl base64 -d'},
    {'name': 'hex', 'enc': None, 'dec': None},
]


def _codec_candidates(holder):
    return [holder['sel']] if holder['sel'] else list(CODECS)


def _octal_escape(data: bytes) -> str:
    return ''.join('\\%03o' % b for b in data)


def _from_od_octal(text: str) -> bytes:
    """Parse `od -v -b` output (space separated 3-digit octal, one per byte)."""
    out = bytearray()
    for line in text.split('\n'):
        for tok in line.split()[1:]:
            if 1 <= len(tok) <= 3 and all(c in '01234567' for c in tok):
                out.append(int(tok, 8) & 0xFF)
    return bytes(out)


def _build_push_script(codec, q, data) -> str:
    if codec['name'] == 'octal':
        parts = [': > ' + q]
        for i in range(0, len(data), 128):
            parts.append("printf '" + _octal_escape(data[i:i + 128]) + "' >> " + q)
        parts.append('true')
        return '\n'.join(parts)
    b64 = base64.b64encode(data).decode('ascii')
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)] or ['']
    delim = '__DEVCTL_PUSH_' + uuid.uuid4().hex[:12] + '__'
    return '%s > %s << %s\n%s\n%s' % (codec['dec'], q, shquote(delim), '\n'.join(lines), delim)

def dispatch(dev, wfile, op, kv, body, info) -> bool:
    if op == 'PING':
        write_message(wfile, 'OK', b'pong')
        return True
    if op == 'INFO':
        write_message(wfile, 'OK', info.encode('utf-8'))
        return True
    if op == 'RESET':
        dev.reset(int(kv.get('delay', 200)))
        write_message(wfile, 'OK', b'reset')
        return True
    if op == 'EXEC':
        timeout = int(kv.get('timeout', DEFAULT_TIMEOUT_MS))
        cmd = body.decode('utf-8', 'replace')
        ok, rc, out, _ = run_on_device(dev, cmd, timeout)
        if not ok:
            write_message(wfile, 'ERR', out.encode('utf-8'), code='timeout', msg='device-did-not-respond')
        else:
            write_message(wfile, 'OK', out.encode('utf-8'), rc=rc)
        return True
    if op == 'PUSH':
        nl = body.find(b'\n')
        if nl < 0:
            write_message(wfile, 'ERR', b'', code='badrequest', msg='missing-path')
            return True
        remote = base64.b64decode(body[:nl]).decode('utf-8', 'replace')
        data = body[nl + 1:]
        timeout = int(kv.get('timeout', DEFAULT_TIMEOUT_MS))
        q = shquote(remote)
        codec = ensure_codec(dev)
        if codec is None:
            write_message(wfile, 'ERR', b'no usable codec on the device (base64/octal)', code='device', msg='codec-unknown')
            return True
        if not push_with_codec(dev, codec, q, data, timeout):
            write_message(wfile, 'ERR', b'upload failed (block verification)', code='device', msg='push-failed')
            return True
        want = hashlib.md5(data).hexdigest()
        got = ''
        ok2, rc2, out2, _ = run_on_device(dev, 'md5sum %s 2>/dev/null' % q, 8000)
        if ok2 and rc2 == 0 and out2:
            parts = out2.split('\n')[0].split()
            got = parts[0] if parts else ''
        write_message(wfile, 'OK', out2.encode('utf-8'), rc=0, written=len(data),
                      md5=want, verified=(got == want))
        return True
    if op == 'PULL':
        remote = base64.b64decode(body).decode('utf-8', 'replace')
        timeout = int(kv.get('timeout', DEFAULT_TIMEOUT_MS))
        q = shquote(remote)
        codec = ensure_codec(dev)
        if codec is None:
            write_message(wfile, 'ERR', b'no usable codec on the device (base64/octal)',
                          code='device', msg='codec-unknown')
            return True
        ok, rc, out, _ = run_on_device(dev, _pull_cmd(codec, q), timeout)
        if not ok:
            write_message(wfile, 'ERR', out.encode('utf-8'), code='timeout', msg='pull-timeout')
            return True
        if rc != 0:
            write_message(wfile, 'ERR', out.encode('utf-8'), code='device', msg='read-failed')
            return True
        try:
            data = _decode_with(codec, out)
        except Exception as exc:
            write_message(wfile, ('ERR decode: %s' % exc).encode('utf-8'), code='decode', msg='decode-failed')
            return True
        write_message(wfile, 'OK', data, rc=0, md5=hashlib.md5(data).hexdigest())
        return True
    if op == 'MD5':
        remote = base64.b64decode(body).decode('utf-8', 'replace')
        ok, rc, out, _ = run_on_device(dev, 'md5sum %s 2>/dev/null' % shquote(remote), 8000)
        if not ok:
            write_message(wfile, 'ERR', out.encode('utf-8'), code='timeout', msg='md5-timeout')
            return True
        first = out.split('\n')[0].split()
        hexd = first[0] if first else ''
        write_message(wfile, 'OK', hexd.encode('utf-8'))
        return True
    if op == 'BYE':
        write_message(wfile, 'OK', b'')
        return False
    write_message(wfile, 'ERR', op.encode('utf-8'), code='unknown-op', msg='unsupported')
    return True
import select  # noqa: E402  (kept next to its only user)

ARGS = None


def raw_pipe(dev, sock) -> None:
    """Bidirectional byte passthrough for the interactive SHELL op (TCP only)."""
    log('Entering interactive raw shell passthrough.')
    try:
        while True:
            idle = True
            if dev.in_waiting() > 0:
                b = dev.read_available(65536)
                if b:
                    sock.sendall(b)
                    idle = False
            r, _, _ = select.select([sock], [], [], 0.02)
            if r:
                data = sock.recv(65536)
                if not data:
                    break
                dev.write(data)
                idle = False
            if idle:
                time.sleep(0.005)
    except OSError:
        pass
    finally:
        log('Interactive raw shell passthrough finished.')


def build_info(dev) -> str:
    return '\n'.join([
        'agent=' + AGENT_VERSION,
        'device=' + DEVICE_NAME,
        'mock=' + str(IS_MOCK),
        'host=' + socket.gethostname(),
        'os=' + sys.platform,
        'pid=' + str(os.getpid()),
        'time=' + time.strftime('%Y-%m-%dT%H:%M:%S'),
    ])


def serve_connection(dev, sock, rfile, wfile, authorized, info) -> None:
    peer = 'stdio' if sock is None else '%s:%d' % sock.getpeername()
    log('Session start: %s' % peer)
    try:
        while True:
            header = read_line(rfile)
            if header is None:
                break
            if not header.strip():
                continue
            parts = header.split(' ')
            op = parts[0].upper()
            kv = {}
            for t in parts[1:]:
                if '=' in t:
                    k, v = t.split('=', 1)
                    kv[k] = v
            try:
                n = int(kv.get('len', '0') or '0')
            except ValueError:
                n = 0
            if n > MAX_BODY_BYTES:
                write_message(wfile, 'ERR', b'', code='too-large', msg='body-too-large')
                continue
            body = read_exact(rfile, n)

            if not authorized:
                if op == 'AUTH':
                    if body.decode('utf-8', 'replace') == ARGS.auth:
                        authorized = True
                        write_message(wfile, 'OK', b'authorized')
                    else:
                        write_message(wfile, 'ERR', b'', code='auth', msg='token-mismatch')
                else:
                    write_message(wfile, 'ERR', b'', code='auth', msg='not-authorized')
                continue

            if op == 'SHELL':
                if sock is not None:
                    write_message(wfile, 'OK', b'')
                    raw_pipe(dev, sock)
                else:
                    write_message(wfile, 'ERR', b'', code='unsupported', msg='shell-requires-tcp')
                break
            if not dispatch(dev, wfile, op, kv, body, info):
                break
    except Exception as exc:  # noqa: BLE001
        log('Session error: %s' % exc, 'WARN')
    finally:
        log('Session end: %s' % peer)


DEVICE_NAME = ''
IS_MOCK = False


def open_device():
    global DEVICE_NAME, IS_MOCK
    if ARGS.mock:
        IS_MOCK = True
        DEVICE_NAME = 'MOCK'
        log('Using built-in mock device (--mock); no serial port is opened.')
        return MockDevice()
    IS_MOCK = False
    DEVICE_NAME = '%s@%s' % (ARGS.port, ARGS.baud)
    return RealSerial(ARGS.port, ARGS.baud, ARGS.data_bits, ARGS.parity, ARGS.stop_bits, ARGS.handshake)


def main() -> int:
    global ARGS, LOG_FILE, DEFAULT_TIMEOUT_MS
    ap = argparse.ArgumentParser(description='Serial debug bridge agent (cross-platform).')
    ap.add_argument('--listen', default='0.0.0.0', help='TCP bind address (default 0.0.0.0)')
    ap.add_argument('--tcp-port', type=int, default=DEFAULT_TCP_PORT, help='TCP port (default 7801)')
    ap.add_argument('--stdio', action='store_true', help='serve one session over stdin/stdout (for SSH)')
    ap.add_argument('--raw', action='store_true', help='pure TCP<->UART passthrough (ser2net style, no protocol)')
    ap.add_argument('--port', default='/dev/ttyUSB0', help='serial device, e.g. /dev/ttyUSB0 or COM3')
    ap.add_argument('--baud', type=int, default=115200)
    ap.add_argument('--data-bits', type=int, default=8, choices=[5, 6, 7, 8])
    ap.add_argument('--parity', default='none', choices=['none', 'odd', 'even', 'mark', 'space'])
    ap.add_argument('--stop-bits', default='one', choices=['one', 'one_point_five', 'two'])
    ap.add_argument('--handshake', default='none', choices=['none', 'xonxoff', 'rtscts', 'dsrdtr'])
    ap.add_argument('--mock', action='store_true', help='use the built-in fake device (no hardware)')
    ap.add_argument('--auth', default='', help='require an AUTH <token> as the first request')
    ap.add_argument('--codec', default='auto', choices=['auto', 'base64', 'busybox-base64', 'openssl-base64', 'hex'],
                    help='force a transfer codec instead of auto-detecting')
    ap.add_argument('--default-timeout-ms', type=int, default=DEFAULT_TIMEOUT_MS)
    ap.add_argument('--log-file', default='')
    ARGS = ap.parse_args()
    LOG_FILE = ARGS.log_file
    DEFAULT_TIMEOUT_MS = ARGS.default_timeout_ms

    dev = open_device()
    try:
        log('serial_agent %s  device=%s%s' % (AGENT_VERSION, DEVICE_NAME, ' auth=on' if ARGS.auth else ''))
        if ARGS.raw:
            serve_tcp_raw(dev)
        elif ARGS.stdio:
            log('Transport: stdio (intended to be launched through SSH)')
            serve_connection(dev, None, sys.stdin.buffer, sys.stdout.buffer, not ARGS.auth, build_info(dev))
        else:
            serve_tcp(dev)
    except KeyboardInterrupt:
        pass
    finally:
        if hasattr(dev, 'close'):
            dev.close()
        log('Exited.')
    return 0


def serve_tcp(dev) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((ARGS.listen, ARGS.tcp_port))
    srv.listen(1)
    log('Transport: TCP, listening on %s:%d' % (ARGS.listen, ARGS.tcp_port))
    log('Waiting for a remote devctl connection... (Ctrl+C to stop)')
    while True:
        conn, _ = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        rfile = conn.makefile('rb')
        wfile = conn.makefile('wb')
        try:
            serve_connection(dev, conn, rfile, wfile, not ARGS.auth, build_info(dev))
        finally:
            try:
                conn.close()
            except Exception:
                pass


def serve_tcp_raw(dev) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((ARGS.listen, ARGS.tcp_port))
    srv.listen(1)
    log('Raw mode: listening on %s:%d (telnet/nc/PuTTY)' % (ARGS.listen, ARGS.tcp_port))
    while True:
        conn, _ = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            raw_pipe(dev, conn)
        finally:
            try:
                conn.close()
            except Exception:
                pass


if __name__ == '__main__':
    sys.exit(main())
