#!/bin/bash
# bist_read.sh <zed|jupiter> -- one BIST snapshot: packets errors ber% cap_out rstcs cfc_est rssi
# Env: W = ssh wrapper. New-taps regs 0x150/0x154 read as junk on pre-240k5 images.
set -u
W=${W:?set W to the anyssh.sh wrapper path}
case "${1:?usage: bist_read.sh zed|jupiter}" in
  zed)     IP=10.0.0.128; B=0x43C00000;;
  jupiter) IP=10.0.0.146; B=0x9D000000;;
  *) echo "usage: bist_read.sh zed|jupiter"; exit 2;;
esac
V=$("$W" $IP "for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = adrv9002-phy ] && P=\$d; done;
 echo \$(busybox devmem $((B+0x104)) 32) \$(busybox devmem $((B+0x108)) 32) \
 \$(busybox devmem $((B+0x144)) 32) \$(busybox devmem $((B+0x150)) 32) \$(busybox devmem $((B+0x154)) 32) \
 \$(cat \$P/in_voltage0_rssi 2>/dev/null|cut -d' ' -f1)" 2>/dev/null | tr -d '\r')
set -- $V
pk=$(printf %d "${1:-0}"); er=$(printf %d "${2:-0}")
ber=$(awk -v e=$er -v p=$pk 'BEGIN{ if(p>0) printf "%.6f", 100*e/(p*120); else printf "na" }')
echo "board=$IP packets=$pk errors=$er ber=${ber}% cap_out=${3:-na} rstcs=${4:-na} cfc_est=${5:-na} rssi=${6:-na}"
