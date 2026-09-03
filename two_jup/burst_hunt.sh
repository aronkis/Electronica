#!/bin/bash
# =============================================================================
# burst_hunt.sh -- pinpoint the source of the 5-100-frame burst class (~1.1% PER).
#
# Known: bursts need the RF path (absent in internal loopback), are 4-27 ms,
# Poisson-arrival (~1 per 2-3 s; NOT a scheduled cal), no carrier signature
# (cfc stable, rstcs=0), no host stall. Suspects: 146 RX AGC steps, event-driven
# device cals, channel/interference, SSI delivery.
#
# This run: a normal reverse capture (AGC auto) with a parallel 20 Hz poller on
# 146 logging BOARD-REALTIME + hardwaregain (the AGC's chosen gain) + rssi.
# The framelog records t_real_ns per frame on the SAME board clock, so burst
# events and gain steps correlate exactly. If every burst coincides with a gain
# step -> AGC. Then (optionally, MODE=manual) a second capture with AGC forced
# to manual fixed gain: bursts gone -> AGC confirmed; persist -> channel/cal/SSI.
#
# Usage: burst_hunt.sh            # AGC auto + gain poller (correlation run)
#        MODE=manual burst_hunt.sh  # AGC manual fixed-gain discriminator run
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.146
MODE=${MODE:-auto}
STAMP=$(date +%Y%m%d_%H%M%S)
OUT=$D/r3cap/hunt_${MODE}_$STAMP
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

echo "=== burst_hunt MODE=$MODE -> $OUT ==="

# start the gain/rssi poller on 146 (survives the capture's own ssh sessions;
# board-realtime timestamps = same clock as framelog t_real_ns)
$W $B 'export P=/sys/bus/iio/devices/iio:device2
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 pkill -f "[g]ainpoll" 2>/dev/null
 setsid sh -c '"'"'echo gainpoll >/dev/null; : > /dev/shm/gain.log
   for i in $(seq 1 5600); do
     echo "0x15C" > /sys/kernel/debug/iio/iio:device0/direct_reg_access 2>/dev/null
     FX=$(cat /sys/kernel/debug/iio/iio:device0/direct_reg_access 2>/dev/null)
     echo "t=$(date +%s.%N) gain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null) dp=$(cat $P/in_voltage0_decimated_power 2>/dev/null) fx=$FX mode=$(cat $P/in_voltage0_gain_control_mode 2>/dev/null)" >> /dev/shm/gain.log
     sleep 0.05
   done'"'"' </dev/null >/dev/null 2>&1 &
 echo poller started (280s @ 20Hz)' 2>/dev/null

# MODE=manual: after bringup arms with AGC auto, flip 146 RX to manual at the
# AGC's settled gain (read it first). Done via a delayed hook: capture_r3's
# wedge-check window is ~60-90s in; we flip at +70s from launch.
if [ "$MODE" = caloff ]; then
  # disable ALL 146 RX tracking cals once the link is up (+70s); restored at end.
  ( sleep 70
    $W $B 'P=/sys/bus/iio/devices/iio:device2
      for c in agc bbdc_rejection quadrature_fic rfdc rssi; do echo 0 > $P/in_voltage0_${c}_tracking_en 2>/dev/null; done
      printf "cals off:"; for c in agc bbdc_rejection quadrature_fic rfdc rssi; do printf " %s=%s" "$c" "$(cat $P/in_voltage0_${c}_tracking_en)"; done; echo' 2>/dev/null
  ) &
  HOOK_PID=$!
fi
if [ "$MODE" = manual ]; then
  ( sleep 70
    $W $B 'P=/sys/bus/iio/devices/iio:device2
      G=$(cat $P/in_voltage0_hardwaregain 2>/dev/null)
      echo manual > $P/in_voltage0_gain_control_mode 2>/dev/null
      echo "$G" > $P/in_voltage0_hardwaregain 2>/dev/null
      echo "manual gain pinned at $G (mode=$(cat $P/in_voltage0_gain_control_mode))"' 2>/dev/null
  ) &
  HOOK_PID=$!
fi

LO_B_RX=1900020000 RXQ=1 GATE_TRIES=12 "$D/capture_r3.sh" B -n ${TAPN:-8000000} -o "$OUT"
RC=$?
{ [ "$MODE" = manual ] || [ "$MODE" = caloff ]; } && wait ${HOOK_PID:-} 2>/dev/null
$W $B 'pkill -f "[g]ainpoll" 2>/dev/null; pkill -f "gain.log" 2>/dev/null; true' 2>/dev/null
scpput root@$B:/dev/shm/gain.log "$OUT/gain.log" || echo "WARN: gain.log fetch failed"
# restore AGC auto for whoever runs next
[ "$MODE" = caloff ] && $W $B 'P=/sys/bus/iio/devices/iio:device2; for c in agc bbdc_rejection quadrature_fic rfdc rssi; do echo 1 > $P/in_voltage0_${c}_tracking_en 2>/dev/null; done; echo cals restored' 2>/dev/null
[ "$MODE" = manual ] && $W $B 'echo automatic > /sys/bus/iio/devices/iio:device2/in_voltage0_gain_control_mode 2>/dev/null; echo AGC restored' 2>/dev/null
[ $RC -ne 0 ] && { echo "capture failed rc=$RC"; exit $RC; }
echo "BURST_HUNT_DONE $OUT"
