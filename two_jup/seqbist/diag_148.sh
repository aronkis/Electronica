#!/bin/bash
# diag_148.sh -- READ-ONLY reachability + state diagnostic for 148, stderr VISIBLE.
# Written after t6-state-148 returned an empty ssh result: an empty result is
# "not reachable / ssh not answering", NOT a board-state reading (the same lesson
# flash_148_txfix.sh's poll_md5_nonempty() encodes). Writes nothing to the board.
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh; A=10.0.0.148
echo "-- ping --"
if ping -c3 -W2 $A >/dev/null 2>&1; then echo "PING_OK"; else echo "PING_FAIL"; fi
echo "-- ssh probe 1: bare hostname, stderr shown, 20 s cap --"
timeout 20 $W $A 'echo HELLO=$(hostname) UP=$(cut -d. -f1 /proc/uptime)s'
echo "-- rc=$? --"
echo "-- ssh probe 2: registers, stderr shown, 30 s cap --"
timeout 30 $W $A 'DM=$(command -v devmem || echo "busybox devmem")
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
echo "TGEN_CTRL=$($DM 0x9D400000) TGEN_GAP=$($DM 0x9D400008)"
echo "TGENRX_CTRL=$($DM 0x9D410000)"
echo "R158=$(rd 0x158) R118=$(rd 0x118) R114=$(rd 0x114) OVF=$(rd 0x1B0)"
p0=$(rd 0x104); sleep 3; p1=$(rd 0x104); echo "RX_FPS_3S=$(( (p1 - p0) / 3 ))"
echo "DAEMONS=$(pgrep -x qpsk_tun | tr "\n" ",")"'
echo "-- rc=$? --"
echo "DIAG_DONE"
