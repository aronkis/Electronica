#!/bin/bash
# quiesce_then_knee.sh -- one unit: quiesce BOTH boards after the daemon leg, then run
# the knee trials. Chained so no SEQ-BIST leg can start while a daemon is still pumping.
#
# WHY THE QUIESCE IS MANDATORY HERE: legrun-whiten-A left qpsk_tun + lock_watchdog
# running on both boards. A SEQ-BIST loopback leg drives the TX byte plane from the
# fabric TGEN; a live daemon drives the SAME plane over MM2S. Two sources = the leg
# measures neither. lock_watchdog must die FIRST -- it relaunches qpsk_tun on death,
# so killing the daemon first just gets it restarted (bringup_r2r3.sh:196-198). Use the
# PIDFILE, never pgrep -f: "pkill -f lock_watchdog" MATCHES THE REMOTE SHELL ITSELF and
# the launch dies silently (ARMCAUSE lesson, bringup_r2r3.sh:196).
set -u
S=$(cd "$(dirname "$0")" && pwd); D=$(cd "$S/.." && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
DUR=${DUR:-60}
log(){ echo "$(date -Is) [q] $*"; }

for ip in $B $A; do
  log "--- quiesce $ip ---"
  R=$($W $ip 'PF=/dev/shm/watchdog.pid
    [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null; sleep 0.5
    pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 0.3
    pkill -x qpsk_tun 2>/dev/null; sleep 1.5
    pkill -9 -x qpsk_tun 2>/dev/null; sleep 0.5
    echo "qpsk_tun=$(pgrep -x qpsk_tun | tr "\n" "," ) wd=$(pgrep -f "[l]ock_watchdog" | tr "\n" ",")"' 2>/dev/null | tr -d '\r')
  log "$ip after quiesce: $R"
  case "$R" in
    "qpsk_tun= wd=") log "$ip QUIESCED_OK" ;;
    *qpsk_tun=*)     log "$ip WARN: something still running -> $R" ;;
    *) log "$ip QUIESCE_UNVERIFIED (empty ssh)"; echo "QUIESCE_UNREACHABLE $ip"; exit 3 ;;
  esac
done

log "=== knee trials (${DUR}s each) ==="
DRY=0 DUR=$DUR bash "$S/gapsweep_go.sh"
RC=$?
log "=== knee trials rc=$RC ==="
exit $RC
