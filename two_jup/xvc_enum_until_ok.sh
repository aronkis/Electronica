#!/bin/bash
# xvc_enum_until_ok.sh -- win the intermittent XVC enumeration BEFORE spending a
# capture arm cycle. Each round: bracket-kill hw/cs_server on nemo, restart the
# on-board daemon fresh, run a minimal vivado enum probe. On success the
# hw_server (persists after vivado exits) holds the registered target for the
# capture session to reuse. Up to ${ROUNDS:-6} rounds.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.148}
ROUNDS=${ROUNDS:-6}
export PATH=/tools/Xilinx/2025.1/Vivado/bin:$PATH
PROBE=/home/tcollins/.claude/jobs/3fe62ff1/tmp/enum_probe.tcl

for r in $(seq 1 $ROUNDS); do
  echo "--- enum round $r ---"
  pkill -f "[h]w_server" 2>/dev/null; pkill -f "[c]s_server" 2>/dev/null; sleep 2
  $W $B 'pkill -x xvc_server 2>/dev/null; sleep 1
    setsid /root/xvc_server 0x9D440000 2542 > /dev/shm/xvc.log 2>&1 & sleep 1
    pgrep -x xvc_server >/dev/null && echo XVCD_UP || echo XVCD_FAIL' 2>/dev/null | tail -1
  L=/home/tcollins/.claude/jobs/3fe62ff1/tmp/enum_r$r.log
  timeout 150 vivado -mode batch -notrace -source "$PROBE" > "$L" 2>&1
  if grep -q "TARGET_OPEN_OK" "$L"; then
    echo "ENUM_OK round=$r (hw_server holds the target; do NOT kill servers/daemon now)"
    exit 0
  fi
  grep -m1 "No devices\|ERROR" "$L" | head -1
done
echo "ENUM_EXHAUSTED after $ROUNDS rounds"
exit 1
