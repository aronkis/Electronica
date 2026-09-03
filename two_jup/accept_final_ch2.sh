#!/bin/bash
# accept_final.sh -- FINAL acceptance at the adopted config: quiet pair
# (fwd 146->148 @2.00 GHz, rev 148->146 @1.90 GHz), CONTINUOUS -B both
# directions for the whole session (radiators first -- locking against idle
# filler PHASE-wedges the resolver), verified lock with in-place rstCS
# recovery, 148 Rx gain pinned post-lock. Windows are sliced from the
# cumulative per-5s rows afterward. Prints the raw row trace per direction.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; REV=1900000000
TOTAL=${TOTAL:-1320}    # 3x120 windows + 900 soak + acquisition margin

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
lastrow(){ $W $1 'grep "ber: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null; }
cleanof(){ echo "$1" | grep -oE 'clean=[0-9]+' | grep -oE '[0-9]+'; }
resync(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null; }

echo "=== FINAL ACCEPTANCE $(date -Is): fwd@$FWD rev@$REV, continuous ${TOTAL}s -B both directions ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null
done
arm $B_IP $FWD $REV
arm $A_IP $REV $FWD

# RADIATORS FIRST: continuous -B on both (feeds byte-TX; scores its own Rx)
for ip in $B_IP $A_IP; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log; setsid sh -c './qpsk_tun -B -d $TOTAL > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
done

# acquisition with real frames on air: watchdog round, then verify BOTH sides
# are producing CLEAN frames; a PHASE-wedged side gets an in-place rstCS resync.
for ip in $B_IP $A_IP; do
  $W $ip 'setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
for try in 1 2 3 4; do
  sleep 10
  RA=$(lastrow $A_IP); RB=$(lastrow $B_IP)
  CA0=${CA1:-0}; CB0=${CB1:-0}
  CA1=$(cleanof "$RA"); CB1=$(cleanof "$RB"); CA1=${CA1:-0}; CB1=${CB1:-0}
  echo "  lock check try$try: A clean=$CA1 (was $CA0) | B clean=$CB1 (was $CB0)"
  OK=1
  if [ "$CA1" -le "$CA0" ]; then resync $A_IP; OK=0; fi
  if [ "$CB1" -le "$CB0" ]; then resync $B_IP; OK=0; fi
  [ $OK = 1 ] && break
done

# pin 148 Rx gain at the settled operating point (the ~2x forward lever)
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage1_hardwaregain' 2>/dev/null)
GV=$(echo "$G" | grep -oE '^[0-9.]+')
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage1_gain_control_mode; echo $GV > \$P/in_voltage1_hardwaregain" 2>/dev/null
echo "  148 Rx gain pinned: $GV dB  (T0 for windows = next row)"
T0A=$(lastrow $A_IP); T0B=$(lastrow $B_IP)
echo "  T0 A: $T0A"; echo "  T0 B: $T0B"

# let the rest of the session run; rows accumulate on-board
sleep $TOTAL
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done

echo "--- FWD(146->148) cumulative rows (slice windows from deltas) ---"
$W $A_IP 'grep -E "ber: t=|frames_scored|buckets" /dev/shm/acc.log' 2>/dev/null
echo "--- REV(148->146) cumulative rows ---"
$W $B_IP 'grep -E "ber: t=|frames_scored|buckets" /dev/shm/acc.log' 2>/dev/null
echo "ACCEPT_FINAL_DONE"
