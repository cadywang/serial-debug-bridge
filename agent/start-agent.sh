#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Start the serial debug bridge agent on Linux  (CLIENT side).
#  Override any value with an environment variable, e.g.:
#      DEV=/dev/ttyS0 BAUD=57600 PORT=7801 ./start-agent.sh
# ---------------------------------------------------------------------------
set -euo pipefail
DEV="${DEV:-/dev/ttyUSB0}"
BAUD="${BAUD:-115200}"
PORT="${PORT:-7801}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/serial_agent.py" --port "$DEV" --baud "$BAUD" --tcp-port "$PORT"
