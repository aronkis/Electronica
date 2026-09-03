#!/bin/bash
# gain_pin_test.sh -- live-effect diagnostic: does pinning the ADRV9002 Rx gain
# (manual @ the auto-selected value) on board A remove the bursty ~1.5e-4
# forward residual? Static replay of paired samples decodes ~0 in both float
# and bit-true fixed, so the live errors come from something only live silicon
# sees -- hw-AGC gain steps mid-frame are the prime suspect.
# Usage: gain_pin_test.sh [dur=120]
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD_HZ=2000000000; REV_HZ=1900000000
DUR=${1:-120}

arm(){ # $1 ip $2 txlo $3 rxlo  (verbatim quiet-pair arm)
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
   busybox devmem 0x9D300000 32 0x1
   echo '$1 armed tx=$2 rx=$3'" 2>/dev/null
}

echo "=== gain-pin test: forward 146->148, A Rx gain pinned manual (dur=${DUR}s) ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4; echo "'$ip' quiesced"' 2>/dev/null
done
arm $B_IP $FWD_HZ $REV_HZ
arm $A_IP $REV_HZ $FWD_HZ

# watchdogs for acquisition
for ip in $B_IP $A_IP; do
  $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done; sleep 1

# read A's auto-selected gain, then PIN it (ADRV9002 manual mode token = 'spi')
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
echo "  A auto gain now: $G -- pinning spi(manual)"
GV=$(echo "$G" | grep -oE '^[0-9.]+')
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage0_gain_control_mode; echo $GV > \$P/in_voltage0_hardwaregain; echo pinned: \$(cat \$P/in_voltage0_gain_control_mode) \$(cat \$P/in_voltage0_hardwaregain)" 2>/dev/null

# -B on A only (forward direction is what we're probing; B keeps radiating via its armed Tx)
$W $B_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR > /dev/shm/gainpin_b.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W $A_IP "cd /root/host_app_k5; rm -f /dev/shm/gainpin.log; setsid sh -c './qpsk_tun -B -d $DUR > /dev/shm/gainpin.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  running ${DUR}s ..."; sleep $((DUR + 8))
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "--- FORWARD with PINNED A gain ($GV dB) ---"
$W $A_IP 'grep -E "frames_scored|buckets" /dev/shm/gainpin.log' 2>/dev/null
echo "GAIN_PIN_TEST_DONE"
