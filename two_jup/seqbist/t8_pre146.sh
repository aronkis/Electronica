#!/bin/bash
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
p(){ echo "== $1"; out=$($W 10.0.0.146 "$2" 2>&1); echo "rc=$? out=[$out]"; }
p df 'echo DFROOT=$(df -k /root | tail -1 | awk "{print \$4}")kB DFBOOT=$(df -k /boot | tail -1 | awk "{print \$4}")kB'
p baks 'echo BAKS=$(ls /root/BOOT.BIN.*.bak 2>/dev/null | tr "\n" " ") PROF=$(ls /root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json 2>/dev/null | tr "\n" " ")'
p regs 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
echo R158=$(rd 0x158) R114=$(rd 0x114)
p0=$(rd 0x104); sleep 5; p1=$(rd 0x104); echo RX_FPS_5S=$(( (p1 - p0) / 5 ))'
p lo 'P=/sys/bus/iio/devices/iio:device2
echo TXLO=$(cat $P/out_altvoltage2_TX1_LO_frequency 2>/dev/null) RXLO=$(cat $P/out_altvoltage0_RX1_LO_frequency 2>/dev/null) TXGAIN=$(cat $P/out_voltage0_hardwaregain 2>/dev/null)'
