#!/bin/bash
# gonogo.sh — bring the OTA link up in a verified-GOOD state (reboot-until-good).
# Root cause: the receiver's ADRV9002 Rx chain has a per-boot good/bad init coin
# (bad boot = linear wideband distortion, ~16% LS residual vs ~6% good). This
# harness boots, arms, verdicts offline (fast numpy LS-residual), and reboots the
# RX board until GO (max MAX_TRIES). Collects dmesg per attempt for the good-vs-bad
# diagnosis (Phase B). Usage: ./gonogo.sh [TX_IP RX_IP CARRIER_HZ TRIM_HZ]
set -u
TX=${1:-10.0.0.146}; RX=${2:-10.0.0.148}
CARRIER=${3:-2000000000}; TRIM=${4:-5420}
MAX_TRIES=6
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
OUT=$D/gonogo_logs; mkdir -p "$OUT"
TXLO=$((CARRIER+TRIM))
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

setup_board(){ # $1=ip : profile + ch2 kill + LNAs + tx_a
  $W $1 'P=/sys/bus/iio/devices/iio:device2; D=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; sleep 1
   echo calibrated > $P/out_voltage1_ensm_mode; echo calibrated > $P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > $D/agpio${g}_direction; echo 1 > $D/agpio${g}_value; done
   echo tx_a > $P/out_voltage0_port_select' 2>/dev/null
}

arm_tx(){ $W $TX "P=/sys/bus/iio/devices/iio:device2; echo $TXLO > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T; echo '0x458 0x2'>\$T; echo '0x044 0x1'>\$T; echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA" 2>/dev/null; }

# NOTE: verdict capture must be UNARMED - the capture DMA taps THROUGH the modem IP;
# arming the rx modem makes the capture show the modem's processed (possibly unlocked)
# stream, not the antenna signal. Unarmed = raw ADC = valid channel/Tx verdict.
arm_rx(){ $W $RX "P=/sys/bus/iio/devices/iio:device2; echo calibrated > \$P/out_voltage0_ensm_mode
 echo $CARRIER > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode" 2>/dev/null; }

echo "[gonogo] link $TX(Tx@$TXLO) -> $RX(Rx@$CARRIER), max $MAX_TRIES tries"
# initial full clean boot of both
$W $TX '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
$W $RX '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
wait_up $TX & wait_up $RX & wait
setup_board $TX; setup_board $RX; arm_tx

for try in $(seq 1 $MAX_TRIES); do
  arm_rx; sleep 1
  $W $RX 'rm -f /dev/shm/gg.iq; timeout 6 iio_readdev -u local: -b 32768 -s 300000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/gg.iq 2>/dev/null' 2>/dev/null
  scpget root@$RX:/dev/shm/gg.iq "$OUT/try${try}.iq"
  V=$(python3 "$D/gonogo_verdict.py" "$OUT/try${try}.iq"); RC=$?
  # bank dmesg for good-vs-bad diagnosis
  $W $RX 'dmesg | grep -iE "adrv9002|axi-adrv|iio" | tail -80' > "$OUT/try${try}_dmesg.txt" 2>/dev/null
  echo "[gonogo] try $try: $V"
  if [ $RC -eq 0 ]; then
    echo "[gonogo] LINK GO on try $try — leaving armed. Captures+dmesg in $OUT/"
    exit 0
  fi
  echo "[gonogo] NO-GO -> rebooting RX board only"
  $W $RX '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
  wait_up $RX
  setup_board $RX
done
echo "[gonogo] FAILED after $MAX_TRIES tries — investigate (dmesg saved per try in $OUT/)"
exit 1
