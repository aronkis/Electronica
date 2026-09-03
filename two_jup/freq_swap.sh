#!/bin/bash
# freq_swap.sh -- localize the ~16 dB Rx-amplitude asymmetry. Measures ADC rms on BOTH
# boards in the ORIGINAL freq assignment and the SWAPPED one. 4 data points tell us
# whether the weak Rx follows the 2.10 GHz frequency (RF path), the board (146 Rx),
# or the Tx. Both boards radiate -B so a modulated signal is present each direction.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; OUT=$D/resid; mkdir -p "$OUT"
F00=2000000000; F10=2100000000
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
   busybox devmem 0x9D300000 32 0x1; echo '$1 Tx=$2 Rx=$3'" 2>/dev/null; }
rms(){ $W $1 'timeout 8 iio_readdev -u local: -b 16384 -s 100000 axi-adrv9002-rx-lpc voltage0_i voltage0_q 2>/dev/null > /dev/shm/g.iq; python3 -c "import array,math; a=array.array(\"h\"); d=open(\"/dev/shm/g.iq\",\"rb\").read(); a.frombytes(d[:len(d)//4*4]); n=max(len(a),1); print(int(math.sqrt(sum(x*x for x in a)/n)))" 2>/dev/null; rss=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null|cut -d" " -f1); echo -n " rssi=$rss"' 2>/dev/null; }
radiate(){ $W $1 "cd /root/host_app_k5; pkill -x qpsk_tun 2>/dev/null; setsid sh -c './qpsk_tun -B -d 90 >/dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null; }

runcfg(){ # $1 label  $2 tx146 $3 rx146  $4 tx148 $5 rx148
  echo "=== CONFIG $1 : 146(Tx$2 Rx$3)  148(Tx$4 Rx$5) ==="
  for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null; done
  arm 10.0.0.146 $2 $3 & arm 10.0.0.148 $4 $5 & wait
  for ip in 10.0.0.146 10.0.0.148; do $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; done
  radiate 10.0.0.146; radiate 10.0.0.148
  echo "  locking 20s..."; sleep 20
  echo "  146 Rx@$3 : rms=$(rms 10.0.0.146)"
  echo "  148 Rx@$5 : rms=$(rms 10.0.0.148)"
}
echo "=== FREQ-SWAP LOCALIZATION $(date -Is) ==="
runcfg ORIG  $F00 $F10  $F10 $F00   | tee "$OUT/freqswap.txt"       # 146 Rx@2.10 (weak baseline), 148 Rx@2.00
runcfg SWAP  $F10 $F00  $F00 $F10   | tee -a "$OUT/freqswap.txt"    # 146 Rx@2.00, 148 Rx@2.10
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "=== DONE. Interpretation: weak Rx follows 2.10GHz=>RF path ; follows 146=>146 Rx board ; symmetric-after-swap=>Tx@2.10 ==="