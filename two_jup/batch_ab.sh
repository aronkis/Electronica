#!/bin/bash
# =============================================================================
# batch_ab.sh [cycles] -- OFF-AIR A/B: is tx_send_batch the -S/-G difference?
#
# THE QUESTION. -S frames in internal loopback but has NEVER framed on air across 9
# attempts, while -G frames on air fine (1023 f/s, 98% CRC) in the same sessions.
# Same fabric, same f1536 geometry, same whitening (WHITEN=0 both), same -M 32
# queued RX, and a fresh dual reboot did not change it. The remaining structural
# difference is the TX submit path: -S uses tx_send_batch() (5 frames per transfer
# at F1536), -G uses tx_send() (one frame per transfer).
#
# THE TEST, entirely in LOOPBACK -- no air link, no peer, no bring-up lottery:
#   arm BATCH   : -S as shipped            (tx_send_batch, 5 frames/transfer)
#   arm NOBATCH : -S with QPSK_SEQ_NOBATCH=1 (tx_send, 1 frame/transfer = the -G path)
# Everything else identical. If the two arms behave the same, tx_send_batch is NOT
# the difference and this line of inquiry is closed.
#
# WHAT "CLEAN" MEANS HERE. Clean = no material difference between arms. That is a
# NEGATIVE result and it is the point: it closes the last named candidate rather
# than opening a new one.
#
# INTERLEAVED. The loopback wedge drifts (+4 to +7.5 s per rep measured) and the
# board can fall into a persistent non-framing state, so arms are round-robined,
# never blocked, and NEVER-framed runs are reported separately from wedges rather
# than pooled as "wedged at t=0".
#
# DRA single-latch: watchdog stopped throughout, restarted at the end.
# 0x114/0x118/0x158 are WRITE-ONLY -- set, never verified by readback.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.146}
M=${M:-32}
DUR=${DUR:-70}
CYCLES=${1:-3}
OUT=$D/r3cap/batchab_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/batchab.csv
echo "run,cycle,arm,ttw_s,ok,lost,junk,tx,txrate,state" > "$CSV"

echo "=== batch_ab: tx_send_batch vs tx_send, in LOOPBACK, $CYCLES cycles -> $OUT ==="
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

run=0
for c in $(seq 1 "$CYCLES"); do
  for arm in BATCH NOBATCH; do
    run=$((run + 1))
    NB=0; [ "$arm" = NOBATCH ] && NB=1
    echo "--- run $run (cycle $c, arm $arm) ---"
    $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5; rm -f /dev/shm/lb.log
      QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 QPSK_SEQ_NOBATCH=$NB \
        setsid chrt -f 50 ./qpsk_tun -S -M $M -r 15360 -d $DUR > /dev/shm/lb.log 2>&1 &
      exit 0" >/dev/null 2>&1
    sleep 6; arm_loopback; sleep $((DUR - 3))
    $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/run${run}_$arm.log"
    $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
    # verify the arm actually took -- never assume an env knob did its job
    if [ "$NB" = 1 ]; then
      grep -q "LAYER B A/B" "$OUT/run${run}_$arm.log" \
        && echo "    NOBATCH banner confirmed" \
        || echo "    !! NOBATCH banner MISSING -- arm did not take, run is INVALID"
    fi
    python3 - "$OUT/run${run}_$arm.log" "$run" "$c" "$arm" "$CSV" <<'PY'
import re, sys
prog, rates = [], []
for ln in open(sys.argv[1], errors="ignore"):
    m = re.search(r"^seq: t=(\d+)s tx=(\d+) ok=(\d+) biterr=\d+ lost=(\d+) dup=\d+ junk=(\d+)", ln)
    if m: prog.append(tuple(int(x) for x in m.groups()))
    m = re.search(r"TXRATE (\d+) f/s", ln)
    if m: rates.append(int(m.group(1)))
run, cyc, arm, csv = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
if not prog:
    print("    no stats"); open(csv,"a").write(f"{run},{cyc},{arm},NA,0,0,0,0,0,NOSTATS\n"); raise SystemExit
last = 0
for i in range(1, len(prog)):
    if prog[i][2] > prog[i-1][2]: last = prog[i][0]
t, tx, ok, lost, junk = prog[-1]
tr = int(sum(rates)/len(rates)) if rates else 0
if ok == 0:            state, ttw = "NEVER_FRAMED", "NEVER"
elif last < t:         state, ttw = "WEDGED", last
else:                  state, ttw = "CLEAN", "NONE"
print(f"    {arm:<8} state={state:<13} ttw={ttw}  ok={ok} lost={lost} junk={junk} txrate={tr}f/s")
open(csv,"a").write(f"{run},{cyc},{arm},{ttw},{ok},{lost},{junk},{tx},{tr},{state}\n")
PY
  done
done

echo
echo "=== VERDICT ==="
python3 - "$CSV" <<'PY'
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1])))
arms = {}
for r in rows: arms.setdefault(r["arm"], []).append(r)
for a in ("BATCH", "NOBATCH"):
    rs = arms.get(a, [])
    if not rs: continue
    framed = [r for r in rs if r["state"] != "NEVER_FRAMED"]
    okv = [int(r["ok"]) for r in rs]
    trv = [int(r["txrate"]) for r in rs if int(r["txrate"]) > 0]
    print(f"  {a:<8} n={len(rs)}  framed={len(framed)}/{len(rs)}  "
          f"ok median={int(st.median(okv))}  "
          f"txrate median={int(st.median(trv)) if trv else 0} f/s")
    print(f"           states: {[r['state'] for r in rs]}")
    print(f"           ttw:    {[r['ttw_s'] for r in rs]}")
print()
b, nb = arms.get("BATCH", []), arms.get("NOBATCH", [])
if not b or not nb:
    sys.exit("  one arm missing -- cannot compare")
bf = sum(1 for r in b if r["state"] != "NEVER_FRAMED")
nf = sum(1 for r in nb if r["state"] != "NEVER_FRAMED")
bok = st.median([int(r["ok"]) for r in b]); nok = st.median([int(r["ok"]) for r in nb])
print(f"  framed:   BATCH {bf}/{len(b)}   NOBATCH {nf}/{len(nb)}")
print(f"  ok median: BATCH {int(bok)}   NOBATCH {int(nok)}")
print()
# a difference must be large to mean anything: ok varies 88..2979 run-to-run in
# loopback, so only a framing-vs-not difference or a big ratio is interpretable.
if bf == 0 and nf == 0:
    print("  >>> INCONCLUSIVE: NEITHER arm framed. The board is likely in the persistent")
    print("      non-framing state -- reboot clears it -- so this run compares nothing.")
elif (bf > 0) != (nf > 0):
    win = "NOBATCH" if nf > 0 else "BATCH"
    print(f"  >>> DIFFERENT: only {win} frames. tx_send_batch IS implicated -- the submit")
    print(f"      path is the -S/-G difference and the fix is to use the per-frame path.")
elif bok and nok and (max(bok, nok) / max(min(bok, nok), 1) > 3):
    print("  >>> MATERIAL DIFFERENCE in ok (>3x). Worth pursuing; collect more cycles.")
else:
    print("  >>> CLEAN / NO DIFFERENCE. Both arms behave the same, so tx_send_batch is")
    print("      NOT the -S/-G difference. The last named candidate is closed. Do NOT")
    print("      open another hypothesis or take another on-air run without deciding")
    print("      first whether Layer B on air is the right instrument at all.")
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
