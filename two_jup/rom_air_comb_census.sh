#!/bin/bash
# rom_air_comb_census.sh -- does the 13.1% comb exist when 146 transmits ROM over air?
# TX-source discriminator: same RF, same SSI, same ingress, same demod as the tun-mode
# 13.107% measurement -- only the TX data source differs (ROM vs byte-DMA).
# Pre-stated verdict: biterr>1e5/s PRESENT ; <1e4/s ABSENT ; else ANOMALOUS.
# Predictions: comb-present ~2e6 err/s ; comb-absent ~2.5e3 err/s (banked 125ms anchor).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DWELL=${DWELL:-120}
OUT=$D/r3cap/combcensus_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
echo "=== ROM-air comb census: 146 ROM -> 148 RX, ${DWELL}s ==="

for ip in $B $A; do
  $W $ip 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
done

rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
rearm_rom $B; rearm_rom $A; sleep 3
rearm_rom $B; rearm_rom $A; sleep 4

FS=$($W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA)
  echo $(( (p1-p0)/5 ))' 2>/dev/null)
echo "  148 ROM framesync = ${FS:-0} f/s (gate >= 1120)"
[ "${FS:-0}" -ge 1120 ] || { echo "ABORT: forward ROM leg not at rate"; exit 1; }

$W $A "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  : > /dev/shm/census.csv
  n=\$(( $DWELL * 20 ))
  i=0
  while [ \$i -lt \$n ]; do
    printf '%s,%s,%s\n' \"\$(date +%s.%N)\" \"\$(rd 0x104)\" \"\$(rd 0x108)\" >> /dev/shm/census.csv
    i=\$((i+1))
    sleep 0.05   # BUGFIX 2026-08-24: without this the loop free-runs (~105 Hz) and
                 # DWELL*20 samples cover ~DWELL/5 seconds, not DWELL
  done" 2>/dev/null
$W $A 'wc -l /dev/shm/census.csv; cat /dev/shm/census.csv' 2>/dev/null | { read hdr; echo "  samples: $hdr"; cat > "$OUT/census.csv"; }
python3 "$D/analyze_comb_census.py" "$OUT/census.csv" | tee "$OUT/verdict.txt"
echo "COMB_CENSUS_DONE $OUT"
