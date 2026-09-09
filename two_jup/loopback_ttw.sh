#!/bin/bash
# =============================================================================
# loopback_ttw.sh [reps] -- time-to-wedge distribution for -S in INTERNAL LOOPBACK.
#
# WHY NOW. The wedge was just shown to reproduce with rx_input_select=0: no air, no
# peer, no RF, no LO, no channel (loopback_20260811_173945, wedged t~45s; the run
# before it t~36-40s). That retires RF/propagation as the cause AND makes TTW cheap
# to sample -- one board, no arm-gate lottery, no peer coordination. On air, TTW cost
# a full bring-up per sample and fluctuated 0.3-20 s on a ten-minute scale, which is
# why the anchor control could never be run against a stable long TTW.
#
# WHAT IT MEASURES. Per rep: the last 5 s interval at which the scorer's ok counter
# advanced. ok freezing while tx keeps climbing IS the wedge. Granularity is the
# daemon's 5 s stat cadence -- adequate for a distribution, not for anchoring.
#
# INDEPENDENCE. Each rep re-arms the fabric from a 0x000 soft reset, so reps do not
# inherit each other's latched state. They are still sequential in time, so a slow
# drift (the ten-minute-scale wandering seen on air) would show up as trend, not
# spread -- the summary reports both, and reps are NOT treated as exchangeable.
#
# Registers 0x114/0x118/0x158 are WRITE-ONLY: set, never verified by readback.
# DRA is a single address latch -- watchdog stopped throughout, restarted at the end.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.146}
M=${M:-32}
REPS=${1:-8}
DUR=${DUR:-75}
OUT=$D/r3cap/lbttw_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/ttw.csv; echo "rep,ttw_s,ok_final,lost_final,junk_final,tx_final,wedged" > "$CSV"

echo "=== loopback_ttw: $REPS reps x ${DUR}s on $B -> $OUT ==="
$W $B 'PF=/dev/shm/watchdog.pid; [ -f $PF ] && kill "$(cat $PF)" 2>/dev/null
  pkill -9 -f "[l]ock_watchdog" 2>/dev/null; sleep 1
  pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog STILL UP" || echo "  watchdog stopped"' 2>/dev/null

arm_loopback(){ $W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access
  echo "0x000 0x1">$DRA; sleep 0.5; echo "0x000 0x0">$DRA
  echo "0x158 0x1">$DRA; echo "0x118 0x0">$DRA; echo "0x114 0x0">$DRA
  TXD=$(for d in /sys/bus/iio/devices/iio:device*; do [ "$(cat $d/name 2>/dev/null)" = axi-adrv9002-tx-lpc ] && echo ${d##*/}; done)
  T=/sys/kernel/debug/iio/$TXD/direct_reg_access
  echo "0x418 0x2">$T; echo "0x458 0x2">$T; echo "0x044 0x1">$T
  echo "0x110 0x1">$DRA; sleep 0.3; echo "0x110 0x0">$DRA' >/dev/null 2>&1; }

for r in $(seq 1 "$REPS"); do
  echo "--- rep $r/$REPS ---"
  $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5; rm -f /dev/shm/lb.log
    QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
      ./qpsk_tun -S -M $M -r 15360 -d $DUR > /dev/shm/lb.log 2>&1 &
    exit 0" >/dev/null 2>&1
  sleep 6; arm_loopback; sleep $((DUR - 4))
  $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/rep$r.log"
  $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
  python3 - "$OUT/rep$r.log" "$r" "$CSV" <<'PY'
import re, sys
prog = []
for ln in open(sys.argv[1]):
    m = re.search(r"^seq: t=(\d+)s tx=(\d+) ok=(\d+) biterr=\d+ lost=(\d+) dup=\d+ junk=(\d+)", ln)
    if m: prog.append(tuple(int(x) for x in m.groups()))
if not prog:
    print("    no stats"); open(sys.argv[3], "a").write(f"{sys.argv[2]},NA,0,0,0,0,NA\n"); raise SystemExit
last = 0
for i in range(1, len(prog)):
    if prog[i][2] > prog[i-1][2]: last = prog[i][0]
t, tx, ok, lost, junk = prog[-1]
# NEVER-FRAMED is NOT a wedge. ok_final==0 means the link never framed at all, a
# different state from "framed then stopped", and scoring it as ttw=0 would pour a
# pile of fake zeros into the TTW distribution and drag every statistic down. Seen
# for real: a whole 18-run anchor batch came back ttw=0/ok=0 after the board fell
# into a persistent non-framing state, which the first version labelled "wedged".
if ok == 0:
    wedged = "NEVER"; ttw = "NEVER"
else:
    wedged = 1 if last < t else 0
    ttw = last if wedged else "NONE"
print(f"    ttw={ttw}s  ok={ok} lost={lost} junk={junk} tx={tx}  wedged={wedged}")
open(sys.argv[3], "a").write(f"{sys.argv[2]},{ttw},{ok},{lost},{junk},{tx},{wedged}\n")
PY
done

echo
echo "=== SUMMARY ==="
python3 - "$CSV" <<'PY'
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1])))
w = [r for r in rows if r["wedged"] == "1"]
n = [r for r in rows if r["wedged"] == "0"]
print(f"  reps: {len(rows)}   wedged: {len(w)}   ran clean: {len(n)}")
if w:
    t = [float(r["ttw_s"]) for r in w]
    print(f"  TTW  min {min(t):.0f}s  median {st.median(t):.0f}s  max {max(t):.0f}s"
          + (f"  stdev {st.stdev(t):.1f}s" if len(t) > 1 else ""))
    print(f"  per-rep TTW in order: {[r['ttw_s'] for r in rows]}")
    # trend vs spread: reps are sequential, NOT exchangeable
    if len(t) > 2:
        idx = list(range(len(t)))
        mt, mi = st.mean(t), st.mean(idx)
        cov = sum((a-mi)*(b-mt) for a, b in zip(idx, t))
        var = sum((a-mi)**2 for a in idx)
        slope = cov/var if var else 0
        print(f"  drift across reps: {slope:+.1f}s per rep "
              f"({'TREND -- reps are not exchangeable, do not pool' if abs(slope)*len(t) > st.stdev(t) else 'no strong trend'})")
    okv = [int(r["ok_final"]) for r in w]
    print(f"  ok at wedge: min {min(okv)} median {int(st.median(okv))} max {max(okv)}")
    print()
    print("  If TTW is tight, the wedge is deterministic and worth anchoring (vary the")
    print("  arm->start delay and see whether TTW tracks it). If it is broad, it is a")
    print("  rate/occupancy effect and TTW is the wrong observable.")
else:
    print("  NO WEDGE in any rep -- the earlier wedges were not reproducible at this")
    print("  duration; re-run longer before drawing conclusions.")
PY

echo
echo "--- restoring air select + watchdog ---"
$W $B 'DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled > /sys/bus/iio/devices/iio:device0/reg_access; echo "0x114 0x1">$DRA; exit 0' >/dev/null 2>&1
$W $B 'pkill -9 -f "[l]ock_watchdog" 2>/dev/null; exit 0' >/dev/null 2>&1
$W $B ': > /dev/shm/watchdog.log; exit 0' >/dev/null 2>&1
$W $B 'nohup setsid /root/lock_watchdog.sh </dev/null >/dev/shm/watchdog.log 2>&1 & disown; exit 0' >/dev/null 2>&1
sleep 2
$W $B 'pgrep -f "[l]ock_watchdog" >/dev/null && echo "  watchdog VERIFIED up" || echo "  watchdog FAILED TO START"' 2>/dev/null
echo "=== $CSV ==="
