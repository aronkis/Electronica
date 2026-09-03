#!/bin/bash
# =============================================================================
# mode2_startcnt_20260830.sh -- ONE rig session on 148 only, NO FLASH, covering
# the two authorised priorities in the same quiesce:
#
#   LEG A  mode 1 (FPGA-internal digital loopback, 0x114=0), ROM BIST
#   LEG B  mode 2 (ADRV9002 SSI near-end loopback, NEL on + 0x114=1), ROM BIST
#
# In BOTH legs we log, at 1 Hz:
#   0x104 packets_out       (frames)
#   0x108 bit_errors_out    (the beat / floor instrument)
#   0x124 cnt_frame_start   (FecCounters e2 = FEC decoder startIn)  <-- START COUNTER
#   0x128 cnt_vit_reset     (FecCounters e3 = Viterbi reset)
#   0x130 cnt_dec_bits      (FecCounters e5 = decoder validOut)
#   0x134 cnt_bist_start    (FecCounters e6 = decoder startOut)  <-- AFTER the decoder
#
# 0x124 / 0x128 / 0x134 bracket BOTH boundaries under investigation:
#   0x124 startIn   -- after the demod, INTO the FEC decoder
#   0x128 vitReset  -- the trellis reset itself
#   0x134 startOut  -- OUT of the decoder (RxAlign output)
# Discrimination through a burst:
#   startIn ->2 and vitReset ->2 : spurious start arrives from the demod side and
#                                  restarts the trellis. CONFIRMED, localised UPSTREAM.
#   startIn  =1 and vitReset ->2 : restart generated INSIDE the decoder; demod innocent.
#   startIn ->2 and vitReset  =1 : extra start absorbed; damage is elsewhere.
#   all three stay 1 through a full-magnitude burst : MODEL DEAD (falsifier).
#
# 0x124 is the pre-registered silicon start-pulse instrument. It is ALREADY in the
# flashed image 786dce9fafc8 (jupiter_byte_pdwit_build produced that md5), so this
# test needs no build and no flash.
#
# PRE-REGISTERED (do not reinterpret after the fact):
#   S1 counter self-test: healthy => d0x124 / d0x104 == 1.00 per second.
#      If it is any other constant, STOP -- do not interpret burst data.
#   S2 prediction: during a beat burst the ratio rises to ~2 starts/frame.
#   S3 FALSIFIER: if the ratio stays 1.00 straight through a full-magnitude burst
#      (d0x108 >> 200/s), the spurious-start model is WRONG and is reported DEAD.
#   M1 mode-2 floor: quiet-second err/s comparable to mode 1 => comb absent on the
#      SSI path too. A comb-scale defect would be orders of magnitude above it.
#
# SENTINEL: rig_lock writes SENTINEL_STOP, which makes the running sentinel exit.
# rig_unlock (on the EXIT trap) removes both files, and sentinelkeeper-*.service
# relaunches the sentinel within 2 min. Nothing extra to do -- verified 2026-08-30.
#
# RAILS: rig lock (single actor), 148 only, 146 never addressed except by the
# standard gated link restore at the end. Positive control in each leg proves the
# loop is real before any null result is allowed to mean anything.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
B=10.0.0.148
PROF=lvds_61p44_fdd_jupiter
DWELL=${DWELL:-400}
OUT=$D/startcnt/$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"

. "$D/sim_repro/riglock.sh"
rig_lock mode2_startcnt
trap 'rig_unlock' EXIT

log(){ echo "$(date +%T) $*" | tee -a "$OUT/run.log"; }

log "=== mode2_startcnt on $B -> $OUT (DWELL=${DWELL}s per leg) ==="
log "--- [0] quiesce 148 (daemon + watchdog) ---"
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; pkill -x qpsk_tun 2>/dev/null; sleep 1
  echo "  quiesced (qpsk_tun left: $(pgrep -c -x qpsk_tun 2>/dev/null || echo 0))"' 2>/dev/null | tee -a "$OUT/run.log"

