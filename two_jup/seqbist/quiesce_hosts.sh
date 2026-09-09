#!/bin/bash
# quiesce_hosts.sh -- take the HOST plane down on both boards without disturbing the
# radio/fabric arm: stop lock_watchdog FIRST (via its PIDFILE -- `pkill -f "[l]ock_watchdog"`
# matches the remote shell itself and is the self-match trap that has bitten this codebase
# twice), then stop qpsk_tun, then VERIFY both are gone. Killing the daemon first only
# gives the watchdog something to relaunch.
#
# It deliberately does NOT touch 0x000/0x114/0x158 or any radio attribute: capture_r3.sh's
# quiesce zeroes 0x9D000000/0x9D000114 and that is what leaves a board in the NEEDS_ARM
# state. Here the boards stay armed exactly as the bring-up left them.
# Env: DRY=1 (default), BOARDS="10.0.0.148 10.0.0.146"
set -u
D=$(cd "$(dirname "$0")/.." && pwd); W=$D/anyssh.sh
DRY=${DRY:-1}; BOARDS=${BOARDS:-"10.0.0.148 10.0.0.146"}
echo "=== quiesce_hosts (watchdog by pidfile, then qpsk_tun, then verify) DRY=$DRY ==="
for ip in $BOARDS; do
  if [ "$DRY" = 1 ]; then echo "[dry] $ip: kill \$(cat /dev/shm/watchdog.pid); pkill -x qpsk_tun; verify"; continue; fi
  out=$($W $ip 'PF=/dev/shm/watchdog.pid
[ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
sleep 1
pkill -x qpsk_tun 2>/dev/null
sleep 2
pkill -9 -x qpsk_tun 2>/dev/null
for w in $(pgrep -f "[l]ock_watchdog"); do kill -9 $w 2>/dev/null; done
sleep 5
pkill -9 -x qpsk_tun 2>/dev/null
sleep 3
echo WD_LEFT=$(pgrep -f "[l]ock_watchdog" | tr "\n" ",") TUN_LEFT=$(pgrep -x qpsk_tun | tr "\n" ",")' 2>&1 | tr -d '\r')
  echo "  $ip $out"
  case "$out" in *"WD_LEFT= TUN_LEFT="*) echo "  $ip QUIESCED" ;; *) echo "  $ip QUIESCE_INCOMPLETE" ;; esac
done
echo "=== quiesce_hosts done ==="
