#!/bin/bash
# near_end_loopback.sh <ip> [lo_mhz] -- SINGLE-UNIT internal RF loopback via the
# ADRV9002 near-end loopback (NO cable). The unit transmits its own modem frames
# and receives them through its OWN analog/ADC/BBDC path -- no second board, no
# over-air. Detects whether the BBDC tick is reproducible on one unit standalone.
# Arm = rf_loopback.sh arm_ber VERBATIM + rx0_near_end_loopback enable in the
# CALIBRATED phase + Tx LO == Rx LO. -S seq mode gives per-event timing so the
# episode cadence (~1.5 s if it is the tick) is measurable.
set -u
D=$(cd "$(dirname "$0")" && pwd); W="$D/anyssh.sh"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
IP=${1:-}; LO_MHZ=${2:-2000}; DUR=${DUR:-90}
[ -n "$IP" ] || { echo "usage: near_end_loopback.sh <ip> [lo_mhz]"; exit 2; }
LO=$(( LO_MHZ * 1000000 ))
TAG=$(echo $IP | tr . _)
OUT=$D/hunt/$(date +%Y%m%d_%H%M%S)_nel_$TAG; mkdir -p $OUT

# arm_nel -- rf_loopback arm_ber VERBATIM + near_end_loopback enable (calibrated phase)
arm_nel(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   echo calibrated > \$P/out_voltage0_ensm_mode; echo calibrated > \$P/in_voltage0_ensm_mode
   echo 1 > \$DB/rx0_near_end_loopback 2>/dev/null; echo \"NEL_SET rc=\$?\"
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo armed" 2>/dev/null; }

echo "=== NEAR-END LOOPBACK (single unit) -- $IP  Tx=Rx=${LO_MHZ}MHz  dur=${DUR}s ==="
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.3; echo cleared' 2>/dev/null
echo "-- arm (near_end_loopback + Tx LO==Rx LO==$LO) --"; arm_nel $IP $LO $LO
$W $IP 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
sleep 12
echo "-- lock check (0x104 packets_out over 5s) --"
L1=$($W $IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > $DRA; cat $DRA' 2>/dev/null | grep -v cwd)
sleep 5
L2=$($W $IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo 0x104 > $DRA; cat $DRA' 2>/dev/null | grep -v cwd)
echo "  packets_out: $L1 -> $L2  (advancing => RX locked to its own looped-back TX)"
$W $IP 'pkill -f "[l]ock_watchdog"' 2>/dev/null
echo "-- qpsk_tun -S -M 32 -d $DUR (seq events -> episode cadence) --"
$W $IP "cd /root/host_app_k5; rm -f /dev/shm/seq_events.log /dev/shm/acc.log; setsid sh -c './qpsk_tun -S -M 32 -d $DUR >/dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
sleep $((DUR+12))
echo "=== RESULT ($IP) ==="
$W $IP 'grep -E "SEQRX|frames_scored|BER=" /dev/shm/acc.log | tail -3' 2>/dev/null | grep -v cwd
scpput root@$IP:/dev/shm/seq_events.log "$OUT/nel_events.log" 2>/dev/null
scpput root@$IP:/dev/shm/acc.log "$OUT/nel_acc.log" 2>/dev/null
echo "  events -> $OUT/nel_events.log"
$W $IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; DB=/sys/kernel/debug/iio/iio:device2; echo 0 > $DB/rx0_near_end_loopback 2>/dev/null; echo cleared' 2>/dev/null
echo "NEL_DONE $OUT"
