#!/bin/bash
# sweep_146rx.sh -- wideband frequency sweep of the 148 Tx -> 146 Rx link, 100 MHz .. 2.1 GHz.
# 148 radiates the modem (-B) at each LO; 146 receives with FIXED (manual) Rx gain so the ADC
# rms tracks the actual received power (not the AGC). 146 Tx disabled (no self-interference).
# Also measures the NOISE floor (148 Tx off) at each point -> signal/noise ratio vs frequency.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; OUT=$D/resid; mkdir -p "$OUT"
STEP=${STEP:-100000000}; F0=${F0:-100000000}; F1=${F1:-2100000000}
arm(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $2 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo armed" 2>/dev/null; }
rms146(){ $W 10.0.0.146 'timeout 8 iio_readdev -u local: -b 16384 -s 80000 axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null > /dev/shm/g.iq; python3 -c "import array,math; a=array.array(\"h\"); d=open(\"/dev/shm/g.iq\",\"rb\").read(); a.frombytes(d[:len(d)//4*4]); n=max(len(a),1); print(int(math.sqrt(sum(x*x for x in a)/n)))" 2>/dev/null' 2>/dev/null; }
txset(){ $W 10.0.0.148 "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode 2>/dev/null; echo $1 > \$P/out_altvoltage2_TX1_LO_frequency 2>/dev/null; echo rf_enabled > \$P/out_voltage0_ensm_mode 2>/dev/null; echo \$(cat \$P/out_altvoltage2_TX1_LO_frequency)" 2>/dev/null; }
rxset(){ $W 10.0.0.146 "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $1 > \$P/out_altvoltage0_RX1_LO_frequency 2>/dev/null; echo rf_enabled > \$P/in_voltage0_ensm_mode 2>/dev/null; echo \$(cat \$P/out_altvoltage0_RX1_LO_frequency)" 2>/dev/null; }
txoff(){ $W 10.0.0.148 'echo rf_disabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode 2>/dev/null' 2>/dev/null; }
txon(){ $W 10.0.0.148 'echo rf_enabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode 2>/dev/null' 2>/dev/null; }

echo "=== 146-Rx WIDEBAND SWEEP ($((F0/1000000))-$((F1/1000000)) MHz step $((STEP/1000000))) $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
arm 10.0.0.148 $F0 & arm 10.0.0.146 $F0 & wait
$W 10.0.0.146 'echo manual > /sys/bus/iio/devices/iio:device2/in_voltage0_gain_control_mode; echo 34 > /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain; echo rf_disabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null  # 146 Rx manual gain, Tx off
# PASS A (signal): 148 -B radiating. PASS B (noise/ambient): 148 -B KILLED + Tx rf_disabled.
declare -A SIG NOI
pass(){ # $1 on(1/0)
  if [ "$1" = 1 ]; then $W 10.0.0.148 "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; echo rf_enabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode 2>/dev/null; setsid sh -c './qpsk_tun -B -d 300 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  else $W 10.0.0.148 'pkill -x qpsk_tun 2>/dev/null; echo rf_disabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode 2>/dev/null' 2>/dev/null; fi
  sleep 3
  f=$F0
  while [ $f -le $F1 ]; do
    [ "$1" = 1 ] && txset $f >/dev/null; rxset $f >/dev/null; sleep 2
    v=$(rms146)
    if [ "$1" = 1 ]; then SIG[$f]=$v; else NOI[$f]=$v; fi
    f=$((f+STEP))
  done
}
pass 1
pass 0
printf "%-8s %-8s %-8s %-8s\n" "f_MHz" "sig" "noise" "S/N_dB" | tee "$OUT/sweep_146rx.txt"
f=$F0
while [ $f -le $F1 ]; do
  s=${SIG[$f]:-0}; n=${NOI[$f]:-0}
  snr=$(python3 -c "import math; s=$s; n=$n; d=s*s-n*n; print(round(10*math.log10(max(d,1)/max(n*n,1)),1) if d>0 else -99)" 2>/dev/null)
  printf "%-8s %-8s %-8s %-8s\n" "$((f/1000000))" "$s" "$n" "$snr" | tee -a "$OUT/sweep_146rx.txt"
  f=$((f+STEP))
done
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== DONE -> $OUT/sweep_146rx.txt ==="
