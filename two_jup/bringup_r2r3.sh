#!/bin/bash
# =============================================================================
# bringup_r2r3.sh <r2|r3> -- bring up the bidirectional f1536 FDD link at the
# R2 (30.72 MSPS / 7.68 Msym/s) or R3 (61.44 / 15.36) rung with every hard-won
# discipline baked in:
#
#  1. CFO POLICY (task-TXCHAR2): the fabric demod has a DEAD ZONE at residual
#     CFO ~= 0 (CFC near-zero dither; 0x154 sign-flips, sync collapses to ~40%).
#     * R0 (240 ksym legacy): CFO NULL REQUIRED (146 RX LO 1900004861) -- the
#       rxfix-era CFO-step storms return without it. (link_test_f1536.sh path.)
#     * R2/R3 (7680/15360 ksym): the null is FATAL. Deliberate offset required
#       on BOTH RX residuals:
#         146 RX LO 1900002500  (+2.4 kHz residual; proven full-rate set:
#                                +/-2.4k..+/-20k all clean)
#         148 RX LO 2000000000  (plain; XO offset leaves -5.15 kHz residual)
#       AVOID 146 RX LO 1900000000 (+4.86 kHz) -- measured BISTABLE.
#  2. SSI delay overrides via the SAFE cache protocol (apply_146_ssi_fix.sh,
#     task-STOCKSSI): 146 tx0 c3d4 at every rate (tuner picks a PRBS-clean
#     mission-bad row); 148 tx0 = tuner at R2 (pristine, TXCHAR2), c5d3 at R3
#     (eye-map pick).
#  3. ARM-QUALITY GATE (TXCHAR2 3/3 fresh-arm ROM probe): after arming, both
#     boards radiate ROM (0x158=0) and BOTH RX sides must decode >= GATE_FPS
#     within the probe window; otherwise auto re-arm (up to GATE_TRIES). Kills
#     the arm-order lottery. Only then switch to byte source + start daemons.
#  4. Host daemons: paced qpsk_tun -G -M 32 -r <ksym> (e50f88c pacing floor);
#     -s 5 stats for measurement fidelity; tun0 MTU 1516.
#
# Usage: bringup_r2r3.sh r2      (lvds_30p72_fdd_jupiter, -r 7680, ~623 f/s)
#        bringup_r2r3.sh r3      (lvds_61p44_fdd_jupiter, -r 15360, ~1245 f/s)
# Env:   GATE_FPS (default 90% of rate), GATE_TRIES=6, WHITEN=0
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146; TA=10.66.0.2; TB=10.66.0.1
RUNG=${1:?usage: bringup_r2r3.sh r2|r3}
case "$RUNG" in
  r2) PROF=lvds_30p72_fdd_jupiter; KSYM=7680;  FPS=623;  SSI148="";     ;;
  r3) PROF=lvds_61p44_fdd_jupiter; KSYM=15360; FPS=1245; SSI148="5 3";  ;;
  *) echo "unknown rung '$RUNG'" >&2; exit 2;;
esac
GATE_FPS=${GATE_FPS:-$(( FPS * 90 / 100 ))}
GATE_TRIES=${GATE_TRIES:-6}
WHITEN=${WHITEN:-0}
# CFO policy (see header): R2/R3 offsets, never the null
LO_B_TX=2000000000; LO_B_RX=1900002500     # 146: Tx fwd 2.0 GHz, Rx rev +2.4k off-null
LO_A_TX=1900000000; LO_A_RX=2000000000     # 148: Tx rev 1.9 GHz, Rx fwd plain (-5.15k residual)

# ---- radio arm (profile + LOs + regfile), ROM source, NO daemon yet ---------
arm_rom(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null; sleep 0.5
 cat /root/$PROF.bin > \$P/stream_config 2>/dev/null; cat /root/$PROF.json > \$P/profile_config 2>/dev/null; sleep 2
 echo calibrated > \$P/out_voltage1_ensm_mode 2>/dev/null; echo calibrated > \$P/in_voltage1_ensm_mode 2>/dev/null
 for g in 4 5 6 7; do echo 1 > \$DB/agpio\${g}_direction; echo 1 > \$DB/agpio\${g}_value; done; echo tx_a > \$P/out_voltage0_port_select
 echo $2 > \$P/out_altvoltage2_TX1_LO_frequency 2>&1; echo 0 > \$P/out_voltage0_hardwaregain; echo rf_enabled > \$P/out_voltage0_ensm_mode
 echo calibrated > \$P/in_voltage0_ensm_mode 2>/dev/null; echo $3 > \$P/out_altvoltage0_RX1_LO_frequency 2>&1
 echo rf_enabled > \$P/in_voltage0_ensm_mode; echo automatic > \$P/in_voltage0_gain_control_mode
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo '0x000 0x1'>\$DRA;sleep 0.5;echo '0x000 0x0'>\$DRA;echo '0x158 0x0'>\$DRA;echo '0x118 0x0'>\$DRA;echo '0x114 0x1'>\$DRA
 TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done);T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
 echo '0x418 0x2'>\$T;echo '0x458 0x2'>\$T;echo '0x044 0x1'>\$T;echo '0x110 0x1'>\$DRA;sleep 0.3;echo '0x110 0x0'>\$DRA
 echo '$1 armed ROM ($PROF)'" 2>/dev/null
}
# ---- ROM re-arm only (no profile reload; for gate retries) ------------------
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
# ---- ROM probe: RX pkts/s over 5 s ------------------------------------------
probe(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); echo $(( (p1 - p0) / 5 ))' 2>/dev/null; }

