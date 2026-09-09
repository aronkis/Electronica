#!/bin/bash
# =============================================================================
# timing_fullarm.sh -- P3 REDESIGNED. Does timing-loop Bn x2 help on a HEALTHY arm?
#
# WHY THIS EXISTS: the two earlier sweeps reported Bn_x2 at +283%/+591% good/s, but
# EVERY control sample in both ran at 484-528 frames/s. The 0.42x degraded plateau is
# ~520; FULL is ~1244. Both sweeps measured a DEGRADED arm end to end, with control
# crc/s 433-465 of ~500 frames (~90% CRC failure). So the result reads as "wider loop
# bandwidth tolerates a bad capture state better", not "wider loop bandwidth is better".
# On a healthy arm Bn x2 may well HURT: more loop bandwidth admits more phase noise.
#
# DESIGN:
#  1. Arm with the NORMAL retry loop until the arm is verified FULL (>=1150 f/s).
#  2. Sweep all four points LIVE inside that ONE session -- the loop-tune registers are
#     runtime-writable, so re-arming between points is unnecessary and would re-roll
#     the lottery, putting the confound straight back in.
#  3. Guard every repetition with an explicit ARM-CLASS CHECK at compiled defaults.
#     An arm-class change is an INVALID sample, same treatment as a negative delta.
# =============================================================================
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; W=$D/anyssh.sh; IP=10.0.0.146
DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
DWELL=${DWELL:-30}
REPS=${REPS:-4}
OUT=$D/loopsweep/fullarm_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/points.csv
FULL_MIN=1150

wr(){ $W $IP "echo '$1 $2' > $DRA" 2>/dev/null; }
restore(){ wr 0x1F8 0x0; wr 0x1FC 0x0; }
wd_stop(){ $W $IP 'pkill -f "[l]ock_watchdog"' 2>/dev/null; }
wd_start(){ $W $IP 'setsid nohup /root/lock_watchdog.sh </dev/null >/dev/null 2>&1 &' 2>/dev/null; }
trap 'echo; echo "INTERRUPTED"; restore; wd_start; exit 130' INT TERM

# ---- step 1: get a FULL arm (normal retry loop, NOT GATE_TRIES=1) ----
echo "=== P3: acquiring a FULL arm (>= ${FULL_MIN} f/s) ==="
ARMRATE=0
for try in $(seq 1 12); do
  SSI146="5 4" RXQ=1 bash $D/bringup_r2r3.sh r3 > "$OUT/bringup_try$try.log" 2>&1
  ARMRATE=$(grep -oE "146 rx=[0-9]+" "$OUT/bringup_try$try.log" | head -1 | cut -d= -f2)
  ARMRATE=${ARMRATE:-0}
  echo "  arm try $try: ${ARMRATE} f/s"
  [ "$ARMRATE" -ge "$FULL_MIN" ] && break
done
if [ "${ARMRATE:-0}" -lt "$FULL_MIN" ]; then
  echo "FATAL: could not obtain a FULL arm in 12 tries (best ${ARMRATE} f/s). Aborting;"
  echo "       measuring loop tuning on a degraded arm is exactly the confound this fixes."
  exit 1
fi
echo "=== FULL arm acquired at ${ARMRATE} f/s -- pinning it for the whole sweep ==="
wd_stop; echo "  lock_watchdog paused (it re-arms on not-locked and resets 0x104 -> negative deltas)"
sleep 5

