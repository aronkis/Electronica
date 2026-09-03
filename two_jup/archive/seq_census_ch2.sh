#!/bin/bash
# seq_census.sh [total_secs=600] -- loss-proof link census with qpsk_tun -S:
# continuous sequence-streaming both directions on the quiet pair, verified
# lock (radiators FIRST -- locking on idle filler PHASE-wedges the resolver),
# 148 Rx gain pinned post-lock. Every transmitted frame ends the run as
# OK / BITERR / LOST exactly once per direction; events land in
# /dev/shm/seq_events.log on each board (the error_hunt trigger feed).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
SRC=$(cd "$D/.." && pwd)/host_app_k5
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; REV=1900000000
TOTAL=${1:-600}
OUT=$D/census/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
lastrow(){ $W $1 'grep "seq: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null; }
okof(){ echo "$1" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+'; }
resync(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null; }

arm(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage0_ensm_mode; echo calibrated > \$P/in_voltage0_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage1_port_select
   echo $2 > \$P/out_altvoltage3_TX2_LO_frequency; echo 0 > \$P/out_voltage1_hardwaregain; echo rf_enabled > \$P/out_voltage1_ensm_mode
   echo $3 > \$P/out_altvoltage1_RX2_LO_frequency; echo rf_enabled > \$P/in_voltage1_ensm_mode; echo automatic > \$P/in_voltage1_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx2-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed'" 2>/dev/null
}

echo "=== SEQ CENSUS $(date -Is): ${TOTAL}s continuous -S both directions ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null
  $W $ip 'mkdir -p /root/host_app_k5' 2>/dev/null
  scpput "$SRC/qpsk_tun.c" "$SRC/qpsk_frame.c" "$SRC/qpsk_frame.h" "$SRC/qpsk_hw.h" \
         "$SRC/qpsk_ber.c" "$SRC/qpsk_ber.h" "$SRC/qpsk_seq.c" "$SRC/qpsk_seq.h" root@$ip:/root/host_app_k5/ || { echo "scp $ip FAIL"; exit 1; }
  R=$($W $ip 'cd /root/host_app_k5 && gcc -O2 -Wall -o qpsk_tun qpsk_tun.c qpsk_frame.c qpsk_ber.c qpsk_seq.c 2>/tmp/gcc.err && echo BUILD_OK || { echo BUILD_FAIL; cat /tmp/gcc.err; }' 2>/dev/null)
  echo "  $ip build: $(echo "$R" | tail -1)"; echo "$R" | grep -q BUILD_OK || exit 1
done
arm $B_IP $FWD $REV
arm $A_IP $REV $FWD

# RADIATORS FIRST: continuous -S on both. RT=1 -> SCHED_FIFO 80 pinned to
# core 3 (the periodic-stall discriminator: the single-packet rearm window is
# ~18 us; a preemption longer than that corrupts/drops delivered frames).
LAUNCH="./qpsk_tun"
[ "${RT:-0}" = 1 ] && LAUNCH="chrt -f 80 taskset -c 3 ./qpsk_tun"
for ip in $B_IP $A_IP; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log /dev/shm/seq_events.log /dev/shm/seq_raw.log; setsid sh -c '$LAUNCH -S -d $TOTAL > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done

# acquisition: watchdog round with real frames on air, then verify OK climbing
for ip in $B_IP $A_IP; do
  $W $ip 'setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
CA1=0; CB1=0
for try in 1 2 3 4; do
  sleep 10
  CA0=$CA1; CB0=$CB1
  CA1=$(okof "$(lastrow $A_IP)"); CB1=$(okof "$(lastrow $B_IP)"); CA1=${CA1:-0}; CB1=${CB1:-0}
  echo "  lock check try$try: A ok=$CA1 (was $CA0) | B ok=$CB1 (was $CB0)"
  OK=1
  if [ "$CA1" -le "$CA0" ]; then resync $A_IP; OK=0; fi
  if [ "$CB1" -le "$CB0" ]; then resync $B_IP; OK=0; fi
  [ $OK = 1 ] && break
done

# pin 148 Rx gain post-lock (the ~2x forward lever); PINBOTH=1 pins 146 too
# (required to bisect agc_tracking without freezing 146's automatic gain)
PINS="$A_IP"; [ "${PINBOTH:-0}" = 1 ] && PINS="$A_IP $B_IP"
for pip in $PINS; do
  G=$($W $pip 'cat /sys/bus/iio/devices/iio:device2/in_voltage1_hardwaregain' 2>/dev/null)
  GV=$(echo "$G" | grep -oE '^[0-9.]+')
  $W $pip "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage1_gain_control_mode; echo $GV > \$P/in_voltage1_hardwaregain" 2>/dev/null
  echo "  $pip Rx gain pinned: $GV dB"
done

# NOTRACK: disable ADRV9002 background tracking cals POST-LOCK on both boards
# (the ~1.57 s periodic-episode discriminator; disabling at ARM kills
# acquisition -- hw AGC/bbdc are load-bearing during lock). NOTRACK is a list:
# NOTRACK="agc rssi bbdc txclg" or NOTRACK=1 (= all four).
if [ -n "${NOTRACK:-}" ]; then
  SET=$NOTRACK; [ "$NOTRACK" = 1 ] && SET="agc rssi bbdc txclg"
  for ip in $B_IP $A_IP; do
    $W $ip "P=/sys/bus/iio/devices/iio:device2
      for w in $SET; do case \$w in
        agc)   echo 0 > \$P/in_voltage1_agc_tracking_en; echo 0 > \$P/in_voltage0_agc_tracking_en;;
        rssi)  echo 0 > \$P/in_voltage1_rssi_tracking_en; echo 0 > \$P/in_voltage0_rssi_tracking_en;;
        bbdc)  echo 0 > \$P/in_voltage1_bbdc_rejection_tracking_en; echo 0 > \$P/in_voltage0_bbdc_rejection_tracking_en;;
        txclg) echo 0 > \$P/out_voltage1_close_loop_gain_tracking_en 2>/dev/null; echo 0 > \$P/out_voltage0_close_loop_gain_tracking_en 2>/dev/null;;
      esac; done
      echo \"tracking post-lock: agc=\$(cat \$P/in_voltage1_agc_tracking_en) bbdc=\$(cat \$P/in_voltage1_bbdc_rejection_tracking_en) rssi=\$(cat \$P/in_voltage1_rssi_tracking_en)\"" 2>/dev/null
  done
fi

sleep $TOTAL
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done

for tag in "FWD_into_148:$A_IP" "REV_into_146:$B_IP"; do
  name=${tag%%:*}; ip=${tag##*:}
  echo "--- $name ---"
  $W $ip 'grep -E "SEQTX|SEQRX|seq: t=" /dev/shm/acc.log | tail -12' 2>/dev/null
  scpput root@$ip:/dev/shm/acc.log "$OUT/${name}_acc.log" 2>/dev/null || true
  scpput root@$ip:/dev/shm/seq_events.log "$OUT/${name}_events.log" 2>/dev/null || true
  scpput root@$ip:/dev/shm/seq_raw.log "$OUT/${name}_raw.log" 2>/dev/null || true
done
echo "SEQ_CENSUS_DONE $OUT"
