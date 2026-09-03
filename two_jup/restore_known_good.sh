#!/bin/bash
# =============================================================================
# restore_known_good.sh -- put the rig back the way it should be found.
#
# End state (matches the pre-session state, not the overnight experiment state):
#   146: TMR image 433fd8dab393, PLAIN host app (no -DQPSK_RXQ_STAT), queued RX at the
#        DEFAULT -M 16, link up and ARM-GATED, lock_watchdog running.
#   148: completely untouched -- AXR/NAK counter intact, daemon + watchdog running.
#
# -M 16 IS NOW THE SHIPPED DEFAULT (owner approved 2026-08-11). It was held at 32 for
# several sessions on the principle that changing a production default is the owner's
# call and not a side effect of a measurement run. That was the right policy and the
# wrong outcome: -M 16 is the single change that meets the <1% delivered-PER goal
# (0.695%, CP95 UL 0.730% PASS vs 1.362% UL 1.405% NOT MET), free, at equal CPU and
# goodput. See RX_CONFIG_SWEEP_RESULTS.md.
#
# WHY A PLAIN REBUILD. The overnight runs built board B with -DQPSK_RXQ_STAT. With the
# flag off the object is byte-identical to the pre-session baseline (verified md5
# 9212aa2f), so a plain build leaves the deployed binary exactly as it was found, with
# the instrumentation living in the committed source, compiled out.
#
# WHY THE WATCHDOG STEP IS EXPLICIT. bring-up stops lock_watchdog for the capture and
# capture_r3.sh -k does NOT restart it -- it only leaves the daemons up. Last session
# this was missed and 148 was left without its watchdog.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd)
W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146

echo "=== RESTORE: gated bring-up, plain app, default -M 16 (shipped) ==="
# NOTE: no HOST_CFLAGS_B -> board B rebuilds WITHOUT the instrumentation.
RXM=16 RXQ=1 RXCYC=0 LO_B_RX=1900020000 GATE_TRIES=12 \
  "$D/capture_r3.sh" B -k -d 15 -n 400000 -o "$D/r3cap/restore_$(date +%H%M%S)" \
  > /tmp/restore_bringup.log 2>&1
echo "  bring-up exit=$? (log /tmp/restore_bringup.log)"
grep -E "ARM GATE|BRING-UP COMPLETE|crc-health" /tmp/restore_bringup.log | tail -3

echo "=== restart lock_watchdog on BOTH boards ==="
# ISOLATED ssh calls, then VERIFY. A detached launch bundled with other commands in one
# ssh block does not survive -- this printed "watchdog launched" while both watchdogs were
# in fact DOWN. Same footgun already fixed in watchdog_efficacy.sh.
for ip in $B $A; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip 'chmod +x /root/lock_watchdog.sh 2>/dev/null; : > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'DAEMON_CMD="./qpsk_tun -G -M 16 -r 15360 -i tun0 -s 5" DAEMON_LOG=/dev/shm/qpsk_tun.log nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
  sleep 2
  if $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo UP || echo DOWN' 2>/dev/null | grep -q UP; then
    echo "  $ip watchdog VERIFIED up"
  else
    echo "  $ip watchdog FAILED TO START"
  fi
done
sleep 3

echo
echo "=== FINAL VERIFIED STATE ==="
for ip in $B $A; do
  echo "--- $ip ---"
  # image identity is the BOOT.BIN md5, same as modem_status.sh uses (146 must be
  # 433fd8dab393 = the T9.0 TMR + loop-tune image)
  $W $ip 'echo "  BOOT.BIN   : $(md5sum /boot/BOOT.BIN 2>/dev/null | cut -c1-12)"
    echo "  app md5    : $(md5sum /root/host_app_k5/qpsk_tun | cut -c1-8)"
    echo "  nakstat    : $(strings /root/host_app_k5/qpsk_tun | grep -c nakstat) (148 must be 4)"
    echo "  rxqstat    : $(strings /root/host_app_k5/qpsk_tun | grep -c rxqstat) (must be 0 -- plain build)"
    p=$(pgrep -x qpsk_tun | head -1)
    echo "  daemon     : ${p:+up pid=$p}${p:-DOWN}"
    [ -n "$p" ] && echo "  cmdline    : $(tr "\0" " " < /proc/$p/cmdline)"
    [ -n "$p" ] && echo "  rx mode    : $(tr "\0" "\n" < /proc/$p/environ | grep -E "QPSK_RX_(QUEUED|CYCLIC)" | tr "\n" " ")"
    pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog   : up" || echo "  watchdog   : DOWN"
    echo "  link stats : $(grep "qpsk_tun stats" /dev/shm/qpsk_tun.log 2>/dev/null | tail -1 | grep -oE "dma_rx_ok=[0-9]+ crc_drop=[0-9]+")"' 2>/dev/null
done
echo
echo "=== restore complete $(date -Is) ==="