echo "=== $RUNG bring-up: $PROF, -r $KSYM, gate >= ${GATE_FPS} f/s ==="
arm_rom $B $LO_B_TX $LO_B_RX &
arm_rom $A $LO_A_TX $LO_A_RX &
wait
# SSI overrides (safe protocol; leaves boards armed ROM via AIR=1 re-arm inside)
SSI158="$($D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1)"; echo "146: $SSI158"
if [ -n "$SSI148" ]; then
  set -- $SSI148
  R148="$(FORCE=1 $D/apply_146_ssi_fix.sh $A $1 $2 2>&1 | tail -1)"; echo "148: $R148"
fi
# the fix re-arms with 0x158=1 (byte); put both back on ROM for the gate.
# DOUBLE-TAP (task-ARMCAUSE): a demod whose 0x000 reset lands while the peer
# radiates garbage/stale-byte/nothing LATCHES a false FTS state (~40% sync,
# 0x154 dither, rstcs calm) that 0x110 cannot clear -- this was the entire
# arm lottery (X1: degraded side follows re-arm order 6/6; X2: double-tap
# 14/14 clean). First tap gets both TX streams clean ROM; second tap re-rolls
# both demods against clean peers.
rearm_rom $B; rearm_rom $A
sleep 3
rearm_rom $B; rearm_rom $A

# ---- arm-quality gate -------------------------------------------------------
try=1; PASS=0
while [ $try -le $GATE_TRIES ]; do
  sleep 4
  FA=$(probe $A); FB=$(probe $B)
  echo "gate try $try: 148 rx=${FA:-0} f/s  146 rx=${FB:-0} f/s (need >= $GATE_FPS)"
  if [ "${FA:-0}" -ge "$GATE_FPS" ] && [ "${FB:-0}" -ge "$GATE_FPS" ]; then PASS=1; break; fi
  rearm_rom $B; rearm_rom $A
  sleep 3
  rearm_rom $B; rearm_rom $A     # double-tap (ARMCAUSE): re-roll against clean peers
  try=$(( try + 1 ))
done
[ $PASS = 1 ] || { echo "ARM GATE FAILED after $GATE_TRIES tries -- NOT starting daemons"; exit 1; }
echo "ARM GATE PASS (try $try)"

# ---- daemons FIRST (stream pumping), THEN byte-source re-arm ---------------
# ORDER MATTERS (R2FINISH finding): flipping 0x158=1 before the daemon's TX
# stream is flowing starts the modulator on an underrunning byte FIFO -> the
# discontinuous stream is demod-hostile at R2 (both dirs 0% while ROM is
# clean). Start the daemon under ROM (its DMA feed queues), let it pump, then
# full re-arm to byte with the stream already continuous: measured flip from
# 0%/0% to 551/602 f/s the moment this ordering was used.
start_daemon(){ # $1 ip $2 tunaddr $3 peer
  $W $1 "cd /root/host_app_k5; QPSK_WHITEN=$WHITEN setsid chrt -f 50 ./qpsk_tun -G -M 32 -r $KSYM -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $2 peer $3 dev tun0; ip link set tun0 up mtu 1516; ip route replace $3 dev tun0 advmss 1476 rto_min 25ms 2>/dev/null
 echo '$1 daemon up (ROM still selected)'" 2>/dev/null
}
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA
 echo "byte re-arm done"' 2>/dev/null; }
start_daemon $B $TB $TA
start_daemon $A $TA $TB
sleep 4                       # let both TX streams pump before the source flip
rearm_byte $B; rearm_byte $A
# byte double-tap (ARMCAUSE): B's flip landed while A was still ROM -- fine --
# but A's flip lands while B is mid-transition; ~8% of flips (2/24 campaign
# arms) latched the same false state (sync-at-rate/100% CRC "wedge from the
# flip"). Re-roll both once more with BOTH byte streams already continuous.
sleep 3
rearm_byte $B; rearm_byte $A

# ---- watchdogs: VERIFIED launch (DEPLOY-A2 §38: two silent launch failures) --
# LESSON (ARMCAUSE soak): pkill/pgrep -f "[l]ock_watchdog" MATCHES THE REMOTE
# SHELL ITSELF (its cmdline contains the plain launch path) -> the shell
# pkills itself and the launch dies silently. Use a PIDFILE, never pgrep -f.
if [ "${WATCHDOG:-1}" = 1 ]; then
  for ip in $B $A; do
    WD=$($W $ip 'PF=/dev/shm/watchdog.pid
 [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; sleep 0.3
 chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log
 setsid nohup /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
 echo $! > $PF
 sleep 2
 if kill -0 "$(cat $PF)" 2>/dev/null && grep -q "STARTING" /dev/shm/watchdog.log; then
   echo "ALIVE pid=$(cat $PF) $(head -1 /dev/shm/watchdog.log)"
 else echo "LAUNCH-FAILED $(tail -2 /dev/shm/watchdog.log 2>/dev/null | tr "\n" "|")"; fi' 2>/dev/null)
    echo "$ip watchdog: $WD"
    case "$WD" in *ALIVE*) ;; *) echo "WARNING: watchdog NOT running on $ip" >&2;; esac
  done
fi
echo "=== $RUNG BRING-UP COMPLETE (byte source live both ends, stream-first + double-tap order) ==="
