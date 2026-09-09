#!/bin/bash
# probe_0x158.sh -- is modem 0x158 (TX data source select) READABLE, and does a write stick?
#
# WHY: seqbist_run.sh's new verify_arm refused ctrlA-r2 because 0x158 read back 0 after
# arm_loop wrote 1. But NO tool in this tree has ever READ 0x158 -- bringup_r2r3.sh,
# loopchk_run.sh, arm148_mode1.sh and rf_loopback.sh all only WRITE it. So there are two
# candidate explanations and they need separating before either the arm or the guard is
# blamed:
#   (A) the write does not stick (real arm failure)  -> verify_arm is right
#   (B) 0x158 is write-only / reads back 0 always    -> verify_arm is a FALSE GATE
# A single ssh session writes and reads in place, so no round-trip timing can confuse it.
# 0x104 is sampled alongside as an independent witness of what the modem is actually doing.
#
# All writes here are ones the standard arm sequences perform routinely. The probe RESTORES
# 0x158 to 0 (ROM, the state the board is in now) on the way out.
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh; A=10.0.0.148
timeout 90 $W $A 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
echo "STEP0_pre        0x158=$(rd 0x158) 0x114=$(rd 0x114) 0x118=$(rd 0x118)"
# is any modem register readable at all? 0x10C was just written 0x60003 by the flash witness
echo "STEP0_control    0x10C=$(rd 0x10C)  (non-zero here proves the read path works)"
echo "0x158 0x1" > $DRA
echo "STEP1_immediate  0x158=$(rd 0x158)"
sleep 1
echo "STEP2_after_1s   0x158=$(rd 0x158)"
echo "0x110 0x1" > $DRA; sleep 0.3; echo "0x110 0x0" > $DRA
echo "STEP3_after_0x110 0x158=$(rd 0x158)"
p0=$(rd 0x104); sleep 3; p1=$(rd 0x104)
echo "STEP4_fps_with_158_1 $(( (p1 - p0) / 3 ))"
# full arm_loop-shaped sequence in ONE session, then read
TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
T=/sys/kernel/debug/iio/$TXD/direct_reg_access
echo "TXD=$TXD"
echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
echo "STEP5_after_full_arm 0x158=$(rd 0x158) 0x114=$(rd 0x114) 0x118=$(rd 0x118)"
p0=$(rd 0x104); sleep 3; p1=$(rd 0x104)
echo "STEP6_fps_after_arm $(( (p1 - p0) / 3 ))"
# write 0 and read: if it reads 0 both when written 1 and when written 0, it is not readable
echo "0x158 0x0" > $DRA
echo "STEP7_written_0  0x158=$(rd 0x158)"
echo "PROBE_DONE"'
echo "-- rc=$? --"
