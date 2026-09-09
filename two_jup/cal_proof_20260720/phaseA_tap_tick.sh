#!/bin/bash
# =============================================================================
# phaseA_tap_tick.sh -- POSITIVE CONTROL for the tone experiment.
# Validate that the rx2-lpc AGC-out tap (0x10C mode 0) actually CARRIES the
# 256-sample BBDC insertion on the known-ticking OTA QPSK forward link (148 RX).
# Capture a long window of (a) the modem-consumed tap and (b) the raw rx-lpc
# receiver-input capture branch, at the real railed-gain operating point.
# Offline detector: d[n]=|x[n]-x[n-256]|^2 must DIP to ~0 periodically (~1.5s)
# on the consumed tap (a repeat of the preceding 256-sample block) and NOT on
# the raw branch. Reuses tap_smoke.sh arm/lock discipline verbatim.
# =============================================================================
set -u
TJ=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
W=$TJ/anyssh.sh
A_IP=10.0.0.148; B_IP=10.0.0.146
FWD=2000000000; REV=1900000000
DUR=${DUR:-12}                    # seconds per capture
FS=1920000
NS=$(( DUR * FS ))
OUT=${OUT:-/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/99c1d537-a8f8-481c-b665-21aeee224f33/scratchpad/phaseA_$(date +%Y%m%d_%H%M%S)}
mkdir -p "$OUT"
scpget(){ SSH_ASKPASS=$TJ/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
lastrow(){ $W $1 'grep "seq: t=" /dev/shm/acc.log 2>/dev/null | tail -1' 2>/dev/null; }
okof(){ echo "$1" | grep -oE 'ok=[0-9]+' | grep -oE '[0-9]+'; }
resync(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; busybox devmem 0x9D300000 32 0x1' 2>/dev/null; }

arm(){ # $1 ip $2 txlo $3 rxlo   (VERBATIM tap_smoke.sh arm)
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo $3 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x1'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
   busybox devmem 0x9D300000 32 0x1; echo '$1 armed'" 2>/dev/null
}

echo "=== PHASE A tap-tick positive control $(date -Is) -> $OUT ==="
for ip in $B_IP $A_IP; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; pkill -x iio_readdev 2>/dev/null; sleep 0.4' 2>/dev/null
done
arm $B_IP $FWD $REV
arm $A_IP $REV $FWD
for ip in $B_IP $A_IP; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log; setsid sh -c './qpsk_tun -S -d 200 > /dev/shm/acc.log 2>&1' </dev/null >/dev/null 2>&1 &" 2>/dev/null
  $W $ip 'setsid /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null
done
sleep 12
for ip in $B_IP $A_IP; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null' 2>/dev/null; done
CA1=0; CB1=0
for try in 1 2 3 4; do
  sleep 10
  CA0=$CA1; CB0=$CB1
  CA1=$(okof "$(lastrow $A_IP)"); CB1=$(okof "$(lastrow $B_IP)"); CA1=${CA1:-0}; CB1=${CB1:-0}
  echo "  lock try$try: A ok=$CA1 (was $CA0) | B ok=$CB1 (was $CB0)"
  OK=1
  [ "$CA1" -le "$CA0" ] && { resync $A_IP; OK=0; }
  [ "$CB1" -le "$CB0" ] && { resync $B_IP; OK=0; }
  [ $OK = 1 ] && break
done
[ "$OK" = 1 ] || { echo "PHASE_A_FAIL: no verified lock"; exit 1; }
G=$($W $A_IP 'cat /sys/bus/iio/devices/iio:device2/in_voltage0_hardwaregain' 2>/dev/null)
GV=$(echo "$G" | grep -oE '^[0-9.]+')
$W $A_IP "P=/sys/bus/iio/devices/iio:device2; echo spi > \$P/in_voltage0_gain_control_mode; echo $GV > \$P/in_voltage0_hardwaregain" 2>/dev/null
echo "  148 Rx gain pinned: $GV dB; forward link locked"

cap(){ # $1 label  $2 iio-device  $3 bbdc(0/1)
  local lbl=$1 dev=$2 bb=$3
  $W $A_IP "echo $bb > /sys/bus/iio/devices/iio:device2/in_voltage0_bbdc_rejection_tracking_en" 2>/dev/null
  sleep 2
  echo "--- capture $lbl ($dev, bbdc_track=$bb, ${DUR}s / ${NS} samp) ---"
  $W $A_IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo '0x10C 0x0' > \$DRA
    rm -f /dev/shm/$lbl.bin
    echo START t=\$(date +%s.%N)
    iio_readdev -u local: -b 65536 -s $NS $dev voltage0_i voltage0_q > /dev/shm/$lbl.bin 2>/dev/shm/${lbl}_err.txt || cat /dev/shm/${lbl}_err.txt
    echo END t=\$(date +%s.%N); ls -l /dev/shm/$lbl.bin" 2>/dev/null
  scpget root@$A_IP:/dev/shm/$lbl.bin "$OUT/$lbl.bin" || echo "WARN pull $lbl failed"
  $W $A_IP "rm -f /dev/shm/$lbl.bin" 2>/dev/null
}

# 1) consumed tap, BBDC ON  (expect periodic 256-repeat dips)
cap tap_bbdcON  axi-adrv9002-rx2-lpc 1
# 2) raw receiver-input branch, BBDC ON  (expect NO dips -- clean capture branch)
cap raw_bbdcON  axi-adrv9002-rx-lpc  1
# 3) consumed tap, BBDC tracking OFF (expect dips GONE; DC junk instead)
cap tap_bbdcOFF axi-adrv9002-rx2-lpc 0
# restore
$W $A_IP "echo 1 > /sys/bus/iio/devices/iio:device2/in_voltage0_bbdc_rejection_tracking_en" 2>/dev/null
for ip in $B_IP $A_IP; do $W $ip 'pkill -x qpsk_tun 2>/dev/null' 2>/dev/null; done
echo "PHASE_A_CAPTURE_DONE $OUT"
