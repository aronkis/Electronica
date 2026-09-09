#!/bin/bash
# capture_gold.sh -- LOCKED golden-on-air capture on the CURRENT image, to test
# harness-vs-deployed match via the validated golden scorer. Establishes lock with
# the proven dual-watchdog + both--B sequence FIRST, THEN switches 146 to ROM
# (keeping 148's watchdog) so the golden message is captured while locked.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
OUT=$D/floorcap; mkdir -p "$OUT"
TXA=${TXA:-2000005489}; FA=${FA:-2000000000}; TXB=${TXB:-2099994268}; FB=${FB:-2100000000}
NSAMP=${NSAMP:-2000000}
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
arm(){ $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed'" 2>/dev/null; }

echo "=== GOLDEN-ON-AIR LOCKED CAPTURE (current image) $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
# build host tool on both (needed for the establish-lock -B)
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ 2>/dev/null
  $W $ip 'cd /root/host_app_k5 && gcc -O2 -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c 2>/dev/null && echo built' 2>/dev/null
done
arm 10.0.0.146 $TXA $FB & arm 10.0.0.148 $TXB $FA & wait
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
# establish lock with both -B (proven to reach 71% clean)
$W 10.0.0.146 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 120 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 30 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  establishing lock (30s)..."; sleep 32
# switch 146 to ROM golden (stop its -B + watchdog so ROM mode sticks); keep 148 watchdog
$W 10.0.0.146 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo "0x158 0x0">$DRA; echo "146 -> ROM"' 2>/dev/null
sleep 5
# HW golden metric on 148
$W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   g=0; for i in $(seq 20); do c=$(rd 0x144); [ "$c" = "0x4922282" ] && g=$((g+1)); sleep 0.2; done
   echo "HW-GOLDEN capGolden=$g/20 rstcs=$(rd 0x150) cfc=$(rd 0x154) rssi=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi|cut -d" " -f1)"' 2>/dev/null | tee "$OUT/gold_hw.txt"
# capture golden Tap-A (long)
$W 10.0.0.148 'rm -f /dev/shm/gold.iq; timeout 30 iio_readdev -u local: -b 16384 -s '"$NSAMP"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/gold.iq 2>/dev/null; echo "cap bytes=$(stat -c %s /dev/shm/gold.iq)"' 2>/dev/null
scpget root@10.0.0.148:/dev/shm/gold.iq "$OUT/gold_148.iq"
echo "  pulled gold_148.iq ($(stat -c %s "$OUT/gold_148.iq" 2>/dev/null) bytes)"
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; echo "'$ip' quiesced"' 2>/dev/null; done
echo "=== GOLDEN CAPTURE done ==="; ls -la "$OUT"/gold_*