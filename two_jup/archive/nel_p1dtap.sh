#!/bin/bash
# nel_p1dtap.sh <ip> -- arm near-end loopback + ROM TX, set the P1D telemetry
# mux (0x10C=4) AFTER the arm's 0x000 reset, and capture the rx2-lpc tap (the
# MODEM-CONSUMED P1D stream where the tick's +32 accept step lives -- NOT the
# capture branch, which is metronomic through the tick). Pull for offline
# +32-accept census. Single unit, cable-free.
set -u
D=$(cd "$(dirname "$0")" && pwd); W="$D/anyssh.sh"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
IP=${1:-}; LO=$(( ${2:-2000} * 1000000 )); SECS=${SECS:-30}
[ -n "$IP" ] || { echo usage; exit 2; }
OUT=$D/hunt/$(date +%Y%m%d_%H%M%S)_nelp1d_$(echo $IP|tr . _); mkdir -p $OUT

$W $IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   pkill -9 -f '[l]ock_watchdog' 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.3
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   echo calibrated > \$P/out_voltage0_ensm_mode; echo calibrated > \$P/in_voltage0_ensm_mode
   echo 1 > \$DB/rx0_near_end_loopback 2>/dev/null
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $LO > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $LO > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1
   echo '0x10C 0x4' > \$DRA; echo 0x10C > \$DRA; echo \"mux=\$(cat \$DRA)\"" 2>/dev/null | grep -v cwd
sleep 4
echo "-- capture rx2-lpc P1D tap ${SECS}s (voltage0_i voltage0_q) --"
$W $IP "timeout $SECS iio_readdev -u local: -b 65536 axi-adrv9002-rx2-lpc voltage0_i voltage0_q > /dev/shm/nelp1d.iq 2>/dev/null; ls -la /dev/shm/nelp1d.iq" 2>/dev/null | grep -v cwd
scpput root@$IP:/dev/shm/nelp1d.iq $OUT/nelp1d.iq 2>/dev/null
ls -la $OUT/nelp1d.iq 2>/dev/null
$W $IP 'DB=/sys/kernel/debug/iio/iio:device2; echo 0 > $DB/rx0_near_end_loopback 2>/dev/null; echo cleared' 2>/dev/null | grep -v cwd
echo "NELP1D_DONE $OUT"
