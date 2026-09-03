#!/bin/bash
# =============================================================================
# step_forensic.sh -- capture the T8.5/canary telemetry ACROSS the 146 RX
# step-down, to identify which block enters the degraded state.
#
# WHAT IS ESTABLISHED (2026-08-07):
#  - 146 RX steps 1244 -> ~500 f/s within 5-20 s of every arm, then holds.
#  - 148 RX is full rate in 30/30 gate probes; 146 RX in 11/30. The defect is
#    confined to the REVERSE direction (148 TX -> 146 RX).
#  - A 0x000 soft re-arm on 146 restores full rate; an 0x110 rstCS pulse does
#    NOT. So the state is NOT carrier sync -- it is something else that only the
#    full datapath reset clears (AGC accumulator, timing sync, or the packet
#    detector's Delay14 moving-sum threshold accumulator).
#
# HYPOTHESIS WORTH TESTING FIRST: the packet detector. A degraded Delay14
# threshold accumulator makes the detector MISS a fraction of frames while the
# frames it does accept still decode cleanly -- which is exactly what we see
# (rate at 40% but the capture's CRC health reads 99%). Note the deployed image
# already carries the TMR fix, so if this is the mechanism it is NOT a
# single-register upset (TMR would mask that) but a systematic drift, which
# triplication cannot help.
#
# Sequence: 0x000 re-arm -> sample every 250 ms for DUR s -> report each register
# in the window before vs after the step, so the block that changes stands out.
# =============================================================================
set -u
D=$(cd "$(dirname "$0")" && pwd); W=$D/anyssh.sh; IP=${IP:-10.0.0.146}
DUR=${DUR:-90}
OUT=$D/decay/forensic_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
REGS="0x104 0x108 0x150 0x170 0x174 0x178 0x17C 0x180 0x184 0x188 0x1E0 0x1E4 0x15C"

$W $IP 'pkill -f "[l]ock_watchdog"; pkill -f "[s]tallpoll"; sleep 1; echo "  pollers stopped (single-reader rule)"' 2>/dev/null

echo "=== 0x000 re-arm, then $DUR s of canary telemetry at 250 ms ==="
# LT_PROP/LT_INTEG (stored integers, decimal) write the timing-loop gains 0x1F8/0x1FC
# BEFORE the re-arm. Unset -> compiled defaults. Bn x2 is LT_PROP=-327012 LT_INTEG=-8720.
LTP=""; LTI=""
if [ -n "${LT_PROP:-}" ]; then
  LTP=$(python3 -c "print(hex(${LT_PROP} & 0xFFFFFFFF))")
  LTI=$(python3 -c "print(hex(${LT_INTEG} & 0xFFFFFFFF))")
  echo "  timing-loop override: 0x1F8=$LTP 0x1FC=$LTI"
fi
$W $IP "DRA=/sys/kernel/debug/iio/iio:device0/direct_reg_access
TXD=\$(for d in /sys/bus/iio/devices/iio:device*; do [ \"\$(cat \$d/name 2>/dev/null)\" = axi-adrv9002-tx-lpc ] && echo \${d##*/}; done)
T=/sys/kernel/debug/iio/\$TXD/direct_reg_access
echo '0x000 0x1' > \$DRA; sleep 0.5; echo '0x000 0x0' > \$DRA
echo '0x158 0x1' > \$DRA; echo '0x118 0x0' > \$DRA; echo '0x114 0x1' > \$DRA
# 0x000 REVERTS the regfile, so the loop-tune override must be (re)written AFTER it --
# same reason the watchdog re-asserts 0x158/0x118/0x114 here.
if [ -n '$LTP' ]; then echo '0x1F8 $LTP' > \$DRA; echo '0x1FC $LTI' > \$DRA; fi
if [ -n \"\$TXD\" ]; then echo '0x418 0x2' > \$T; echo '0x458 0x2' > \$T; echo '0x044 0x1' > \$T; fi
echo '0x110 0x1' > \$DRA; sleep 0.3; echo '0x110 0x0' > \$DRA
: > /dev/shm/forensic.csv
end=\$(( \$(date +%s) + $DUR ))
while [ \$(date +%s) -lt \$end ]; do
  line=\$(date +%s%N)
  for a in $REGS; do echo \$a > \$DRA; line=\"\$line,\$(cat \$DRA)\"; done
  echo \"\$line\" >> /dev/shm/forensic.csv
  sleep 0.25
done
echo traced \$(wc -l < /dev/shm/forensic.csv)" 2>/dev/null

$W $IP 'cat /dev/shm/forensic.csv' 2>/dev/null > "$OUT/forensic.csv"
echo "=== $(wc -l < "$OUT/forensic.csv") rows -> $OUT/forensic.csv ==="

REGS="$REGS" python3 - "$OUT/forensic.csv" <<'PY'
import sys,csv,os
names=os.environ['REGS'].split()
rows=[]
for r in csv.reader(open(sys.argv[1])):
    if len(r) < len(names)+1: continue
    try: rows.append((int(r[0]),[int(x,16) for x in r[1:len(names)+1]]))
    except ValueError: pass
if len(rows)<20: print("too few samples"); raise SystemExit
t0=rows[0][0]
PK=names.index('0x104')
# instantaneous rate, then locate the step: last index where a trailing window is still fast
rate=[]
for (ta,va),(tb,vb) in zip(rows,rows[1:]):
    dt=(tb-ta)/1e9
    rate.append(((tb-t0)/1e9, (vb[PK]-va[PK])/dt if dt>0 and vb[PK]>=va[PK] else None))
def win(lo,hi):
    v=[r for t,r in rate if r is not None and lo<=t<hi]
    return sum(v)/len(v) if v else 0
print("\n  rate in 5 s blocks:")
T=(rows[-1][0]-t0)/1e9
step=None
for s in range(0,int(T),5):
    r=win(s,s+5); print(f"    {s:3d}-{s+5:3d}s {r:7.0f} f/s")
    if step is None and s>0 and r<800 and win(0,5)>1000: step=s
if step is None:
    print("\n  NO STEP observed in this run -- link stayed fast; rerun.")
    raise SystemExit
print(f"\n  STEP detected at ~{step} s. Comparing registers before vs after:")
def snap(lo,hi):
    sel=[v for t,v in rows if lo<=(t-t0)/1e9<hi]
    return sel
pre=snap(0,step); post=snap(step+5,T)
print(f"  {'reg':<8} {'pre (min..max)':<28} {'post (min..max)':<28} note")
for i,n in enumerate(names):
    if n in ('0x104','0x108'):    # cumulative counters: compare RATES not values
        pr=(pre[-1][i]-pre[0][i])/max(1e-9,(step))
        po=(post[-1][i]-post[0][i])/max(1e-9,(T-step-5))
        print(f"  {n:<8} rate {pr:10.1f}/s          rate {po:10.1f}/s          {'<== RATE CHANGED' if pr>0 and abs(po-pr)/pr>0.2 else ''}")
        continue
    a=[v[i] for v in pre]; b=[v[i] for v in post]
    sa,sb=set(a),set(b)
    note=''
    if not (sa & sb): note='<== DISJOINT (separates the two regimes)'
    elif len(sb)==1 and len(sa)>1: note='<== FROZE after the step'
    elif len(sa)==1 and len(sb)>1: note='<== became active after the step'
    print(f"  {n:<8} {min(a):#011x}..{max(a):#011x}   {min(b):#011x}..{max(b):#011x}   {note}")
PY
