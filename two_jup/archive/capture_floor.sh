#!/bin/bash
# capture_floor.sh -- capture the byte-payload FLOORING condition for the RTL-replay
# differential. 146 TX@2.00 -> 148 RX@2.00 (the 3.46e-3 locked-but-flooring direction).
#
# Produces (host-side, in two_jup/floorcap/):
#   floor_148.iq        Tap-A receiver-input I/Q on 148 while 146 radiates the -B reference
#   floor_148b.iq       a 2nd capture (repeatability)
#   floor_148_ber.txt   148's qpsk_tun -B full-packet BER = HARDWARE TRUTH (scored vs known pattern)
#   floor_regs.txt      cap_out/bit_errors/rstcs/cfc/levelLog/rssi snapshots
#   floor_romgate.txt   ROM-on-air: 146 tx_data_source=0 -> does the golden pattern floor on HW? (caveat-3)
# NON-DESTRUCTIVE: arm + read + ONE writedev per board (146 -B, 148 -B). No reflash.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
OUT=$D/floorcap; mkdir -p "$OUT"
TXA=${TXA:-2000005489}   # 146 TX (-> 148 RX@2.00)
FA=${FA:-2000000000}     # 148 RX@2.00
TXB=${TXB:-2099994268}   # 148 TX (-> 146 RX@2.10)  [FDD peer, keeps both locked]
FB=${FB:-2100000000}     # 146 RX@2.10
DUR_TX=${DUR_TX:-240}    # 146 radiates the reference this long (must outlast the captures)
DUR_RX=${DUR_RX:-60}     # 148 -B measures HW BER this long
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; rd(){ echo "$1">$DRA;cat $DRA; }
   P=/sys/bus/iio/devices/iio:device2
   echo "pkts=$(rd 0x104) cap=$(rd 0x144) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null|cut -d" " -f1)"' 2>/dev/null; }

echo "=== FLOOR CAPTURE  146 TX@2.00 -> 148 RX@2.00  (DUR_TX=$DUR_TX DUR_RX=$DUR_RX) $(date -Is) ==="

# 1. quiesce
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4; echo "'$ip' quiesced"' 2>/dev/null
done

# 2. deploy + build host tool (incl qpsk_ber) on both
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R"|tail -1)"; echo "$R"|grep -q BUILD_OK || exit 1
done

# 3. arm FDD both (verbatim from ber_ota.sh: profile, LOs, RF, modem reset, 0x158=1 byte-DMA, 0x114=1 air, tx mux, byte_ctrl_gpio)
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
arm 10.0.0.146 $TXA $FB &
arm 10.0.0.148 $TXB $FA &
wait
echo "  PRE 148: $(snap 10.0.0.148)"

# 4. watchdog both (re-arm out of the armed-before-signal wedge -> lock)
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done

# 5. 146 radiates the reference (long); 148 -B measures HW BER (the truth)
$W 10.0.0.146 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $DUR_TX > /dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $DUR_RX > /dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
echo "  146 -B (${DUR_TX}s TX) + 148 -B (${DUR_RX}s RX) launched; waiting for lock..."
sleep 25; echo "  MID 148: $(snap 10.0.0.148)"
sleep $((DUR_RX - 25 + 6))

# 6. fetch 148 HW BER (the ground truth) + snapshot
$W 10.0.0.148 'cat /dev/shm/ber.log 2>/dev/null' 2>/dev/null | grep -E 'ber:|===|frames_scored|buckets|CLEAN|NOISY|PHASE|MISS|ROTATED|per-offset|byte:|errs:' | tail -40 > "$OUT/floor_148_ber.txt"
echo "  148 HW -B BER captured -> floor_148_ber.txt ; POST-RX 148: $(snap 10.0.0.148)"
{ echo "PRE/MID/POST 148 regs:"; snap 10.0.0.148; } > "$OUT/floor_regs.txt"

# 7. Tap-A receiver-input I/Q on 148 (146 still radiating byte-DMA reference). NO gain/LO change (use armed automatic-gain state).
for tag in 148 148b; do
  $W 10.0.0.148 'rm -f /dev/shm/floor.iq; timeout 15 iio_readdev -u local: -b 16384 -s 400000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/floor.iq 2>/dev/null; echo "cap bytes=$(stat -c %s /dev/shm/floor.iq)"' 2>/dev/null
  scpget root@10.0.0.148:/dev/shm/floor.iq "$OUT/floor_${tag}.iq"
  echo "  pulled floor_${tag}.iq ($(stat -c %s "$OUT/floor_${tag}.iq" 2>/dev/null) bytes)"; sleep 2
done

# 8. ROM-on-air gate (caveat-3): stop 146 -B, set 146 tx_data_source=0 (ROM golden), read 148 cap_out/bit_errors
$W 10.0.0.146 'pkill -x qpsk_tun 2>/dev/null; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo "0x158 0x0">$DRA; sleep 1; echo "146 -> ROM-on-air"' 2>/dev/null
sleep 3
{ echo "=== ROM-on-air gate (146 tx_data_source=0): does the golden pattern floor on HW? ==="
  for i in 1 2 3 4 5; do $W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }; echo "cap=$(rd 0x144) biterr=$(rd 0x108) rstcs=$(rd 0x150)"' 2>/dev/null; sleep 0.6; done
} > "$OUT/floor_romgate.txt"
cat "$OUT/floor_romgate.txt"

# 9. quiesce
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; echo "'$ip' quiesced"' 2>/dev/null; done
echo "=== FLOOR CAPTURE done. artifacts in $OUT/ ==="
ls -la "$OUT"/