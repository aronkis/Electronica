#!/bin/bash
# c1b_bist_controlled.sh -- C1 with its own validity control.
#
# The BIST (Capture_Data_Bits -> 0x108) compares the POST-VITERBI decoded info bits
# against a reference message compiled into the netlist. Before believing any BER it
# reports, we must prove the BIST is actually locked to what the transmitter radiates.
# So this runs BOTH arms back to back on the same link, same session:
#
#   ARM A  TX = fabric ROM (0x158=0)  -> BIST reference SHOULD match  -> expect LOW BER
#   ARM B  TX = host byte stream (0x158=1) -> reference CANNOT match  -> expect ~0.5 BER
#
# Arm B is the planted fault. If Arm B does NOT show a massive BER, the BIST is not
# comparing against the radiated payload at all and the whole instrument is void --
# in which case C1 reports INCONCLUSIVE rather than a false clean bill.
#
# If the control passes, Arm A's BER localizes the forward corrupt-frame class:
#   Arm A BER ~1e-5 or below  => decoder output CLEAN => the ~8.3 %/frame corruption
#                                is introduced DOWNSTREAM, inside the byte plane/DMA.
#   Arm A BER ~1e-2+          => corruption is AT OR BEFORE the decoder (signal domain).
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
TX=10.0.0.146
RX=10.0.0.148
DWELL=${1:-60}

echo "C1B start $(date -Is)  dwell=${DWELL}s per arm  forward 146->148"

restore() {
  echo "=== restore ==="
  $W $TX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    echo "0x158 0x1" > $DRA' 2>/dev/null
  for ip in $TX $RX; do
    $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null
      nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & exit 0' 2>/dev/null
    sleep 1
    $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' wd up" || echo "  '"$ip"' wd DOWN"' 2>/dev/null
  done
}
trap restore EXIT

arm() { # $1 = label, $2 = 0x158 value
  echo "=== ARM $1 : 146 tx_data_source = $2 ==="
  $W $TX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    echo "0x158 '"$2"'" > $DRA' 2>/dev/null
  sleep 4
  $W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
p0=$(( $(rd 0x104) )); e0=$(( $(rd 0x108) )); d0=$(( $(rd 0x130) )); r0=$(( $(rd 0x150) ))
sleep '"$DWELL"'
p1=$(( $(rd 0x104) )); e1=$(( $(rd 0x108) )); d1=$(( $(rd 0x130) )); r1=$(( $(rd 0x150) ))
dp=$(( p1 - p0 )); de=$(( e1 - e0 )); dd=$(( d1 - d0 )); dr=$(( r1 - r0 ))
echo "  packets=$dp biterr=$de decbits=$dd rstcs=$dr"
if [ $dd -gt 0 ]; then
  awk -v e=$de -v d=$dd -v p=$dp -v n='"$DWELL"' "BEGIN{
    printf \"  ARMRESULT fps=%.1f BER=%.3e biterr_per_frame=%.1f\n\", p/n, e/d, (p>0? e/p : 0) }"
else
  echo "  ARMRESULT NO_DECODED_BITS (link down or counter dead)"
fi' 2>/dev/null
}

echo "=== bring up ==="
QPSK_FRAMELOG= "$D/bringup_r2r3.sh" r3 > /tmp/c1b_bringup.log 2>&1 \
  && grep -E "ARM GATE|BRING-UP COMPLETE" /tmp/c1b_bringup.log | tail -2 \
  || { echo "C1B_FAIL bringup"; tail -5 /tmp/c1b_bringup.log; exit 1; }

for ip in $TX $RX; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null
done
echo "  watchdogs stopped"

arm ROM_reference 0x0
arm HOST_bytes_CONTROL 0x1
echo "C1B_DONE $(date -Is)"
