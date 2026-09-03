#!/bin/bash
# capture_esrc.sh -- Phase-2 error-source hardware run. Enhances capture_floor.sh to
# settle the three still-open questions with ONE careful run:
#   Q1 real per-offset map : scp the RAW /dev/shm/ber.log (capture_floor's grep dropped the map rows)
#   Q2 frame accounting     : PRE + POST snaps of 0x104/0x108/0x144/0x150/0x154 + exact -B window secs
#                             -> expected(window/frameperiod) vs d packets_out(0x104) vs frames_scored
#   AltC representativeness : a LONG 2M-sample Tap-A capture (~220 frames ~1s) so an ideal decode over
#                             a representative window can't be dismissed as a lucky 43-frame stretch
#   Q3b (opt, ACQ=1)        : acquisition-anchored capture -- start iio_readdev, THEN bring far TX up,
#                             so the RTL replay sees the same lock transient (fixes cold-start quadrant)
# NON-DESTRUCTIVE: arm + read + ONE writedev per board. No reflash. Tap-A only (separate ADI DMA; never S2MM>512K).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$(dirname "$0")/.." && pwd)/host_app_k5
OUT=$D/esrc; mkdir -p "$OUT"
TXA=${TXA:-2000005489}; FA=${FA:-2000000000}; TXB=${TXB:-2099994268}; FB=${FB:-2100000000}
DUR_TX=${DUR_TX:-260}     # 146 radiates the reference this long (must outlast all captures)
DUR_RX=${DUR_RX:-60}      # 148 -B measures HW BER this long (the truth window)
NSAMP=${NSAMP:-2000000}   # long Tap-A capture (proven safe via capture_gold)
ACQ=${ACQ:-0}             # 1 -> also take an acquisition-anchored capture for the RTL Q3b leg
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
snap(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null; rd(){ echo "$1">$DRA;cat $DRA; }
   P=/sys/bus/iio/devices/iio:device2
   echo "pkts=$(rd 0x104) cap=$(rd 0x144) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) fx=$(rd 0x15C) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null|cut -d" " -f1)"' 2>/dev/null; }

echo "=== ESRC CAPTURE 146 TX@2.00 -> 148 RX@2.00 (DUR_TX=$DUR_TX DUR_RX=$DUR_RX NSAMP=$NSAMP ACQ=$ACQ) $(date -Is) ==="

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
# 3. arm FDD both (verbatim from capture_floor.sh)
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
PRE148=$(snap 10.0.0.148); echo "  PRE 148: $PRE148"
# 4. watchdog both
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
# 5. 146 radiates the reference (long); 148 -B measures HW BER (the truth). Record the wall time.
T0=$(date +%s)
$W 10.0.0.146 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $DUR_TX > /dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
$W 10.0.0.148 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c './qpsk_tun -B -d $DUR_RX > /dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
# snapshot 148 registers right AFTER 148 -B starts (BER-window PRE) so d(0x104) brackets exactly the -B window
sleep 3; BWPRE148=$(snap 10.0.0.148)
echo "  146 -B (${DUR_TX}s) + 148 -B (${DUR_RX}s) launched; BER-window PRE 148: $BWPRE148"
sleep $((DUR_RX - 3 + 6))
# 6. 148 -B has ended -> BER-window POST snap + fetch FULL raw report (keeps the per-offset map)
BWPOST148=$(snap 10.0.0.148); T1=$(date +%s)
scpget root@10.0.0.148:/dev/shm/ber.log "$OUT/esrc_148_ber_full.txt"
echo "  full -B report -> esrc_148_ber_full.txt ; BER-window POST 148: $BWPOST148"
{ echo "=== ESRC frame accounting (148, direction 146->148) ==="
  echo "arm-PRE          : $PRE148"
  echo "BER-window PRE   : $BWPRE148"
  echo "BER-window POST  : $BWPOST148"
  echo "BER-window wall  : $((T1-T0)) s (nominal -B -d $DUR_RX)"
  echo "frame period     : 1133 sym / 240e3 = 4.721 ms -> ~211.8 frames/s"
  echo "note: expected-frames = window_s * 211.8 ; d_packets_out = 0x104(POST)-0x104(PRE) ; frames_scored from report"
} > "$OUT/esrc_frameacct.txt"
cat "$OUT/esrc_frameacct.txt"
# 7. LONG Tap-A receiver-input I/Q on 148 (146 still radiating). Representative window for the ideal decode.
$W 10.0.0.148 'rm -f /dev/shm/esrc.iq; timeout 40 iio_readdev -u local: -b 32768 -s '"$NSAMP"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/esrc.iq 2>/dev/null; echo "cap bytes=$(stat -c %s /dev/shm/esrc.iq)"' 2>/dev/null
scpget root@10.0.0.148:/dev/shm/esrc.iq "$OUT/esrc_148_long.iq"
echo "  pulled esrc_148_long.iq ($(stat -c %s "$OUT/esrc_148_long.iq" 2>/dev/null) bytes, ~$(( $(stat -c %s "$OUT/esrc_148_long.iq" 2>/dev/null)/4/4545 )) frames)"
# 8. ROM-on-air gate (payload-independence cross-check)
$W 10.0.0.146 'pkill -x qpsk_tun 2>/dev/null; DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo "0x158 0x0">$DRA; sleep 1; echo "146 -> ROM-on-air"' 2>/dev/null
sleep 3
{ echo "=== ROM-on-air gate (146 tx_data_source=0): golden pattern floor on HW? ==="
  for i in 1 2 3 4 5 6; do $W 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA;cat $DRA; }; echo "cap=$(rd 0x144) biterr=$(rd 0x108) rstcs=$(rd 0x150)"' 2>/dev/null; sleep 0.6; done
} > "$OUT/esrc_romgate.txt"
cat "$OUT/esrc_romgate.txt"
# 9. (optional) acquisition-anchored capture for the RTL Q3b leg: TX down, start capture, TX up mid-capture.
if [ "$ACQ" = "1" ]; then
  echo "  [ACQ] acquisition-anchored capture: 146 TX down, start 148 capture, then 146 TX up"
  $W 10.0.0.146 'P=/sys/bus/iio/devices/iio:device2; echo rf_disabled > $P/out_voltage0_ensm_mode; echo "146 TX off"' 2>/dev/null; sleep 1
  $W 10.0.0.146 "cd /root/host_app_k5; rm -f /dev/shm/ber.log; setsid sh -c 'sleep 2; echo rf_enabled > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode; ./qpsk_tun -B -d 30 > /dev/shm/ber.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  $W 10.0.0.148 'rm -f /dev/shm/acq.iq; timeout 25 iio_readdev -u local: -b 32768 -s '"$NSAMP"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/acq.iq 2>/dev/null; echo "acq bytes=$(stat -c %s /dev/shm/acq.iq)"' 2>/dev/null
  scpget root@10.0.0.148:/dev/shm/acq.iq "$OUT/esrc_148_acq.iq"
  echo "  pulled esrc_148_acq.iq ($(stat -c %s "$OUT/esrc_148_acq.iq" 2>/dev/null) bytes)"
fi
# 10. quiesce
for ip in 10.0.0.146 10.0.0.148; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; echo "'$ip' quiesced"' 2>/dev/null; done
echo "=== ESRC CAPTURE done. artifacts in $OUT/ ==="; ls -la "$OUT"/
