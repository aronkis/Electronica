#!/bin/bash
# g1_gate.sh — deploy the T8 image to one board and run the G1 BIST-on-air gate.
#   1. deploy BOOT.BIN to RX board (backs up current), reboot, setup (profile/ch2/LNA/tx_a)
#   2. internal-loopback sanity (rx_input=0): BIST must be golden
#   3. ensure the TX board is armed (canonical full arm at CARRIER+TRIM)
#   4. canonical full arm on RX (air, 0x114=1), 60 s: cap_out==0x04922282, rstcs static
#   5. forensic 0x15C readout (levelLog|maxBurst|maxGap|validDuty) — silicon truth of the rail
#   6. ANTI-MIRAGE: far Tx ensm=calibrated -> BIST must degrade -> restore
# Usage: g1_gate.sh BOOT.BIN RX_IP TX_IP [CARRIER TRIM ARM_TX(1|0)]
set -u
BIN=$1; RX=$2; TX=$3; CARRIER=${4:-2000000000}; TRIM=${5:-0}; ARMTX=${6:-1}
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
TXLO=$((CARRIER+TRIM))
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

echo "[g1] deploy $(md5sum "$BIN" | cut -c1-12) -> $RX"
scpput "$BIN" root@$RX:/dev/shm/BOOT.new
$W $RX 'S=$(stat -c %s /dev/shm/BOOT.new); if [ "$S" -gt 6000000 ]; then cp /boot/BOOT.BIN /boot/BOOT.BIN.prev_g1; cp /dev/shm/BOOT.new /boot/BOOT.BIN; sync; echo "  swapped -> $(md5sum /boot/BOOT.BIN | cut -c1-12)"; else echo "  BAD SIZE $S"; exit 1; fi; (sleep 1; reboot) >/dev/null 2>&1 &' 2>/dev/null || exit 1
wait_up $RX
$W $RX 'P=/sys/bus/iio/devices/iio:device2; D2=/sys/kernel/debug/iio/iio:device2
 echo "  boot=$(md5sum /boot/BOOT.BIN | cut -c1-12) devs=$(ls /sys/bus/iio/devices | wc -l)"
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
 echo "  fs=$(cat $P/in_voltage0_sampling_frequency)"
 echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
 for g in 4 5 6 7; do echo 1 > $D2/agpio${g}_direction; echo 1 > $D2/agpio${g}_value; done
 echo tx_a > $P/out_voltage0_port_select' 2>/dev/null

echo "[g1] internal loopback sanity"
IL=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 2; rd 0x144' 2>/dev/null)
echo "  internal cap=$IL (need 0x4922282)"
[ "$IL" = "0x4922282" ] || { echo "[g1] FAIL: internal loopback not golden"; exit 1; }

if [ "$ARMTX" = "1" ]; then
  echo "[g1] arm TX board $TX @${TXLO}"
  $W $TX "P=/sys/bus/iio/devices/iio:device2; echo $TXLO > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
   echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
   echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA" 2>/dev/null
fi

echo "[g1] air BIST (canonical arm, 60 s observation)"
$W $RX "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode
 echo $CARRIER > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA; sleep 3
 r0=\$(rd 0x150); locks=0
 for t in \$(seq 1 12); do c=\$(rd 0x144); [ \"\$c\" = \"0x4922282\" ] && locks=\$((locks+1)); echo -n \"\$c \"; sleep 5; done
 r1=\$(rd 0x150); f=\$(rd 0x15C); e=\$(rd 0x108)
 echo \"\"
 echo \"  locks=\$locks/12 rstcs \$r0->\$r1 err=\$e forensic=\$f\"
 python3 -c \"
v=int('\$f',16)
print('  forensic: levelLog=%d maxBurst=%d maxGap=%d validDuty=%d (expect duty 128, gap<=2)' % ((v>>24)&255,(v>>16)&255,(v>>8)&255,v&255))\"" 2>/dev/null

echo "[g1] ANTI-MIRAGE control (far Tx off)"
$W $TX 'echo calibrated > /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode' 2>/dev/null
sleep 3
AM=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 4; rd 0x144' 2>/dev/null)
echo "  far-Tx-off cap=$AM (must NOT be 0x4922282)"
$W $TX 'P=/sys/bus/iio/devices/iio:device2; echo rf_enabled > $P/out_voltage0_ensm_mode' 2>/dev/null
if [ "$AM" = "0x4922282" ]; then echo "[g1] FAIL: MIRAGE (golden with far Tx off)"; exit 1; fi
echo "[g1] anti-mirage OK; re-check air lock after Tx restore"
sleep 3
FIN=$($W $RX 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; rd(){ echo "$1">$DRA; cat $DRA; }
 echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA; sleep 4; rd 0x144' 2>/dev/null)
echo "  restored cap=$FIN"
if [ "$FIN" = "0x4922282" ]; then echo "[g1] G1 PASS"; exit 0; else echo "[g1] G1 FAIL (no re-lock after restore)"; exit 1; fi
