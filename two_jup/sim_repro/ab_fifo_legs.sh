#!/bin/bash
# ab_fifo_legs.sh <tag> -- the A/B leg set: 3 forward saturated legs on the CURRENT
# 148 image (same protocol as the baseline: GATE_DIR=A capture_r3.sh A -d 68 -k),
# with 0x1B0 (ByteRxFifo overflow) / 0x104 polls during each leg, scored by
# accept_analyze.py. Sentinel held for the duration. Usage: ab_fifo_legs.sh fifo4k
set -u
TAG=${1:?tag}; S=/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad
cd /mnt/onetb/scratch/qpsk-jupiter-modem/two_jup
. sim_repro/riglock.sh
if [ -e "$RIG_LOCK" ] && [ "${RIGLOCK_PARENT:-}" = 1 ]; then :; else rig_lock ab_fifo_legs_$TAG; trap rig_unlock EXIT; fi
poll(){ . sim_repro/no_arm_inflight.sh; arm_guard ab_poll || { echo ARM_INFLIGHT; return; }; ./anyssh.sh 10.0.0.148 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; for r in 0x104 0x1B0 0x1C0; do echo $r > $DRA; printf "%s=%s " $r $(cat $DRA); done; for d in /sys/bus/iio/devices/iio:device*; do [ -f $d/in_temp7_input ] && printf "tempPS=%s tempPL=%s " $(cat $d/in_temp7_input) $(cat $d/in_temp8_input); done; date +%s.%N' 2>/dev/null; }
IMG=$(./anyssh.sh 10.0.0.148 'md5sum /boot/BOOT.BIN | cut -c1-12' 2>/dev/null); echo "AB_LEGS $TAG image=$IMG $(date -Is)" >> $S/ab_${TAG}.txt
for i in 1 2 3; do
  ( GATE_DIR=A ./capture_r3.sh A -d 68 -k -o r3cap/fifo${TAG}_$(date +%Y%m%d_%H%M%S)_r$i > $S/ab_${TAG}_r$i.log 2>&1 ) &
  P=$!; sleep 75; echo "POLL1 r$i $(poll)" >> $S/ab_${TAG}.txt; sleep 20; echo "POLL2 r$i $(poll)" >> $S/ab_${TAG}.txt; wait $P
done
for d in $(ls -d r3cap/fifo${TAG}_*); do python3 accept_analyze.py $d/frames.bin 2>&1 | grep -E "PER=|UNUSABLE" | head -1; done >> $S/ab_${TAG}.txt
echo AB_DONE >> $S/ab_${TAG}.txt; echo done > $S/ab_${TAG}.done
