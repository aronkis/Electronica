#!/bin/bash
# ddrcap2_capture.sh SEL NAME -- one 512 MB capture of one selector on the CURRENT arm (no arm inside).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; B=${B:-10.0.0.148}; SEL=${1:?SEL}; NAME=${2:?NAME}
SZ=${SZ:-134217728}; GOLD=BCF94856; OUT=${OUT:-$D/ddrcap2_pc/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }; norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
rd(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }
wr(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '$1 $2' > $DRA" >/dev/null 2>&1; }
[ -e "$OUT/$NAME.bin" ] && { log "REFUSE: $OUT/$NAME.bin exists"; exit 5; }
wr 0x10C "0x$(printf %X $(( (SEL<<16) | 3 )))"; sleep 2
C0=$(rd 0x20C); [ "$(norm "$C0")" = "$GOLD" ] || { log "ABORT: capTAP $C0 != golden"; exit 4; }
$W $B "cd /tmp && rm -f g.bin && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/g.bin" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
$W $B "cat /tmp/g.bin" > "$OUT/$NAME.bin" 2>/dev/null; GOT=$(stat -c %s "$OUT/$NAME.bin" 2>/dev/null || echo 0)
[ "$GOT" -ge $(( SZ*4*9/10 )) ] && $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1 || log "SHORT: $GOT bytes, board file kept"
C1=$(rd 0x20C); log "$NAME sel$SEL bytes=$GOT pre=$C0 post=$C1"; echo "$NAME sel=$SEL bytes=$GOT pre=$C0 post=$C1" >> "$OUT/meta.txt"
[ "$(norm "$C1")" = "$GOLD" ] || log "WARN: post capTAP not golden -- capture not credited"
