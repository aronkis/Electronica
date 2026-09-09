#!/bin/bash
# beat_tap_capture.sh SEL -- ONE arm on 148 (mode 1), TWO burst-phased 512 MB DDR captures of one selector:
#   mid.bin   : triggered when 0x108 delta > THRESH (guaranteed in-burst, as sel5_capture.sh)
#   onset.bin : launched at T_trigger + PERIOD - LEAD so the ~1.09 s window straddles the NEXT onset
# Rules (each learned the hard way, see sel5_capture.sh): 0x10C set AFTER the arm and verified by
# effect on 0x20C; 1 s polls, one register per poll; capTAP golden before/after each capture or the
# capture is not credited; host-side stat BEFORE the board-side rm; no retry loop.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; ARM=${ARM:-$D/arm148_mode1.sh}; B=${B:-10.0.0.148}
SEL=${SEL:-${1:?usage: beat_tap_capture.sh SEL  (or SEL=n via launch_rig_unit.sh)}}
SZ=${SZ:-134217728}; PERIOD=${PERIOD:-120.2}; LEAD=${LEAD:-1.5}
THRESH=${THRESH:-3000}; GOLD=BCF94856; OUT=${OUT:-$D/beatcap/$(date +%Y%m%d_%H%M%S)_sel$SEL}; mkdir -p "$OUT"
# Known tap-3 burst words (capTAP takes one of these DURING a genuine beat burst,
# by design -- SESSION_20260830_AUTONOMOUS.md sec72/sec38/sec26). A pre/post
# capTAP read of one of these, not just GOLD, still credits the capture.
RUNGWORDS="0AA4D2D3 D8A04817 D71F70D3 6B47D467 93E1A9FA BFED37AC D748FC96 41800000"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
norm(){ printf %s "$1" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
ok_or_rung(){ local n; n=$(norm "$1"); [ "$n" = "$GOLD" ] && return 0; for w in $RUNGWORDS; do [ "$n" = "$w" ] && return 0; done; return 1; }
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
rd(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }
wr(){ $W $B "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo '$1 $2' > $DRA" >/dev/null 2>&1; }
capture(){ # $1 = name
  local C0 C1 GOT CREDIT; C0=$(rd 0x20C)
  ok_or_rung "$C0" || { log "ABORT $1: capTAP $C0 != golden and not a known burst word"; return 4; }
  $W $B "cd /tmp && rm -f g.bin && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/g.bin 2>/dev/null; stat -c 'BOARD %s' /tmp/g.bin" 2>/dev/null | tail -1 | tee -a "$OUT/run.log"
  [ -e "$OUT/$1.bin" ] && { log "REFUSE: $OUT/$1.bin exists ($(stat -c %s "$OUT/$1.bin") bytes) -- not overwriting"; return 5; }
  $W $B "cat /tmp/g.bin" > "$OUT/$1.bin" 2>/dev/null
  GOT=$(stat -c %s "$OUT/$1.bin" 2>/dev/null || echo 0)
  if [ "$GOT" -ge $(( SZ*4*9/10 )) ]; then $W $B "rm -f /tmp/g.bin" >/dev/null 2>&1; else log "SHORT $1: $GOT bytes -- board file kept"; fi
  C1=$(rd 0x20C); log "$1: $GOT bytes pre=$C0 post=$C1"
  if ok_or_rung "$C1"; then CREDIT=yes; else CREDIT=no; log "WARN $1: post capTAP $C1 not golden/known-rung -- capture not credited"; fi
  echo "$1 bytes=$GOT pre=$C0 post=$C1 credit=$CREDIT" >> "$OUT/meta.txt"
}
log "=== beat_tap_capture sel$SEL -> $OUT"
$ARM 2>&1 | tee -a "$OUT/run.log" | grep -q ARM_OK || { log "ARM failed -- stop (no retry)"; exit 3; }
wr 0x10C "0x$(printf %X $(( (SEL<<16) | 3 )))"; sleep 2
C=$(rd 0x20C); [ "$(norm "$C")" = "$GOLD" ] || { log "selector set but capTAP $C != golden -- stop"; exit 4; }
echo "sel=$SEL mux=0x$(printf %X $(( (SEL<<16) | 3 )))" > "$OUT/meta.txt"
echo "t,errps" > "$OUT/errps.csv"; e0=$(( $(rd 0x108) )); T0=$(date +%s.%N); TRIG=""
for w in $(seq 1 300); do
  sleep 1; e1=$(( $(rd 0x108) )); E=$(( (e1-e0)&0xFFFFFFFF )); e0=$e1
  echo "$w,$E" >> "$OUT/errps.csv"
  [ "$E" -gt "$THRESH" ] && { TRIG=$(date +%s.%N); log "TRIGGER errps=$E at +${w}s"; break; }
done
[ -n "$TRIG" ] || { log "no burst in 300 s -- stop"; exit 6; }
echo "T_trigger=$TRIG" >> "$OUT/meta.txt"
capture mid || exit $?
TON=$(python3 -c "print($TRIG + $PERIOD - $LEAD)"); echo "T_onset_pred=$TON" >> "$OUT/meta.txt"
log "waiting $(python3 -c "print(round($TON - $(date +%s.%N), 1))")s for predicted onset (PERIOD=$PERIOD LEAD=$LEAD)"
while [ "$(python3 -c "print(int($(date +%s.%N) < $TON))")" = 1 ]; do sleep 1; done
capture onset || exit $?
log "=== done"
