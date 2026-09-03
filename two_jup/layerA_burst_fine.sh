#!/bin/bash
# layerA_burst_poll.sh -- 1 s-resolution poll of the in-fabric comparator (0x108)
# in digital loopback, ROM reference, to resolve mid-dwell burst boundaries,
# sizes and spacings. Skips the deterministic first-minute arm transient
# (218,534 errors) before the measurement window.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.148}
DWELL=${DWELL:-3000}   # units now 0.1s when FINE=1

echo "=== Layer A burst poll FINE: ${DWELL} samples at 0.1 s resolution ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null

$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA
  echo "0x118 0x0">$DRA
  echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
  echo "  armed (ROM, digital loopback)"' 2>/dev/null

echo "--- waiting out the deterministic arm transient (65 s) ---"
sleep 65

echo "--- polling ${DWELL} x 0.1s (on-board loop -> /dev/shm/burst.csv) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  : > /dev/shm/burst.csv
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
  for i in \$(seq 1 $DWELL); do
    sleep 0.1
    p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
    echo \"\$i \$(( (p1-p0) & 0xFFFFFFFF )) \$(( (e1-e0) & 0xFFFFFFFF ))\" >> /dev/shm/burst.csv
    p0=\$p1; e0=\$e1
  done
  echo POLL_DONE" 2>/dev/null

OUT=$D/r3cap/burstpoll_$(date +%Y%m%d_%H%M%S).csv
$W $B 'cat /dev/shm/burst.csv' 2>/dev/null > "$OUT"
echo "CSV: $OUT ($(wc -l < "$OUT") samples)"

echo "--- burst analysis (threshold: d108 > 200/s vs ~56/s steady) ---"
awk '{ if ($3 > 200) { if (!inb) { start=$1; sum=0; inb=1 }
         sum += $3; last=$1 }
       else if (inb) { printf "BURST t=%d..%d dur=%ds size=%d", start, last, last-start+1, sum;
         if (prevend) printf " gap_from_prev=%ds interval_start_to_start=%ds", start-prevend, start-prevstart;
         printf "\n"; prevend=last; prevstart=start; inb=0 } }
     END { if (inb) printf "BURST t=%d..%d dur=%ds size=%d (open at end)\n", start, last, last-start+1, sum }' "$OUT"
awk '$3<=200 {q+=$3; n++} END { if (n) printf "QUIET floor: %.1f err/s over %d quiet seconds\n", q/n, n }' "$OUT"
awk '{f+=$2} END { printf "fsync mean %.1f f/s over %d s\n", f/NR, NR }' "$OUT"

echo "--- restore SKIPPED (146 down; leave loopback, watchdog off) ---"
echo "BURSTPOLL_DONE"
