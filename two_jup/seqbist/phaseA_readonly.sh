#!/bin/bash
# phaseA_readonly.sh -- Task 6 PHASE A read-only rig checks. NO writes of any kind.
#
# Two ssh round-trips total (one per board). Nothing here writes a register, a
# file, or a radio attribute; the only "write" anywhere is `echo enabled >
# .../reg_access` which is the driver's read-enable latch and is already asserted
# by every other tool -- it is NOT a modem register write. Register READS use
# direct_reg_access's read idiom (`echo <addr> > DRA; cat DRA`), which the rails
# count as a read; they are done once each, not polled.
#
# 148 checks (the flash chain's [1/5] preconditions, ahead of time):
#   - booted /boot/BOOT.BIN md5-12 (must be the banked restore point f6a8c3ea119c)
#   - /root/BOOT.BIN.<bak>.bak present + its md5-12
#   - free space in /root and /boot (the chain stages a 7.2 MB file)
# 146 checks (stage-2 "146 silent" precondition, plan T3):
#   - qpsk_tun / lock_watchdog running?
#   - out_voltage0_ensm_mode  (rf_enabled => the PA is keyed, ROM or byte)
#   - 0x158 (0 = ROM source radiating, 1 = external byte stream)
#   - 0x114, 0x104 delta over 5 s (is the modem actually emitting frames?)
#   146 is the vendh lineage: it has no traffic_gen at 0x9D400000 -- never poke it.
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
BAK=${FLASH_BAK:-f6a8c3ea119c}

echo "=== PHASE-A read-only checks $(date -Is) ==="
echo "--- 148 ($A): flash preconditions ---"
$W $A "echo IMG=\$(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)
 if [ -f /root/BOOT.BIN.$BAK.bak ]; then echo BAKFILE=present BAKMD5=\$(md5sum /root/BOOT.BIN.$BAK.bak | cut -c1-12) BAKSZ=\$(stat -c %s /root/BOOT.BIN.$BAK.bak); else echo BAKFILE=MISSING; fi
 echo DFROOT=\$(df -k /root | tail -1 | awk '{print \$4}')kB DFBOOT=\$(df -k /boot | tail -1 | awk '{print \$4}')kB
 echo PROF=\$(ls /root/lvds_61p44_fdd_jupiter.bin /root/lvds_61p44_fdd_jupiter.json 2>/dev/null | tr '\n' ' ')
 echo DAEMONS=\$(pgrep -x qpsk_tun | tr '\n' ',')\$(pgrep -f '[l]ock_watchdog' | tr '\n' ',')" 2>/dev/null | tr -d '\r' | sed 's/^/  148 /'

echo "--- 146 ($B): silence check (read-only; vendh lineage, no traffic_gen) ---"
$W $B "P=/sys/bus/iio/devices/iio:device2
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo IMG=\$(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)
 echo QPSK_TUN=\$(pgrep -x qpsk_tun | tr '\n' ',' ) WD=\$(pgrep -f '[l]ock_watchdog' | tr '\n' ',')
 echo TX_ENSM=\$(cat \$P/out_voltage0_ensm_mode 2>/dev/null) RX_ENSM=\$(cat \$P/in_voltage0_ensm_mode 2>/dev/null)
 echo TXLO=\$(cat \$P/out_altvoltage2_TX1_LO_frequency 2>/dev/null) RXLO=\$(cat \$P/out_altvoltage0_RX1_LO_frequency 2>/dev/null)
 echo TXGAIN=\$(cat \$P/out_voltage0_hardwaregain 2>/dev/null)
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\" > \$DRA; cat \$DRA; }
 echo R158=\$(rd 0x158) R114=\$(rd 0x114) R118=\$(rd 0x118)
 p0=\$(rd 0x104); sleep 5; p1=\$(rd 0x104); echo RX_FPS_5S=\$(( (p1 - p0) / 5 ))" 2>/dev/null | tr -d '\r' | sed 's/^/  146 /'
echo "=== PHASE-A read-only checks DONE ==="
