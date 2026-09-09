#!/bin/bash
# radio_knobs_probe.sh -- SEQ-BIST Task 8a step 1. READ-ONLY enumeration of the
# ADRV9002 RX gain-control / tracking-calibration knobs on one board.
#
# Writes NOTHING to the board. ONE ssh session. No register reads: every
# `*reg_access` and `direct_reg_access` node is EXCLUDED from every cat --
# reading direct_reg_access returns whatever address was last written and DRA
# traffic with no arm in flight has hung a board before (memory:
# rig-noping-hang-dra-during-arm). Names that read as triggers (initcal,
# calibrate, reset) are listed but never cat'd.
#
# Usage (as a unit): launch_rig_unit.sh knobs148 <abs path> IP=10.0.0.148 OUT=<dir>
set -u
D=$(cd "$(dirname "$0")" && pwd); TJ=$(cd "$D/.." && pwd); W=$TJ/anyssh.sh
IP=${IP:-10.0.0.148}
OUT=${OUT:-$D/knobs_$IP}
mkdir -p "$OUT"

$W "$IP" '
set -u
echo "### host $(hostname) $(date -Is)"
echo "### iio devices"
for d in /sys/bus/iio/devices/iio:device*; do
  echo "$d name=$(cat $d/name 2>/dev/null)"
done
PHY=""
for d in /sys/bus/iio/devices/iio:device*; do
  case "$(cat $d/name 2>/dev/null)" in *adrv9002*phy*|adrv9002-phy) PHY=$d;; esac
done
if [ -z "$PHY" ]; then echo "### FATAL: no adrv9002 phy iio device found"; exit 9; fi
echo "### PHY=$PHY  (bringup_r2r3.sh hardcodes iio:device2 -- confirm/deny above)"
echo "### ls $PHY"
ls -1 "$PHY"
echo "### gain-control + rx0 attributes (read-only, reg_access excluded)"
for a in in_voltage0_gain_control_mode in_voltage0_gain_control_mode_available \
         in_voltage0_hardwaregain in_voltage0_hardwaregain_available \
         in_voltage0_ensm_mode in_voltage0_ensm_mode_available \
         in_voltage0_interface_gain in_voltage0_interface_gain_available \
         in_voltage0_digital_gain_control_mode in_voltage0_digital_gain_control_mode_available \
         in_voltage0_rssi in_voltage0_rf_bandwidth in_voltage0_sampling_frequency \
         in_voltage0_nco_frequency in_voltage0_quadrature_tracking_en \
         in_voltage0_bbdc_rejection_tracking_en in_voltage0_rfdc_tracking_en \
         in_voltage0_agc_tracking_en in_voltage0_hd_tracking_en \
         in_voltage0_rssi_tracking_en in_voltage0_gain_control_pin_mode_en; do
  if [ -e "$PHY/$a" ]; then printf "%s = %s\n" "$a" "$(cat "$PHY/$a" 2>&1 | head -3 | tr "\n" "|")"; fi
done
echo "### every *tracking* / *cal* / *gain* named node on the phy (values, safe ones only)"
for f in "$PHY"/*; do
  b=${f##*/}
  case "$b" in *reg_access*|*direct*|*initcal*|*calibrate*|*reset*|*stream_config*|*profile_config*) echo "SKIPPED (never read): $b"; continue;; esac
  case "$b" in *tracking*|*cal*|*gain*|*agc*)
    [ -f "$f" ] && printf "%s = %s\n" "$b" "$(cat "$f" 2>&1 | head -3 | tr "\n" "|")";;
  esac
done
DBG=/sys/kernel/debug/iio/${PHY##*/}
echo "### ls -la $DBG"
ls -la "$DBG" 2>&1 | head -80
echo "### debugfs tracking / cal nodes (values; reg_access + triggers NEVER read)"
for f in "$DBG"/*; do
  b=${f##*/}
  case "$b" in *reg_access*|*direct*|*initcal*|*calibrate*|*reset*) echo "SKIPPED (never read): $b"; continue;; esac
  case "$b" in *tracking*|*cal*|*agc*|*dc_offset*|*qec*|*gain*)
    [ -f "$f" ] && printf "%s = %s\n" "$b" "$(cat "$f" 2>&1 | head -3 | tr "\n" "|")";;
  esac
done
echo "### hardwaregain series (5 reads, 1 s apart -- is the AGC hunting?)"
for i in 1 2 3 4 5; do
  printf "t%s %s  mode=%s\n" "$i" "$(cat "$PHY/in_voltage0_hardwaregain" 2>&1)" "$(cat "$PHY/in_voltage0_gain_control_mode" 2>&1)"
  sleep 1
done
echo "### daemon / link state (context only)"
pgrep -x qpsk_tun >/dev/null && echo "qpsk_tun RUNNING" || echo "qpsk_tun not running"
echo "### END"
' > "$OUT/knobs.txt" 2>&1
RC=$?
echo "rc=$RC out=$OUT/knobs.txt lines=$(wc -l < "$OUT/knobs.txt")"
tail -c 200 "$OUT/knobs.txt" >/dev/null
echo "KNOBS_DONE $OUT/knobs.txt"
exit $RC
