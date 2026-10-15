#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  verify-live.sh -- end-to-end check against a running agent.
#
#  Run this ON THE SERVER, with an agent already up (TCP) or reachable by ssh:
#      ./verify-live.sh 127.0.0.1:17801
#      ./verify-live.sh 172.21.5.10:7801
#
#  It exercises: info, exec, pull, and push/pull round-trips of several sizes,
#  comparing md5 end to end. Exits non-zero if anything mismatches.
# ---------------------------------------------------------------------------
set -u
TARGET="${1:-127.0.0.1:7801}"
DEVCTL="${DEVCTL:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../cli/devctl.py}"
WORK="${WORK:-/tmp/devctl-verify}"
mkdir -p "$WORK"
fail=0
run() { python3 "$DEVCTL" --tcp "$TARGET" "$@"; }

echo "== info =="
run info | head -3

echo "== exec =="
run exec 'uname -a'

echo "== pull a device file =="
run pull /etc/hostname "$WORK/hostname.txt" && echo -n "  content: " && head -1 "$WORK/hostname.txt" || fail=1

for SZ in 4096 60000 200000; do
  echo "== $SZ byte round trip =="
  head -c "$SZ" /dev/urandom > "$WORK/src.bin"
  run push "$WORK/src.bin" /tmp/devctl_v.bin || fail=1
  local_md5=$(md5sum "$WORK/src.bin" | awk '{print $1}')
  dev_md5=$(run md5 /tmp/devctl_v.bin)
  rm -f "$WORK/back.bin"
  run pull /tmp/devctl_v.bin "$WORK/back.bin" || fail=1
  back_md5=$(md5sum "$WORK/back.bin" 2>/dev/null | awk '{print $1}')
  echo "  local=$local_md5"
  echo "  dev  =$dev_md5"
  echo "  back =$back_md5"
  if [ "$local_md5" = "$dev_md5" ] && [ "$local_md5" = "$back_md5" ]; then
    echo "  OK"
  else
    echo "  MISMATCH"; fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $fail
