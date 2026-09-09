#!/bin/bash
. "$(dirname "$0")/sim_repro/no_arm_inflight.sh"; arm_guard health_probe || exit 3
# health_probe_reset_aware.sh <ip> [dwell_s] -- RESET-AWARE replacement for the
# legacy 4s health-gate probe that failed fsv2/wit3 (fsync=(d0x104)/4,
# wcnt=(d0x1C0)/4/191). That legacy pattern is the one BRINGUP_SEQUENCER.md
# rung 6 FORBIDS: 0x104 is reset by rstCS (fires every ~5-7 s on a HEALTHY
# link -- rate_probe.sh header) and by the watchdog's 0x000 (which also clears
# 0x1C0), so a 4 s window catches a reset ~73% of the time and reads
# positive-but-far-too-small (the documented example: 622 f/s on a true 1244
# link; fsv2/wit3 read 573-576/493 -- see the WITNESS_HEALTH_GATE forensic in
# HANDOFF_20260813.md).
#
# Method (rate_probe.sh idiom, extended to the byte-plane word counter):
# sample 0x104 (fsync), 0x150 (rstcs count) and 0x1C0 (byte words) every 1 s
# for DWELL s; score each 1 s interval; EXCLUDE intervals where 0x104 stepped
# backward/reset or 0x150 changed (a reset landed); report the mean over CLEAN
# intervals plus resets_s so a storm is its own visible metric, never a
# silent under-read.
# Output: fsync=<f/s> wcnt=<f/s> resets_s=<r/s> clean=<n>/<N>
set -u
IP=${1:?usage: health_probe_reset_aware.sh <ip> [dwell_s]}
DWELL=${2:-12}
W=$(cd "$(dirname "$0")" && pwd)/anyssh.sh
$W "$IP" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
rd(){ echo "$1">$DRA; cat $DRA; }
N='"$DWELL"'
p_prev=$(( $(rd 0x104) )); r_prev=$(( $(rd 0x150) )); w_prev=$(( $(rd 0x1C0) ))
fs_sum=0; wc_sum=0; clean=0; resets=0
for i in $(seq 1 $N); do
  sleep 1
  p=$(( $(rd 0x104) )); r=$(( $(rd 0x150) )); w=$(( $(rd 0x1C0) ))
  dp=$(( p - p_prev )); dr=$(( r - r_prev )); dw=$(( (w - w_prev) & 0xFFFFFFFF ))
  if [ $dp -lt 0 ] || [ $dr -ne 0 ]; then
    resets=$((resets+1))
  else
    fs_sum=$((fs_sum+dp)); wc_sum=$((wc_sum+dw)); clean=$((clean+1))
  fi
  p_prev=$p; r_prev=$r; w_prev=$w
done
if [ $clean -gt 0 ]; then
  echo "fsync=$((fs_sum/clean)) wcnt=$((wc_sum/clean/191)) resets_s=$((resets))/$N clean=$clean/$N"
else
  echo "fsync=0 wcnt=0 resets_s=$resets/$N clean=0/$N (ALL intervals dirty -- reset storm, judge on resets_s)"
fi' 2>/dev/null
