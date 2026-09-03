#!/bin/bash
# test_gainboost.sh -- is 146's weak Rx fixable by filling the ADC (gain headroom)?
# Arm FDD both, then on 146 switch to MANUAL Rx gain and sweep it UP; read back the
# actual (capped) gain, the resulting ADC rms (Tap-A), and the -B BER. If higher gain
# raises rms toward 148's ~4700 and drops BER, the residual is under-driven-ADC (AGC)
# and fixable; if gain caps at 34 with rms stuck ~786, it's RF link-budget.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; OUT=$D/resid; mkdir -p "$OUT"
TXA=2000005489; FA=2000000000; TXB=2099994268; FB=2100000000
arm(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo $4 > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed gc=$4'" 2>/dev/null; }
rmscap(){ $W 10.0.0.146 'timeout 8 iio_readdev -u local: -b 16384 -s 100000 axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null > /dev/shm/g.iq; python3 -c "import sys,struct,statistics; d=open(\"/dev/shm/g.iq\",\"rb\").read(); import array; a=array.array(\"h\"); a.frombytes(d[:len(d)//4*4]); import math; n=len(a); s=sum(x*x for x in a)/max(n,1); print(int(math.sqrt(s)))" 2>/dev/null' 2>/dev/null; }

echo "=== GAINBOOST TEST $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
arm 10.0.0.146 $TXA $FB manual & arm 10.0.0.148 $TXB $FA automatic & wait   # 146 RX manual, 148 TX
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
$W 10.0.0.148 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 120 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null  # 148 radiates
$W 10.0.0.146 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 120 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null  # 146 measures
sleep 12
echo "  probe 146 Rx gain ceiling (set manual, request 60 dB):"
$W 10.0.0.146 'P=/sys/bus/iio/devices/iio:device2; echo manual > $P/in_voltage0_gain_control_mode 2>/dev/null; echo 60 > $P/in_voltage0_hardwaregain 2>/dev/null; echo "  requested 60 -> readback MAX=$(cat $P/in_voltage0_hardwaregain)"' 2>/dev/null
echo "  --- gain sweep: gain -> ADC rms (target ~4700 like 148) ---"
for g in 34 40 44 48 52; do
  $W 10.0.0.146 "echo $g > /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain 2>/dev/null" 2>/dev/null; sleep 3
  ACT=$($W 10.0.0.146 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
  echo "    gain=$g (act=$ACT)  rms_adc=$(rmscap)  rssi=$($W 10.0.0.146 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null|cut -d" " -f1' 2>/dev/null)"
done
sleep 5
echo "  146 RX -B (at last gain) BER:"; $W 10.0.0.146 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== DONE ==="
