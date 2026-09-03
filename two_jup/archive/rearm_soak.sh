#!/bin/bash
# rearm_soak.sh — T8 hardware phase-coin experiment. With the far Tx (146) armed and
# trimmed, repeatedly full-arm the RX modem (148, agcfix image) and classify each arm:
#   GOLDEN  cap_out becomes 0x04922282
#   CYCLING rstcs_count increments across the settle (carrier-sync acquire->reset loop)
#   STUCK   cap frozen, rstcs static
# If the ingest valid-phase is a per-arm coin, expect a nonzero GOLDEN fraction.
# Usage: rearm_soak.sh [N_ARMS SETTLE_S]   (default 36 arms, 10 s settle)
set -u
N=${1:-36}; SETTLE=${2:-10}
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
RX=10.0.0.148
LOG=$D/gonogo_logs/rearm_soak_$(date +%m%d_%H%M).csv
mkdir -p "$D/gonogo_logs"
echo "arm,ts,cap1,cap2,rstcs_pre,rstcs_post,cfc,class" > "$LOG"
echo "[rearm_soak] $N arms x ${SETTLE}s settle -> $LOG"
gold=0
for a in $(seq 1 $N); do
  R=$($W $RX "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
   echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA
   echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
   echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
   sleep 2; pre=\$(rd 0x150)
   sleep $SETTLE
   c1=\$(rd 0x144); post=\$(rd 0x150); cfc=\$(rd 0x154); sleep 0.5; c2=\$(rd 0x144)
   echo \"\$c1,\$c2,\$pre,\$post,\$cfc\"" 2>/dev/null)
  c1=$(echo "$R"|cut -d, -f1); c2=$(echo "$R"|cut -d, -f2)
  pre=$(echo "$R"|cut -d, -f3); post=$(echo "$R"|cut -d, -f4); cfc=$(echo "$R"|cut -d, -f5)
  if [ "$c1" = "0x4922282" ] || [ "$c2" = "0x4922282" ]; then class=GOLDEN; gold=$((gold+1))
  elif [ "$pre" != "$post" ]; then class=CYCLING
  else class=STUCK; fi
  echo "$a,$(date +%H:%M:%S),$c1,$c2,$pre,$post,$cfc,$class" >> "$LOG"
  echo "[rearm_soak] arm $a/$N: $class (cap=$c1 rstcs $pre->$post)"
done
echo "[rearm_soak] DONE: GOLDEN $gold/$N ($(awk "BEGIN{printf \"%.0f\",100*$gold/$N}")%)"
