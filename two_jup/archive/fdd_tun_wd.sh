#!/bin/bash
# fdd_tun_wd.sh -- bidirectional FDD tun0 link, cold start, watchdog on BOTH boards
# (no manual stagger). Each board: FD arm + qpsk_tun -F -i tun0 + lock_watchdog +
# tun0 addressing. Watchdogs re-arm until both lock -> tun0 IP traffic flows.
# 146=10.66.0.1 <-> 148=10.66.0.2, MTU 116. Then PING both ways over the RF link.
set -u
TXA=2000005489; FB=2100000000    # 146 TX@2.00 -> 148 RX@2.00 ; 146 RX@2.10
TXB=2099994268; FA=2000000000    # 148 TX@2.10 -> 146 RX@2.10 ; 148 RX@2.00
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh

for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; ip addr flush dev tun0 2>/dev/null; sleep 0.3; echo "'$ip' cleared"' 2>/dev/null
done

coldstart(){ # $1 ip $2 txlo $3 rxlo $4 tunaddr $5 peer
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   cd /root/host_app_k5; setsid ./qpsk_tun -F -i tun0 -s 30 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
   rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
   n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
   ip addr replace $4 peer $5 dev tun0; ip link set tun0 up mtu 116; ip route replace $5 dev tun0 advmss 56 rto_min 25ms 2>/dev/null
   echo '$1 cold-started, tun0 set'" 2>/dev/null
}

echo "=== SIMULTANEOUS cold start (both boards, no stagger) ==="
coldstart 10.0.0.146 $TXA $FB 10.66.0.1 10.66.0.2 &
coldstart 10.0.0.148 $TXB $FA 10.66.0.2 10.66.0.1 &
wait
echo "=== waiting ~55s for watchdogs to lock + tun0 traffic ==="
sleep 55
for ip in 10.0.0.146 10.0.0.148; do
  echo "--- $ip ---"
  $W $ip 'echo "  wd: $(tail -1 /dev/shm/watchdog.log 2>/dev/null)"; echo "  daemon: $(grep -oE "dma_rx_ok=[0-9]+ crc_drop=[0-9]+" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1)"; echo "  tun0: $(ip -o addr show tun0 2>/dev/null | grep -oE "inet [0-9.]+")"' 2>/dev/null
done
echo "=== PING 146 -> 148 over the RF link ==="
$W 10.0.0.146 'ping -c 6 -W 3 10.66.0.2 2>&1 | tail -3' 2>/dev/null
echo "=== PING 148 -> 146 over the RF link ==="
$W 10.0.0.148 'ping -c 6 -W 3 10.66.0.1 2>&1 | tail -3' 2>/dev/null
echo "=== DONE ==="