# ---- measurement primitive ----
pt(){ # $1 label $2 prop $3 integ   (0 0 = compiled default)
  local ph ih
  if [ "$2" = 0 ]; then ph=0x0; ih=0x0; else
    ph=$(python3 -c "print(hex($2 & 0xFFFFFFFF))"); ih=$(python3 -c "print(hex($3 & 0xFFFFFFFF))"); fi
  $W $IP "echo '0x1F8 $ph' > $DRA; echo '0x1FC $ih' > $DRA" 2>/dev/null
  sleep 3
  local out
  out=$($W $IP "echo 0x104 > $DRA; p0=\$(cat $DRA); c0=\$(tail -1 /dev/shm/qpsk_tun.log|grep -oE 'crc_drop=[0-9]+'|cut -d= -f2)
sleep $DWELL
echo 0x104 > $DRA; p1=\$(cat $DRA); c1=\$(tail -1 /dev/shm/qpsk_tun.log|grep -oE 'crc_drop=[0-9]+'|cut -d= -f2)
python3 -c \"
p0=int('\$p0',16); p1=int('\$p1',16); c0=int('\${c0:-0}'); c1=int('\${c1:-0}')
df=p1-p0; dc=c1-c0
print(f'{int(df/$DWELL) if df>=0 else -1} {int(dc/$DWELL) if dc>=0 else -1}')\"" 2>/dev/null)
  local fr=$(echo $out | awk '{print $1}'); local cr=$(echo $out | awk '{print $2}')
  if [ "${fr:-0}" -lt 0 ] || [ "${cr:-0}" -lt 0 ]; then
    printf "    %-12s INVALID (counter reset mid-window)\n" "$1"; return
  fi
  printf "    %-12s frames/s=%-6s crc/s=%-6s good/s=%-6s\n" "$1" "$fr" "$cr" "$((fr-cr))"
  echo "$REP,$1,$fr,$cr,$((fr-cr))" >> "$CSV"
}

# ---- arm-class guard: measure at compiled defaults, short window ----
armclass(){
  restore; sleep 3
  local out
  out=$($W $IP "echo 0x104 > $DRA; p0=\$(cat $DRA); sleep 10; echo 0x104 > $DRA; p1=\$(cat $DRA)
python3 -c \"
p0=int('\$p0',16); p1=int('\$p1',16); d=p1-p0
print(int(d/10) if d>=0 else -1)\"" 2>/dev/null)
  echo "${out:-0}"
}

echo "rep,label,frames_s,crc_s,good_s" > "$CSV"
ORDERS="control Bn_x1.41 Bn_x2.00 Bn_x2.80
Bn_x2.00 control Bn_x2.80 Bn_x1.41
Bn_x2.80 Bn_x1.41 control Bn_x2.00
Bn_x1.41 Bn_x2.80 Bn_x2.00 control"

REP=0
while read -r o1 o2 o3 o4; do
  REP=$((REP+1)); [ "$REP" -gt "$REPS" ] && break
  AC=$(armclass)
  if [ "${AC:-0}" -lt "$FULL_MIN" ]; then
    echo "--- repetition $REP: ARM CLASS CHECK = ${AC} f/s -> NOT FULL, arm degraded mid-run"
    echo "    discarding this repetition and stopping; samples after a class change are invalid."
    break
  fi
  echo "--- repetition $REP (arm class check ${AC} f/s = FULL) ---"
  for nm in $o1 $o2 $o3 $o4; do case $nm in
    control)  pt control 0 0 ;;
    Bn_x1.41) pt Bn_x1.41 -230543 -4334 ;;
    Bn_x2.00) pt Bn_x2.00 -327012 -8720 ;;
    Bn_x2.80) pt Bn_x2.80 -457817 -17085 ;;
  esac; done
done <<< "$ORDERS"

restore; wd_start
echo "defaults restored, wd restarted"
echo "=== SUMMARY on a FULL arm (mean over repeats) ==="
python3 -c "
import csv,collections,statistics
d=collections.defaultdict(list)
rows=list(csv.reader(open('$CSV')))[1:]
for r in rows: d[r[1]].append((int(r[2]),int(r[3]),int(r[4])))
if not d: print('  no valid samples'); raise SystemExit
base=statistics.mean([x[2] for x in d['control']]) if 'control' in d else None
for k in ['control','Bn_x1.41','Bn_x2.00','Bn_x2.80']:
    if k not in d: continue
    f=[x[0] for x in d[k]]; g=[x[2] for x in d[k]]
    mf=statistics.mean(f); mg=statistics.mean(g)
    delta=f'{100*(mg-base)/base:+.1f}%' if base else ''
    print(f'  {k:<10} n={len(f)}  frames/s {mf:7.0f}  good/s {mg:7.0f} {delta}   samples={g}')
print()
print('  Compare against the DEGRADED-arm sweeps (control ~500 f/s, good/s 58-121):')
print('  if Bn_x2 no longer wins here, it is a degraded-mode crutch, not a PER fix.')
"
echo "=== -> $CSV ==="
