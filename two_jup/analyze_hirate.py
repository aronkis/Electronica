#!/usr/bin/env python3
"""High-rate (1 kHz) stage_poll analysis: per-frame corruption structure of the
119.75 s beat. cap_in/cap_deint/cap_out are RAW packed bits (bit p = the p-th
coded/decoded bit of the frame), so we can read the exact error pattern.

Reports: corrupt RUNS (consecutive corrupt samples ~= consecutive corrupt frames),
the set of distinct corrupt coded-bit words, per-word error weight vs golden, and
exhaustive shift tests (is a corrupt word = golden serial-shifted by k bits?).
"""
import sys, csv
from collections import Counter, defaultdict

def H(r,k):
    try: return int(r[k],16)
    except: return None

def popcount(x): return bin(x & 0xFFFFFFFF).count('1')

def main():
    rows=list(csv.DictReader(open(sys.argv[1])))
    t=[int(r['t_ms']) for r in rows]
    dur=(t[-1]-t[0])/1000.0
    print("samples=%d span=%.1fs rate=%.0f Hz"%(len(rows),dur,len(rows)/max(dur,1e-9)))
    caps=['cap_in','cap_deint','cap_out']
    gold={c:Counter(H(r,c) for r in rows).most_common(1)[0][0] for c in caps}
    for c in caps: print("  golden %s = 0x%08X"%(c,gold[c]))

    # burst windows via bit_errors_out 1s buckets
    sec=defaultdict(list)
    for r in rows:
        if H(r,'bit_errors_out') is not None: sec[t[rows.index(r)]//1000 if False else int(r['t_ms'])//1000].append(H(r,'bit_errors_out'))
    # simpler: recompute with index
    sec=defaultdict(list)
    for i,r in enumerate(rows):
        v=H(r,'bit_errors_out')
        if v is not None: sec[t[i]//1000].append(v)
    secs=sorted(sec); rate={}; prev=None
    for s in secs:
        v=sec[s][-1]
        if prev is not None: rate[s]=(v-prev)&0xFFFFFFFF
        prev=v
    import statistics
    fl=statistics.median(list(rate.values())) if rate else 0
    th=max(500,fl*5)
    bursts=[]; inb=False
    for s in sorted(rate):
        if rate[s]>th:
            if not inb: st=s; sm=0; inb=True
            sm+=rate[s]; last=s
        elif inb: bursts.append((st,last,sm)); inb=False
    if inb: bursts.append((st,last,sm))
    print("bursts:", [("%d-%ds"%(a,b),sz) for a,b,sz in bursts])

    def inburst(ms): return any(a*1000<=ms<=(b+1)*1000 for a,b,_ in bursts)

    for c in caps:
        g=gold[c]
        # runs of corrupt samples
        runs=[]; cur=0
        for i,r in enumerate(rows):
            v=H(r,c)
            if v is not None and v!=g and inburst(t[i]):
                cur+=1
            else:
                if cur>0: runs.append(cur); cur=0
        if cur>0: runs.append(cur)
        corr=[H(r,c) for i,r in enumerate(rows) if H(r,c) is not None and H(r,c)!=g and inburst(t[i])]
        print("\n== %s == golden=0x%08X  corrupt_samples=%d  runs=%d (len hist: %s)"%(
            c,g,len(corr),len(runs),Counter(runs).most_common(6)))
        cc=Counter(corr)
        print("   distinct corrupt words=%d; top:"%len(cc))
        for w,n in cc.most_common(8):
            e=w^g
            print("     0x%08X x%d  err_weight=%d/32"%(w,n,popcount(e)))
        # shift test on the most common corrupt word
        if cc:
            w=cc.most_common(1)[0][0]
            best=None
            for k in range(-16,17):
                if k==0: continue
                sh=((g<<k)&0xFFFFFFFF) if k>0 else (g>>(-k))
                hd=popcount(sh^w)
                if best is None or hd<best[1]: best=(k,hd)
            print("   best serial-shift match for 0x%08X: shift=%+d hamming=%d/32"%(w,best[0],best[1]))

    # cross-stage: do in/deint/out corrupt on the SAME samples?
    both=0; only_in=0
    for i,r in enumerate(rows):
        if not inburst(t[i]): continue
        di=H(r,'cap_in')!=gold['cap_in']
        do=H(r,'cap_out')!=gold['cap_out']
        if di and do: both+=1
        elif di and not do: only_in+=1
    print("\ncross-stage in-burst: cap_in&cap_out both corrupt=%d, cap_in-only=%d"%(both,only_in))

if __name__=='__main__': main()
