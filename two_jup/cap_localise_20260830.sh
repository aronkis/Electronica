#!/bin/bash
# =============================================================================
# cap_localise_20260830.sh -- WHERE DO THE ERRORS FIRST APPEAR?
#
# Follow-on to mode2_startcnt_20260830.sh, which established that the control
# path is clean (1.0000 startIn/vitReset/startOut per frame through 801k bit
# errors). That leaves the data path, and every error number this campaign has
# is measured POST-Viterbi (the BIST comparator taps RxAlign dataOut/validOut).
#
# FecCapture (inside FEC_Decoder_Wrapper) already carries three per-frame
# snapshots, each re-armed at startIn, each holding the first 32 bits:
#   0x13C cap_in     bitsIn      -- coded bits from the DEMOD  (pre-deint, pre-Viterbi)
#   0x140 cap_deint  codedPair   -- out of the DEINTERLEAVER   (pre-Viterbi)
#   0x144 cap_out    decBit      -- decoded output             (POST-Viterbi; golden 0x04922282)
# Present in the flashed image 786dce9fafc8. No build, no flash.
#
# PRE-REGISTERED:
#   C1 self-test: in QUIET seconds all three caps must be ~100% constant. If any
#      tap is not constant when the link is clean, STOP -- the golden assumption
#      is wrong and no burst result may be interpreted.
#   C2 localisation, during a burst:
#      cap_in deviates                      -> errors ALREADY in the demod output;
#                                              FEC decoder is a victim, fault UPSTREAM.
#      cap_in golden, cap_deint deviates    -> the DEINTERLEAVER corrupts it.
#      cap_in+cap_deint golden, cap_out dev -> the VITERBI misdecodes correct input.
#      all three golden through a burst     -> the damage is outside the first 32 bits
#                                              of the frame; report that, do not force
#                                              a verdict.
#
# LIMITATION, stated before the run: these are snapshots, not counters. 1 Hz
# sampling sees one frame in ~1246. That is fine for a BURST (near-100% duty) and
# USELESS for the 0.09% quiet floor -- this run localises the burst only.
#
# 148 only. 146 is addressed solely by the standard gated restore at the end.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
DWELL=${DWELL:-400}
OUT=$D/caploc/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/sim_repro/riglock.sh"
rig_lock cap_localise
trap 'rig_unlock' EXIT

log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== cap_localise on $B -> $OUT (DWELL=${DWELL}s) ==="
log "--- [0] quiesce 148 ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced"' 2>/dev/null | tee -a "$OUT/run.log"

log "--- [1] arm mode 1 (internal digital loopback, ROM BIST) ---"
$W $B "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo 2000000000 > \$P/out_altvoltage2_TX1_LO_frequency; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo 2000000000 > \$P/out_altvoltage0_RX1_LO_frequency; echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA
 echo '0x158 0x0'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x0'>\$DRA
 echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '  armed MODE1 (ROM, internal digital loopback)'" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [2] lock gate + first cap read ---"
sleep 6
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo "$1">$DRA; cat $DRA; }
 p0=$(($(rd 0x104))); e0=$(($(rd 0x108))); sleep 10
 p1=$(($(rd 0x104))); e1=$(($(rd 0x108)))
 echo "PROBE LOCK fps=$(( (p1-p0)/10 )) errps=$(( (e1-e0)/10 )) capIn=$(rd 0x13C) capDeint=$(rd 0x140) capOut=$(rd 0x144)"' 2>/dev/null | tee -a "$OUT/run.log"

log "--- [3] 65 s arm-transient wait ---"
sleep 65

log "--- [4] ${DWELL}s poll at 1 Hz: frames err capIn capDeint capOut ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/caploc.csv
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
 for i in \$(seq 1 $DWELL); do
   sleep 1
   ci=\$(rd 0x13C); cd=\$(rd 0x140); co=\$(rd 0x144)
   p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
   echo \"\$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF )) \$ci \$cd \$co\" >> /dev/shm/caploc.csv
   p0=\$p1; e0=\$e1
 done
 echo POLL_DONE" 2>/dev/null | tee -a "$OUT/run.log"
$W $B 'cat /dev/shm/caploc.csv' 2>/dev/null > "$OUT/caploc.csv"
log "  CSV $OUT/caploc.csv ($(wc -l < "$OUT/caploc.csv") samples)"

log "--- [R1] gated link restore at the SHIPPED defaults ---"
RXM=16 RXQ=1 GATE_TRIES=12 "$D/bringup_r2r3.sh" r3 > "$OUT/restore.log" 2>&1
log "  bring-up exit=$? (log $OUT/restore.log)"
grep -E "ARM GATE|gate try" "$OUT/restore.log" | tail -3 | tee -a "$OUT/run.log"
log "--- [R2] restart lock_watchdog on both boards ---"
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip 'chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'nohup /root/lock_watchdog.sh > /dev/shm/watchdog.log 2>&1 &' >/dev/null 2>&1
done
sleep 2
for ip in 10.0.0.146 10.0.0.148; do
  log "  $ip watchdog: $($W $ip 'pgrep -c -f "[l]ock_watchdog"' 2>/dev/null)  qpsk_tun: $($W $ip 'pgrep -c -x qpsk_tun' 2>/dev/null)"
done
log "=== CAP_LOCALISE_DONE $OUT ==="
