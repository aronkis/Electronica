#!/bin/bash
# layerA_spitrace.sh -- Axis B of BEAT_BISECTION_PLAN.md: is there ANY SPI traffic to
# the ADRV9002 coincident with the 119.75 s burst? Digital loopback arm (beat-bearing),
# concurrent on-board: (a) 1 s comparator poll, (b) kernel SPI event trace with
# timestamps. Window 200 s covers the arm+153 s burst. Correlate offline.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
DWELL=${DWELL:-200}

echo "=== SPI-coincidence trace on $B (${DWELL}s, burst expected ~t+153s from arm) ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo quiesced' 2>/dev/null

echo "--- arm (digital loopback, ROM) + start trace & poll ---"
$W $B "T=/sys/kernel/debug/tracing
  echo 0 > \$T/tracing_on; echo > \$T/trace
  echo 1 > \$T/events/spi/enable
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA
  echo '0x158 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x0'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9001-tx-lpc ] && echo \${d##*/}; done)
  TL=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$TL; echo '0x458 0x2'>\$TL; echo '0x044 0x1'>\$TL
  echo 1 > \$T/tracing_on
  A0=\$(awk '{print \$1}' /proc/uptime)
  echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
  echo \"ARM_UPTIME \$A0\" > /dev/shm/spitrace_meta.txt
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  : > /dev/shm/burst.csv
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
  for i in \$(seq 1 $DWELL); do
    sleep 1
    U=\$(awk '{print \$1}' /proc/uptime)
    p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
    echo \"\$i \$U \$(( (p1-p0) & 0xFFFFFFFF )) \$(( (e1-e0) & 0xFFFFFFFF ))\" >> /dev/shm/burst.csv
    p0=\$p1; e0=\$e1
  done
  echo 0 > \$T/tracing_on; echo 0 > \$T/events/spi/enable
  cp \$T/trace /dev/shm/spi_trace.txt
  echo TRACE_LINES=\$(grep -c . /dev/shm/spi_trace.txt)
  echo SPITRACE_POLL_DONE" 2>/dev/null

OUT=$D/r3cap/spitrace_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
$W $B 'cat /dev/shm/burst.csv' 2>/dev/null > "$OUT/burst.csv"
$W $B 'cat /dev/shm/spi_trace.txt' 2>/dev/null > "$OUT/spi_trace.txt"
$W $B 'cat /dev/shm/spitrace_meta.txt' 2>/dev/null > "$OUT/meta.txt"
echo "captured: $OUT (burst $(wc -l < "$OUT/burst.csv") rows, spi $(wc -l < "$OUT/spi_trace.txt") lines)"

echo "--- burst windows (poll-uptime timestamped) ---"
awk '$4 > 200 { if(!inb){s=$2; inb=1} e=$2; n+=$4 }
     $4 <= 200 && inb { printf "BURST uptime %.2f..%.2f size=%d\n", s, e, n; inb=0; n=0 }
     END{ if(inb) printf "BURST uptime %.2f..%.2f size=%d (open)\n", s, e, n }' "$OUT/burst.csv"
echo "--- SPI activity histogram (1 s bins, trace timestamps are uptime-based) ---"
grep -E "spi_transfer_start|spi_message_start" "$OUT/spi_trace.txt" | \
  awk '{ for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+:$/){t=$i; sub(/:$/,"",t); print int(t)} }' | \
  sort -n | uniq -c | tail -40

echo "--- restore rig ---"
bash "$D/restore_known_good.sh" > /tmp/spitrace_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "SPITRACE_DONE $OUT"
