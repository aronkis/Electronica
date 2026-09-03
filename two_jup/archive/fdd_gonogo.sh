#!/bin/bash
# fdd_gonogo.sh — simultaneous FDD verification with unarmed-modem verdicts.
# Link A: 146 Tx1@FA -> 148 Rx1@FA ; Link B: 148 Tx1@FB -> 146 Rx1@FB, BOTH LIVE AT ONCE.
# Both boards transmit the GOLDEN via host-DMA (modems stay UNARMED so each board's
# capture tap = raw ADC = valid offline verdict; modem-Tx FDD returns after the
# Phase-B/C BIST fix). Trims scale the measured 2.0GHz XO offset (+5.42k on 146 Tx)
# by carrier ratio. Verdicts via gonogo_verdict.py on simultaneous captures.
set -u
FA=${1:-2400000000}   # link A carrier (146->148)
FB=${2:-2450000000}   # link B carrier (148->146)
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
OUT=$D/gonogo_logs; mkdir -p "$OUT"
TRIMA=$(python3 -c "print(int(5420*$FA/2.0e9))")     # 146 Tx trim (+)
TRIMB=$(python3 -c "print(int(-5420*$FB/2.0e9))")    # 148 Tx trim (-)
TXA=$((FA+TRIMA)); TXB=$((FB+TRIMB))
scpget(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }
wait_up(){ until ! ping -c1 -W1 $1 >/dev/null 2>&1; do sleep 2; done; until ping -c1 -W2 $1 >/dev/null 2>&1; do sleep 3; done; sleep 20; }

echo "[fdd] A: 146 Tx@$TXA -> 148 Rx@$FA | B: 148 Tx@$TXB -> 146 Rx@$FB (host-DMA golden both)"
$W 10.0.0.146 '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
$W 10.0.0.148 '(sleep 1; reboot)>/dev/null 2>&1 &' 2>/dev/null
wait_up 10.0.0.146 & wait_up 10.0.0.148 & wait

setup(){ # $1=ip $2=txlo $3=rxlo : full FDD setup + host-DMA golden Tx (modem untouched)
  scpget "$D/golden_tx.iq" root@$1:/dev/shm/golden.iq
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DBG=/sys/kernel/debug/iio/iio:device2
   cat /root/lvds_1p92_mhz.bin > \$P/stream_config 2>/dev/null; cat /root/lvds_1p92_mhz.json > \$P/profile_config 2>/dev/null; sleep 1
   echo calibrated > \$P/out_voltage1_ensm_mode; echo calibrated > \$P/in_voltage1_ensm_mode
   for g in 4 5 6 7; do echo 1 > \$DBG/agpio\${g}_direction; echo 1 > \$DBG/agpio\${g}_value; done
   echo tx_a > \$P/out_voltage0_port_select
   echo $2 > \$P/out_altvoltage2_TX1_LO_frequency; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency
   echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
   echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
   TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done); T=/sys/kernel/debug/iio/\$TXD/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   echo '0x418 0x0' > \$T; echo '0x458 0x0' > \$T; echo '0x044 0x1' > \$T
   pkill iio_writedev 2>/dev/null
   ( setsid timeout 600 iio_writedev -u local: -b 181280 -c axi-adrv9002-tx-lpc voltage0 voltage1 < /dev/shm/golden.iq >/dev/null 2>&1 ) &
   sleep 2; echo \"$1 FDD up: Tx@$2 (writedev=\$(pgrep -c iio_writedev)) Rx@$3\"" 2>/dev/null
}
setup 10.0.0.146 $TXA $FB
setup 10.0.0.148 $TXB $FA
sleep 2
# SIMULTANEOUS captures on both receivers (background both, then collect)
$W 10.0.0.148 'rm -f /dev/shm/fa.iq; timeout 8 iio_readdev -u local: -b 32768 -s 300000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/fa.iq 2>/dev/null; echo "148 capA=$(stat -c %s /dev/shm/fa.iq) rssi=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi)"' 2>/dev/null &
$W 10.0.0.146 'rm -f /dev/shm/fb.iq; timeout 8 iio_readdev -u local: -b 32768 -s 300000 axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/fb.iq 2>/dev/null; echo "146 capB=$(stat -c %s /dev/shm/fb.iq) rssi=$(cat /sys/bus/iio/devices/iio:device2/in_voltage0_rssi)"' 2>/dev/null &
wait
scpget root@10.0.0.148:/dev/shm/fa.iq "$OUT/fdd_linkA.iq"
scpget root@10.0.0.146:/dev/shm/fb.iq "$OUT/fdd_linkB.iq"
VA=$(python3 "$D/gonogo_verdict.py" "$OUT/fdd_linkA.iq"); RA=$?
VB=$(python3 "$D/gonogo_verdict.py" "$OUT/fdd_linkB.iq"); RB=$?
echo "[fdd] LINK A (146->148 @$FA): $VA"
echo "[fdd] LINK B (148->146 @$FB): $VB"
if [ $RA -eq 0 ] && [ $RB -eq 0 ]; then echo "[fdd] FDD GO — both links clean simultaneously"; exit 0; fi
echo "[fdd] FDD NO-GO"; exit 1