# ---- device-name probe: the layerA_ssi_nel.sh harness looks for
#      axi-adrv9001-tx-lpc while every other script uses axi-adrv9002-tx-lpc.
#      Record which is real rather than blind-fixing it.
log "--- [0b] device-name + NEL-attribute probe (instrument before interpreting) ---"
$W $B 'for d in /sys/bus/iio/devices/iio:device*; do n=$(cat $d/name 2>/dev/null); echo "  $d name=$n"; done
  echo "  NEL attr holders:"; for d in /sys/kernel/debug/iio/iio:device*; do
    [ -f $d/rx0_near_end_loopback ] && echo "    $d"; done' 2>/dev/null | tee -a "$OUT/run.log"

# ---------------------------------------------------------------- arm helpers
# mode 1 arm: full profile reload + ROM BIST + internal digital loopback.
# Idiom copied verbatim from loopback_soak.sh (the script every prior burst
# measurement used), so the numbers are directly comparable.
arm_mode1(){
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
 echo '  armed MODE1 (0x114=0 internal digital, ROM)'" 2>/dev/null | tee -a "$OUT/run.log"
}

# register-only re-arm; $1 = tx_data_source, $2 = rx_input_select
rearm(){
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA; sleep 0.5; echo '0x000 0x0'>\$DRA
 echo '0x158 0x$1'>\$DRA; echo '0x118 0x0'>\$DRA; echo '0x114 0x$2'>\$DRA
 echo '0x110 0x1'>\$DRA; sleep 0.3; echo '0x110 0x0'>\$DRA
 echo '  re-armed 0x158=$1 0x114=$2'" 2>/dev/null | tee -a "$OUT/run.log"
}

nel(){ # $1 = 1 on / 0 off
  $W $B "PHY=\$(for d in /sys/kernel/debug/iio/iio:device*; do
     [ -f \$d/rx0_near_end_loopback ] && echo \$d; done | head -1)
   [ -z \"\$PHY\" ] && { echo '  NEL_ATTR_MISSING'; exit 1; }
   echo $1 > \$PHY/rx0_near_end_loopback; echo $1 > \$PHY/rx1_near_end_loopback
   echo \"  NEL=$1 (\$PHY) readback rx0='\$(cat \$PHY/rx0_near_end_loopback 2>/dev/null)'\"" 2>/dev/null | tee -a "$OUT/run.log"
}

# short probe: $1 dwell, $2 label -> frames/s, err/s, starts/s, starts-per-frame
probe(){
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); s0=\$((\$(rd 0x124))); v0=\$((\$(rd 0x128))); o0=\$((\$(rd 0x134)))
 sleep $1
 p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108))); s1=\$((\$(rd 0x124))); v1=\$((\$(rd 0x128))); o1=\$((\$(rd 0x134)))
 dp=\$(( (p1-p0) & 0xFFFFFFFF )); de=\$(( (e1-e0) & 0xFFFFFFFF ))
 ds=\$(( (s1-s0) & 0xFFFFFFFF )); dv=\$(( (v1-v0) & 0xFFFFFFFF )); do_=\$(( (o1-o0) & 0xFFFFFFFF ))
 echo \"PROBE $2 dwell=$1 dframes=\$dp derr=\$de dstartIn=\$ds dvitrst=\$dv dstartOut=\$do_ fps=\$((dp/$1)) errps=\$((de/$1))\"" 2>/dev/null | tee -a "$OUT/run.log"
}

