#!/bin/bash
# =============================================================================
# dra_guard.sh <check|claim|release|who> <ip> [owner] -- single-reader guard for
# the modem's debugfs direct_reg_access interface.
#
# THE DEFECT THIS OBSERVES
# direct_reg_access is a single ADDRESS LATCH: a reader writes the address it wants,
# then reads the value back. Two readers interleaving return each other's registers,
# silently, with no error anywhere. Measured 2026-08-07: with stallpoll and
# lock_watchdog both running, 0.08% of soak rows carried a FOREIGN register's value --
# 0xC010180 (adc_forensic 0x15C) appeared in the PACKET COUNT column 77 times in one
# 3.5 h capture. One such value inflates a run delta by 2e8. It silently poisoned
# run-based statistics and cost a full re-derive of the frame-rate analysis to find.
#
# It is the worst class of defect on this rig: it corrupts data rather than failing.
# Nothing detected it, and nothing prevents it recurring -- hence this.
#
#   check    read-only. Enumerate every process on the board that is known to read
#            direct_reg_access. Exit 1 if more than one. Safe to run any time; this
#            is the sequencer's rung 3 and it never writes anything.
#   who      like check but just prints the owner file, if any
#   claim    atomically take the lock (mkdir is atomic on any POSIX fs, and busybox
#            ash has no flock). Records owner, pid, host, timestamp.
#   release  drop the lock IF we own it -- refuses to steal another owner's lock.
#
# HONEST LIMITATION: claim/release are ADVISORY. stallpoll and lock_watchdog predate
# this and do not participate, so `check` (which looks at what is actually running) is
# the load-bearing half today. Retrofitting the two legacy readers is the follow-up;
# until then treat a `check` failure as real and a clean `claim` as necessary-not-
# sufficient.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
CMD=${1:?usage: dra_guard.sh <check|claim|release|who> <ip> [owner]}
IP=${2:?usage: dra_guard.sh <check|claim|release|who> <ip> [owner]}
OWNER=${3:-$(whoami)@$(hostname)}
LOCK=/dev/shm/dra.lock.d

case "$CMD" in
check|who)
  # Known readers, by cmdline pattern. Bracket trick so the pattern never matches
  # the ssh command line carrying it (a pkill footgun this rig has hit before).
  OUT=$($W "$IP" '
    n=0
    for pat in "[s]tallpoll" "[l]ock_watchdog" "[s]tall_catch" "[r]ate_probe" "[d]ecay_trace" "[s]tep_probe"; do
      pids=$(pgrep -f "$pat" 2>/dev/null | tr "\n" " ")
      [ -n "$pids" ] && { echo "READER $pat $pids"; n=$((n+1)); }
    done
    # anything currently holding EITHER latch open. device2 (the ADRV9002) has its own
    # direct_reg_access -- a second, independent address latch with the same hazard.
    # Missed on the first pass because the campaign only ever corrupted device0.
    for f in /sys/kernel/debug/iio/iio:device0/direct_reg_access \
             /sys/kernel/debug/iio/iio:device2/direct_reg_access; do
      for p in $(fuser $f 2>/dev/null); do
        echo "OPEN_FD $(basename $(dirname $f)) pid=$p cmd=$(cat /proc/$p/comm 2>/dev/null)"
      done
    done
    echo "COUNT $n"
    [ -d '"$LOCK"' ] && { echo "LOCKFILE:"; cat '"$LOCK"'/owner 2>/dev/null; } || echo "LOCKFILE: none"
  ' 2>/dev/null)
  echo "$OUT" | grep -v '^COUNT '
  N=$(echo "$OUT" | sed -n 's/^COUNT //p')
  N=${N:-0}
  if [ "$N" -gt 1 ]; then
    echo "FAIL: $N concurrent direct_reg_access readers on $IP -- reads WILL corrupt each other"
    exit 1
  elif [ "$N" -eq 1 ]; then
    echo "OK: exactly one reader on $IP"
  else
    echo "OK: no readers on $IP"
  fi
  ;;
claim)
  R=$($W "$IP" "mkdir $LOCK 2>/dev/null && {
        printf 'owner=%s\npid=%s\nwhen=%s\n' '$OWNER' \$\$ \"\$(date -Is)\" > $LOCK/owner
        echo CLAIMED; } || { echo BUSY; cat $LOCK/owner 2>/dev/null; }" 2>/dev/null)
  echo "$R"
  echo "$R" | grep -q CLAIMED || exit 1
  ;;
release)
  R=$($W "$IP" "if [ -d $LOCK ]; then
        cur=\$(sed -n 's/^owner=//p' $LOCK/owner 2>/dev/null)
        if [ \"\$cur\" = '$OWNER' ] || [ -z \"\$cur\" ]; then rm -rf $LOCK; echo RELEASED
        else echo \"REFUSED held by \$cur\"; fi
      else echo 'NOT_HELD'; fi" 2>/dev/null)
  echo "$R"
  echo "$R" | grep -qE "RELEASED|NOT_HELD" || exit 1
  ;;
*) echo "unknown command: $CMD" >&2; exit 2 ;;
esac
