#!/bin/bash
# capture_rom.sh -- ROM-on-air capture for the CLEAN RTL-vs-HW differential.
# 146 radiates the GOLDEN ROM message (tx_data_source=0, in-fabric -> NO iio_writedev),
# 148 RX@2.00. Captures a LONG Tap-A window (2M samples ~220 frames) of the golden
# message + the HW golden lock metric (cap_out golden-fraction + bit_errors rate).
# Offline: obj_byte_iq scores GOLDEN directly (validated metric, no byte-align ambiguity),
# soak_decode gives the float-reference leg, blind_evm the constellation.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
OUT=$D/floorcap; mkdir -p "$OUT"
TXA=${TXA:-2000005489}; FA=${FA:-2000000000}; TXB=${TXB:-2099994268}; FB=${FB:-2100000000}
NSAMP=${NSAMP:-2000000}
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
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed tx=$2 rx=$3'" 2>/dev/null; }

echo "=== ROM-ON-AIR CAPTURE  146 ROM-TX@2.00 -> 148 RX@2.00  (NSAMP=$NSAMP) $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
arm 10.0.0.146 $TXA $FB &
arm 10.0.0.148 $TXB $FA &
wait
# 146 -> ROM source (tx_data_source=0); 148 stays byte-source (irrelevant, it's RX)
$W 10.0.0.146 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo "0x158 0x0">$DRA; echo "146 -> ROM"' 2>/dev/null
# watchdog on 148 only (re-arm to lock onto 146's ROM); NOT on 146 (would reset ROM mode)
$W 10.0.0.148 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
echo "  waiting for 148 to lock onto ROM..."; sleep 20
# HW golden metric: cap_out golden-fraction over 20 reads + bit_errors rate over ~5s
$W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }
   g=0; for i in $(seq 20); do c=$(rd 0x144); [ "$c" = "0x4922282" ] && g=$((g+1)); sleep 0.2; done
   b0=$(rd 0x108); p0=$(rd 0x104); sleep 5; b1=$(rd 0x108); p1=$(rd 0x104)
   echo "HW-GOLDEN: capGolden=$g/20 biterr_delta=$(( $b1 - $b0 )) pkts_delta=$(( $p1 - $p0 )) rstcs=$(rd 0x150) cfc=$(rd 0x154) rssi=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi|cut -d" " -f1)"' 2>/dev/null | tee "$OUT/rom_hw.txt"
# long Tap-A capture of the golden message
$W 10.0.0.148 'rm -f /dev/shm/rom.iq; timeout 30 iio_readdev -u local: -b 16384 -s '"$NSAMP"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/rom.iq 2>/dev/null; echo "cap bytes=$(stat -c %s /dev/shm/rom.iq)"' 2>/dev/null
scpget root@10.0.0.148:/dev/shm/rom.iq "$OUT/rom_148.iq"
echo "  pulled rom_148.iq ($(stat -c %s "$OUT/rom_148.iq" 2>/dev/null) bytes)"
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; echo "'$ip' quiesced"' 2>/dev/null; done
echo "=== ROM CAPTURE done ==="; ls -la "$OUT"/rom_*