# 1 Hz poll for $1 seconds -> csv "t frames err startIn vitrst decbits startOut"
poll(){ # $1 secs, $2 outfile
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
 echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
 rd(){ echo \"\$1\">\$DRA; cat \$DRA; }
 : > /dev/shm/startcnt.csv
 p0=\$((\$(rd 0x104))); e0=\$((\$(rd 0x108))); s0=\$((\$(rd 0x124))); v0=\$((\$(rd 0x128))); b0=\$((\$(rd 0x130))); o0=\$((\$(rd 0x134)))
 for i in \$(seq 1 $1); do
   sleep 1
   p1=\$((\$(rd 0x104))); e1=\$((\$(rd 0x108))); s1=\$((\$(rd 0x124))); v1=\$((\$(rd 0x128))); b1=\$((\$(rd 0x130))); o1=\$((\$(rd 0x134)))
   echo \"\$i \$(( (p1-p0)&0xFFFFFFFF )) \$(( (e1-e0)&0xFFFFFFFF )) \$(( (s1-s0)&0xFFFFFFFF )) \$(( (v1-v0)&0xFFFFFFFF )) \$(( (b1-b0)&0xFFFFFFFF )) \$(( (o1-o0)&0xFFFFFFFF ))\" >> /dev/shm/startcnt.csv
   p0=\$p1; e0=\$e1; s0=\$s1; v0=\$v1; b0=\$b1; o0=\$o1
 done
 echo POLL_DONE" 2>/dev/null | tee -a "$OUT/run.log"
  $W $B 'cat /dev/shm/startcnt.csv' 2>/dev/null > "$2"
  log "  CSV $2 ($(wc -l < "$2") samples)"
}

# ============================================================== LEG A: mode 1
log "--- [A1] arm mode 1 (internal digital loopback, ROM BIST) ---"
arm_mode1
sleep 6
log "--- [A2] lock gate ---"
probe 10 A_LOCK
log "--- [A3] POSITIVE CONTROL: 0x158=1 byte source with no daemon => errors must go HIGH ---"
rearm 1 0
sleep 4
probe 12 A_CTRL_HIGH
log "--- [A4] back to ROM + 65 s arm-transient wait ---"
rearm 0 0
sleep 65
log "--- [A5] ${DWELL}s poll at 1 Hz ---"
poll "$DWELL" "$OUT/mode1.csv"

# ============================================================== LEG B: mode 2
log "--- [B1] enable ADRV9002 SSI near-end loopback ---"
nel 1
log "--- [B2] arm mode 2 (NEL on, 0x114=1 SSI RX, ROM BIST) ---"
rearm 0 1
sleep 6
log "--- [B3] lock gate (NEL path lock is NOT guaranteed) ---"
probe 10 B_LOCK
BFPS=$(grep "PROBE B_LOCK" "$OUT/run.log" | tail -1 | grep -oE "fps=[0-9]+" | tr -dc 0-9)
if [ "${BFPS:-0}" -eq 0 ]; then
  log "  NEL_NO_LOCK: demod does not lock on the SSI near-end path -- LEG B ABORTED (not a null result)"
else
  log "--- [B4] POSITIVE CONTROL: 0x158=1 => must go HIGH, proving RX tracks 148's OWN TX (not 146 air) ---"
  rearm 1 1
  sleep 4
  probe 12 B_CTRL_HIGH
  log "--- [B5] back to ROM + 65 s arm-transient wait ---"
  rearm 0 1
  sleep 65
  log "--- [B6] ${DWELL}s poll at 1 Hz ---"
  poll "$DWELL" "$OUT/mode2.csv"
fi

# ================================================================== restore
log "--- [R1] NEL off ---"
nel 0
log "--- [R2] gated link restore: bringup_r2r3.sh r3 at the SHIPPED defaults ---"
# bringup_r2r3.sh defaults ARE the shipped set (RXQ=1, LO_A_RX +20k, LO_B_RX +40k).
# NOT restore_known_good.sh: that one pins LO_B_RX=1900020000 (+20k), the stale and
# measurably worse reverse setting (1.99% vs 1.39%).
RXM=16 RXQ=1 GATE_TRIES=12 "$D/bringup_r2r3.sh" r3 > "$OUT/restore.log" 2>&1
log "  bring-up exit=$? (log $OUT/restore.log)"
grep -E "ARM GATE|BRING-UP COMPLETE|gate try" "$OUT/restore.log" | tail -4 | tee -a "$OUT/run.log"
log "--- [R3] restart lock_watchdog on both boards (isolated calls, then verify) ---"
for ip in 10.0.0.146 10.0.0.148; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip 'chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'nohup /root/lock_watchdog.sh > /dev/shm/watchdog.log 2>&1 &' >/dev/null 2>&1
done
sleep 2
for ip in 10.0.0.146 10.0.0.148; do
  log "  $ip watchdog pids: $($W $ip 'pgrep -c -f "[l]ock_watchdog"' 2>/dev/null)  qpsk_tun: $($W $ip 'pgrep -c -x qpsk_tun' 2>/dev/null)"
done
log "=== MODE2_STARTCNT_DONE $OUT ==="
