#!/bin/bash
# =============================================================================
# stagesig_run_20260830.sh -- TX-vs-RX discriminator on 148, image ed44769ed7aa (bounded window: stages 0,1,2,3 covered).
#
# The flashed witness runs seven per-frame signature accumulators and per-stage
# mismatch counters; fixctl[11:8] selects which one is read back:
#   0x20C = selected stage's latest per-frame signature
#   0x210 = selected stage's MISMATCH COUNT (frames differing from the reference
#           frame, latched at frame 8 after the soft reset). Accumulating.
#
# THIS IMAGE (build 1) COVERS STAGES 0 AND 1 ONLY. The sim gate showed stages
# 2-6 are not frame-invariant with its unbounded accumulator, so their counters
# are meaningless here and are recorded as UNCOVERED, never interpreted.
#   stage 0 = dataIn  == the RX chain input == the TX MODULATOR OUTPUT
#   stage 1 = AGC out
#
# Only valid in MODE 1 (FPGA-internal digital loopback, rx_input_select=0). On
# the air link the RX input is the ADC and differs every frame by construction,
# so every counter climbs and the reading means nothing -- that is exactly what
# the post-flash smoke test showed and why it was not interpretable.
#
# PRE-REGISTERED:
#   G1 instrument gate: in QUIET loopback seconds stage 0's mismatch delta must
#      be 0. If it is nonzero when the link is clean, the reference frame is bad
#      (latched at frame 8, possibly mid-acquisition) -- STOP, do not interpret.
#   G2 TX VERDICT:
#      stage 0 mismatch climbs during a burst  -> the TRANSMITTER's own output
#         varies frame to frame: the TX is the source, and mode-1 loopback puts
#         it inside the loop so this is a real indictment.
#      stage 0 mismatch stays FLAT through a full-magnitude burst while 0x108
#         accumulates errors -> the TX output is bit-identical every frame and
#         the fault is DOWNSTREAM, in the RX chain. TX exonerated on silicon.
#   G3 stage 1 (AGC out) splits "RX input" from "post-AGC" if stage 0 is flat.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
DWELL=${DWELL:-400}
OUT=$D/stagesig/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/sim_repro/riglock.sh"
rig_lock stagesig_run
trap 'rig_unlock' EXIT

log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== stagesig_run on $B (image ed44769ed7aa (bounded window: stages 0,1,2,3 covered)) -> $OUT ==="
log "--- [0] quiesce ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo "  quiesced"' 2>/dev/null | tee -a "$OUT/run.log"

log "--- [1] arm MODE 1 (internal digital loopback, ROM BIST); soft reset re-arms the witness ---"
$W $B "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo 2000000000 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo 2000000000 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x208 0x0'>\$DRA
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA
 echo '0x158 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x0'>\$DRA
 echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '  armed MODE1 ROM, fixctl=0 (no fix arms)'" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [2] lock gate ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 10
 p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
 echo \"PROBE LOCK fps=\$(( (p1-p0)/10 )) errps=\$(( (e1-e0)/10 ))\"" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [3] 65 s arm-transient wait ---"
sleep 65

log "--- [4] ${DWELL}s poll: per second, frames/err plus a full 7-stage mismatch sweep ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/stagesig.csv
 for i in \$(seq 1 $DWELL); do
   p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
   M=\"\"
   for s in 0 1 2 3 4 5 6; do
     echo \"0x208 \$(printf 0x%X \$((s<<8)))\" > \$DRA
     M=\"\$M \$((\$(rd 0x210)))\"
   done
   echo '0x208 0x0' > \$DRA
   sleep 1
   p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
   echo \"\$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF ))\$M\" >> /dev/shm/stagesig.csv
 done
 echo POLL_DONE" 2>/dev/null | tee -a "$OUT/run.log"
$W $B 'cat /dev/shm/stagesig.csv' 2>/dev/null > "$OUT/stagesig.csv"
log "  CSV $OUT/stagesig.csv ($(wc -l < "$OUT/stagesig.csv") samples)"

log "--- [R] gated link restore at the SHIPPED defaults ---"
RXM=16 RXQ=1 GATE_TRIES=12 "$D/bringup_r2r3.sh" r3 > "$OUT/restore.log" 2>&1
log "  bring-up exit=$? (log $OUT/restore.log)"
grep -E "ARM GATE" "$OUT/restore.log" | tail -2 | tee -a "$OUT/run.log"
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip 'chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'nohup /root/lock_watchdog.sh > /dev/shm/watchdog.log 2>&1 &' >/dev/null 2>&1
done
sleep 2
for ip in 10.0.0.146 10.0.0.148; do
  log "  $ip watchdog: $($W $ip 'pgrep -c -f "[l]ock_watchdog"' 2>/dev/null)  qpsk_tun: $($W $ip 'pgrep -c -x qpsk_tun' 2>/dev/null)"
done
log "=== STAGESIG_RUN_DONE $OUT ==="
