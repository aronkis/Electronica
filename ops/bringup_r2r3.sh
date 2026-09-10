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
#  4. Host daemons: paced qpsk_tun -G -M 16 -r <ksym> (e50f88c pacing floor);
#     RXM DEFAULT IS 16 (was 32) as of 2026-08-11. Measured, replicated across two
#     sessions and 4/4 paired interleaved cycles: -M 16 gives 0.695% delivered PER
#     (Clopper-Pearson 95% upper bound 0.730%) against the <1% acceptance gate, vs
#     1.362% (UL 1.405%, gate NOT MET) at -M 32 -- at equal CPU (13.5% vs 13.4%) and
#     equal goodput (14.04 vs 13.94 Mbit/s). The expected CPU penalty from more DMA
#     transactions did not materialise. Details: RX_CONFIG_SWEEP_RESULTS.md.
#     -M 8 is statistically indistinguishable (0.660%/0.691%); 16 is preferred only
#     because it replicated across two sessions. Do NOT use -M 64 (wedged the link
#     outright) and do NOT revert to the legacy path (RXQ=0 is 2-4x worse).
#     Override with RXM=<n> for experiments.
#     -s 5 stats for measurement fidelity; tun0 MTU 1516.
#
# Usage: bringup_r2r3.sh r2      (lvds_30p72_fdd_jupiter, -r 7680, ~623 f/s)
#        bringup_r2r3.sh r3      (lvds_61p44_fdd_jupiter, -r 15360, ~1245 f/s)
# Env:   GATE_FPS (default 90% of rate), GATE_TRIES=6, WHITEN=1 (payload whitening, both ends; 0 = legacy)
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
# WHITEN default 0 -> 1 (2026-09-08, ledger FWD_CRC_REGRESSION_0907 §47.21-§47.23): with the TX
# scrambler hard-disabled and host whitening off, the daemon's idle frames went to air as a
# constant byte pattern that contains two preamble-like stretches; on air the Preamble_Detector
# occasionally picked one of them, the Packet_Controller started the frame 1,549/3,085 symbols
# early and the next true start truncated it -- 97 % of the forward residual (0.045 -> 0.005 %
# window PER when whitening was turned on). BOTH ENDS OR NOTHING: this default reaches both
# daemons through start_daemon AND the watchdog relaunch string below.
WHITEN=${WHITEN:-1}
# CFO policy (see header): R2/R3 offsets, never the null
LO_B_TX=2000000000; LO_B_RX=${LO_B_RX:-1900040000}  # 146 Rx rev; default +40k off-null (2026-08-28 sweep: 1.39 %/CP95UL 1.47 vs 1.99 %/2.09 at the old +2.5k; -20k 1.60, +20k 1.78, +80k 1.75, -40k 1.49). Reversible via LO_B_RX env.
                                           # Override (e.g. 1900020000 = +20k) to move off
                                           # the CFO~0 dead-zone -- the residual-regime capture.
LO_A_TX=1900000000; LO_A_RX=${LO_A_RX:-2000020000}  # 148: Tx rev 1.9 GHz; Rx fwd DEFAULT +20k off-null (operator-acked 2026-08-26: comb 13.0%->6.0% steady, sign-asymmetric CFO response; old plain 2000000000 sits on the bad side of the asymmetry). Env-overridable.

