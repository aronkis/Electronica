#!/bin/bash
# =============================================================================
# rf_loopback.sh <ip> [lo_mhz]  -- SINGLE-RADIO RF loopback BER on ONE Jupiter.
#
# Exercises the REAL RF chain (DAC -> PA -> [external Tx->Rx cable/attenuator] ->
# LNA -> ADC) on one board, scoring its own -B reference. This is the "one radio"
# real-data test -- distinct from the DIGITAL internal loopback (rx_input_select=0,
# no RF) in test.sh loopback, and from the two-board FDD link in link_test.sh.
#
#   *** PHYSICAL PREREQUISITE ***  the board's Tx1 output must be cabled to its
#   own Rx1 input through an ATTENUATOR (~30-40 dB; Tx0dBFS into a bare LNA can
#   saturate/damage it). Tx and Rx share ONE LO here (lo_mhz, default 2000).
#
# NOTE: ready-to-run but NOT hardware-validated in this kit (the loopback cable
# was not rigged when this was authored). The arm register sequence is copied
# VERBATIM from link_test.sh arm_ber() -- do NOT paraphrase the pokes (the radio
# wedges if the sequence is wrong; Jupiter has no remote power).
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W="$D/anyssh.sh"
IP=${1:-}
LO_MHZ=${2:-2000}
DUR=${DUR:-60}
[ -n "$IP" ] || { echo "usage: rf_loopback.sh <board-ip> [lo_mhz]   (default lo=2000)"; exit 2; }
LO=$(( LO_MHZ * 1000000 ))

# arm_ber() -- VERBATIM from link_test.sh (single board; Tx LO == Rx LO == $LO).
arm_ber(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo armed" 2>/dev/null; }

echo "=== RF LOOPBACK (single radio) -- $IP  Tx=Rx=${LO_MHZ}MHz  dur=${DUR}s ==="
echo "!! ensure Tx1 -> Rx1 is cabled through an attenuator (~30-40 dB) on $IP !!"
echo "-- quiesce --"
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; echo cleared' 2>/dev/null
echo "-- arm (Tx LO == Rx LO == $LO) --"; arm_ber $IP $LO $LO
echo "-- launch watchdog --"
$W $IP 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
echo "-- qpsk_tun -B -d $DUR (scratch -> /dev/shm/ber.log) --"
$W $IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $DUR >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
sleep_n=$(( DUR + 10 )); echo "-- running ~${sleep_n}s --"; sleep "$sleep_n"
echo "=== RF LOOPBACK RESULT ($IP) ==="
$W $IP 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'full-packet report|frames_scored=|buckets:|^ber:' | tail -4
echo "-- quiesce --"
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; echo cleared' 2>/dev/null
echo "=== RF LOOPBACK DONE ==="
