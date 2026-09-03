#!/bin/bash
# preflight.sh -- reachability + identity + SSI + LO + DDS-presence on both Jupiters.
set -u
WRAP=/mnt/onetb/scratch/qpsk_variants/two_jup/anyssh.sh
for ip in 10.0.0.148 10.0.0.146; do
  ping -c1 -W2 $ip >/dev/null 2>&1 || { echo "$ip DOWN"; continue; }
  "$WRAP" $ip '
    P=""; TX=""; for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null);
      [ "$n" = adrv9002-phy ] && P=$d; [ "$n" = axi-adrv9002-tx-lpc ] && TX=$d; done
    dds=no; [ -n "$TX" ] && ls "$TX" 2>/dev/null | grep -q F1_frequency && dds=yes
    modem=no; busybox devmem 0x9D000000 32 >/dev/null 2>&1 && modem=yes
    printf "%s model=%s fs=%s rxlo=%s txlo=%s dds=%s modembase=%s bootmd5=%s\n" \
      "'"$ip"'" "$(tr -d "\0" < /sys/firmware/devicetree/base/model)" \
      "$(cat $P/in_voltage0_sampling_frequency 2>/dev/null)" \
      "$(cat $P/out_altvoltage0_RX1_LO_frequency 2>/dev/null)" \
      "$(cat $P/out_altvoltage2_TX1_LO_frequency 2>/dev/null)" \
      "$dds" "$modem" "$(md5sum /boot/BOOT.BIN | cut -c1-32)"'
done
