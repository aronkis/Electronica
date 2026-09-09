#!/bin/bash
# nel_rawcap.sh <ip> -- arm near-end loopback with ROM TX (tx_data_source=0, no
# host feed needed), capture the raw receiver-input IQ (rx-lpc voltage0, the
# safe Tap-A path), and pull it. Offline displacement tracking then looks for
# the +256-sample tick insertion (every ~1.5 s if the unit ticks). Single unit,
# cable-free, no second board, no over-air.
set -u
D=$(cd "$(dirname "$0")" && pwd); W="$D/anyssh.sh"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
IP=${1:-}; LO=$(( ${2:-2000} * 1000000 )); SECS=${SECS:-30}
[ -n "$IP" ] || { echo usage; exit 2; }
OUT=$D/hunt/$(date +%Y%m%d_%H%M%S)_nelraw_$(echo $IP|tr . _); mkdir -p $OUT

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
   busybox devmem 0x9D300000 32 0x1; echo armed_rom_tx" 2>/dev/null | grep -v cwd
sleep 3
echo "-- capture rx-lpc voltage0 raw IQ ${SECS}s (receiver input) --"
$W $IP "timeout $SECS iio_readdev -u local: -b 65536 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/nelraw.iq 2>/dev/null; ls -la /dev/shm/nelraw.iq" 2>/dev/null | grep -v cwd
scpput root@$IP:/dev/shm/nelraw.iq $OUT/nelraw.iq 2>/dev/null
ls -la $OUT/nelraw.iq 2>/dev/null
$W $IP 'DB=/sys/kernel/debug/iio/iio:device2; echo 0 > $DB/rx0_near_end_loopback 2>/dev/null; echo cleared' 2>/dev/null | grep -v cwd
echo "NELRAW_DONE $OUT"
