#!/bin/bash
# Test whether WIDER LO separation fixes the 146 full-duplex RX failure.
# For each (FA,FB): clean measure CFO (ch2), clean arm (fresh profile reload +
# ch2 OFF + ch1-only), bidirectional -e echo. If 146 RX recovers as separation
# grows -> RF interference (front-end blocking). If not -> not RF (digital/SSI).
# Usage: fdd_sep_test.sh FA FB   (FA=146->148 carrier, FB=148->146 carrier)
set -u
FA=$1; FB=$2
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
sp(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
reload_clean(){ $W $1 'pkill -x qpsk_tun 2>/dev/null; P=/sys/bus/iio/devices/iio:device2; D=/sys/kernel/debug/iio/iio:device2
  cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
  echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
  for g in 4 5 6 7; do echo 1 > $D/agpio${g}_direction; echo 1 > $D/agpio${g}_value; done; echo tx_a > $P/out_voltage0_port_select' 2>/dev/null; }
armtx(){ $W $1 "P=/sys/bus/iio/devices/iio:device2
  echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5;pkill -x qpsk_tun 2>/dev/null;sleep 0.3;(setsid nohup ./qpsk_tun -F -e -d 90 >/dev/shm/tx.log 2>&1 &);sleep 2" 2>/dev/null; }
measure(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; echo $2 > \$P/out_altvoltage1_RX2_LO_frequency 2>/dev/null; echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode 2>/dev/null; sleep 1
  rm -f /dev/shm/c.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/c.iq 2>/dev/null" 2>/dev/null
 sp root@$1:/dev/shm/c.iq $D/c.iq
 python3 -c "
import numpy as np
d=np.fromfile('$D/c.iq',dtype=np.int16);I=d[0::2].astype(float);Q=d[1::2].astype(float);n=min(len(I),len(Q));x=I[:n]+1j*Q[:n];x-=x.mean()
N=1<<16;w=x[:N]**4;W=np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N),1<<18)));f=np.linspace(-.96e6,.96e6,1<<18)
m=np.abs(f)<400e3;W2=W.copy();W2[~m]=0;pk=int(np.argmax(W2));print('%d %.0f'%(round(f[pk]/4),W2[pk]/np.median(W[m])))"; }
echo "=== SEP TEST: FA=$FA (146->148) FB=$FB (148->146)  sep=$(( (FA>FB?FA-FB:FB-FA)/1000000 ))MHz ==="
reload_clean 10.0.0.146; reload_clean 10.0.0.148
$W 10.0.0.148 'echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
armtx 10.0.0.146 $FA; read CA SA < <(measure 10.0.0.148 $FA); TXA=$((FA-CA)); echo "  link A snr=$SA -> 146 TXLO=$TXA"
$W 10.0.0.146 'echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
armtx 10.0.0.148 $FB; read CB SB < <(measure 10.0.0.146 $FB); TXB=$((FB-CB)); echo "  link B snr=$SB -> 148 TXLO=$TXB"
# clean full-duplex arm (fresh reload + ch2 off), both TX on
reload_clean 10.0.0.146; reload_clean 10.0.0.148
for pr in "10.0.0.146 $TXA $FB" "10.0.0.148 $TXB $FA"; do set -- $pr
 $W $1 "P=/sys/bus/iio/devices/iio:device2
  echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5;sleep 0.3;(setsid nohup ./qpsk_tun -F -e -d 30 >/dev/shm/ech.log 2>&1 &)" 2>/dev/null
done
until ! $W 10.0.0.146 'pgrep -x qpsk_tun >/dev/null && echo R||echo D' 2>/dev/null | grep -q R; do sleep 5; done
echo "  146 (RX 148@$FB): $($W 10.0.0.146 'grep ECHO: /dev/shm/ech.log|tail -1' 2>/dev/null)"
echo "  148 (RX 146@$FA): $($W 10.0.0.148 'grep ECHO: /dev/shm/ech.log|tail -1' 2>/dev/null)"
