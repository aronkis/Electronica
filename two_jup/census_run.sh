#!/bin/bash
# =============================================================================
# census_run.sh -- long fixed-tap (tap 3) census on 148, mode-1 internal loopback.
#
# Purpose: settle two questions §31/§32 could not, both needing far more burst
# samples than the existing ~400s runs:
#   1. Is the burst word set really closed (union stuck at 7-8 words)?
#   2. Are ALL burst words explainable by displacement (5/8 mapped, 3 did not)?
#
# Model: two_jup/tap_run.sh (fixed-tap arming + polling) and
#        two_jup/multitap_run.sh (arm sequence, CSV shape, gated restore).
# CSV shape matches multitap.csv so score_repertoire.py can score it directly:
#   tap t frames err capTAP capIn capDeint capOut
#
# Rails (2026-08-31 overnight census task):
#   - rig mutex via agents/rigmutex.sh, held (with heartbeat) for the whole run
#   - iq_debug_mux set AFTER the 0x000 soft reset, verified against the tap-3
#     golden value 0xBCF94856 before trusting anything
#   - positive control before the long dwell: prove 0x20C can both hold golden
#     and show a non-golden value (natural burst OR deliberate tap flip)
#   - NO FLASH. Board 146 untouched except the standard two-node gated restore.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
# DWELL is an ITERATION COUNT (one iteration = 8 register reads + sleep 1),
# not seconds. Measured rate from 20260831_074947/run.log: 400 iterations in
# 416s = 1.04 s/iteration. Default 22500 iterations ~= 23,400s ~= 6.5h wall,
# comfortably >= the 5h rail with margin for analysis before 07:00 ET.
DWELL=${DWELL:-22500}
TAP=3                              # fixed for the whole run, per tap_run.sh's rule
GOLDEN=0xBCF94856
TAP0_GOLDEN=0x121D8572             # known tap-0 golden, from multitap.csv
OUT=$D/census/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/agents/rigmutex.sh"
if ! rig_acquire census_run 120; then
  echo "FAILED to acquire rig mutex (rc=$?)" | tee -a "$OUT/run.log"
  exit 1
