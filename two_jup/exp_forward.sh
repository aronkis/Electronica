#!/bin/bash
# =============================================================================
# exp_forward.sh -- parameterized FORWARD-link experiment driver for the RF
# residual chase (Contingency B). Measures 146 TX@F -> 148 RX@F with -B on 148
# under selectable levers:
#   -f HZ        forward carrier (default 2000000000)
#   -d SECS      -B duration (default 120)
#   --park148tx  park 148's own Tx LO at 1.5 GHz and rf_disable it
#                (self-interference discriminator; default: Tx armed @1.90 GHz)
#   --qec        enable quadrature_w_poly + fic + rfdc tracking cals on 148 Rx0
#                (set in 'calibrated' ENSM state -- rf_enabled denies the write)
#   --pin        pin 148 Rx analog gain (spi @ auto-picked value) after lock
#   -t TAG       label for the result line
# Prints one RESULT line: tag, config, BER, buckets, rssi before/after.
# Boards are left quiesced-armed as usual; strictly serial SSH.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; RXF=""; DUR=120; PARK=0; QEC=0; PIN=0; TAG=exp
while [ $# -gt 0 ]; do
  case "$1" in
    -f) FWD=$2; shift 2;;
    -r) RXF=$2; shift 2;;          # 148 Rx LO (default: same as -f). Set differently
                                   # to TRIM the inter-board XO CFO (~-6.3 kHz @2.0G).
    -d) DUR=$2; shift 2;;
    --park148tx) PARK=1; shift;;
    --qec) QEC=1; shift;;
    --pin) PIN=1; shift;;
    -t) TAG=$2; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[ -n "$RXF" ] || RXF=$FWD

echo "=== exp_forward [$TAG] F=$FWD dur=$DUR park148tx=$PARK qec=$QEC pin=$PIN ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 0.4' 2>/dev/null
done

# --- arm 146: Tx=F (the forward radiator); Rx parked at 1.90 (unused here) ---
$W $B_IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
 echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $FWD > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo 1900000000 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 busybox devmem 0x9D300000 32 0x1; echo '146 armed tx=$FWD'" 2>/dev/null

# --- arm 148: Rx=F (+optional QEC cals in calibrated state), Tx armed@1.90 or parked ---
if [ $PARK = 1 ]; then TX148=1500000000; TXEN=rf_disabled; else TX148=1900000000; TXEN=rf_enabled; fi
QECW=""
if [ $QEC = 1 ]; then QECW="echo calibrated > \$P/in_voltage0_ensm_mode
 echo 1 > \$P/in_voltage0_quadrature_w_poly_tracking_en 2>&1 | tail -1
 echo 1 > \$P/in_voltage0_quadrature_fic_tracking_en 2>&1 | tail -1
 echo 1 > \$P/in_voltage0_rfdc_tracking_en 2>&1 | tail -1
 echo \"qec set: wpoly=\$(cat \$P/in_voltage0_quadrature_w_poly_tracking_en) fic=\$(cat \$P/in_voltage0_quadrature_fic_tracking_en) rfdc=\$(cat \$P/in_voltage0_rfdc_tracking_en)\""; fi
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
 echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
 $QECW
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $TX148 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo $TXEN > \$P/out_voltage0_ensm_mode
 echo $RXF > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 busybox devmem 0x9D300000 32 0x1; echo \"148 armed rx=$FWD tx=$TX148($TXEN)\"" 2>/dev/null

# --- start the RADIATOR first: the TX side's qpsk_tun -B feeds the byte-TX
# DMA with the reference frames -- without it 146 transmits idle filler and
# every received frame scores PHASE. Long duration covers lock-loop + measure. ---
$W $B_IP "cd /root/host_app_k5; setsid sh -c './qpsk_tun -B -d $((DUR+150)) > /dev/shm/exp_b.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null

# --- VERIFIED-LOCK LOOP (acquisition is stochastic; ~1/3 arms fail): watchdog,
# then a 6 s -B probe must show aligned frames; else re-sync and retry. ---
LOCKED=0
for try in 1 2 3; do
  $W $A_IP 'rm -f /dev/shm/watchdog.log; setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
  sleep 12
  $W $A_IP 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; sleep 1
  PR=$($W $A_IP 'cd /root/host_app_k5; ./qpsk_tun -B -d 6 2>/dev/null | grep frames_scored' 2>/dev/null)
  AL=$(echo "$PR" | grep -oE 'aligned\(clean\+noisy\)=[0-9]+' | grep -oE '[0-9]+$')
  echo "  lock probe try$try: ${PR:-none}"
  if [ "${AL:-0}" -gt 100 ]; then LOCKED=1; break; fi
  # re-sync: carrier reset pulse + byte re-arm, then another watchdog round
  $W $A_IP 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null
done
[ $LOCKED = 1 ] || echo "  WARN: no verified lock after 3 tries -- measuring anyway (expect junk)"

# --- optional gain pin (only after verified lock, so the pinned value is sane) ---
GV=auto
if [ $PIN = 1 ]; then
  G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
  GV=$(echo "$G" | grep -oE '^[0-9.]+')
  $W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage0_gain_control_mode; echo $GV > \$P/in_voltage0_hardwaregain" 2>/dev/null
fi
R0=$($W $A_IP 'cut -d" " -f1 /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null' 2>/dev/null)

# --- the measurement ---
$W $A_IP "cd /root/host_app_k5; rm -f /dev/shm/exp.log; setsid sh -c './qpsk_tun -B -d $DUR > /dev/shm/exp.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
sleep $((DUR + 8))
for ip in $A_IP $B_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
R1=$($W $A_IP 'cut -d" " -f1 /sys/bus/iio/devices/iio:device2/in_voltage0_rssi 2>/dev/null' 2>/dev/null)
RES=$($W $A_IP 'grep -E "frames_scored" /dev/shm/exp.log' 2>/dev/null)
BK=$($W $A_IP 'grep -E "^buckets" /dev/shm/exp.log' 2>/dev/null)
echo "RESULT [$TAG] F=$FWD RXF=$RXF park=$PARK qec=$QEC pin=$PIN gain=$GV rssi=$R0->$R1"
echo "  $RES"
echo "  $BK"
