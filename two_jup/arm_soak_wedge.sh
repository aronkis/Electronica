#!/bin/bash
# =============================================================================
# arm_soak_wedge.sh <r2|r3> <n_soaks> [outdir] -- ARMCAUSE addendum: capture the
# ~2-3 min sync-but-CRC-fail WEDGE onset with full per-second telemetry, and
# exercise the HOST-WEDGE watchdog gate (5aa33ac) in situ.
#
# Per soak: FULL arm (bringup discipline: CFO policy + safe SSI overrides +
# ROM quality gate) -> stream-first byte flip -> SOAKSECS (default 300 s) of
# 1 Hz on-board register sampling (pkts/rstcs/cfc/lvl/deint counters/biterr/
# rssi/hwgain) + qpsk_tun stats lines, both boards in parallel.
#   soak 1          : NO watchdog (clean wedge-onset observation)
#   soak 2..n       : repo lock_watchdog.sh pushed to /root + launched with
#                     pgrep liveness VERIFY (the §38 silent-launch-failure fix)
#                     -> in-situ proof of the HOST-WEDGE gate + auto-recovery
# Ends fully quiesced. Output tagged for arm_telemetry_classify-style parsing.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146; TA=10.66.0.2; TB=10.66.0.1
RUNG=${1:?usage: arm_soak_wedge.sh r2|r3 n_soaks [outdir]}
N=${2:-3}
case "$RUNG" in
  r2) PROF=lvds_30p72_fdd_jupiter; KSYM=7680;  FPS=623;  SSI148="";    ;;
  r3) PROF=lvds_61p44_fdd_jupiter; KSYM=15360; FPS=1245; SSI148="5 3"; ;;
  *) echo "unknown rung" >&2; exit 2;;
esac
OUT=${3:-/tmp/armsoak_${RUNG}_$(date +%m%d_%H%M)}
mkdir -p "$OUT"; LOG=$OUT/soak.log
SOAKSECS=${SOAKSECS:-300}; WHITEN=${WHITEN:-0}
LO_B_TX=2000000000; LO_B_RX=1900002500
LO_A_TX=1900000000; LO_A_RX=2000000000
say(){ echo "@@ $*" >> "$LOG"; }
scpput(){ SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no "$@" </dev/null 2>/dev/null; }

