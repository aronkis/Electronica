#!/bin/bash
# Move the FDD pair to clean spectrum (clear of 2.4GHz WiFi), measure CFO both
# directions via ch2, arm full-duplex with measured trims, bidirectional -e echo.
set -u
FA=2100000000   # SWAP: 146->148, 148 RX@2.10
FB=2000000000   # SWAP: 148->146, 146 RX@2.00
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
sp(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
armtx(){ # $1 ip $2 txlo  -> byte-Tx AIR radiating (daemon -e)
 $W $1 "P=/sys/bus/iio/devices/iio:device2; D=/sys/kernel/debug/iio/iio:device2
  cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
  echo calibrated > \$P/out_voltage1_ensm_mode; for g in 4 5 6 7; do echo 1 > \$D/agpio\${g}_direction; echo 1 > \$D/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
  echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x158 0x1'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; (setsid nohup ./qpsk_tun -F -e -d 90 >/dev/shm/tx.log 2>&1 &); sleep 2" 2>/dev/null
}
measure(){ # $1 rx_ip $2 carrier ; echoes CFO
 $W $1 "P=/sys/bus/iio/devices/iio:device2; echo $2 > \$P/out_altvoltage1_RX2_LO_frequency 2>/dev/null; echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode 2>/dev/null; sleep 1
  rm -f /dev/shm/c.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/c.iq 2>/dev/null" 2>/dev/null
 sp root@$1:/dev/shm/c.iq $D/c_$1.iq
 python3 -c "
import numpy as np
d=np.fromfile('$D/c_$1.iq',dtype=np.int16); I=d[0::2].astype(float);Q=d[1::2].astype(float);n=min(len(I),len(Q));x=I[:n]+1j*Q[:n];x-=x.mean()
N=1<<16; w=x[:N]**4; W=np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N),1<<18))); f=np.linspace(-0.96e6,0.96e6,1<<18)
m=np.abs(f)<400e3; W2=W.copy(); W2[~m]=0; pk=int(np.argmax(W2)); snr=W2[pk]/np.median(W[m])
print('%d %.0f' % (round(f[pk]/4), snr))"
}
echo "=== measure link A (146->148 @$FA) ==="
$W 10.0.0.148 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
armtx 10.0.0.146 $FA
read CFOA SNRA < <(measure 10.0.0.148 $FA)
TXA=$((FA - CFOA)); echo "  CFO_A=$CFOA Hz snr=$SNRA -> 146 TXLO=$TXA"
$W 10.0.0.146 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
echo "=== measure link B (148->146 @$FB) ==="
armtx 10.0.0.148 $FB
read CFOB SNRB < <(measure 10.0.0.146 $FB)
TXB=$((FB - CFOB)); echo "  CFO_B=$CFOB Hz snr=$SNRB -> 148 TXLO=$TXB"
$W 10.0.0.148 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
echo "=== arm full-duplex (measured trims) + bidirectional echo ==="
# 146: Tx@TXA Rx@FB ; 148: Tx@TXB Rx@FA
for pair in "10.0.0.146 $TXA $FB" "10.0.0.148 $TXB $FA"; do set -- $pair
 $W $1 "P=/sys/bus/iio/devices/iio:device2
  echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x158 0x1'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; (setsid nohup ./qpsk_tun -F -e -d 35 >/dev/shm/ech.log 2>&1 &)" 2>/dev/null
done
until ! $W 10.0.0.146 'pgrep -x qpsk_tun >/dev/null && echo R||echo D' 2>/dev/null | grep -q R; do sleep 5; done
echo "146 (RX 148@$FB): $($W 10.0.0.146 'grep ECHO: /dev/shm/ech.log|tail -1' 2>/dev/null)"
echo "148 (RX 146@$FA): $($W 10.0.0.148 'grep ECHO: /dev/shm/ech.log|tail -1' 2>/dev/null)"
echo "TRIMS: 146_TXLO=$TXA 148_TXLO=$TXB (carriers A=$FA B=$FB)"
