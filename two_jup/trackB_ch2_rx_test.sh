#!/bin/bash
# trackB_ch2_rx_test.sh — Rx-on-ch2 FDD isolation experiment (Track B of the LO-issue goal).
# PREREQUISITE (physical): move/add a cable so 146 Tx1 SMA -> 148 **Rx2** SMA.
#   (Verified 2026-07-06: the Rx2 port currently has NO cable — rssi2 = 75.7 dB noise floor.)
# Also recommended first: reseat/inspect ALL RF cables+pads — the link regressed midday
#   2026-07-06 in both directions with all digital elements verified clean (see memory notes).
#
# What it does:
#  1. Flash 148 -> ch2 image (b853f5ef, modem on Rx2/Tx2)  [ch2 img at two_jup/ch2_BOOT.BIN.save]
#  2. 146 (gather 753760ad) clean-armed as full-rate Tx1@2.40.
#  3. 148: modem Rx2@2.40 baseline (all own Tx off)  -> BIST must be GOLDEN 0x4922282.
#  4. Enable 148's Tx1 (ch1 pins, physically separate from Rx2) LO@2.45 -> read BIST.
#     GOLDEN  => channel separation defeats the own-Tx desense -> build "Tx ch1 + Rx ch2" modem for FDD.
#     BROKEN  => on-die/shared-LO coupling regardless of pins -> FDD needs external duplexer, or use pseudo-TDD.
set -e
W=${W:-$(dirname "$0")/anyssh.sh}
D=$(cd "$(dirname "$0")" && pwd)
ask() { SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null; }

echo "== 1. flash 148 -> ch2 image =="
ask "$D/ch2_BOOT.BIN.save" root@10.0.0.148:/dev/shm/BOOT.ch2
$W 10.0.0.148 'cp /dev/shm/BOOT.ch2 /boot/BOOT.BIN; sync; md5sum /boot/BOOT.BIN; (sleep 1; reboot) >/dev/null 2>&1 &'
until ! ping -c1 -W1 10.0.0.148 >/dev/null 2>&1; do sleep 2; done
until ping -c1 -W2 10.0.0.148 >/dev/null 2>&1; do sleep 3; done; sleep 20

echo "== 2. reboot+clean-arm 146 as Tx1@2.40 (gather, full rate) =="
$W 10.0.0.146 '(sleep 1; reboot) >/dev/null 2>&1 &'
until ! ping -c1 -W1 10.0.0.146 >/dev/null 2>&1; do sleep 2; done
until ping -c1 -W2 10.0.0.146 >/dev/null 2>&1; do sleep 3; done; sleep 20
$W 10.0.0.146 'P=/sys/bus/iio/devices/iio:device2; cat /root/lvds_1p92_mhz.bin > $P/stream_config; cat /root/lvds_1p92_mhz.json > $P/profile_config; sleep 1
 echo 2400000000 > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain; echo rf_enabled > $P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; echo "146 Tx1@2.40 armed"'

echo "== 3+4. 148 ch2-Rx baseline then +Tx1 stressor =="
$W 10.0.0.148 'P=/sys/bus/iio/devices/iio:device2; cat /root/lvds_1p92_mhz.bin > $P/stream_config; cat /root/lvds_1p92_mhz.json > $P/profile_config; sleep 1
 # baseline: only Rx2 active
 echo calibrated > $P/in_voltage0_ensm_mode; echo calibrated > $P/out_voltage0_ensm_mode; echo calibrated > $P/out_voltage1_ensm_mode
 echo 2400000000 > $P/out_altvoltage1_RX2_LO_frequency; echo rf_enabled > $P/in_voltage1_ensm_mode; echo automatic > $P/in_voltage1_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 1.5
 echo "STEP3 baseline (own Tx OFF), rssi2=$(cat $P/in_voltage1_rssi):"
 for i in 1 2 3 4 5 6; do echo -n "$(rd 0x144) "; sleep 0.4; done; echo
 # stressor: Tx1 (ch1 pins) LO@2.45 on
 echo 2450000000 > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain; echo rf_enabled > $P/out_voltage0_ensm_mode; sleep 0.5
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 1.5
 echo "STEP4 +Tx1@2.45 ON (ch1 pins):"
 for i in 1 2 3 4 5 6; do echo -n "$(rd 0x144) "; sleep 0.4; done; echo
 echo "(golden=0x4922282). If STEP3 golden + STEP4 golden -> channel separation WORKS."'
echo "== done. Restore 148: scp two_jup/gather_BOOT.BIN -> /boot/BOOT.BIN + reboot =="
