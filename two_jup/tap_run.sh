#!/bin/bash
# =============================================================================
# dbgcap_run.sh -- systematic per-stage sweep on 148, mode-1 internal loopback.
#
# Reads the frame-anchored decision captures added by dbgcap_inject.py (and, if
# the image also carries txcap_inject.py, the transmitter capture):
#   iq_debug_mux 0x10C selects the RX stage:
#       0 AGC out | 1 postSymbolSync | 2 postCarrierSync | 3 QPSKConstellation
#   fixctl bit12 = 1 selects TXCAP (the transmitter, TX-anchored) instead
#   0x20C = last frame's 32-bit hard-decision capture
#   0x210 = MISMATCH COUNT vs the frame-8 reference (accumulating)
#
# Also logs the FecCapture snapshots that are already proven on silicon, so the
# whole chain is covered in one run:
#   0x13C cap_in (demod out / FEC in) | 0x140 cap_deint | 0x144 cap_out
#
# POSITIVE CONTROL (standing rule, section 0): before any null is credited, the
# witness must be shown able to move. Phase [PC] parks on tap 3 and confirms the
# mismatch counter is FLAT, then switches to tap 0 and confirms it CLIMBS. Flat-
# then-climbing proves both halves: quiet when it should be, moving when it must.
# A counter that stays flat across the switch is DEAD and every null it produced
# is void -- that is exactly how the section 20 result was lost.
# 0x20C (the capture itself) is logged alongside 0x210 (the counter): a capture
# reading zero is a dead block on its face.
#
# PRE-REGISTERED, per witness:
#   H1 coverage gate: a witness whose mismatch delta is NONZERO in QUIET seconds
#      is UNCOVERED on hardware. Report it as such; never interpret its burst
#      numbers. (This is what killed the stage-signature instrument twice.)
#   H2 localisation: among witnesses that PASS H1, the FIRST one along the chain
#      whose mismatch delta rises during bursts is where the error first appears.
#      Chain order: TXCAP -> AGC -> postSymbolSync -> postCarrierSync ->
#                   QPSKConstellation -> cap_in -> cap_deint -> cap_out
#   H3 TX verdict: TXCAP flat through a full-magnitude burst => transmitter
#      output bit-identical every frame => TX EXONERATED on silicon.
#      TXCAP climbing => TX is the source.
#
# 148 only. 146 addressed solely by the standard gated restore.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
DWELL=${DWELL:-400}
HAVE_TXCAP=${HAVE_TXCAP:-1}
TAP=${TAP:-3}                     # FIXED for the whole run (see section 23): the reference dcref is
                                  # latched at frame 8 against whatever tap is selected THEN, so the
                                  # tap is set before the soft reset and never touched during the poll.
                                  # Sweeping it mid-run makes the DBGCAP counter meaningless.
                                  # latched once at frame 8 against whatever tap is selected THEN, so the
                                  # tap must be set before the soft reset and never touched during the
                                  # poll. Sweeping it mid-run makes the DBGCAP counter meaningless.
OUT=$D/tap/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/sim_repro/riglock.sh"
rig_lock tap_run
trap 'rig_unlock' EXIT
log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== dbgcap_run on $B (HAVE_TXCAP=$HAVE_TXCAP) -> $OUT ==="
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
 echo '  armed MODE1 ROM, fixctl=0, iq_debug_mux=$TAP (FIXED for this run)'" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [1b] set the tap AFTER the arm: the 0x000 soft reset clears the AXI write registers, so a
#          pre-reset write is wiped (proved by capTAP reading tap-0's pattern all through 20260831_071043) ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 echo '0x10C 0x$TAP' > \$DRA; sleep 1
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 echo \"  tap set: iq_debug_mux=$TAP  capTAP(0x20C)=\$(rd 0x20C)\"" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [2] lock gate ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); sleep 10
 p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
 echo \"PROBE LOCK fps=\$(( (p1-p0)/10 )) errps=\$(( (e1-e0)/10 ))\"" 2>/dev/null | tee -a "$OUT/run.log"

log "--- [3] 65 s arm-transient wait ---"
sleep 65

# CSV columns: t frames err  mmTX mmDEMOD mmTAP  capIn capDeint capOut  capTAP

log "--- [4] ${DWELL}s poll: per second, sweep every witness ---"
$W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/tap.csv
 for i in \$(seq 1 $DWELL); do
   p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108)))
   if [ $HAVE_TXCAP -eq 1 ]; then
     echo '0x208 0x1000' > \$DRA; TXM=\$((\$(rd 0x210)))
   else
     TXM=0
   fi
   echo '0x208 0x0' > \$DRA
   M=\" \$((\$(rd 0x210)))\"; C=\" \$(rd 0x20C)\"
   echo '0x208 0x2000' > \$DRA; DM=\$((\$(rd 0x210)))
   echo '0x208 0x0' > \$DRA
   CI=\$(rd 0x13C); CD=\$(rd 0x140); CO=\$(rd 0x144)
   sleep 1
   p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108)))
   echo \"\$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF )) \$TXM \$DM\$M \$CI \$CD \$CO\$C\" >> /dev/shm/tap.csv
 done
 echo POLL_DONE" 2>/dev/null | tee -a "$OUT/run.log"
$W $B 'cat /dev/shm/tap.csv' 2>/dev/null > "$OUT/tap.csv"
log "  CSV $OUT/dbgcap.csv ($(wc -l < "$OUT/tap.csv") samples)"

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
log "=== TAP_RUN_DONE $OUT ==="
