#!/bin/bash
# =============================================================================
# mux_test.sh -- does the -S daemon restart drop the TX byte-source mux that
# bring-up established?
#
# WHY. Five Layer B runs have failed the framing gate with ok=0 and no frame
# structure at ANY offset in the delivered slices. Under-feed and missing pacing
# are both now DEAD by measurement (a 242% overfeed framed nothing; a 95%
# correctly-paced feed framed nothing). What is left is structural.
#
# layerb_run.sh kills the -G daemons and starts -S ones AFTER bring-up has already
# set the TX mux. lock_watchdog's rearm_once explicitly re-applies 0x158
# (tx_data_source), 0x118 (tx_source_select) and 0x114 (rx_input_select) after any
# reset -- direct evidence that these do NOT survive on their own.
#
# THE TEST. Read the readable mux registers with -G running, swap to -S exactly as
# layerb_run.sh does, and read them again. Differ -> the restart drops the mux and
# the fix is to re-apply it after launching -S.
#
# ############################################################################
# ##  THIS TEST IS VOID AS WRITTEN. DO NOT TRUST ITS VERDICT.               ##
# ############################################################################
# 0x114 IS WRITE-ONLY TOO. Positive control, run AFTER this test produced a
# confident-looking "SAME" verdict:
#     0x114 as found        : 0x0
#     0x114 after writing 1 : 0x0
#     0x114 after writing 0 : 0x0
#     0x114 restored to 1   : 0x0
#     0x104 packets         : 0x9CBE   <- DRA reads work fine
# So 0x114/0x118 always read 0x0 regardless of what was written, and comparing
# them between -G and -S discriminates NOTHING. The "SAME" verdict below is an
# artifact, not evidence that the mux survives the -S swap.
#
# The tell was visible in the output and I nearly missed it: bring-up writes
# 0x114=0x1, the -G link was demonstrably framing (3712 packets/3s), and the
# register still read 0x0. A readback that contradicts a known-good write is the
# signature of a write-only register, not of a cleared mux.
#
# ANY FUTURE VERSION MUST establish observability FIRST: write a known value,
# read it back, and abort if it does not survive -- before drawing any verdict.
#
# What this run DID produce, valid because it does not depend on readback: the
# 0x104 framesync rate FELL from ~1237/s under -G to ~242/s under -S on 146
# (and 613/s -> 128/s on 148). The fabric still syncs under -S, at ~20% the rate.
#
# 0x158 IS WRITE-ONLY. Verified earlier this campaign: write 1 -> reads 0x0, write
# 0 -> reads 0x0. It CANNOT be checked this way and is deliberately not read here;
# a previous watchdog gate built on reading it back would have been always-true.
#
# DRA IS A SINGLE ADDRESS LATCH. Concurrent readers silently corrupt each other --
# that is how biterr once read back cap_out's constant. The watchdogs are stopped
# for the duration so this script is the ONLY reader, and restarted at the end.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
M=${M:-32}
OUT=$D/r3cap/muxtest_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"

# one DRA reader, one register at a time, on one board
rd_mux() { # $1 ip  $2 label
  $W "$1" 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
    echo enabled > /sys/bus/iio/devices/iio:device0/reg_access 2>/dev/null
    rd(){ echo "$1" > $DRA; cat $DRA; }
    echo "  0x114 rx_input_select = $(rd 0x114)"
    echo "  0x118 tx_source_select = $(rd 0x118)"
    echo "  0x144 cap_out          = $(rd 0x144)"
    p0=$(rd 0x104); sleep 3; p1=$(rd 0x104)
    echo "  0x104 packets/3s       = $(( $(( $p1 )) - $(( $p0 )) ))"' 2>/dev/null
}

echo "=== mux_test: does the -S swap drop the TX mux? -> $OUT ==="
echo "--- stopping watchdogs on BOTH boards (single DRA reader discipline) ---"
for ip in $B $A; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1; done
sleep 1
for ip in $B $A; do
  $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' watchdog STILL UP -- readings would be corrupt" || echo "  '"$ip"' watchdog stopped"' 2>/dev/null
