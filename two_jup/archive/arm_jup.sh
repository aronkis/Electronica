#!/bin/bash
# arm_jup.sh <ip> <txlo_hz> <rxlo_hz> -- load lvds_1p92 profile, run cals, set LOs, in-FPGA-Tx MUX,
# reset+select+rstCS. Parametrized on Tx/Rx LO. Single SSH call (no concurrent access).
set -u
WRAP=/mnt/onetb/scratch/qpsk_variants/two_jup/anyssh.sh
IP=${1:?ip}; TXLO=${2:?txlo}; RXLO=${3:?rxlo}
"$WRAP" $IP '
 P=""; TXD=""; for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
   [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = axi-adrv9002-tx-lpc ] && TXD=${d##*/}; done
 [ -z "$P" ] && { echo NO_PHY; exit 1; }
 cat /root/lvds_1p92_mhz.bin > $P/stream_config 2>/dev/null
 cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null || { sleep 1; cat /root/lvds_1p92_mhz.json > $P/profile_config 2>/dev/null; }
 sleep 2
 echo 1 > $P/out_voltage0_lo_leakage_tracking_en; echo 1 > $P/out_voltage0_quadrature_tracking_en
 echo '"$TXLO"' > $P/out_altvoltage2_TX1_LO_frequency; echo 0 > $P/out_voltage0_hardwaregain
 echo rf_enabled > $P/out_voltage0_ensm_mode 2>/dev/null
 echo '"$RXLO"' > $P/out_altvoltage0_RX1_LO_frequency; echo 1 > $P/in_voltage0_quadrature_tracking_en
 echo rf_enabled > $P/in_voltage0_ensm_mode 2>/dev/null
 echo manual > $P/in_voltage0_gain_control_mode; echo 24 > $P/in_voltage0_hardwaregain
 DRA=/sys/kernel/debug/iio/$TXD/direct_reg_access; echo "0x418 0x2" > $DRA; echo "0x458 0x2" > $DRA; echo "0x044 0x1" > $DRA
 busybox devmem 0x9D000000 32 1; sleep 1; busybox devmem 0x9D00011C 32 0; busybox devmem 0x9D000118 32 0
 busybox devmem 0x9D000114 32 1; busybox devmem 0x9D000110 32 1; sleep 0.3; busybox devmem 0x9D000110 32 0
 echo "ARMED ip='"$IP"' tx=$(cat $P/out_altvoltage2_TX1_LO_frequency) rx=$(cat $P/out_altvoltage0_RX1_LO_frequency) fs=$(cat $P/in_voltage0_sampling_frequency) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null)"'
