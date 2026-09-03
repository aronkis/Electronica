#!/bin/bash
# =============================================================================
# loopback_anchor.sh -- is the loopback wedge anchored to the ARM, or to the
# daemon's own stream start?
#
# THE QUESTION. loopback_ttw just produced 8/8 wedges with the last four tight at
# 45/45/45/40 s. A reproducible ~45 s wedge is either a deterministic time-triggered
# event counted from the fabric ARM (a periodic calibration would fit -- this
# campaign has documented a ~1.5 s BBDC cadence), or it is counted from when the
# byte stream starts flowing. Those have identical TTW when arm and start are a
# fixed distance apart, which they have been in every run so far (arm at t=6).
#
# THE TEST. Keep stream-first ordering (daemon first, THEN arm -- flipping the other
# way starts the modulator on an underrunning FIFO, bringup_r2r3.sh:128), and VARY
# the arm time. TTW is always measured from the daemon's own t=0.
#     anchored to the ARM    -> TTW = arm_delay + constant   (rises 1:1 with delay)
#     anchored to the STREAM -> TTW = constant               (flat vs delay)
#
# WHY THIS RUN CAN SUCCEED WHERE THE ON-AIR ONE COULD NOT. ttw_anchor_control.sh was
# inconclusive because by the time it ran the rig had returned to the fast-wedge
# state, so every arm read the detector floor (~0.3 s) -- a floored value is constant
# regardless of what it is anchored to, and discriminates nothing. Here the rig is in
# the stable ~45 s state and the floor is nowhere near.
#
# INTERLEAVED, NOT BLOCKED. loopback_ttw measured +4.0 s per rep of drift, so reps
# are NOT exchangeable and running all of one delay then all of another would
# confound the delay with the trend. Delays are round-robined, and the analysis
# reports the trend alongside the effect.
#
# 0x114/0x118/0x158 are WRITE-ONLY: set, never verified by readback.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
B=${BOARD:-10.0.0.146}
M=${M:-32}
DUR=${DUR:-90}
CYCLES=${1:-3}                      # round-robin passes over the delay set
DELAYS=${DELAYS:-"6 16 26"}         # arm delay after daemon start, seconds
OUT=$D/r3cap/lbanchor_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/anchor.csv
echo "run,cycle,arm_delay_s,ttw_s,ok_final,wedged" > "$CSV"

echo "=== loopback_anchor: cycles=$CYCLES delays='$DELAYS' dur=${DUR}s -> $OUT ==="
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
  for dly in $DELAYS; do
    run=$((run + 1))
    echo "--- run $run (cycle $c, arm at t=${dly}s) ---"
    $W $B "pkill -x qpsk_tun 2>/dev/null; sleep 1; cd /root/host_app_k5; rm -f /dev/shm/lb.log
      QPSK_FRAME=f1536 QPSK_SEQ_KEEPM=1 QPSK_RX_QUEUED=1 setsid chrt -f 50 \
        ./qpsk_tun -S -M $M -r 15360 -d $DUR > /dev/shm/lb.log 2>&1 &
      exit 0" >/dev/null 2>&1
    sleep "$dly"; arm_loopback; sleep $((DUR - dly - 3))
    $W $B 'cat /dev/shm/lb.log' 2>/dev/null > "$OUT/run$run.log"
    $W $B 'pkill -x qpsk_tun 2>/dev/null; exit 0' >/dev/null 2>&1
    python3 - "$OUT/run$run.log" "$run" "$c" "$dly" "$CSV" <<'PY'
import re, sys
prog = []
for ln in open(sys.argv[1]):
    m = re.search(r"^seq: t=(\d+)s tx=\d+ ok=(\d+)", ln)
    if m: prog.append((int(m.group(1)), int(m.group(2))))
run, cyc, dly, csv = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
if not prog:
    print("    no stats"); open(csv, "a").write(f"{run},{cyc},{dly},NA,0,NA\n"); raise SystemExit
last = 0
for i in range(1, len(prog)):
    if prog[i][1] > prog[i-1][1]: last = prog[i][0]
t, ok = prog[-1]
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
print(f"    arm@{dly}s -> ttw={ttw}s  ok={ok}  wedged={wedged}")
open(csv, "a").write(f"{run},{cyc},{dly},{ttw},{ok},{wedged}\n")
PY
  done
done