done

echo
echo "--- fresh R3 bring-up so we start from a known-good -G link ---"
"$D/bringup_r2r3.sh" r3 > "$OUT/bringup.log" 2>&1 || { echo "BRINGUP FAILED"; }
grep -E "ARM GATE|BRING-UP COMPLETE" "$OUT/bringup.log" | tail -2
# bring-up starts its own watchdogs; stop them again before reading
for ip in $B $A; do $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1; done
sleep 1

echo
echo "##### STATE A: -G running (the link that FRAMES) #####"
for ip in $B $A; do
  n=$( [ "$ip" = "$B" ] && echo "146 (RX)" || echo "148 (TX)" )
  echo "--- $n ---"
  $W $ip 'p=$(pgrep -x qpsk_tun|head -1); echo "  daemon: $( [ -n "$p" ] && tr "\0" " " < /proc/$p/cmdline || echo DOWN )"' 2>/dev/null
  rd_mux "$ip" | tee -a "$OUT/state_G_$( [ "$ip" = "$B" ] && echo 146 || echo 148 ).txt"
done

echo
echo "--- swapping to -S exactly as layerb_run.sh does ---"
for ip in $B $A; do $W $ip 'pkill -x qpsk_tun 2>/dev/null; sleep 0.5; exit 0' 2>/dev/null; done
for ip in $A $B; do
  $W $ip "cd /root/host_app_k5; rm -f /dev/shm/acc.log
    QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
      ./qpsk_tun -S -M $M -r 15360 -d 60 > /dev/shm/acc.log 2>&1 &
    exit 0" >/dev/null 2>&1
done
sleep 8

echo
echo "##### STATE B: -S running (the link that does NOT frame) #####"
for ip in $B $A; do
  n=$( [ "$ip" = "$B" ] && echo "146 (RX)" || echo "148 (TX)" )
  echo "--- $n ---"
  $W $ip 'p=$(pgrep -x qpsk_tun|head -1); echo "  daemon: $( [ -n "$p" ] && tr "\0" " " < /proc/$p/cmdline || echo DOWN )"' 2>/dev/null
  rd_mux "$ip" | tee -a "$OUT/state_S_$( [ "$ip" = "$B" ] && echo 146 || echo 148 ).txt"
done

echo
echo "=== VERDICT ==="
for n in 146 148; do
  g=$OUT/state_G_$n.txt; s=$OUT/state_S_$n.txt
  [ -s "$g" ] && [ -s "$s" ] || { echo "  $n: missing readings"; continue; }
  echo "--- $n ---"
  for r in 0x114 0x118; do
    gv=$(grep -m1 "$r" "$g" | awk -F'= ' '{print $2}')
    sv=$(grep -m1 "$r" "$s" | awk -F'= ' '{print $2}')
    if [ "$gv" = "$sv" ]; then
      echo "  $r: -G=$gv  -S=$sv   SAME"
    else
      echo "  $r: -G=$gv  -S=$sv   *** CHANGED ***"
    fi
  done
done
echo
echo "  Reading: any *** CHANGED *** on 0x114/0x118 means the -S daemon restart"
echo "  drops the mux bring-up established -- re-apply it after launching -S."
echo "  All SAME means the mux survives and the fault is elsewhere (next candidate:"
echo "  tx_send_batch at F1536 geometry, which -G never exercises)."

echo
echo "--- stopping -S daemons, restarting watchdogs ---"
for ip in $B $A; do $W $ip 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1; done
for ip in $B $A; do
  $W $ip 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
  $W $ip ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
  $W $ip 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
  sleep 2
  $W $ip 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  '"$ip"' watchdog VERIFIED up" || echo "  '"$ip"' watchdog FAILED TO START"' 2>/dev/null
done
echo "=== artifacts in $OUT ==="
