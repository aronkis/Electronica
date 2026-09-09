#!/bin/bash
# beat_timeline.sh -- TIMELINE ONLY on the CURRENT arm: no arm, no capture, no 0x10C write.
# Reads 0x20C (capTAP) once before and once after; for SECS seconds, one bounded 0x108 poll
# per second (single register per poll, rail: minimise register reads). Writes errps.csv in the
# 3-column cumulative form beat_detect.py --per-second's detect_seconds() consumes (t,packets,errs
# where errs is the CUMULATIVE 0x108 value -- detect_seconds diffs it itself; packets is unused by
# the parser and left 0 since we never read 0x104 here), plus meta.txt (pre/post capTAP, start/end
# epoch, count of inter-poll gaps > 2 s). Aborts (TIMELINE_ABORT) after 3 CONSECUTIVE read failures.
# DRY=1 fabricates a plausible register stream (quiet ~100/s baseline, three synthetic 60,000/s
# bursts of 3 s each, 120 s apart) so the CSV + beat_detect.py parser path is exercised end to end
# with zero board contact -- no ssh/scp is invoked at all under DRY.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=${W:-$D/anyssh.sh}; A=${A:-10.0.0.148}
SECS=${SECS:-420}; OUT=${OUT:-$D/beattl/$(date +%Y%m%d_%H%M%S)}; DRY=${DRY:-0}
mkdir -p "$OUT"
DRA='/sys/kernel/debug/iio/iio:device0/direct_reg_access'
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

# rd_real REG -- one bounded (30s) read of REG over ssh, one register per poll. Echoes the value
# (possibly empty on failure/timeout); caller decides failure vs success.
rd_real(){ timeout 30 $W $A "echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; echo $1 > $DRA; cat $DRA" 2>/dev/null | tr -d '\r' | tail -1; }

# DRY fabrication: deterministic cumulative 0x108 stream, no sleeps, no ssh.
DRY_BASE_INC=100
DRY_BURST_STARTS="100 220 340"   # three windows, 120 s apart
dry_reg108(){ # $1 = second index (1-based)
  local sec=$1 inc=$DRY_BASE_INC bs
  for bs in $DRY_BURST_STARTS; do
    if [ "$sec" -ge "$bs" ] && [ "$sec" -lt "$((bs+3))" ]; then inc=60000; break; fi
  done
  echo "$inc"
}

if [ "$DRY" = 1 ]; then
  log "[dry] 0x20C pre-read (no board contact)"; PRE="0xBCF94856"
else
  PRE=$(rd_real 0x20C)
fi

START=$(date +%s.%N); FAILS=0; GAPS=0; LASTT=$START; CUM=0
echo "t,packets,errs" > "$OUT/errps.csv"
i=1
while [ "$i" -le "$SECS" ]; do
  if [ "$DRY" != 1 ]; then sleep 1; fi
  if [ "$DRY" = 1 ]; then
    V=$(dry_reg108 "$i")
  else
    V=$(rd_real 0x108)
  fi
  if [ -z "$V" ]; then
    FAILS=$((FAILS+1))
    log "0x108 read FAILED ($FAILS/3 consecutive) at t=$i"
    if [ "$FAILS" -ge 3 ]; then
      log "TIMELINE_ABORT secs=$i (3 consecutive read failures)"
      echo "TIMELINE_ABORT secs=$i" >> "$OUT/meta.txt"
      exit 3
    fi
    i=$((i+1)); continue
  fi
  FAILS=0
  if [ "$DRY" != 1 ]; then
    NOW=$(date +%s.%N)
    GAPDT=$(python3 -c "print(1 if ($NOW - $LASTT) > 2 else 0)")
    [ "$GAPDT" = 1 ] && GAPS=$((GAPS+1))
    LASTT=$NOW
  fi
  if [ "$DRY" = 1 ]; then
    CUM=$((CUM+V))
  else
    CUM=$(( V ))   # 0x108 is itself the cumulative counter on-board; DRY synthesises its own cumulative sum above
  fi
  echo "$i,0,$CUM" >> "$OUT/errps.csv"
  i=$((i+1))
done
END=$(date +%s.%N)

if [ "$DRY" = 1 ]; then
  log "[dry] 0x20C post-read (no board contact)"; POST="0xBCF94856"
else
  POST=$(rd_real 0x20C)
fi

{
  echo "pre_capTAP=$PRE"
  echo "post_capTAP=$POST"
  echo "start_epoch=$START"
  echo "end_epoch=$END"
  echo "gaps_gt_2s=$GAPS"
} >> "$OUT/meta.txt"

log "TIMELINE_OK secs=$SECS gaps=$GAPS pre=$PRE post=$POST"
echo "TIMELINE_OK secs=$SECS gaps=$GAPS pre=$PRE post=$POST"
python3 "$D/beat_detect.py" "$OUT/errps.csv" --per-second | tee -a "$OUT/run.log" | grep '^BURSTS '
