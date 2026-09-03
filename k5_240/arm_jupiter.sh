#!/bin/bash
# arm_jupiter.sh -- cal + arm Jupiter for FDD (Tx 2.45 GHz in-FPGA ROM, Rx 2.40 GHz), with readbacks.
# Env: W = ssh wrapper (anyssh.sh <ip> '<cmd>'). Exits 1 on any readback mismatch.
# iio devices resolved BY NAME (robust to renumbering).
set -u
W=${W:?set W to the anyssh.sh wrapper path}
IP=10.0.0.146
"$W" $IP '
 for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
   [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = axi-adrv9002-tx-lpc ] && TXD=${d##*/}; done
 [ -z "$P" ] && { echo NO_PHY; exit 1; }
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null
 cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null || { sleep 1; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; }
 sleep 2
 echo 1 > $P/out_voltage0_lo_leakage_tracking_en; echo 1 > $P/out_voltage0_quadrature_tracking_en
 echo 2450000000 > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain
 echo rf_enabled > $P/out_voltage0_ensm_mode 2>/dev/null
 echo 2400000000 > $P/out_altvoltage0_RX1_LO_frequency; echo 1 > $P/in_voltage0_quadrature_tracking_en
 echo rf_enabled > $P/in_voltage0_ensm_mode 2>/dev/null
 echo manual > $P/in_voltage0_gain_control_mode; echo 24 > $P/in_voltage0_hardwaregain
 DRA=/sys/kernel/debug/iio/$TXD/direct_reg_access; echo "0x418 0x2" > $DRA; echo "0x458 0x2" > $DRA; echo "0x044 0x1" > $DRA
 busybox devmem 0x9D000000 32 1; sleep 1; busybox devmem 0x9D00011C 32 0; busybox devmem 0x9D000118 32 0
 busybox devmem 0x9D000114 32 1; busybox devmem 0x9D000110 32 1; sleep 0.3; busybox devmem 0x9D000110 32 0
' >/dev/null 2>&1
R=$("$W" $IP '
 for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
   [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = axi-adrv9002-tx-lpc ] && TXD=${d##*/}; done
 echo $(cat $P/out_altvoltage2_TX1_LO_frequency) $(cat $P/out_altvoltage0_RX1_LO_frequency) \
  $(cat $P/in_voltage0_sampling_frequency) $(cat $P/out_voltage0_hardwaregain|cut -d. -f1) $(cat $P/in_voltage0_hardwaregain|cut -d. -f1)
 DRA=/sys/kernel/debug/iio/$TXD/direct_reg_access; echo 0x418 > $DRA; cat $DRA' 2>/dev/null | tr '\n' ' ')
echo "readback: $R"
echo "$R" | grep -q "2450000000 2400000000 1920000 0 24" && echo "$R" | grep -q "0x2" \
  && echo ARM_JUPITER_OK || { echo ARM_JUPITER_FAIL; exit 1; }
