#!/bin/bash
# test_quietband.sh -- (A) disambiguate the 2.10 GHz noise at 146 Rx (148 LO leakage vs external),
# and (B) bring the FDD link up on a QUIET pair 2.00 + 1.90 GHz and measure both directions.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; SRC=$D/../host_app_k5
OUT=$D/resid; mkdir -p "$OUT"; F00=2000000000; F190=1900000000; F210=2100000000; FAR=1500000000
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
   busybox devmem 0x9D300000 32 0x1; echo armed" 2>/dev/null; }
rms(){ $W $1 'timeout 8 iio_readdev -u local: -b 16384 -s 80000 axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null > /dev/shm/g.iq; python3 -c "import array,math; a=array.array(\"h\"); d=open(\"/dev/shm/g.iq\",\"rb\").read(); a.frombytes(d[:len(d)//4*4]); n=max(len(a),1); print(int(math.sqrt(sum(x*x for x in a)/n)))" 2>/dev/null' 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; rd(){ echo "$1">$DRA;cat $DRA; }; echo "rssi=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null|cut -d" " -f1) rstcs=$(rd 0x150) cap=$(rd 0x144)"' 2>/dev/null; }

echo "=== (A) 2.10 GHz noise disambiguation @146 Rx ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
arm 10.0.0.146 $F00 $F210 & arm 10.0.0.148 $F210 $F00 & wait
$W 10.0.0.146 'echo rf_disabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null   # 146 Tx off
$W 10.0.0.148 'echo rf_disabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null   # 148 Tx off, LO still @2.10
sleep 2; echo "  148 Tx-LO @2.10 (off): 146 Rx@2.10 noise rms = $(rms 10.0.0.146)"
$W 10.0.0.148 "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode; echo $FAR > \$P/out_altvoltage2_TX1_LO_frequency; echo rf_disabled > \$P/out_voltage0_ensm_mode" 2>/dev/null  # 148 Tx LO -> 1.5G
sleep 2; echo "  148 Tx-LO @1.5G (off): 146 Rx@2.10 noise rms = $(rms 10.0.0.146)   (drop => 148 LO leakage; stays => external)"

echo "=== (B) QUIET-PAIR FDD LINK 2.00 + 1.90 GHz ==="
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null
  $W $ip 'cd /root/host_app_k5 && [ -x qpsk_tun ] || gcc -O2 -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c 2>/dev/null' 2>/dev/null; done
arm 10.0.0.146 $F00 $F190 & arm 10.0.0.148 $F190 $F00 & wait   # 146 Tx@2.00 Rx@1.90 ; 148 Tx@1.90 Rx@2.00
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
$W 10.0.0.146 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 55 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d 55 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  locking (20s)..."; sleep 20
echo "  146 Rx@1.90 : rms=$(rms 10.0.0.146)  snap=$(snap 10.0.0.146)"
echo "  148 Rx@2.00 : rms=$(rms 10.0.0.148)  snap=$(snap 10.0.0.148)"
sleep 40
echo "  --- 146 RX@1.90 (reverse) -B ---"; $W 10.0.0.146 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2
echo "  --- 148 RX@2.00 (forward) -B ---"; $W 10.0.0.148 'cat /dev/shm/ber.log' 2>/dev/null | grep -E 'frames_scored|buckets' | tail -2
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== DONE ==="
