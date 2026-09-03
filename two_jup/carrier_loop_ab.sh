#!/bin/bash
# =============================================================================
# carrier_loop_ab.sh [passes] [soak_s] -- INTERLEAVED carrier-loop setting comparison.
#
# WHY NOT carrier_loop_sweep.sh. That script visits each setting ONCE for ~15 s. The
# carrier-loop fault is EPISODIC -- Layer A caught an episode inside 152 s (golden 0.4%,
# cfc_std 3925) while the very next baseline read golden 99.3% / cfc_std 220. On a 15 s
# window an episode landing anywhere gets silently attributed to whichever register value
# happened to be live. That is exactly what produced a non-monotonic cfo_threshold
# result: 2x default looked catastrophic (golden 94.0%, biterr/s 4601) while 4x default
# was clean (99.3%, 340). A threshold effect cannot be non-monotonic like that; an
# episode can.
#
# This is the same trap the overnight -M sweep hit: one cycle per point said M=8 ~ M=16
# and legacy was merely mediocre; six INTERLEAVED cycles said otherwise. Same fix here.
#
# METHOD. Round-robin the settings, several passes, so an episode is equally likely to
# hit every arm, and rank on the MEDIAN across passes rather than a single window. Also
# report the per-pass spread and count how many windows look episodic (golden < 90%),
# because "how often does this setting episode" is the actual question -- not "what was
# golden% during one arbitrary 15 s".
#
# Measures IN FABRIC (ROM/BIST), so the DMA plane cannot confound it.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh
A=10.0.0.148; B=10.0.0.146
PASSES=${1:-4}
SOAK=${2:-25}
GOLDEN=0x04922282
OUT=$D/loopsweep/ab_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
CSV=$OUT/results.csv
echo "pass,label,golden_pct,cfc_std,rstcs_per_s,biterr_per_s" > "$CSV"

# label:reg=val[,reg=val...]   ("-" = leave every register at its compiled default)
SETTINGS=${SETTINGS:-"default:- csprop49:0x170=49 csinteg2:0x174=2 cfothr13107:0x184=13107"}

poke(){ $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
  echo enabled>/sys/bus/iio/devices/iio:device0/reg_access; echo '$1 $2'>\$DRA" 2>/dev/null; }

reset_regs(){ for r in 0x170 0x174 0x178 0x17C 0x180 0x184; do poke $r 0x0; done; }

measure(){ # $1 pass  $2 label
  local N=$(( SOAK * 10 ))
  $W $B "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access; rd(){ echo \"\$1\">\$DRA;cat \$DRA; }
   : > /dev/shm/ab.log
   for i in \$(seq $N); do echo \"cap=\$(rd 0x144) rstcs=\$(rd 0x150) cfc=\$(rd 0x154) biterr=\$(rd 0x108)\" >> /dev/shm/ab.log; sleep 0.1; done" 2>/dev/null
  SSH_ASKPASS=$D/askpass.sh SSH_ASKPASS_REQUIRE=force DISPLAY=:0 setsid -w scp \
    -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    root@$B:/dev/shm/ab.log "$OUT/p$1_$2.log" </dev/null 2>/dev/null
  python3 - "$OUT/p$1_$2.log" "$1" "$2" "$CSV" <<'PY'
import re,sys,numpy as np
rows=[]
for ln in open(sys.argv[1]):
    m=re.search(r"cap=0x([0-9a-fA-F]+).*rstcs=0x([0-9a-fA-F]+).*cfc=0x([0-9a-fA-F]+).*biterr=0x([0-9a-fA-F]+)",ln)
    if m: rows.append([int(m.group(i),16) for i in range(1,5)])
if len(rows)<5:
    print(f"  p{sys.argv[2]} {sys.argv[3]:12s} too few samples"); sys.exit()
a=np.array(rows); cap,rst,cfc,be=a[:,0],a[:,1],a[:,2],a[:,3]
sx=lambda u:(int(u)&0x1FFFFF)-(1<<21) if (int(u)&0x1FFFFF)>=(1<<20) else (int(u)&0x1FFFFF)
cfcs=np.array([sx(v) for v in cfc])
g=100*np.mean(cap==0x04922282); dt=len(rst)*0.1
rr=(rst[-1]-rst[0])/dt; br=(be[-1]-be[0])/dt
print(f"  p{sys.argv[2]} {sys.argv[3]:12s} golden={g:5.1f}%  cfc_std={cfcs.std():5.0f}  rstcs/s={rr:.2f}  biterr/s={br:.0f}"
      + ("   <-- EPISODIC" if g<90 else ""))
open(sys.argv[4],'a').write(f"{sys.argv[2]},{sys.argv[3]},{g:.1f},{cfcs.std():.0f},{rr:.2f},{br:.0f}\n")
PY
}

echo "=== carrier_loop_ab: $PASSES passes x ${SOAK}s, interleaved -> $OUT ==="
echo "=== settings: $SETTINGS ==="
echo "--- assuming a ROM/BIST link is already armed (run reverse_rom_soak or the sweep first) ---"

for p in $(seq 1 "$PASSES"); do
  echo "## pass $p/$PASSES"
  for st in $SETTINGS; do
    lbl=${st%%:*}; kvs=${st#*:}
    reset_regs
    if [ "$kvs" != "-" ]; then
      IFS=, ; for kv in $kvs; do poke "${kv%=*}" "${kv#*=}"; done; unset IFS
    fi
    sleep 3
    measure "$p" "$lbl"
  done
done
reset_regs

echo
echo "=== MEDIAN ACROSS PASSES (rank on this, not on any single window) ==="
python3 - "$CSV" <<'PY'
import csv,sys,statistics as st
from collections import defaultdict
d=defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    d[r['label']].append((float(r['golden_pct']),float(r['cfc_std']),float(r['biterr_per_s'])))
print(f"{'setting':14s} {'n':>2} {'med golden':>10} {'med cfc_std':>11} {'med biterr/s':>12} {'episodic':>9}")
for k,v in sorted(d.items(), key=lambda x:-st.median([a for a,_,_ in x[1]])):
    g=[a for a,_,_ in v]; c=[b for _,b,_ in v]; e=[x for _,_,x in v]
    print(f"{k:14s} {len(v):>2} {st.median(g):>9.1f}% {st.median(c):>11.0f} {st.median(e):>12.0f} "
          f"{sum(1 for x in g if x<90):>6}/{len(g)}")
print("\n  'episodic' = windows with golden < 90%. With an intermittent fault this column")
print("  matters more than the medians: the question is how OFTEN a setting episodes.")
PY
