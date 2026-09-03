#!/bin/bash
# layerA_analog_v2.sh -- A-analogue floor v2: same rails as layerA_ber_analog.sh
# (ladder 30->24->18, RSSI at every step, in-fabric scoring, UNCALIBRATED radiated
# path caveat) but the reference dwells are TIMED INTO THE QUIET ZONES between the
# 119.75 s bursts, using the burst phase pinned by the 2026-08-19 NEL run:
# bursts START at arm+153 s (then +119.75 s each, 6-8 s long, arm-phase-locked).
# Quiet-zone dwell windows (relative to the final ROM arm's 0x110 pulse):
#   [170,240] [290,360] [410,480] [530,600]  -- 4 x 70 s, all >=9 s clear of bursts.
# Goal: a burst-free analogue floor to compare against the digital 3.7e-6 floor.
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=10.0.0.148
LO=${LO:-1900020000}

echo "=== Layer A ANALOGUE v2 (quiet-zone dwells) on $B, LO=$LO ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null

arm(){ # $1 = tx_data_source, $2 = TX attenuation dB
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
  TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9001-tx-lpc ] && echo \${d##*/}; done)
  T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
  echo \"0x418 0x2\">\$T; echo \"0x458 0x2\">\$T; echo \"0x044 0x1\">\$T
  echo \"0x110 0x1\">\$DRA; sleep 0.3; echo \"0x110 0x0\">\$DRA
  echo \"  armed (0x158=$1, 0x114=1 AIR, tx_atten=-$2 dB)\"" 2>/dev/null
}

rssi(){ $W $B 'P=/sys/bus/iio/devices/iio:device2
  echo "RSSI rssi=$(cat $P/in_voltage0_rssi 2>/dev/null || echo NA) agc_gain=$(cat $P/in_voltage0_hardwaregain 2>/dev/null || echo NA)"' 2>/dev/null; }

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
  echo "--- ladder: -$ATT dB, ROM, lock probe ---"
  arm 0 $ATT; sleep 5; rssi
  OUT=$(probe 15 "LOCK_ATT$ATT"); echo "$OUT"
  FPS=$(echo "$OUT" | grep -oE 'fps=[0-9]+' | tr -dc 0-9)
  if [ "${FPS:-0}" -ge 1100 ]; then LOCKATT=$ATT; echo "LOCK at -$ATT dB"; break; fi
  echo "  no lock at -$ATT (fps=${FPS:-0})"
done
if [ -z "$LOCKATT" ]; then
  echo "LAYERA_ANALOG_V2_NO_LOCK"
  bash "$D/restore_known_good.sh" > /tmp/layerA_an2_restore.log 2>&1
  exit 2
fi

echo "--- POSITIVE CONTROL at -$LOCKATT dB ---"
arm 1 $LOCKATT; sleep 5; rssi
probe 15 CTRL_HIGH

echo "--- REFERENCE arm; quiet-zone dwells [170,240] [290,360] [410,480] [530,600] ---"
arm 0 $LOCKATT
T0=$SECONDS
for START in 170 290 410 530; do
  NOW=$(( SECONDS - T0 ))
  WAIT=$(( START - NOW )); [ $WAIT -gt 0 ] && sleep $WAIT
  rssi
  probe 70 "QZ_${START}"
done
echo "--- one deliberately BURST-SPANNING dwell for contrast: [630,700] covers burst at 633+ ---"
NOW=$(( SECONDS - T0 )); WAIT=$(( 630 - NOW )); [ $WAIT -gt 0 ] && sleep $WAIT
probe 70 "BURSTSPAN_630"

echo "--- restore rig ---"
bash "$D/restore_known_good.sh" > /tmp/layerA_an2_restore.log 2>&1
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
  rd(){ echo "$1">$DRA; cat $DRA; }
  p0=$(($(rd 0x104))); sleep 3; p1=$(($(rd 0x104))); echo "RIG: fsync/s=$(( (p1-p0)/3 ))"' 2>/dev/null
echo "LAYERA_ANALOG_V2_DONE lock_att=-${LOCKATT} dB (UNCALIBRATED radiated path; dwell timing from NEL-pinned burst phase arm+153s/119.75s)"
