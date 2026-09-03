#!/bin/bash
# dds_tone.sh <ip> <txlo_hz> <delta_hz> <scale> -- emit a single complex DDS tone at LO+delta.
# Sets DAC source to DDS (0x418/0x458 = 0x0), F1 I/Q to +delta with 90deg quadrature (SSB), Tx on.
# Works on the jupiter modem image (DAC temporarily switched from modem->DDS).
set -u
WRAP=$(cd "$(dirname "$0")" && pwd)/anyssh.sh
IP=${1:?ip}; TXLO=${2:?txlo}; D=${3:-100000}; SC=${4:-0.25}
"$WRAP" $IP '
 P=""; TXD=""; for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
   [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = axi-adrv9002-tx-lpc ] && TXD=$d; done
 echo '"$TXLO"' > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain
 echo rf_enabled > $P/out_voltage0_ensm_mode 2>/dev/null
 TXDN=${TXD##*/}; DRA=/sys/kernel/debug/iio/$TXDN/direct_reg_access; echo "0x418 0x0" > $DRA; echo "0x458 0x0" > $DRA
 echo '"$D"' > $TXD/out_altvoltage0_TX1_I_F1_frequency; echo '"$SC"' > $TXD/out_altvoltage0_TX1_I_F1_scale; echo 0 > $TXD/out_altvoltage0_TX1_I_F1_phase
 echo '"$D"' > $TXD/out_altvoltage2_TX1_Q_F1_frequency; echo '"$SC"' > $TXD/out_altvoltage2_TX1_Q_F1_scale; echo 270000 > $TXD/out_altvoltage2_TX1_Q_F1_phase
 echo 0 > $TXD/out_altvoltage1_TX1_I_F2_scale 2>/dev/null; echo 0 > $TXD/out_altvoltage3_TX1_Q_F2_scale 2>/dev/null
 echo "TONE_SET ip='"$IP"' txlo=$(cat $P/out_altvoltage2_TX1_LO_frequency) f1=$(cat $TXD/out_altvoltage0_TX1_I_F1_frequency) sc=$(cat $TXD/out_altvoltage0_TX1_I_F1_scale)"'
