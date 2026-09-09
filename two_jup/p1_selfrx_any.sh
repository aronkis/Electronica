#!/bin/bash
# p1_selfrx146.sh -- 1-ft SELF-RECEPTION on 146 (P1 closing experiment, take 2).
# Full single-board arm (profile + TX/RX LO both 2.0 GHz at calibration time --
# the live RX-LO retune perturbs TX, measured 13:5x), SSI fix, ROM DOUBLE-TAP
# (ARMCAUSE false-FTS cure), ROM self-lock + BIST BER probe, then stream-first
# byte flip (double-tap) and the 60 s crc/idle idle-leg measurement.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${SELFRX_IP:-10.0.0.146}
PROF=lvds_61p44_fdd_jupiter
TXLO=${SELFRX_TXLO:-2000000000}; RXLO=${SELFRX_RXLO:-2000020000}
echo "P1_SELFRX start $(date -Is)"

echo "== [1] full arm (TX=$TXLO RX=$RXLO, ROM) =="
$W $B "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null
 pkill -f \"[l]ock_watchdog\" 2>/dev/null; pkill -f \"[s]tallpoll\" 2>/dev/null; sleep 1
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $TXLO > \$P/out_altvoltage2_TX1_LO_frequency 2>&1; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $RXLO > \$P/out_altvoltage0_RX1_LO_frequency 2>&1
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '  armed ROM self ($PROF, TX $TXLO RX $RXLO)'" 2>/dev/null

echo "== [2] SSI fix (146: standing 3 4; 148: skip per bringup default) =="
[ "$B" = 10.0.0.146 ] && $D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1 || echo "  skipped for $B"

rearm(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
echo "== [3] ROM double-tap (ARMCAUSE cure, self-peer) =="
rearm; sleep 2; rearm; sleep 5

echo "== [4] ROM self-lock + BIST BER probe (60s) =="
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$(rd 0x104); e0=\$(rd 0x108); r0=\$(rd 0x150); sleep 60; p1=\$(rd 0x104); e1=\$(rd 0x108); r1=\$(rd 0x150)
 dp=\$(( \$((p1)) - \$((p0)) )); de=\$(( \$((e1)) - \$((e0)) )); dr=\$(( \$((r1)) - \$((r0)) ))
 echo \"ROM_SELF fsync/s=\$((dp/60)) biterr/s=\$((de/60)) rstcs_d=\$dr\"" 2>/dev/null

echo "== [5] daemon (stream-first) + byte double-tap =="
$W $B "cd /root/host_app_k5; QPSK_WHITEN=0 QPSK_RX_QUEUED=1 setsid chrt -f 50 ./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 sleep 6; echo '  daemon up'" 2>/dev/null
byteflip(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
byteflip; sleep 2; byteflip; sleep 8

echo "== [6] byte self idle-leg (60s crc/idle) =="
S0=$($W $B 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null)
sleep 60
S1=$($W $B 'grep "qpsk_tun stats" /dev/shm/qpsk_tun.log | tail -1' 2>/dev/null)
echo "S0: $S0"; echo "S1: $S1"
echo "P1_SELFRX_DONE $(date -Is)"
