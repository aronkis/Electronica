#!/bin/bash
# t6_onset_capture.sh -- capture the burst ONSET by predicting it, not reacting to it.
# ONE revision of the capture instrument: option 2 (periodicity-armed) + large capture, together.
#
# Pre-registered in SESSION_20260830_AUTONOMOUS.md §51. Read that before interpreting anything.
#
# Why prediction rather than a faster trigger: a reactive trigger starts the capture 1-2 s AFTER
# onset, so it can only ever sample the middle of a burst. Predicting lets the capture START
# BEFORE onset and span the transition, which is the only thing that tests jump-vs-walk (§43/§51).
#
# Why a large capture: coverage, not latency, is the binding constraint. Measured ceiling
# 2026-09-01: 134 MB (-s 33554432) completes in 4 s, leaves 1398 MB free, /tmp tmpfs has 945 MB.
# 134 MB = 16,777,216 beats = 1361.8 frames = 4.36 s of link time at 312 f/s -- long enough to
# bracket an onset even with +/-2 s prediction error.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=${B:-10.0.0.148}
SZ=${SZ:-33554432}          # samples; 134 MB; 4.36 s of link time
PERIOD=${PERIOD:-120.2}     # burst period, re-synced every cycle (measured 121.8/119.8/121.8)
LEAD=${LEAD:-1.0}           # start the capture this many seconds BEFORE predicted onset
THRESH=${THRESH:-3000}      # errs/s that counts as in-burst
N=${N:-2}
GOLD=BCF94856
OUT=${OUT:-$D/onset/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

# 0.25 s error-rate sampler on the board; prints "<epoch_ms> <errs_in_window>"
watch_onset(){  # $1 = max seconds to watch
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
   end=\$(( \$(date +%s) + $1 ))
   prev=\$((\$(rd 0x108)))
   while [ \$(date +%s) -lt \$end ]; do
     # 1 s, NOT 0.25 s. A 0.25 s poll quadruples direct_reg_access traffic and
     # hung 148 on 2026-09-01 ~11:5x before writing a single log line. Every one
     # of the 30+ safe capture runs polled at 1 s. Trigger latency was never the
     # binding constraint (coverage is), so the faster poll bought nothing.
     sleep 1
     cur=\$((\$(rd 0x108))); d=\$(( (cur-prev)&0xFFFFFFFF )); prev=\$cur
     if [ \$d -gt $(( THRESH )) ]; then echo \"ONSET \$(date +%s.%N) \$d\"; exit 0; fi
   done
   echo NOONSET" 2>/dev/null | tr -d '\r' | tail -1
}
probe(){ $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
   p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 2; p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
   echo \"\$(( (p1-p0)/2 )) \$(( (e1-e0)/2 )) \$(rd 0x20C)\"" 2>/dev/null | tr -d '\r' | tail -1; }

read -r F E C <<<"$(probe)"
CN=$(printf %s "${C:-}" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F')
[ "$CN" != "$GOLD" ] && { log "PRE-CHECK FAIL: capTAP [$CN] != [$GOLD] -- not capturing"; exit 4; }
log "pre-check OK: fps=$F errps=$E capTAP=$C ; capture $SZ samples = $(( SZ*4/1048576 )) MB"

log "syncing to the burst phase (watching 0x108 at 0.25 s)..."
S=$(watch_onset 200)
case "$S" in ONSET*) T0=$(echo "$S" | awk '{print $2}'); log "  onset observed at $T0 (errs/0.25s=$(echo "$S"|awk '{print $3}'))";;
  *) log "  no onset within 200 s -- cannot sync; aborting"; exit 5;; esac

for n in $(seq 1 $N); do
  TARGET=$(python3 -c "print(f'{$T0 + $PERIOD*$n - $LEAD:.3f}')")
  NOW=$(date +%s.%N)
  SLEEP=$(python3 -c "print(max(0.0, $TARGET-$NOW))")
  log "--- capture $n: predicted onset $(python3 -c "print(f'{$T0+$PERIOD*$n:.1f}')"), starting ${LEAD}s early; sleeping ${SLEEP}s"
  sleep "$SLEEP"
  ST=$(date +%s.%N)
  $W $B "cd /tmp && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/on$n.bin 2>/dev/null; echo \$?" >/dev/null 2>&1
  EN=$(date +%s.%N)
  log "  capture $n done: started $ST ended $EN (span $(python3 -c "print(f'{$EN-$ST:.2f}')")s)"
  $W $B "cat /tmp/on$n.bin" > "$OUT/onset_$(printf %02d $n).bin" 2>/dev/null
  PULLED=$(stat -c %s "$OUT/onset_$(printf %02d $n).bin" 2>/dev/null)
  log "  pulled $PULLED bytes"
  # Delete the board-side file NOW. /tmp is a 981 MB tmpfs; leaving a 512 MB
  # capture there truncated the next one to 209 MB (2.68 s instead of 4.37 s)
  # with no error -- iio_readdev just stopped at ENOSPC and returned success.
  $W $B "rm -f /tmp/on$n.bin" >/dev/null 2>&1
  FREE=$($W $B "df -m /tmp | awk 'NR==2{print \$4}'" 2>/dev/null | tr -d ' \r\n')
  log "  board /tmp free after cleanup: ${FREE}MB"
  if [ "${PULLED:-0}" -lt $(( SZ*4*9/10 )) ]; then
    log "  !!! SHORT CAPTURE: got $PULLED of $(( SZ*4 )) bytes -- treat this capture as truncated"
  fi
  read -r F1 E1 C1 <<<"$(probe)"
  log "  post: fps=$F1 errps=$E1 capTAP=$C1"
  # re-sync rather than free-run: the period drifts (121.8 / 119.8 / 121.8)
  R=$(watch_onset 200)
  case "$R" in ONSET*) T0=$(echo "$R" | awk '{print $2}'); PERIOD=${PERIOD}; log "  re-synced: next onset reference $T0";;
    *) log "  re-sync failed; keeping the old reference";; esac
done
log "=== done: $N onset-bracketing captures in $OUT"
