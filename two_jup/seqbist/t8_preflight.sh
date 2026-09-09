#!/bin/bash
# t8_preflight.sh -- Task 8 read-only preflight (no writes except the driver's
# reg_access read-enable latch). One ssh round-trip per board, no polling.
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
RCMD='
P=/sys/bus/iio/devices/iio:device2
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo IMG=$(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)
echo QPSK_TUN_BIN=$([ -f /root/host_app_k5/qpsk_tun ] && echo present || echo MISSING) NAKSTAT_N=$(strings /root/host_app_k5/qpsk_tun 2>/dev/null | grep -c nakstat)
echo DAEMONS=$(pgrep -x qpsk_tun | tr "\n" ",") WD=$(pgrep -f "[l]ock_watchdog" | tr "\n" ",")
echo DFROOT=$(df -k /root | tail -1 | awk "{print \$4}")kB DFBOOT=$(df -k /boot | tail -1 | awk "{print \$4}")kB
echo BAKS=$(ls /root/BOOT.BIN.*.bak 2>/dev/null | tr "\n" " ")
echo PROF=$(ls /root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json 2>/dev/null | tr "\n" " ")
echo TX_ENSM=$(cat $P/out_voltage0_ensm_mode 2>/dev/null) RX_ENSM=$(cat $P/in_voltage0_ensm_mode 2>/dev/null)
echo TXLO=$(cat $P/out_altvoltage2_TX1_LO_frequency 2>/dev/null) RXLO=$(cat $P/out_altvoltage0_RX1_LO_frequency 2>/dev/null)
echo TXGAIN=$(cat $P/out_voltage0_hardwaregain 2>/dev/null) RXGAIN=$(cat $P/in_voltage0_hardwaregain 2>/dev/null)
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
rd(){ echo "$1" > $DRA; cat $DRA; }
echo R158=$(rd 0x158) R114=$(rd 0x114) R118=$(rd 0x118)
p0=$(rd 0x104); sleep 5; p1=$(rd 0x104); echo RX_FPS_5S=$(( (p1 - p0) / 5 ))
DM=$(command -v devmem || echo "busybox devmem")
echo TGEN_CTRL=$($DM 0x9D400000 2>/dev/null) TGENRX_CTRL=$($DM 0x9D410000 2>/dev/null)
'
echo "=== T8 PREFLIGHT (read-only) $(date -Is) ==="
for ip in 10.0.0.148 10.0.0.146; do
  echo "--- $ip ---"
  $W "$ip" "$RCMD" 2>&1 | tr -d '\r' | sed "s/^/  $ip /"
done
echo "=== T8 PREFLIGHT DONE $(date -Is) ==="
