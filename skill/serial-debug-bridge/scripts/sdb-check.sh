#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  sdb-check.sh -- verify the serial-debug-bridge link and identify the device.
#
#  Run this on the SERVER before doing anything else. It answers three
#  questions that are otherwise guessed at:
#    1. which devctl and which endpoint am I about to talk to?
#    2. is the agent answering, and which device is actually on the other end?
#    3. can that device decode/verify file transfers at all?
#
#  Usage:
#      scripts/sdb-check.sh                 # uses SDB_DEVCTL / SDB_TARGET
#      scripts/sdb-check.sh --ports         # also list local listeners on the port
#      SDB_TARGET=172.21.5.10:7801 scripts/sdb-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

DEVCTL="${SDB_DEVCTL:-}"
TARGET="${SDB_TARGET:-127.0.0.1:17801}"
SHOW_PORTS=0
[ "${1:-}" = "--ports" ] && SHOW_PORTS=1

if [ -z "$DEVCTL" ]; then
    for c in "$HOME/serial-debug-bridge/devctl.py" "$HOME/.local/share/serial-debug-bridge/devctl.py" "./cli/devctl.py"; do
        [ -f "$c" ] && DEVCTL="$c" && break
    done
fi
[ -n "$DEVCTL" ] && [ -f "$DEVCTL" ] || { echo "sdb-check: devctl.py not found; set SDB_DEVCTL" >&2; exit 2; }

PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "sdb-check: python3 not found" >&2; exit 2; }

HOST="${TARGET%:*}"
PORT="${TARGET##*:}"

echo "== endpoint =="
echo "  devctl : $DEVCTL"
echo "  target : $TARGET"

if [ "$SHOW_PORTS" = 1 ]; then
    echo "== listeners for port $PORT on this host =="
    (command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -E "[:.]$PORT\b") \
      || (command -v netstat >/dev/null 2>&1 && netstat -tln 2>/dev/null | grep -E "[:.]$PORT\b") \
      || echo "  (no ss/netstat)"
    echo "  note: if one address is wider than the other (0.0.0.0 vs a specific"
    echo "  address) the wider one may never receive the connection: a more"
    echo "  specific bind wins. This is what happens when an editor auto-forwards"
    echo "  the port on 127.0.0.1 and shadows a reverse tunnel to 127.0.0.1."
fi

echo "== agent =="
if ! "$PY" "$DEVCTL" --tcp "$TARGET" info; then
    echo "sdb-check: the agent did not answer. See references/troubleshooting.md" >&2
    exit 1
fi

echo "== device identity =="
IDENT="$("$PY" "$DEVCTL" --tcp "$TARGET" exec "uname -a; hostname 2>/dev/null" 2>&1)" || true
printf '%s\n' "$IDENT"

# After a reboot the console usually sits at a login prompt. Retrying exec there
# only burns one 30 s timeout per attempt, so say it once and point at the fix.
if printf '%s' "$IDENT" | grep -qi 'login:'; then
    echo
    echo "!! the device is sitting at a login prompt (login:)."
    echo "!! do NOT retry exec: each attempt just burns a 30 s timeout."
    echo "!! log in as root (usually password-less), then continue:"
    echo "!!   interactive: sdb shell  ->  type: root  ->  Ctrl+]"
    echo "!!   scripted   : start the agent with -Raw / --raw and send:"
    echo "!!                printf '\nroot\n' | nc <client>:<port>"
    echo "!!   details: references/troubleshooting.md section 10"
fi

echo "== transfer capability =="
"$PY" "$DEVCTL" --tcp "$TARGET" exec "command -v busybox base64 openssl awk od md5sum 2>/dev/null" || true

echo "== hint =="
echo "  expected: md5sum present, and either base64 (any variant) or awk+od."
echo "  speed is roughly 1-1.2 KB/s; compress large payloads first."