echo
echo "=== VERDICT ==="
python3 - "$CSV" <<'PY'
import csv, sys, statistics as st
rows = [r for r in csv.DictReader(open(sys.argv[1])) if r["wedged"] == "1"]
if len(rows) < 4:
    sys.exit("  too few wedged runs to decide")
by = {}
for r in rows:
    by.setdefault(float(r["arm_delay_s"]), []).append(float(r["ttw_s"]))
ds = sorted(by)
print("  arm_delay -> TTW (from daemon t=0)")
for d in ds:
    v = by[d]
    print(f"    {d:>4.0f}s : {[f'{x:.0f}' for x in v]}   mean {st.mean(v):.1f}s")
print()
allt = [float(r["ttw_s"]) for r in rows]
# FLOOR CHECK FIRST -- the failure that made the on-air control inconclusive.
if max(allt) < 10:
    print("  >>> INCONCLUSIVE: every TTW is at the detector floor. A floored value is")
    print("      constant regardless of anchoring and discriminates NOTHING.")
    raise SystemExit
lo, hi = min(ds), max(ds)
obs = st.mean(by[hi]) - st.mean(by[lo])
exp = hi - lo
spread = st.pstdev(allt)
print(f"  delay range {exp:.0f}s   observed TTW shift {obs:+.1f}s   pooled spread {spread:.1f}s")

# SIGNIFICANCE, not just direction. The first version of this verdict declared
# "anchored to the ARM" off means of 25.0/38.3/50.0 built from n=3,3,2 with a
# within-group spread of ~25s -- an effect indistinguishable from noise that
# happened to slope the right way. That is the same defect as the on-air anchor
# verdict that could not tell "constant" from "floored": a rule with no notion of
# how much evidence it needs. Permutation test on the delay/TTW correlation.
pairs = [(float(r["arm_delay_s"]), float(r["ttw_s"])) for r in rows]
n = len(pairs)
xs = [a for a, _ in pairs]; ys = [b for _, b in pairs]
def corr(x, y):
    mx, my = st.mean(x), st.mean(y)
    num = sum((a-mx)*(b-my) for a, b in zip(x, y))
    dx = sum((a-mx)**2 for a in x) ** 0.5
    dy = sum((b-my)**2 for b in y) ** 0.5
    return num/(dx*dy) if dx and dy else 0.0
r_obs = corr(xs, ys)
# deterministic permutation sweep (no RNG -- Math.random-free, reproducible)
import itertools
perms = list(itertools.permutations(range(n))) if n <= 8 else None
if perms:
    ge = sum(1 for pm in perms if corr(xs, [ys[i] for i in pm]) >= r_obs)
    pval = ge / len(perms)
else:
    # too many to enumerate: fixed-seed shuffle
    import random
    rng = random.Random(12345); ge = 0; N = 20000
    yy = list(ys)
    for _ in range(N):
        rng.shuffle(yy)
        if corr(xs, yy) >= r_obs: ge += 1
    pval = ge / N
print(f"  correlation delay vs TTW: r = {r_obs:+.3f}   permutation p = {pval:.3f}  (n={n})")
print()
MINN = 12
if n < MINN:
    print(f"  >>> UNDERPOWERED: only {n} wedged runs (want >= {MINN}). With a within-group")
    print(f"      spread of ~{spread:.0f}s against a {exp:.0f}s delay range, this cannot separate")
    print(f"      a 1:1 anchor from noise. NO VERDICT. Collect more cycles and re-analyse.")
elif pval > 0.05:
    print(f"  >>> NOT SIGNIFICANT (p={pval:.3f}). TTW does not track the arm delay beyond")
    print(f"      chance. The wedge is not a deterministic arm-anchored event at this")
    print(f"      resolution; a rate/occupancy or race explanation fits better.")
elif abs(obs - exp) < 0.4 * exp:
    print(f"  >>> ARM-ANCHORED (p={pval:.3f}): TTW rises ~1:1 with arm delay. A deterministic")
    print(f"      time-triggered event a fixed interval after the arm.")
elif abs(obs) < 0.4 * exp:
    print(f"  >>> STREAM-ANCHORED (p={pval:.3f}): TTW is flat vs arm delay -- it counts from")
    print(f"      when the byte stream starts, not from the fabric arm.")
else:
    print(f"  >>> PARTIAL tracking (p={pval:.3f}): {obs:+.1f}s against {exp:.0f}s expected.")
print()
print("  NOTE: runs are sequential under a measured +4s/rep drift, so delays were")
print("  round-robined rather than blocked. Compare within cycles if the trend is large.")
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
