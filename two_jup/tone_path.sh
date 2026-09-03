#!/bin/bash
# tone_path.sh <txip> <ch> <txlo> <delta> <scale> <rxip> <rxlo> <outfile>
# Emit a DDS tone on <txip> channel <ch> (1|2) at txlo+delta, capture on <rxip> channel <ch>, pull to host.
# ch1: TxLO=altvoltage2 RxLO=altvoltage0 txdev=tx-lpc rxdev=rx-lpc tx_ensm=out_voltage0 rx=in_voltage0
# ch2: TxLO=altvoltage3 RxLO=altvoltage1 txdev=tx2-lpc rxdev=rx2-lpc tx_ensm=out_voltage1 rx=in_voltage1
set -u
WRAP=$(cd "$(dirname "$0")" && pwd)/anyssh.sh
SC=$(cd "$(dirname "$0")" && pwd)
TXIP=${1:?}; CH=${2:?}; TXLO=${3:?}; D=${4:-100000}; SCL=${5:-0.25}; RXIP=${6:?}; RXLO=${7:?}; OUT=${8:?}
if [ "$CH" = 1 ]; then TXLOA=out_altvoltage2_TX1_LO_frequency; RXLOA=out_altvoltage0_RX1_LO_frequency; TXNAME=axi-adrv9002-tx-lpc; RXNAME=axi-adrv9002-rx-lpc; TXENS=out_voltage0_ensm_mode; RXENS=in_voltage0_ensm_mode; RXGM=in_voltage0_gain_control_mode; RXHG=in_voltage0_hardwaregain; TXHG=out_voltage0_hardwaregain
else TXLOA=out_altvoltage3_TX2_LO_frequency; RXLOA=out_altvoltage1_RX2_LO_frequency; TXNAME=axi-adrv9002-tx2-lpc; RXNAME=axi-adrv9002-rx2-lpc; TXENS=out_voltage1_ensm_mode; RXENS=in_voltage1_ensm_mode; RXGM=in_voltage1_gain_control_mode; RXHG=in_voltage1_hardwaregain; TXHG=out_voltage1_hardwaregain; fi
# --- Tx tone ---
"$WRAP" $TXIP '
 P=""; TXD=""; for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
   [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = '"$TXNAME"' ] && TXD=$d; done
 echo '"$TXLO"' > $P/'"$TXLOA"'; echo 0 > $P/'"$TXHG"'; echo rf_enabled > $P/'"$TXENS"' 2>/dev/null
 TXDN=${TXD##*/}; DRA=/sys/kernel/debug/iio/$TXDN/direct_reg_access; echo "0x418 0x0" > $DRA; echo "0x458 0x0" > $DRA
 echo '"$D"' > $TXD/out_altvoltage0_TX1_I_F1_frequency; echo '"$SCL"' > $TXD/out_altvoltage0_TX1_I_F1_scale; echo 0 > $TXD/out_altvoltage0_TX1_I_F1_phase
 echo '"$D"' > $TXD/out_altvoltage2_TX1_Q_F1_frequency; echo '"$SCL"' > $TXD/out_altvoltage2_TX1_Q_F1_scale; echo 270000 > $TXD/out_altvoltage2_TX1_Q_F1_phase
 echo "TONE ch='"$CH"' ip='"$TXIP"' txlo=$(cat $P/'"$TXLOA"') f1=$(cat $TXD/out_altvoltage0_TX1_I_F1_frequency)"' 2>/dev/null
sleep 1
# --- Rx capture ---
"$WRAP" $RXIP '
 P=""; for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = adrv9002-phy ] && P=$d; done
 echo '"$RXLO"' > $P/'"$RXLOA"'; echo rf_enabled > $P/'"$RXENS"' 2>/dev/null
 echo manual > $P/'"$RXGM"'; echo 24 > $P/'"$RXHG"'
 rm -f /dev/shm/cap.iq; timeout 15 iio_readdev -u local: -b 16384 -s 120000 '"$RXNAME"' voltage0_i voltage0_q > /dev/shm/cap.iq 2>/dev/null
 echo "CAP ch='"$CH"' ip='"$RXIP"' bytes=$(stat -c %s /dev/shm/cap.iq) fs=$(cat $P/in_voltage0_sampling_frequency) rssi=$(cat $P/'"${RXHG%_hardwaregain}"'_rssi 2>/dev/null)"' 2>/dev/null
SSH_ASKPASS=$SC/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w \
  scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@$RXIP:/dev/shm/cap.iq "$OUT" </dev/null 2>/dev/null
echo "pulled -> $OUT ($(stat -c %s "$OUT" 2>/dev/null) bytes)"
