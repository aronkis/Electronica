#!/bin/bash
# soak_harness.sh — unattended link-intermittency soak (146 Tx@2.0 -> 148 Rx@2.0, OTA, LNAs on)
# Each iteration: canonical arms -> BIST x5 -> classify GOLD/STABLEWRONG/VARYING/DEAD -> log CSV.
# On failure: save a 100k-sample IQ capture (payload-diff analysis later). Reboot both boards
# every REBOOT_EVERY iterations for clean-state statistics. Ctrl-C / kill to stop.
#
#   log:      soak/soak_log.csv   (ts,iter,mode,class,locks,caps,rssi,temp148,temp146,cfo_est,capfile)
#   captures: soak/fail_<iter>_<ts>.iq  (capped at MAX_CAPS)
#   stop:     touch soak/STOP     (or kill the process)

set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
SOAK=$D/soak; mkdir -p "$SOAK"
LOG=$SOAK/soak_log.csv
[ -f "$LOG" ] || echo "ts,iter,mode,class,locks,caps,rssi,temp148,temp146,cfo_hz,capfile" > "$LOG"
REBOOT_EVERY=10
MAX_CAPS=100
GOLD=0x4922282

scpget() { SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

reboot_both() {
  $W 10.0.0.148 '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
  $W 10.0.0.146 '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
  for ip in 148 146; do until ! ping -c1 -W1 10.0.0.$ip >/dev/null 2>&1; do sleep 2; done; done
  for ip in 148 146; do until ping -c1 -W2 10.0.0.$ip >/dev/null 2>&1; do sleep 3; done; done
  sleep 20
  for ip in 148 146; do
    $W 10.0.0.$ip 'P=/sys/bus/iio/devices/iio:device2; D=/sys/kernel/debug/iio/iio:device2
      cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null
      cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
      echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
      for g in 4 5 6 7; do echo 1 > $D/agpio${g}_direction; echo 1 > $D/agpio${g}_value; done' 2>/dev/null
  done
}

arm_link() {
  # 146 = Tx full canonical @2.0 atten0 ; 148 = Rx canonical (own Tx RF silent)
  $W 10.0.0.146 'P=/sys/bus/iio/devices/iio:device2
    echo 2000000000 > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain
    echo rf_enabled > $P/out_voltage0_ensm_mode
    DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
    TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
    T=/sys/kernel/debug/iio/$TXD/direct_reg_access
    echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null
  $W 10.0.0.148 'P=/sys/bus/iio/devices/iio:device2
    echo calibrated > $P/out_voltage0_ensm_mode
    echo 2000000000 > $P/out_altvoltage0_RX1_LO_frequency
    echo rf_enabled > $P/in_voltage0_ensm_mode; echo automatic > $P/in_voltage0_gain_control_mode
    DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
    echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null
}

measure() {  # echoes: locks|caps|rssi|temp148
  $W 10.0.0.148 'P=/sys/bus/iio/devices/iio:device2
    DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
    rd(){ echo "$1">$DRA; cat $DRA; }
    sleep 2; locks=0; caps=""
    for t in 1 2 3 4 5; do c=$(rd 0x144); caps="$caps$c;"; [ "$c" = "0x4922282" ] && locks=$((locks+1)); sleep 0.4; done
    echo "$locks|$caps|$(cat $P/in_voltage0_rssi 2>/dev/null | cut -d" " -f1)|$(cat $P/in_temp0_input 2>/dev/null)"' 2>/dev/null
}

ncaps=$(ls "$SOAK"/fail_*.iq 2>/dev/null | wc -l)
iter=0
echo "soak harness started $(date -Is) (REBOOT_EVERY=$REBOOT_EVERY MAX_CAPS=$MAX_CAPS)"
while true; do
  [ -f "$SOAK/STOP" ] && { echo "STOP file seen — exiting"; break; }
  iter=$((iter+1))
  mode=rearm
  if [ $(( (iter-1) % REBOOT_EVERY )) -eq 0 ]; then mode=reboot; reboot_both; fi
  arm_link
  M=$(measure)
  locks=$(echo "$M" | cut -d'|' -f1); caps=$(echo "$M" | cut -d'|' -f2)
  rssi=$(echo "$M" | cut -d'|' -f3);  t148=$(echo "$M" | cut -d'|' -f4)
  t146=$($W 10.0.0.146 'cat /sys/bus/iio/devices/iio:device2/in_temp0_input 2>/dev/null' 2>/dev/null)
  # classify
  ucaps=$(echo "$caps" | tr ';' '\n' | grep -v '^$' | sort -u | wc -l)
  if [ "${locks:-0}" -ge 4 ]; then class=GOLD
  elif [ "$ucaps" -le 2 ]; then class=STABLEWRONG
  elif echo "$caps" | grep -q '^0x0;0x0'; then class=DEAD
  else class=VARYING; fi
  capfile=""
  cfo=""
  if [ "$class" != "GOLD" ] && [ "$ncaps" -lt "$MAX_CAPS" ]; then
    ts=$(date +%H%M%S)
    $W 10.0.0.148 'rm -f /dev/shm/sk.iq; timeout 5 iio_readdev -u local: -b 16384 -s 100000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/sk.iq 2>/dev/null' 2>/dev/null
    capfile="fail_${iter}_${ts}.iq"
    scpget root@10.0.0.148:/dev/shm/sk.iq "$SOAK/$capfile"
    ncaps=$((ncaps+1))
    cfo=$(python3 - "$SOAK/$capfile" <<'PY' 2>/dev/null
import sys, numpy as np
d=np.fromfile(sys.argv[1],dtype=np.int16); I=d[0::2].astype(float);Q=d[1::2].astype(float)
n=min(len(I),len(Q)); x=I[:n]+1j*Q[:n]; x=x-x.mean()
N=1<<16; w=x[:N]**4
W=np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N)))); f=np.linspace(-0.96e6,0.96e6,N)
m=np.abs(f)<40e3; W[~m]=0
print(int(f[np.argmax(W)]/4))
PY
)
  fi
  line="$(date -Is),$iter,$mode,$class,${locks:-?}/5,\"$caps\",$rssi,$t148,$t146,$cfo,$capfile"
  echo "$line" >> "$LOG"
  echo "[$iter] $class locks=${locks:-?}/5 rssi=$rssi t148=$t148 $capfile"
  sleep 5
done
