#!/bin/bash
# state_check_148.sh -- READ-ONLY state audit of 148 after the ctrlA att.1 crash
# (seqbist_run.sh died on a syntax error mid-window, so its EXIT trap may not have run).
# Reads only; writes nothing. One ssh round trip.
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh; A=10.0.0.148
$W $A 'DM=$(command -v devmem || echo "busybox devmem")
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
echo "TGEN_CTRL=$($DM 0x9D400000)  TGEN_GAP=$($DM 0x9D400008)"
echo "TGENRX_CTRL=$($DM 0x9D410000)  TGENRX_GAP=$($DM 0x9D410008)"
echo "R158=$(rd 0x158) R118=$(rd 0x118) R114=$(rd 0x114) OVF_0x1B0=$(rd 0x1B0)"
p0=$(rd 0x104); sleep 3; p1=$(rd 0x104); echo "RX_FPS_3S=$(( (p1 - p0) / 3 ))"
echo "DAEMONS=$(pgrep -x qpsk_tun | tr "\n" ",")$(pgrep -f "[l]ock_watchdog" | tr "\n" ",")"' 2>/dev/null | tr -d '\r'
echo "STATE_CHECK_DONE"
