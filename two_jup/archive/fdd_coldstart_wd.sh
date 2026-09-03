#!/bin/bash
# fdd_coldstart_wd.sh -- bidirectional FDD cold start with the lock_watchdog on BOTH
# boards (NO manual stagger). Each board arms full-duplex + runs a -e echo daemon +
# runs lock_watchdog.sh; the watchdogs re-arm until both lock on the peer. Proves the
# watchdog replaces the manual staggered startup and handles the 2-board coupling.
# 146 TX@2.00->148 RX@2.00 ; 148 TX@2.10->146 RX@2.10.
set -u
TXA=2000005111  # 146 TX (-> 148 RX@2.00)
TXB=2099994621  # 148 TX (-> 146 RX@2.10)
FA=2000000000   # 148 RX
FB=2100000000   # 146 RX
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh

# KILL (separate call; '[l]ock_watchdog' regex + no literal 'lock_watchdog.sh' -> no self-kill)
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; echo "'$ip' cleared"' 2>/dev/null
done

# COLDSTART one board: reload + FD arm + daemon + watchdog (all detached). No pkill here.
coldstart(){ # $1 ip $2 txlo $3 rxlo
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
   cd /root/host_app_k5; setsid ./qpsk_tun -F -e -d 600 </dev/null >/dev/shm/src.log 2>&1 &
   rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
   echo '$1 cold-started (daemon+watchdog)'" 2>/dev/null
}

echo "=== SIMULTANEOUS cold start (both boards, no stagger) ==="
coldstart 10.0.0.146 $TXA $FB &
coldstart 10.0.0.148 $TXB $FA &
wait
echo "=== waiting ~50s for both watchdogs to converge ==="
sleep 50
for ip in 10.0.0.146 10.0.0.148; do
  echo "--- $ip watchdog (last 4) ---"
  $W $ip 'tail -4 /dev/shm/watchdog.log 2>/dev/null; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   p0=$(rd 0x104);r0=$(rd 0x150);sleep 4;p1=$(rd 0x104);r1=$(rd 0x150)
   echo "  dpkts/4s=$(( $p1 - $p0 )) drstcs/4s=$(( $r1 - $r0 ))  (dpkts>0+drstcs low = LOCKED)"' 2>/dev/null
done
