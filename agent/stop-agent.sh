#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Stop serial_agent.py processes on this client and release the serial port.
#  Use "devctl ... shutdown" when the agent still answers (TCP or SSH): it
#  exits by itself. This script is for an agent that outlived its terminal or
#  its listener while still holding the port.
#
#      ./stop-agent.sh                     stop every agent found
#      ./stop-agent.sh --port /dev/ttyUSB0 only that serial device
#      ./stop-agent.sh --tcp-port 7801     only that TCP port
#      ./stop-agent.sh --list              print them, stop nothing
#
#  For the systemd unit, "systemctl stop serial-agent" is the right command.
# ---------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: stop-agent.sh [--port DEV] [--tcp-port N] [--list]

  --port DEV       only the agent serving that serial device
  --tcp-port N     only the agent listening on that TCP port
  -n, --list       print the agents, stop nothing
  -h, --help       show this text
USAGE
}

PORT=""
TCPPORT=""
LIST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    --tcp-port) TCPPORT="${2:-}"; shift 2 ;;
    --tcp-port=*) TCPPORT="${1#*=}"; shift ;;
    -n|--list) LIST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "stop-agent: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Read "--name value" / "--name=value" out of an agent command line.
arg_value() {
  printf '%s\n' "$1" | awk -v name="$2" '
    { for (i = 1; i <= NF; i++) {
        t = "--" name
        if ($i == t) { print $(i + 1); exit }
        if (substr($i, 1, length(t) + 1) == t "=") { print substr($i, length(t) + 2); exit }
      } }'
}

if ! command -v pgrep > /dev/null 2>&1; then
  echo 'stop-agent: pgrep is missing (procps/busybox); find the agent by hand:' >&2
  echo 'stop-agent:   ps -ef | grep serial_agent.py   then   kill <pid>' >&2
  exit 2
fi

# The bracket keeps pgrep from matching its own command line.
pids="$(pgrep -f 'serial_agent[.]py' || true)"
if [ -z "$pids" ]; then
  echo 'stop-agent: no serial_agent.py process found.'
  exit 0
fi

found=0
failed=0

for pid in $pids; do
  # pgrep matches a fragment, so confirm the process really is the agent; -ww
  # keeps ps from truncating a long command line to the terminal width.
  cmd="$(ps -ww -o command= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in
    *serial_agent.py*) ;;
    *) continue ;;
  esac

  dev="$(arg_value "$cmd" port)"
  tcp="$(arg_value "$cmd" tcp-port)"
  if [ -n "$PORT" ] && [ "$dev" != "$PORT" ]; then
    continue
  fi
  if [ -n "$TCPPORT" ] && [ "$tcp" != "$TCPPORT" ]; then
    continue
  fi

  found=$((found + 1))
  echo "  pid=$pid port=${dev:--} tcp=${tcp:--}"
  if [ "$LIST" = "1" ]; then
    continue
  fi

  if ! kill "$pid" 2>/dev/null; then
    echo "stop-agent: FAILED to signal pid=$pid" >&2
    failed=$((failed + 1))
    continue
  fi
  # Give the agent a moment to die on SIGTERM before escalating.
  for _ in 1 2 3 4 5 6; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.5
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "stop-agent: FAILED to stop pid=$pid" >&2
    failed=$((failed + 1))
  else
    echo "stop-agent: stopped pid=$pid"
  fi
done

if [ "$found" = "0" ]; then
  echo "stop-agent: no matching agent found (port=${PORT:--} tcp-port=${TCPPORT:--})"
  echo 'stop-agent: another program can still hold the port (serial terminal, IDE).'
  exit 0
fi
if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0