#!/bin/bash
# live_check.sh -- read-only live confirmation of the CFO-step reset-storm mechanism.
# Arms the flooring link (146 TX@2.00 -> 148 RX@2.00), runs -B, and RAPID-POLLS the
# carrier-sync reset counter (0x150 rstcs) + coarse-CFO estimate (0x154 cfc) on 148 to
# measure the LIVE step-to-step cfc jitter (vs the calibrated 697 Hz = 3277-En21 threshold)
# and the live reset rate. Calibration: ~4.70 En21/Hz (subagent), so 3277 En21 ~ 697 Hz.
# NON-DESTRUCTIVE: arm + read only. No reflash, no writes beyond arm.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
OUT=$D/livechk; mkdir -p "$OUT"
TXA=${TXA:-2000005489}; FA=${FA:-2000000000}; TXB=${TXB:-2099994268}; FB=${FB:-2100000000}
POLL=${POLL:-50}   # seconds of rapid polling
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

echo "=== LIVE CHECK (rstcs+cfc rapid poll) $(date -Is) ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ 2>/dev/null
  $W $ip 'cd /root/host_app_k5 && gcc -O2 -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c 2>/dev/null && echo built' 2>/dev/null
done
arm 10.0.0.146 $TXA $FB & arm 10.0.0.148 $TXB $FA & wait
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
# radiate + measure (flooring), then rapid-poll while it runs
$W 10.0.0.146 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 80 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 62 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  polling across acquisition (3s in)..."; sleep 3
# RAPID POLL on 148: tight loop reading 0x150 (rstcs) + 0x154 (cfc) with a wall clock
$W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo "$1">$DRA; cat $DRA; }
   end=$(( $(date +%s) + '"$POLL"' ))
   : > /dev/shm/livepoll.log
   while [ $(date +%s) -lt $end ]; do t=$(date +%s.%N); r=$(rd 0x150); c=$(rd 0x154); echo "$t $r $c"; done >> /dev/shm/livepoll.log
   echo "poll lines=$(wc -l < /dev/shm/livepoll.log)"' 2>/dev/null
scpget root@10.0.0.148:/dev/shm/livepoll.log "$OUT/livepoll.log"
echo "  pulled livepoll.log ($(wc -l < "$OUT/livepoll.log" 2>/dev/null) lines)"
# also grab the -B buckets + a reg snapshot for context (BOTH directions)
echo "--- 148 RX (forward 146->148) ---" | tee "$OUT/livechk_ber.txt"
$W 10.0.0.148 'cat /dev/shm/ber.log 2>/dev/null' 2>/dev/null | grep -E 'ber:|frames_scored|buckets' | tail -3 | tee -a "$OUT/livechk_ber.txt"
echo "--- 146 RX (reverse 148->146) ---" | tee -a "$OUT/livechk_ber.txt"
$W 10.0.0.146 'cat /dev/shm/ber.log 2>/dev/null' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2 | tee -a "$OUT/livechk_ber.txt"
$W 10.0.0.146 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; rd(){ echo "$1">$DRA;cat $DRA; }; echo "146 rstcs=$(rd 0x150) cfc=$(rd 0x154)"' 2>/dev/null | tee -a "$OUT/livechk_ber.txt"
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== LIVE CHECK done -> $OUT/ ==="