fi
HB_PID=""
RESTORED=0
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }
do_restore(){
  [ "$RESTORED" -eq 1 ] && return 0
  RESTORED=1
  log "--- [R] gated link restore at the SHIPPED defaults ---"
  RXM=16 RXQ=1 GATE_TRIES=12 "$D/bringup_r2r3.sh" r3 > "$OUT/restore.log" 2>&1
  RC=$?
  log "  bring-up exit=$RC (log $OUT/restore.log)"
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
}
cleanup(){
  # Always restore the link before releasing the mutex, even on an early
  # abort/kill/stop -- the rig must not be left dead until 07:00.
  #
  # !!! LAUNCH THIS UNIT WITH -p TimeoutStopSec=600 !!!
  # 2026-08-31 22:10: launched WITHOUT it, so `systemctl stop` gave this
  # cleanup systemd's default 90 s. do_restore needs about that long on its
  # own (arm + up to 12 gate tries), so SIGKILL landed on bringup_r2r3.sh
  # MID-ARM and board 148 hung -- the documented image-independent no-ping
  # hang -- with nobody present to power-cycle it.
  # A cleanup that cannot finish before it is killed is not a cleanup.
  do_restore
  [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null
  rig_release
}
trap cleanup EXIT INT TERM

# background heartbeat so a 6h dwell never looks stale to another actor
( while :; do sleep 90; rig_heartbeat; done ) &
HB_PID=$!

log "=== census_run on $B tap=$TAP dwell=${DWELL}s -> $OUT ==="
rig_phase "quiesce"
log "--- [0] quiesce ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo "  quiesced"' 2>/dev/null | tee -a "$OUT/run.log"

rig_phase "arm"
log "--- [1] arm MODE 1 (internal digital loopback, ROM BIST) ---"
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
 echo '  armed MODE1 ROM, fixctl=0'" 2>/dev/null | tee -a "$OUT/run.log"

rig_phase "set_tap"
log "--- [1b] set the tap AFTER the arm (0x000 soft reset clears AXI write regs) ---"
TAPREAD=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 echo '0x10C 0x$TAP' > \$DRA; sleep 1
 echo '0x20C'>\$DRA; cat \$DRA" 2>/dev/null)
log "  tap set: iq_debug_mux=$TAP  capTAP(0x20C)=$TAPREAD"
norm(){ echo "$1" | tr -d ' \r\n' | sed -E 's/^0[xX]//' | tr 'a-f' 'A-F'; }
TAPREAD_NORM=$(norm "$TAPREAD")
GOLDEN_NORM=$(norm "$GOLDEN")
if [ "$TAPREAD_NORM" != "$GOLDEN_NORM" ]; then
  log "  !!! ABORT: 0x20C=$TAPREAD_NORM does not match tap-3 golden $GOLDEN_NORM -- tap not actually selected. Not proceeding, not flashing."
  exit 2
fi
log "  CONFIRMED on tap 3 (golden match)"

rig_phase "lock_gate"
log "--- [2] lock gate sanity ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 10
 p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
 echo \"PROBE LOCK fps=\$(( (p1-p0)/10 )) errps=\$(( (e1-e0)/10 ))\"" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [3] 65 s arm-transient wait ---"
sleep 65

rig_phase "positive_control"
log "--- [4] POSITIVE CONTROL: prove 0x20C can move before trusting any null ---"
log "  [4a] natural poll of 0x20C once/sec for 70s"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/pc.csv
 for i in \$(seq 1 70); do
   C=\$(rd 0x20C); sleep 1; echo \"\$i \$C\" >> /dev/shm/pc.csv
 done
 echo PC_DONE" 2>/dev/null | tee -a "$OUT/run.log"
$W $B 'cat /dev/shm/pc.csv' 2>/dev/null > "$OUT/positive_control.csv"
NG=$(awk -v g="$GOLDEN_NORM" '{v=toupper($2); sub(/^0X/,"",v); if (v!=g) print}' "$OUT/positive_control.csv" | wc -l)
GN=$(awk -v g="$GOLDEN_NORM" '{v=toupper($2); sub(/^0X/,"",v); if (v==g) print}' "$OUT/positive_control.csv" | wc -l)
log "  [4a] natural 70s poll: golden=$GN non-golden=$NG (see $OUT/positive_control.csv)"

log "  [4b] deliberate tap flip 3->0->3 to prove the capture path moves regardless"
FLIP=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo '0x10C 0x0' > \$DRA; sleep 1; C0=\$(rd 0x20C)
 echo '0x10C 0x3' > \$DRA; sleep 1; C3=\$(rd 0x20C)
 echo \"tap0=\$C0 tap3=\$C3\"" 2>/dev/null)
log "  [4b] flip result: $FLIP"
TAP0READ_RAW=$(echo "$FLIP" | sed -n 's/.*tap0=\(0x[0-9A-Fa-f]*\).*/\1/p')
TAP3READ_RAW=$(echo "$FLIP" | sed -n 's/.*tap3=\(0x[0-9A-Fa-f]*\).*/\1/p')
TAP0READ=$(norm "$TAP0READ_RAW")
TAP3READ2=$(norm "$TAP3READ_RAW")
TAP0_GOLDEN_NORM=$(norm "$TAP0_GOLDEN")
MOVES="no"
[ "$TAP0READ" != "$TAP3READ2" ] && MOVES="yes"
MATCHES_PREDICTED="no"
[ "$TAP0READ" = "$TAP0_GOLDEN_NORM" ] && [ "$TAP3READ2" = "$GOLDEN_NORM" ] && MATCHES_PREDICTED="yes"
log "  [4b] capture register value CHANGES with tap selection: $MOVES (tap0=$TAP0READ tap3=$TAP3READ2); matches predicted golden pair (tap0=$TAP0_GOLDEN_NORM tap3=$GOLDEN_NORM): $MATCHES_PREDICTED"
if [ "$NG" -eq 0 ] && [ "$MOVES" != "yes" ]; then
  log "  !!! ABORT: no non-golden value seen naturally AND deliberate tap flip did not move 0x20C. Instrument not proven alive. Not proceeding."
  exit 3
