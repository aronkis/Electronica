#!/bin/bash
# t6_armed_capture.sh -- ONE capture per arm, from a link verified healthy at the
# moment of capture.
#
# Why: 2026-09-01 07:48 measured that DDR capture DEGRADES the receive link from
# about the third capture of a run -- fps halves (1248 -> ~600), capTAP stops
# matching golden, errs/s rises to ~35k, and it does NOT recover when capture
# stops. Last night's burst captures were numbers 4-7 of their run, i.e. after
# that onset, so they cannot be cleanly attributed to the beat.
#
# So: arm, verify golden, wait for the trigger, take exactly ONE capture, verify
# health again, re-arm for the next one. Slower, but every capture comes from a
# link that was provably healthy when it was taken.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; B=${B:-10.0.0.148}
N=${N:-6}; SZ=${SZ:-262144}; THRESH=${THRESH:-5000}; MODE=${MODE:-burst}
GOLD=BCF94856
OUT=${OUT:-$D/t6armed/$(date +%Y%m%d_%H%M%S)}; mkdir -p "$OUT"
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
arm(){
  $W $B 'PROF=jupiter_240k5; P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   cat /root/$PROF.bin > $P/stream_config 2>/dev/null; cat /root/$PROF.json > $P/profile_config 2>/dev/null; sleep 2
   echo calibrated > $P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > $P/in_voltage1_ensm_mode 2>/dev/null
   for g in 4 5 6 7; do echo 1 > $DB/agpio${g}_direction; echo 1 > $DB/agpio${g}_value; done
   echo tx_a > $P/out_voltage0_port_select
   echo 2000000000 > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain; echo rf_enabled > $P/out_voltage0_ensm_mode
   echo 2000000000 > $P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > $P/in_voltage0_ensm_mode; echo automatic > $P/in_voltage0_gain_control_mode
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo "0x208 0x0" > $DRA
   echo "0x000 0x1" > $DRA; sleep 0.5; echo "0x000 0x0" > $DRA
   echo "0x158 0x0" > $DRA; echo "0x118 0x0" > $DRA; echo "0x114 0x0" > $DRA
   echo "0x110 0x1" > $DRA; sleep 0.3; echo "0x110 0x0" > $DRA
   sleep 70
   echo "0x10C 0x60003" > $DRA; sleep 2; echo armed' >/dev/null 2>&1
}
probe(){  # -> "fps errps capTAP"
  $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo "$1">$DRA; cat $DRA; }
   p0=$(($(rd 0x104))); e0=$(($(rd 0x108))); sleep 2; p1=$(($(rd 0x104))); e1=$(($(rd 0x108)))
   echo "$(( (p1-p0)/2 )) $(( (e1-e0)/2 )) $(rd 0x20C)"' 2>/dev/null | tr -d '\r' | tail -1
}
log "=== armed-capture run: N=$N mode=$MODE size=$SZ -> $OUT"
got=0; try=0
while [ $got -lt $N ] && [ $try -lt $((N*3)) ]; do
  try=$((try+1))
  log "--- trial $try: arming (80 s)"
  arm
  read -r F0 E0 C0 <<<"$(probe)"
  CN=$(printf %s "${C0:-}" | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F')
  if [ "$CN" != "$GOLD" ] || [ "${F0:-0}" -lt 1100 ]; then
    log "  PRE-CHECK FAIL: fps=$F0 errps=$E0 capTAP=[$CN] want [$GOLD] -- not capturing this trial"
    continue
  fi
  log "  pre-check OK: fps=$F0 errps=$E0 capTAP=$C0"
  # wait for the wanted condition, at most 150 s (~1.3 beat periods)
  hit=0
  for s in $(seq 1 50); do
    read -r F E C <<<"$(probe)"
    if [ "$MODE" = burst ] && [ "${E:-0}" -gt "$THRESH" ]; then hit=1; break; fi
    if [ "$MODE" = quiet ] && [ "${E:-0}" -le 200 ]; then hit=1; break; fi
  done
  [ $hit -eq 0 ] && { log "  no $MODE window within the healthy period; re-arming"; continue; }
  got=$((got+1))
  f="$OUT/${MODE}_$(printf %02d $got)_err${E}.bin"
  $W $B "cd /tmp && iio_readdev -b 4096 -s $SZ axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /tmp/a.bin 2>/dev/null" >/dev/null 2>&1
  $W $B 'cat /tmp/a.bin' > "$f" 2>/dev/null
  read -r F1 E1 C1 <<<"$(probe)"
  log "  CAPTURED $MODE $got/$N errs=$E bytes=$(stat -c %s "$f" 2>/dev/null) | post: fps=$F1 errps=$E1 capTAP=$C1"
done
log "=== done: $got/$N $MODE captures, each from a link verified golden immediately before capture"
