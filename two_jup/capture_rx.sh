#!/bin/bash
# capture_rx.sh <ip> <rxlo_hz> <nsamp> <outfile> -- set Rx LO, capture int16 IQ to /dev/shm, pull to host.
# Prints the board's actual Rx sampling_frequency (needed for correct spectral analysis).
set -u
WRAP=$(cd "$(dirname "$0")" && pwd)/anyssh.sh
SC=$(cd "$(dirname "$0")" && pwd)
IP=${1:?ip}; RXLO=${2:?rxlo}; N=${3:-120000}; OUT=${4:?out}
"$WRAP" $IP '
 P=""; for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = adrv9002-phy ] && P=$d; done
 echo '"$RXLO"' > $P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > $P/in_voltage0_ensm_mode 2>/dev/null
 echo manual > $P/in_voltage0_gain_control_mode; echo 24 > $P/in_voltage0_hardwaregain
 rm -f /dev/shm/cap.iq; timeout 15 iio_readdev -u local: -b 16384 -s '"$N"' axi-adrv9002-rx-lpc voltage0_i voltage0_q > /dev/shm/cap.iq 2>/dev/null
 echo "CAP ip='"$IP"' bytes=$(stat -c %s /dev/shm/cap.iq) fs=$(cat $P/in_voltage0_sampling_frequency 2>/dev/null) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null)"'
SSH_ASKPASS=$SC/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w \
  scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  root@$IP:/dev/shm/cap.iq "$OUT" </dev/null 2>/dev/null
echo "pulled -> $OUT ($(stat -c %s "$OUT" 2>/dev/null) bytes)"