fi
log "  POSITIVE CONTROL PASS: capture register proven capable of a non-null (natural nongold=$NG, or deliberate-flip moves=$MOVES)"

rig_phase "dwell"
log "--- [5] restore tap 3 for the long dwell and re-verify golden ---"
# A SINGLE read cannot decide this. During a burst the capture legitimately
# reads non-golden -- that IS the phenomenon under study -- so a one-shot
# equality check calls the experiment broken every time it samples the thing it
# exists to measure. Bursts last ~6 s at a ~5 % duty cycle, so sample across a
# window LONGER than a burst and take the mode, which is the same
# golden-constancy logic used everywhere else in this campaign.
# The first run of this script aborted here on exactly that false alarm, with
# the board healthy (ARM GATE PASS, 1245 f/s) and tap 3 verified moments before.
RECHECK_N=${RECHECK_N:-15}
RECHECK_GAP=${RECHECK_GAP:-2}
# Normalise EVERY sample with norm(), the same helper the rest of the script
# uses. Revision 1 compared a raw "0xBCF94856" against GOLDEN_NORM's stripped
# "BCF94856" and aborted reporting "modal ... is 0xBCF94856, not golden
# BCF94856" -- the values were identical and only the 0x prefix differed. The
# abort text printing two strings that look equal is what gave it away; a check
# that can fail on formatting must print what it actually compared.
# norm() ends with `tr -d ' \r\n'`, so it emits NO trailing newline -- calling it
# in a loop concatenates every sample into one string and the mode is garbage.
# printf '%s\n' restores the separator. Both of these were caught offline,
# before spending rig time, by running the comparison on synthetic samples.
TAPSAMPLES=$($W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 echo '0x10C 0x3' > \$DRA; sleep 1
 for k in \$(seq 1 $RECHECK_N); do echo '0x20C'>\$DRA; cat \$DRA; sleep $RECHECK_GAP; done" \
 2>/dev/null | while read -r ln; do [ -n "$ln" ] && printf '%s\n' "$(norm "$ln")"; done)
MODE=$(printf '%s\n' "$TAPSAMPLES" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
NGOLD=$(printf '%s\n' "$TAPSAMPLES" | grep -c "^${GOLDEN_NORM}$" || true)
log "  re-armed tap 3: $RECHECK_N samples over $((RECHECK_N*RECHECK_GAP))s, modal=$MODE, golden hits=$NGOLD"
if [ "$MODE" != "$GOLDEN_NORM" ]; then
  log "  !!! ABORT: modal capTAP over $((RECHECK_N*RECHECK_GAP))s is [$MODE], golden is [$GOLDEN_NORM] (bracketed to expose whitespace/prefix)."
  log "  !!! That is not a burst -- a burst moves a minority of samples. Not proceeding."
  exit 4
fi

log "--- [6] ${DWELL}s poll (tap 3 fixed): per second, sweep cap_in/cap_deint/cap_out and capTAP ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/census.csv
 for i in \$(seq 1 $DWELL); do
   p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
   CT=\$(rd 0x20C); CI=\$(rd 0x13C); CD=\$(rd 0x140); CO=\$(rd 0x144)
   sleep 1
   p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
   echo \"$TAP \$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF )) \$CT \$CI \$CD \$CO\" >> /dev/shm/census.csv
   if [ \$(( i % 300 )) -eq 0 ]; then echo \"  progress i=\$i\" ; fi
 done
 echo CENSUS_DONE" 2>/dev/null | tee -a "$OUT/run.log"
$W $B 'cat /dev/shm/census.csv' 2>/dev/null > "$OUT/census.csv"
log "  CSV $OUT/census.csv ($(wc -l < "$OUT/census.csv") samples)"

rig_phase "restore"
do_restore
log "=== CENSUS_RUN_DONE $OUT ==="
