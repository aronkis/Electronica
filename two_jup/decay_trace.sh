#!/bin/bash
# =============================================================================
# decay_trace.sh -- THE DISCRIMINATING MEASUREMENT.
#
# Two competing explanations for "control measures ~500 f/s on a link that armed
# at 1244 f/s", and every previous number on this rig is ambiguous between them:
#
#  (A) RESET ARTIFACT. 0x104 is reset by rstCS. A 30 s window that contains a
#      reset yields (p1-p0) = "frames since the last reset" -- positive, so the
#      negative-delta guard never fires, but far too small. Resets every ~15 s
#      give 1244*15/30 = 622; we measured 491-540. Bn x2 stretching the interval
#      to ~20 s gives 829; we measured 840. One mechanism fits all of it, and it
#      would mean Bn x2 moves the RESET RATE, not the frame rate.
#  (B) REAL DECAY. The link genuinely falls from 1244 to ~500 within seconds.
#      Supported by the soak table: 30-34 s RESET-FREE runs averaged 712 f/s,
#      which resets cannot explain by construction.
#
# Discriminator: sample 0x104 AND 0x150 every 250 ms on a fresh FULL arm with
# NOTHING else touching debugfs, and compute the INSTANTANEOUS rate per interval.
#   - rate holds ~1244 between resets  -> (A), decay is dead
#   - rate falls monotonically, no resets -> (B), decay is the headline
#   - both visible -> we get the reset rate and the decay slope separately
#
# Single on-board reader: the soak CSVs are contaminated because stallpoll and
# lock_watchdog shared the one direct_reg_access address latch (0.09% of rows
# carried a foreign register's value, e.g. 0xc010180 68 times).
# =============================================================================
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; W=$D/anyssh.sh; IP=10.0.0.146
DUR=${DUR:-120}
OUT=$D/decay/$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
FULL_MIN=1150

echo "=== ensuring no other debugfs reader ==="
$W $IP 'pkill -f "[l]ock_watchdog"; pkill -f "[s]tallpoll"; sleep 1
pgrep -f "[l]ock_watchdog" >/dev/null && echo "WARN wd alive" || echo "  wd stopped"
pgrep -f "[s]tallpoll"     >/dev/null && echo "WARN stallpoll alive" || echo "  stallpoll stopped"' 2>/dev/null

echo "=== acquiring a FULL arm ==="
RATE=0
for try in $(seq 1 8); do
  SSI146="5 4" RXQ=1 bash $D/bringup_r2r3.sh r3 > "$OUT/bringup_$try.log" 2>&1
  RATE=$(grep -oE "146 rx=[0-9]+" "$OUT/bringup_$try.log" | head -1 | cut -d= -f2); RATE=${RATE:-0}
  echo "  try $try: ${RATE} f/s"
  [ "$RATE" -ge "$FULL_MIN" ] && break
done
[ "${RATE:-0}" -ge "$FULL_MIN" ] || { echo "FATAL: no FULL arm in 8 tries"; exit 1; }
echo "=== FULL arm at ${RATE} f/s -- tracing immediately (no settle, we want the transient) ==="

# bring-up restarts the watchdog; kill it again so this trace has the bus to itself
$W $IP 'pkill -f "[l]ock_watchdog"; pkill -f "[s]tallpoll"' 2>/dev/null

$W $IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
: > /dev/shm/decay.csv
end=\$(( \$(date +%s) + $DUR ))
while [ \$(date +%s) -lt \$end ]; do
  echo 0x104 > \$DRA; p=\$(cat \$DRA)
  echo 0x150 > \$DRA; r=\$(cat \$DRA)
  echo \"\$(date +%s%N),\$p,\$r\" >> /dev/shm/decay.csv
  sleep 0.25
done
echo traced \$(wc -l < /dev/shm/decay.csv) samples" 2>/dev/null

sshpass -p analog scp -o StrictHostKeyChecking=no root@$IP:/dev/shm/decay.csv "$OUT/decay.csv" 2>/dev/null \
  || $W $IP 'cat /dev/shm/decay.csv' 2>/dev/null > "$OUT/decay.csv"
echo "=== $(wc -l < "$OUT/decay.csv") samples -> $OUT/decay.csv ==="

python3 - "$OUT/decay.csv" <<'PY'
import sys,csv
rows=[]
for r in csv.reader(open(sys.argv[1])):
    if len(r)<3: continue
    try: rows.append((int(r[0]),int(r[1],16),int(r[2],16)))
    except ValueError: pass
if len(rows)<10: print("too few samples"); raise SystemExit
t0=rows[0][0]
print(f"{len(rows)} samples over {(rows[-1][0]-t0)/1e9:.1f} s\n")
print("  t(s)  inst_f/s   d_rstcs  event")
resets=0
inst=[]
for (ta,pa,ra),(tb,pb,rb) in zip(rows,rows[1:]):
    dt=(tb-ta)/1e9
    if dt<=0: continue
    dr=rb-ra
    if pb<pa:
        resets+=1
        print(f"  {(tb-t0)/1e9:5.1f}      --      {dr:+4d}  <== 0x104 RESET ({pa} -> {pb})")
        continue
    rate=(pb-pa)/dt
    inst.append(((tb-t0)/1e9, rate))
    print(f"  {(tb-t0)/1e9:5.1f}  {rate:8.0f}   {dr:+4d}")
print(f"\n=== {resets} resets in {(rows[-1][0]-t0)/1e9:.0f} s ===")
if inst:
    n=len(inst); q=max(1,n//4)
    for lbl,seg in (("first quarter",inst[:q]),("last quarter",inst[-q:])):
        v=[r for _,r in seg]
        print(f"  {lbl:<14} mean {sum(v)/len(v):6.0f} f/s   min {min(v):.0f} max {max(v):.0f}")
    print("\n  VERDICT: monotonic fall with few resets => REAL DECAY (B).")
    print("           steady ~1244 punctuated by resets => RESET ARTIFACT (A).")
PY