# ---- radio arm (profile + LOs + regfile), ROM source, NO daemon yet ---------
# CRITICAL (double-hang 2026-08-04 x2): arm_rom pkills [l]ock_watchdog+[s]tallpoll
# BEFORE the profile reload -- a stale wd polling direct_reg_access across the
# reload hard-hangs the board (both, since we arm in parallel). NOTE: comments
# must stay OUT of the quoted remote string (anyssh flattens newlines; an inline
# '#' comments out the whole rest of the arm sequence -- bit us on bringup5).
arm_rom(){ # $1 ip $2 txlo $3 rxlo
  $W $1 "P=/sys/bus/iio/devices/iio:device2; DB=/sys/kernel/debug/iio/iio:device2
 pkill -x qpsk_tun 2>/dev/null
 pkill -f \"[l]ock_watchdog\" 2>/dev/null; pkill -f \"[s]tallpoll\" 2>/dev/null; sleep 1
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
if [ "${SSI146:-3 4}" = skip ]; then
  SSI158="SKIPPED (auto-tune delays stand -- per-image)"; echo "146: $SSI158"
else
  SSI158="$($D/apply_146_ssi_fix.sh $B ${SSI146:-3 4} 2>&1 | tail -1)"; echo "146: $SSI158"   # SSI146: per-image tx0 clk/dat
fi
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
  # GATE_DIR (default both): B = require only 146 RX (reverse dir, 148->146); A = only
  # 148 RX. Used to validate ONE direction when the other is intentionally down (e.g.
  # 146 on a CYCLIC bitstream with a forward-air regression -- reverse RX still valid).
  case "${GATE_DIR:-both}" in
    B) [ "${FB:-0}" -ge "$GATE_FPS" ] && { PASS=1; break; } ;;
    A) [ "${FA:-0}" -ge "$GATE_FPS" ] && { PASS=1; break; } ;;
    *) { [ "${FA:-0}" -ge "$GATE_FPS" ] && [ "${FB:-0}" -ge "$GATE_FPS" ]; } && { PASS=1; break; } ;;
  esac
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
  # QPSK_FRAMELOG passthrough (env-gated; empty when caller has not set it ->
  # logger disabled -> behavior unchanged). capture_r3.sh exports it to get
  # per-frame telemetry from the R3 daemons.
  # DAEMON_EXTRA (env, default empty -> no change): extra qpsk_tun flags, e.g.
  # -A to force the in-process ARQ on for arq_r3.sh's measurement.
  # QPSK_RX_CYCLIC (env RXCYC, default 0): cyclic-ring RX. Applied ONLY to board B
  # ($B=146, the CONFIG.CYCLIC 1 bitstream). NEVER to A (148, non-cyclic bitstream) --
  # the cyclic host path on a non-cyclic bitstream dies after one ring. So A stays 0.
  CYC=0; [ "$1" = "$B" ] && CYC=${RXCYC:-0}
  # RXCYC_A (2026-08-14 overnight): 148 now runs the skid2/lean lineage which
  # bakes CONFIG.CYCLIC=1 (complete_byte_t8.tcl) -- cyclic on A is a valid
  # runtime opt-in. qpsk_tun still hardware-gates it at start.
  [ "$1" != "$B" ] && CYC=${RXCYC_A:-0}
  # QPSK_RX_QUEUED default flipped 0 -> 1 (2026-08-27, QUEUED_RX_MODE_VERDICT.md):
  # queued-request RX (next S2MM transfer pre-armed in hardware) measured 8.73/8.89 %
  # forward PER vs 13.93/13.98 % for reset-per-transfer on the identical protocol; no
  # fabric change, watchdog re-arms 0, wedge rate unchanged (1/3 legs each), bidirectional
  # collapse unchanged. RXQ=0 restores the legacy path (used explicitly by the FIFO A/B).
  # DAEMON_ENV is a verbatim "K=V K=V" pass-through for daemon env knobs that are not
  # part of the fixed list below (e.g. the QPSK_ARQ_* cross-link ARQ tuning). Unset =>
  # the launch line is byte-identical to the original.
  # Per-board overrides (task-3-fix1 C-1): RXM_A/RXM_B and DAEMON_ENV_A/DAEMON_ENV_B
  # let a caller target 148 ($A) or 146 ($B) independently, following the RXCYC/RXCYC_A
  # precedent above. With none of these set, RXM_EFF/DENV_EFF equal the old shared
  # RXM/DAEMON_ENV and the launch line is byte-identical to today.
  RXM_EFF=${RXM:-16}; DENV_EFF=${DAEMON_ENV:-}
  if [ "$1" = "$A" ]; then RXM_EFF=${RXM_A:-$RXM_EFF}; DENV_EFF=${DAEMON_ENV_A:-$DENV_EFF}; fi
  if [ "$1" = "$B" ]; then RXM_EFF=${RXM_B:-$RXM_EFF}; DENV_EFF=${DAEMON_ENV_B:-$DENV_EFF}; fi
  $W $1 "cd /root/host_app_k5; QPSK_WHITEN=$WHITEN QPSK_FRAMELOG=${QPSK_FRAMELOG:-} QPSK_RX_CYCLIC=$CYC QPSK_RX_QUEUED=${RXQ:-1} ${DENV_EFF} setsid chrt -f 50 ./qpsk_tun -G -M ${RXM_EFF} -r $KSYM -i tun0 -s 5 ${DAEMON_EXTRA:-} </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
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
    # The watchdog relaunch string must carry the same per-board -M and DAEMON_ENV
    # knobs as start_daemon (task-3-rereview: a relaunch mid-leg otherwise silently
    # reverts them). With nothing set the string is byte-identical to the original
    # "./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5" at r3 (lock_watchdog runs it via sh -c, so
    # a K=V prefix is honoured). -r carries $KSYM, not a literal, so an r2 leg is not
    # silently re-paced to r3 by a mid-leg relaunch (2026-09-09).
    WRXM=${RXM:-16}; WDENV=${DAEMON_ENV:-}
    if [ "$ip" = "$A" ]; then WRXM=${RXM_A:-$WRXM}; WDENV=${DAEMON_ENV_A:-$WDENV}; fi
    if [ "$ip" = "$B" ]; then WRXM=${RXM_B:-$WRXM}; WDENV=${DAEMON_ENV_B:-$WDENV}; fi
    # QPSK_WHITEN first so a relaunched daemon matches its peer (a DAEMON_ENV that also sets
    # it comes later in the prefix and wins, exactly as legrun_go.sh's WHITEN_DENV relies on).
    WCMD="QPSK_WHITEN=$WHITEN ${WDENV:+$WDENV }./qpsk_tun -G -M $WRXM -r $KSYM -i tun0 -s 5"
    WD=$($W $ip 'PF=/dev/shm/watchdog.pid
 [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; sleep 0.3
 chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log
 DAEMON_CMD="'"$WCMD"'" DAEMON_LOG=/dev/shm/qpsk_tun.log \
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
