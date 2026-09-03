#!/bin/bash
# CONCLUSIVE test that 146's co-located TX is the interferer to 146's own RX.
# Steady source: 148 byte-Tx @2.0G. Receiver: 146 RX@2.0G (byte daemon, counts
# rx_ok). Independent variable: 146's OWN TX @2.1G -- swept OFF then ON across a
# gain (attenuation) ladder. If 146 RX degrades monotonically with 146 TX power
# -> the co-located TX is the interferer (dose-response). Also verifies ensm
# up/down transitions (calibrated<->rf_enabled) behave + reports rx1 level/AGC.
set -u
FSRC=2000000000     # 148->146 (146 receives here)
FTX=2100000000      # 146's own TX carrier (the interferer under test)
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
reload_clean(){ $W $1 'pkill -x qpsk_tun 2>/dev/null; P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
  cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
  echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
  for g in 4 5 6 7; do echo 1 > $DB/agpio${g}_direction; echo 1 > $DB/agpio${g}_value; done; echo tx_a > $P/out_voltage0_port_select' 2>/dev/null; }

echo "=== SETUP: 148 = steady source (byte-Tx @$FSRC), 146 = receiver @$FSRC, 146 own-TX @$FTX ==="
reload_clean 10.0.0.146; reload_clean 10.0.0.148
# 148 steady source
$W 10.0.0.148 "P=/sys/bus/iio/devices/iio:device2
 echo $FSRC > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 cd /root/host_app_k5;pkill -x qpsk_tun 2>/dev/null;sleep 0.3;(setsid nohup ./qpsk_tun -F -e -d 300 >/dev/shm/src.log 2>&1 &);sleep 2;echo \"148 source up: daemon=\$(pgrep -c qpsk_tun)\"" 2>/dev/null

# arm 146 as receiver @FSRC (RX carrier), own TX @FTX; returns after arming (TX ensm set per condition)
arm146(){ # $1 = tx_ensm (calibrated|rf_enabled)  $2 = tx_hwgain
 $W 10.0.0.146 "P=/sys/bus/iio/devices/iio:device2
  echo $FTX > \$P/out_altvoltage2_TX1_LO_frequency; echo $2 > \$P/out_voltage0_hardwaregain; echo $1 > \$P/out_voltage0_ensm_mode
  echo $FSRC > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA" 2>/dev/null; }

# measure 146 RX quality for 15s + report ensm/level
meas146(){ # label
 $W 10.0.0.146 'P=/sys/bus/iio/devices/iio:device2
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
  txensm=$(cat $P/out_voltage0_ensm_mode); txg=$(cat $P/out_voltage0_hardwaregain); rxensm=$(cat $P/in_voltage0_ensm_mode)
  r0=$(rd 0x150)
  cd /root/host_app_k5;pkill -x qpsk_tun 2>/dev/null;sleep 0.3;./qpsk_tun -F -e -d 15 2>&1 | grep ECHO: | tail -1 | sed "s/^/    /"
  r1=$(rd 0x150); f=$(rd 0x15C)
  echo "    tx_ensm=$txensm tx_gain=$txg rx_ensm=$rxensm | rstcs $r0->$r1 rssi_rx1=$(cat $P/in_voltage0_rssi) levelLog=$(( (0x${f#0x} >> 24) & 255 ))"' 2>/dev/null; }

echo ""
echo "=== CONDITION 1: 146 own-TX OFF (ensm calibrated) -- BASELINE (no co-located TX) ==="
arm146 calibrated 0; meas146
echo ""
echo "=== CONDITION 2..6: 146 own-TX ON (rf_enabled), gain sweep (dose-response) ==="
for g in -40 -30 -20 -10 0; do
  echo "--- 146 own-TX ON, hwgain=${g} dB ---"
  arm146 rf_enabled $g; meas146
done
echo ""
echo "=== CONDITION 7: power 146 TX back DOWN (ensm calibrated) -- verify RX RECOVERS (up/down behavior) ==="
arm146 calibrated 0; meas146
$W 10.0.0.148 'pkill -x qpsk_tun 2>/dev/null; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
$W 10.0.0.146 'pkill -x qpsk_tun 2>/dev/null; echo 0 > /sys/bus/iio/devices/iio:device2/out_voltage0_hardwaregain; echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
echo "=== DONE (boards idled) ==="
