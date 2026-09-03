#!/bin/bash
# characterize_residual.sh -- quantify the post-rxfix residual BER per direction and
# localize why 146's Rx is the weak side. Arms FDD both, runs -B both directions
# simultaneously, snaps per-board Rx metrics (rssi/rxgain/cfc/level/rstcs/biterr), and
# captures Tap-A (Rx INPUT) on BOTH boards for an EVM comparison (blind_evm). Read-only
# beyond arm; no reflash.  148 RX = 146->148 @2.00 ; 146 RX = 148->146 @2.10.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
OUT=$D/resid; mkdir -p "$OUT"
TXA=2000005489; FA=2000000000; TXB=2099994268; FB=2100000000
DUR=${DUR:-55}; NSAMP=${NSAMP:-400000}
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; rd(){ echo "$1">$DRA;cat $DRA; }
   P=/sys/bus/iio/devices/iio:device2
   echo "rssi=$(cat $P/in_voltage0_rssi 2>/dev/null|cut -d" " -f1) rxgain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null|cut -d" " -f1) cfc=$(rd 0x154) lvl=$(rd 0x15C) rstcs=$(rd 0x150) biterr=$(rd 0x108) cap=$(rd 0x144) pkts=$(rd 0x104)"' 2>/dev/null; }
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

echo "=== RESIDUAL CHARACTERIZATION $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ 2>/dev/null
  $W $ip 'cd /root/host_app_k5 && gcc -O2 -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c 2>/dev/null && echo built' 2>/dev/null
done
arm 10.0.0.146 $TXA $FB & arm 10.0.0.148 $TXB $FA & wait
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
# -B both directions
$W 10.0.0.146 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $((DUR+20)) >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $((DUR+20)) >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  locking (25s)..."; sleep 25
{ echo "--- snaps @ t~25s ---"; echo "146(RX@2.10 from 148): $(snap 10.0.0.146)"; echo "148(RX@2.00 from 146): $(snap 10.0.0.148)"; } | tee "$OUT/resid_snaps.txt"
sleep 8
# Tap-A Rx-input capture on BOTH boards
for ip in 146 148; do
  $W 10.0.0.$ip 'rm -f /dev/shm/rx.iq; timeout 15 iio_readdev -u local: -b 16384 -s '"$NSAMP"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/rx.iq 2>/dev/null; echo "cap=$(stat -c %s /dev/shm/rx.iq)"' 2>/dev/null
  scpget root@10.0.0.$ip:/dev/shm/rx.iq "$OUT/rx_${ip}.iq"
  echo "  pulled rx_${ip}.iq ($(stat -c %s "$OUT/rx_${ip}.iq" 2>/dev/null) B)"
done
sleep $((DUR-40))
{ echo "--- snaps @ end ---"; echo "146: $(snap 10.0.0.146)"; echo "148: $(snap 10.0.0.148)"; } | tee -a "$OUT/resid_snaps.txt"
echo "=== 146 RX (reverse 148->146) -B ==="; $W 10.0.0.146 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2 | tee "$OUT/resid_146_ber.txt"
echo "=== 148 RX (forward 146->148) -B ==="; $W 10.0.0.148 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2 | tee "$OUT/resid_148_ber.txt"
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== DONE -> $OUT/ ==="
