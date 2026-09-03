#!/bin/bash
# layerA_ber_analog.sh -- Layer A ANALOGUE loopback (spec 2026-08-18):
# single Jupiter, TX out through the real RF chain, radiated antenna-to-antenna
# coupling back into RX on the same board (authorized substitute for the
# attenuated cable). In-fabric scoring ONLY (0x104 frames / 0x108 comparator);
# TX reference = ROM (0x158=0); positive control = byte-source garbage (0x158=1).
#
# *** UNCALIBRATED PATH CAVEAT (bank with every number): the antenna-to-antenna
# coupling magnitude, ripple, polarization and bench multipath are unknown; the
# BER measured here is "RF chain in-loop at an UNCONTROLLED SNR", not a
# calibrated waterfall point. RSSI is recorded at every step to characterize
# the actual path loss. This also deviates from the strict "no propagation"
# wording: ~10 cm of radiated path exists. ***
#
# Attenuation ladder (operator-authorized): start 30 dB TX attenuation; step to
# 24 then 18 ONLY if no framesync lock; hard stop at 18.
# Base state = post-restore link config (proven profile/ports); this script
# changes only: TX/RX LO (set equal), TX attenuation, ensm/gain modes, and the
# fabric muxes via the bringup-sequenced batch (0x114=1 air path, 0x158 source).
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
LO=${LO:-1900020000}

echo "=== Layer A ANALOGUE: antenna-coupled RF loopback on $B, LO=$LO ==="
echo "--- [1] quiesce watchdog + daemon ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null

arm(){ # $1 = tx_data_source (0=ROM ref, 1=garbage control), $2 = TX attenuation dB (positive)
  $W $B "P=/sys/bus/iio/devices/iio:device2
  echo $LO > \$P/out_altvoltage2_TX1_LO_frequency
  echo $LO > \$P/out_altvoltage0_RX1_LO_frequency
  echo -$2 > \$P/out_voltage0_hardwaregain
  echo rf_enabled > \$P/out_voltage0_ensm_mode
  echo automatic > \$P/in_voltage0_gain_control_mode
  echo rf_enabled > \$P/in_voltage0_ensm_mode
  DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo \"0x000 0x1\">\$DRA; sleep 0.5; echo \"0x000 0x0\">\$DRA
  echo \"0x158 0x$1\">\$DRA
  echo \"0x118 0x0\">\$DRA
  echo \"0x114 0x1\">\$DRA
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done)
  T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T
  echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA
  echo \"  armed (0x158=$1, 0x114=1 AIR, tx_atten=-$2 dB, LO=$LO)\"" 2>/dev/null
}

rssi(){ # print RSSI + AGC state
  $W $B 'P=/sys/bus/iio/devices/iio:device2
  R=$(cat $P/in_voltage0_rssi 2>/dev/null || echo NA)
  G=$(cat $P/in_voltage0_hardwaregain 2>/dev/null || echo NA)
  echo "RSSI rssi=$R agc_gain=$G"' 2>/dev/null
}

probe(){ # $1 dwell, $2 label
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
  p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
  sleep $1
  p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
  dp=\$(( (p1-p0) & 0xFFFFFFFF )); de=\$(( (e1-e0) & 0xFFFFFFFF ))
  echo \"PROBE $2 dwell=$1 d104=\$dp d108=\$de fps=\$((dp/$1)) errps=\$((de/$1))\"" 2>/dev/null
}

LOCKATT=""
for ATT in 30 24 18; do
  echo "--- ladder: TX attenuation -$ATT dB, ROM source, lock probe ---"
  arm 0 $ATT; sleep 5
  rssi
  OUT=$(probe 15 "LOCK_ATT$ATT")
  echo "$OUT"
  FPS=$(echo "$OUT" | grep -oE 'fps=[0-9]+' | tr -dc 0-9)
  if [ "${FPS:-0}" -ge 1100 ]; then LOCKATT=$ATT; echo "LOCK at -$ATT dB"; break; fi
  echo "  no lock at -$ATT (fps=${FPS:-0})"
done
if [ -z "$LOCKATT" ]; then
  echo "LAYERA_ANALOG_NO_LOCK (ladder exhausted at -18 dB; hard stop per authorization)"
  bash "$D/restore_known_good.sh" > /tmp/layerA_an_restore.log 2>&1
  exit 2
fi

echo "--- [2] POSITIVE CONTROL at -$LOCKATT dB: 0x158=1 garbage -- must count HIGH ---"
arm 1 $LOCKATT; sleep 5
rssi
probe 15 CTRL_HIGH

echo "--- [3] REFERENCE dwells at -$LOCKATT dB ---"
arm 0 $LOCKATT; sleep 5
rssi
probe 60 ROM_A1
probe 60 ROM_A2
echo "--- [3b] independent re-arm ---"
arm 0 $LOCKATT; sleep 5
rssi
probe 60 ROM_B1
probe 120 ROM_LONG

echo "--- [4] restore rig ---"
bash "$D/restore_known_good.sh" > /tmp/layerA_an_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "LAYERA_ANALOG_DONE lock_att=-$LOCKATT dB (UNCALIBRATED radiated path -- see header caveat)"
