#!/usr/bin/env python3
"""Score sim_burst_force per-frame logs: errors/frame before/after the force, persistence, NCO phase drift.
Columns: packet errs clks rstcs forced occ=N mu=M cnt=C push=P pop=Q"""
import sys, re, statistics
def load(p):
    rows=[]; notes=[]
    for l in open(p):
        if l.startswith('#'): notes.append(l.strip()); continue
        f=l.split(); d={'pk':int(f[0]),'err':int(f[1]),'clk':int(f[2]),'rst':int(f[3]),'forced':int(f[4])}
        for kv in f[5:]:
            k,v=kv.split('='); d[k]=int(v)
        rows.append(d)
    return rows, notes
for p in sys.argv[1:]:
    rows,notes=load(p)
    if not rows: print(p, "no frames"); continue
    pre=[r for r in rows if 40<=r['pk']<=79]; post=[r for r in rows if r['pk']>=83]
    def m(x): return statistics.mean([r['err'] for r in x]) if x else float('nan')
    errpost=[r['err'] for r in post]; nz=sum(1 for e in errpost if e>0)
    occ=[r.get('occ') for r in rows if 'occ' in r]; cnt=[r.get('cnt') for r in rows if 'cnt' in r]; mu=[r.get('mu') for r in rows if 'mu' in r]
    print(f"{p}: frames={len(rows)} pre(40-79)={m(pre):.1f}/fr post(83+)={m(post):.1f}/fr frames_with_errors_post={nz}/{len(post)} max={max(errpost) if errpost else 0} rstcs={rows[-1]['rst']} occ pre/post={pre[-1].get('occ') if pre else None}/{post[-1].get('occ') if post else None} occ_range={min(occ) if occ else None}-{max(occ) if occ else None}")
    if cnt: print(f"   NCO cnt at frame starts: first={cnt[:5]} last={cnt[-5:]} mu first={mu[:5]} last={mu[-5:]}")
    for n in notes: print("   ", n)