arm_rom(){ # $1 ip $2 txlo $3 rxlo   (verbatim bringup_r2r3.sh)
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
rearm_rom(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x0">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
probe(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo 0x104 > $DRA; p0=$(cat $DRA); sleep 5; echo 0x104 > $DRA; p1=$(cat $DRA); echo $(( (p1 - p0) / 5 ))' 2>/dev/null; }
rearm_byte(){ $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA; echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x1">$DRA
 TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done); T=/sys/kernel/debug/iio/$TXD/direct_reg_access
 echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T; echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' 2>/dev/null; }
start_daemon(){ # $1 ip $2 tunaddr $3 peer
  $W $1 "cd /root/host_app_k5; QPSK_WHITEN=$WHITEN setsid chrt -f 50 ./qpsk_tun -G -M 32 -r $KSYM -i tun0 -s 5 </dev/null >/dev/shm/qpsk_tun.log 2>&1 &
 n=0; while [ \$n -lt 15 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; n=\$((n+1)); done
 ip addr replace $2 peer $3 dev tun0; ip link set tun0 up mtu 1516; echo '$1 daemon up'" 2>/dev/null
}
# --- watchdog deploy + VERIFIED launch (fixes the §38 silent-failure path) ---
push_watchdog(){ scpput "$D/lock_watchdog.sh" root@$1:/root/lock_watchdog.sh; }
# PIDFILE launch -- pgrep/pkill -f self-matches the remote shell (the plain
# script path appears in its own cmdline) and silently kills the launch.
start_watchdog(){ # $1 ip -> echoes ALIVE line or FAILED (checked by caller)
  $W $1 'PF=/dev/shm/watchdog.pid
 [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; sleep 0.3
 chmod +x /root/lock_watchdog.sh; : > /dev/shm/watchdog.log
 setsid nohup /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &
 echo $! > $PF
 sleep 2
 if kill -0 "$(cat $PF)" 2>/dev/null && grep -q "STARTING" /dev/shm/watchdog.log; then
   echo "watchdog ALIVE pid=$(cat $PF) log=$(tail -1 /dev/shm/watchdog.log 2>/dev/null)"
 else echo "watchdog LAUNCH FAILED"; fi' 2>/dev/null
}
stop_watchdog(){ $W $1 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; echo wd-stopped' 2>/dev/null; }
soakwin(){ # $1 ip $2 tag $3 secs : 1 Hz regs + every-5 s daemon stats line
  $W $1 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 P=/sys/bus/iio/devices/iio:device2
 rd(){ echo "$1">$DRA; cat $DRA; }
 for s in $(seq 0 '"$3"'); do
  echo "s=$s t=$(date +%s.%N) pkts=$(rd 0x104) biterr=$(rd 0x108) rstcs=$(rd 0x150) cfc=$(rd 0x154) lvl=$(rd 0x15C) c120=$(rd 0x120) c124=$(rd 0x124) c12C=$(rd 0x12C) rssi=$(cat $P/in_voltage0_rssi 2>/dev/null|cut -d" " -f1) hwg=$(cat $P/in_voltage0_hardwaregain 2>/dev/null|cut -d" " -f1)"
  [ $(( s % 5 )) = 0 ] && echo "s=$s HOST $(grep "qpsk_tun stats" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1)"
  sleep 1
 done
 echo "WDLOG-TAIL: $(tail -5 /dev/shm/watchdog.log 2>/dev/null | tr "\n" "|")"' 2>/dev/null \
  | sed "s/^/@@ $2 /" >> "$LOG"
}
quiesce(){ $W $1 'pkill -x qpsk_tun 2>/dev/null; pkill -f "[l]ock_watchdog" 2>/dev/null; pkill -x iio_readdev 2>/dev/null; ip link del tun0 2>/dev/null
 P=/sys/bus/iio/devices/iio:device2; echo 0 > $P/out_voltage0_hardwaregain
 DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
 echo "0x000 0x1">$DRA; sleep 0.3; echo "0x000 0x0">$DRA; echo "0x114 0x0">$DRA
 echo "quiesced qpsk=$(pgrep -c -x qpsk_tun || echo 0) wd=$(pgrep -c -f "[l]ock_watchdog" || echo 0)"' 2>/dev/null | sed "s/^/@@ QUIESCE $1 /" >> "$LOG"; }
trap 'quiesce $B; quiesce $A; say "DONE_MARKER (trap)"' EXIT INT TERM

say "ARMCAUSE wedge soak start rung=$RUNG n=$N soaksecs=$SOAKSECS $(date -Is)"
for i in $(seq 1 $N); do
  WD=0; [ $i -ge 2 ] && WD=1
  say "SOAK $i WD=$WD t=$(date -Is)"
  # full arm + gate (up to 3 tries)
  ok=0
  for try in 1 2 3; do
    arm_rom $B $LO_B_TX $LO_B_RX >> "$LOG" 2>&1 &
    arm_rom $A $LO_A_TX $LO_A_RX >> "$LOG" 2>&1 &
    wait
    S146="$($D/apply_146_ssi_fix.sh $B 3 4 2>&1 | tail -1)"; say "SOAK $i ssi146: $S146"
    if [ -n "$SSI148" ]; then set -- $SSI148
      S148="$(FORCE=1 $D/apply_146_ssi_fix.sh $A $1 $2 2>&1 | tail -1)"; say "SOAK $i ssi148: $S148"; fi
    rearm_rom $B; rearm_rom $A; sleep 4
    FA=$(probe $A); FB=$(probe $B)
    say "SOAK $i gate try $try: 148=$FA 146=$FB (need $(( FPS * 90 / 100 )))"
    if [ "${FA:-0}" -ge $(( FPS * 90 / 100 )) ] && [ "${FB:-0}" -ge $(( FPS * 90 / 100 )) ]; then ok=1; break; fi
  done
  [ $ok = 1 ] || { say "SOAK $i ARM GATE FAILED -- skipping soak"; continue; }
  # daemons (stream-first) + byte flip
  start_daemon $B $TB $TA >> "$LOG" 2>&1
  start_daemon $A $TA $TB >> "$LOG" 2>&1
  sleep 4
  rearm_byte $B; rearm_byte $A
  if [ $WD = 1 ]; then
    push_watchdog $B; push_watchdog $A
    WB="$(start_watchdog $B)"; say "SOAK $i wd146: $WB"
    WA="$(start_watchdog $A)"; say "SOAK $i wd148: $WA"
    case "$WB$WA" in *FAILED*) say "SOAK $i WATCHDOG LAUNCH FAILED -- soaking without";; esac
  fi
  soakwin $B "SW $i B" $SOAKSECS & PB=$!
  soakwin $A "SW $i A" $SOAKSECS & PA=$!
  wait $PB $PA
  [ $WD = 1 ] && { stop_watchdog $B >/dev/null; stop_watchdog $A >/dev/null; }
  $W $B 'pkill -x qpsk_tun 2>/dev/null; ip link del tun0 2>/dev/null' 2>/dev/null
  $W $A 'pkill -x qpsk_tun 2>/dev/null; ip link del tun0 2>/dev/null' 2>/dev/null
  say "SOAK $i END t=$(date -Is)"
done
say "soak campaign complete $(date -Is)"
