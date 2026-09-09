#!/bin/bash
# =============================================================================
# multitap_run.sh -- capTAP golden-constancy for every RX stage, one rig session.
#
# Scores the CAPTURE register (0x20C) by golden-constancy, exactly the way
# cap_in/cap_deint/cap_out have been scored all along. Deliberately does NOT use
# the on-chip mismatch counter (0x210), because that instrument has two faults
# established on 2026-08-31:
#   (1) the 0x000 soft reset clears the AXI write registers, so a tap selected
#       before the reset is wiped -- run 20260831_071043 read tap 0's pattern
#       throughout while believing it was on tap 3;
#   (2) the reference is latched at frame 8, ~6 ms after reset, while the loops
#       are still acquiring, so it is a bad baseline -- DEMODCAP showed 3.45
#       mismatches/s in quiet while cap_in, the SAME bits scored by golden-
#       constancy, was 100 % golden.
# Golden-constancy needs no reference latch and no reset ordering: the golden is
# the modal value of that tap's own quiet samples.
#
# iq_debug_mux (0x10C), set AFTER the arm and held for a full dwell per tap:
#   0 AGC out | 1 postSymbolSync | 2 postCarrierSync | 3 QPSKConstellation
#
# PRE-REGISTERED:
#   K1 coverage: a tap whose capture is <99 % golden in QUIET seconds is
#      UNCOVERED (not frame-invariant on hardware); its burst number is void.
#   K2 localisation: among covered taps, the FIRST in chain order
#      (AGC -> postSymbolSync -> postCarrierSync -> constellation -> cap_in)
#      whose golden fraction DROPS during bursts is where the error first appears.
#   K3 if every covered tap holds golden through bursts while cap_in drops, the
#      error enters at or after the demodulator's slice/serialise path.
#
# 148 only; 146 addressed solely by the standard gated restore.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
DWELL=${DWELL:-400}
TAPS=${TAPS:-"0 1 2 3"}
OUT=$D/multitap/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/sim_repro/riglock.sh"
rig_lock multitap_run
trap 'rig_unlock' EXIT
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== multitap_run on $B taps='$TAPS' dwell=${DWELL}s -> $OUT ==="
log "--- [0] quiesce ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1; echo "  quiesced"' 2>/dev/null | tee -a "$OUT/run.log"

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

log "--- [2] lock gate + 65 s arm-transient wait ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 10
 p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
 echo \"PROBE LOCK fps=\$(( (p1-p0)/10 )) errps=\$(( (e1-e0)/10 ))\"" 2>/dev/null | tee -a "$OUT/run.log"
sleep 65

# CSV columns: tap t frames err capTAP capIn capDeint capOut
: > "$OUT/multitap.csv"
for T in $TAPS; do
  log "--- [tap $T] set iq_debug_mux AFTER the arm, hold for ${DWELL}s ---"
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
   echo '0x10C 0x$T' > \$DRA; sleep 2
   echo \"  tap $T selected, capTAP=\$(rd 0x20C)\"" 2>/dev/null | tee -a "$OUT/run.log"
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
   echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
   rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
   : > /dev/shm/mt.csv
   for i in \$(seq 1 $DWELL); do
     p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
     CT=\$(rd 0x20C); CI=\$(rd 0x13C); CD=\$(rd 0x140); CO=\$(rd 0x144)
     sleep 1
     p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
     echo \"$T \$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF )) \$CT \$CI \$CD \$CO\" >> /dev/shm/mt.csv
   done
   echo TAP_${T}_DONE" 2>/dev/null | tee -a "$OUT/run.log"
  $W $B 'cat /dev/shm/mt.csv' 2>/dev/null >> "$OUT/multitap.csv"
  log "  tap $T collected ($(wc -l < "$OUT/multitap.csv") rows total)"
done

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
log "=== MULTITAP_RUN_DONE $OUT ==="
