#!/bin/bash
# Full bidirectional FDD tun0 link with STAGGERED startup (the acquisition-race fix).
# Link: 146 TX@2.00->148 RX@2.00 ; 148 TX@2.10->146 RX@2.10.
# Measure trims (ch2) -> bring up 148 full-duplex+daemon FIRST (steady) -> bring up
# 146 -> tun0 addressing (146=10.66.0.1, 148=10.66.0.2, MTU 116) -> verify dma_rx + ping.
set -u
FA=2000000000   # 146 TX -> 148 RX
FB=2100000000   # 148 TX -> 146 RX
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; SRC=$D/../host_app_k5
sp(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
reload(){ $W $1 'pkill -x qpsk_tun 2>/dev/null; P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
  cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
  echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
  for g in 4 5 6 7; do echo 1 > $DB/agpio${g}_direction; echo 1 > $DB/agpio${g}_value; done; echo tx_a > $P/out_voltage0_port_select' 2>/dev/null; }
txon(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5;pkill -x qpsk_tun 2>/dev/null;sleep 0.3;(setsid nohup ./qpsk_tun -F -e -d 40 >/dev/shm/m.log 2>&1 &);sleep 2" 2>/dev/null; }
measure(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode 2>/dev/null; echo $2 > \$P/out_altvoltage1_RX2_LO_frequency 2>/dev/null; sleep 1; rm -f /dev/shm/c.iq; timeout 6 iio_readdev -u local: -b 32768 -s 250000 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/c.iq 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode" 2>/dev/null; sp root@$1:/dev/shm/c.iq $D/c.iq; python3 -c "
import numpy as np
d=np.fromfile('$D/c.iq',dtype=np.int16);I=d[0::2].astype(float);Q=d[1::2].astype(float);n=min(len(I),len(Q));x=I[:n]+1j*Q[:n];x-=x.mean()
N=1<<16;w=x[:N]**4;W=np.fft.fftshift(np.abs(np.fft.fft(w*np.hanning(N),1<<18)));f=np.linspace(-.96e6,.96e6,1<<18)
m=np.abs(f)<400e3;W2=W.copy();W2[~m]=0;pk=int(np.argmax(W2));print('%d'%round(f[pk]/4))"; }

echo "=== measure trims ==="
reload 10.0.0.146; reload 10.0.0.148
$W 10.0.0.148 'echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
txon 10.0.0.146 $FA; CA=$(measure 10.0.0.148 $FA); TXA=$((FA-CA)); echo "  146 TX trim: CFO=$CA -> TXLO=$TXA"
$W 10.0.0.146 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
txon 10.0.0.148 $FB; CB=$(measure 10.0.0.146 $FB); TXB=$((FB-CB)); echo "  148 TX trim: CFO=$CB -> TXLO=$TXB"
$W 10.0.0.148 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null

# full-duplex arm + tun daemon. bringup(): arm TX/RX + launch -i tun0 + set tun addr
bringup(){ # $1 ip $2 txlo $3 rxlo $4 tunaddr $5 peeraddr
 reload $1
 $W $1 "P=/sys/bus/iio/devices/iio:device2
  echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
  echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
  cd /root/host_app_k5;pkill -x qpsk_tun 2>/dev/null;sleep 0.3;(setsid nohup ./qpsk_tun -F -i tun0 -s 30 >/dev/shm/qpsk_tun.log 2>&1 &);sleep 1
  for i in \$(seq 15); do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; done
  ip addr replace $4 peer $5 dev tun0; ip link set tun0 up mtu 116; ip route replace $5 dev tun0 advmss 56 rto_min 25ms 2>/dev/null
  echo \"  $1 up: tun0=\$(ip -o addr show tun0 2>/dev/null | grep -oE 'inet [0-9.]+ peer [0-9.]+')\"" 2>/dev/null; }

echo "=== STAGGERED bring-up: 148 FIRST (steady), then 146 ==="
bringup 10.0.0.148 $TXB $FA 10.66.0.2 10.66.0.1
echo "  ...148 steady, waiting 6s before 146..."; $W 10.0.0.148 'sleep 6; echo -n' 2>/dev/null
bringup 10.0.0.146 $TXA $FB 10.66.0.1 10.66.0.2
echo "=== verify dma_rx flowing (both directions) ==="
$W 10.0.0.148 'sleep 8; grep -oE "dma_tx=[0-9]+ dma_rx_ok=[0-9]+ crc_drop=[0-9]+" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1' 2>/dev/null | sed 's/^/  148: /'
$W 10.0.0.146 'grep -oE "dma_tx=[0-9]+ dma_rx_ok=[0-9]+ crc_drop=[0-9]+" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1' 2>/dev/null | sed 's/^/  146: /'
echo "=== PING 146 -> 148 over the RF link ==="
$W 10.0.0.146 'ping -c 5 -W 2 10.66.0.2 2>&1 | tail -4' 2>/dev/null
echo "=== PING 148 -> 146 ==="
$W 10.0.0.148 'ping -c 5 -W 2 10.66.0.1 2>&1 | tail -4' 2>/dev/null
echo "=== DONE ==="
