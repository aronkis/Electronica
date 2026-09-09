#!/bin/bash
# Arm-lottery experiment v2 -- fixed instrumentation (remote emits a flat dump; parsed
# locally). v1's remote helper used positional args inside nested quotes and silently
# produced empty fields for all 20 arms; the rates were fine, the state was lost.
set -u
D=/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup; W=$D/anyssh.sh; IP=10.0.0.146
OUT=$D/armstat/v2_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
N=${1:-20}
for n in $(seq 1 $N); do
  GATE_TRIES=1 SSI146="5 4" RXQ=1 bash $D/bringup_r2r3.sh r3 > "$OUT/bringup_$n.log" 2>&1
  rate=$(grep -oE "146 rx=[0-9]+" "$OUT/bringup_$n.log" | head -1 | cut -d= -f2)
  $W $IP 'B=/sys/kernel/debug/iio/iio:device2
for a in rx0_ssi_clk_delay rx0_ssi_i_data_delay rx0_ssi_q_data_delay rx0_ssi_strobe_delay tx0_ssi_clk_delay tx0_ssi_i_data_delay tx0_ssi_q_data_delay tx0_ssi_strobe_delay; do
  echo "$a=$(cat $B/$a 2>/dev/null)"
done
echo "--rx0status--"; cat $B/rx0_ssi_test_mode_status 2>/dev/null
echo "--tx0status--"; cat $B/tx0_ssi_test_mode_status 2>/dev/null
echo "--ensm--"; cat /sys/bus/iio/devices/iio:device2/in_voltage0_ensm_mode 2>/dev/null; cat /sys/bus/iio/devices/iio:device2/out_voltage0_ensm_mode 2>/dev/null' 2>/dev/null > "$OUT/state_$n.txt"
  printf "  arm %2d: rate=%-6s state captured (%s lines)\n" "$n" "${rate:-?}" "$(wc -l < "$OUT/state_$n.txt")"
  echo "${rate:-0}" > "$OUT/rate_$n.txt"
done
python3 - "$OUT" <<'PY'
import sys,os,re,collections
d=sys.argv[1]; recs=[]
for f in sorted(os.listdir(d)):
    m=re.match(r'rate_(\d+)\.txt',f)
    if not m: continue
    n=m.group(1)
    rate=int(open(os.path.join(d,f)).read().strip() or 0)
    st={}
    p=os.path.join(d,f'state_{n}.txt')
    if os.path.exists(p):
        sec=None
        for line in open(p):
            line=line.strip()
            if line.startswith('--'): sec=line.strip('-'); continue
            if '=' in line and sec is None:
                k,v=line.split('=',1); st[k]=v
            elif ':' in line and sec:
                k,v=line.split(':',1); st[f'{sec}.{k.strip()}']=v.strip()
            elif line and sec=='ensm': st.setdefault('ensm',[]) ; st['ensm']=st.get('ensm','')+line+'/'
    recs.append((n,rate,st))
def cls(r): return 'FULL' if r>=1150 else ('0.71x' if 850<=r<1150 else ('0.42x' if 350<=r<850 else 'DEAD'))
g=collections.defaultdict(list)
for n,rate,st in recs: g[cls(rate)].append(st)
print(f"\n=== {len(recs)} arms ===")
for k,v in sorted(g.items()): print(f"   {k:<7} {len(v):2d}/{len(recs)}  ({100*len(v)/len(recs):.0f}%)")
keys=set()
for _,_,st in recs: keys|=set(st.keys())
print("\nfield values per outcome class (looking for SEPARATION):")
for k in sorted(keys):
    vals={c:sorted({s.get(k,'?') for s in v}) for c,v in g.items()}
    allv=set()
    for s in vals.values(): allv|=set(s)
    if len(allv)==1: continue          # constant, uninformative
    classes=[c for c in vals]
    sep=all(not (set(vals[a]) & set(vals[b])) for i,a in enumerate(classes) for b in classes[i+1:])
    print(f"   {k:<28} {dict(vals)}{'   <== SEPARATES CLASSES' if sep else ''}")
print("\n(if nothing separates: the bad arm state is NOT visible in the driver's register set)")
PY
