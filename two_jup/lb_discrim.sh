#!/bin/bash
# 146 half-rate discriminator: is it 146's own RX/fabric, or the RF path from 148?
# Arms each board with 0x114=0 (FPGA-INTERNAL loopback: board hears its own TX)
# and probes framesync rate. Control = the same probe with 0x114=1 (air).
#   146 loopback ~1245  => 146 receiver + fabric FINE -> RF path / 148 TX implicated
#   146 loopback ~510   => 146's own receive chain is the problem (RF exonerated)
# Non-destructive: register writes only, cleared by the next restore.
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146

rearm(){ # $1 ip  $2 value for 0x114 (0=internal loopback, 1=air)
  $W $1 "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo \"0x000 0x1\">\$DRA; sleep 0.5; echo \"0x000 0x0\">\$DRA; echo \"0x158 0x0\">\$DRA; echo \"0x118 0x0\">\$DRA; echo \"0x114 0x$2\">\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T; echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA" 2>/dev/null; }

probe(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); echo $(( (p1 - p0) / 5 ))' 2>/dev/null; }

rstcs(){ $W $1 'busybox devmem 0x9D000150' 2>/dev/null; }

for mode in 0 1; do
  [ $mode = 0 ] && label="INTERNAL LOOPBACK (0x114=0)" || label="AIR (0x114=1)"
  echo "=== $label ==="
  rearm $B $mode; rearm $A $mode
  sleep 3
  rearm $B $mode; rearm $A $mode     # double-tap, same discipline as bring-up
  sleep 4
  for rep in 1 2; do
    fb=$(probe $B); fa=$(probe $A)
    echo "  rep$rep: 146 rx=${fb:-0} f/s (rstcs=$(rstcs $B))   148 rx=${fa:-0} f/s (rstcs=$(rstcs $A))"
  done
done
echo "LB_DISCRIM_DONE"
