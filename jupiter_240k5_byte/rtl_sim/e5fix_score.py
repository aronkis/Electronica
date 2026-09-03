#!/usr/bin/env python3
"""Score burst-force runs: per-frame BIST errors after the force; persistence = frames with >0 errors after the
force until the first run of 5 clean frames; steady = errors/frame over the last 30 frames."""
import sys,glob,os
def score(path):
    rows=[]; forced_at=None; hdr={}
    for l in open(path):
        if l.startswith('#'):
            if 'FORCED' in l: forced_at=int(l.split('packet')[1].split()[0])
            if 'offset_before' in l: hdr=dict(kv.split('=') for kv in l[1:].split())
            continue
        p=l.split()
        if len(p)>=4: rows.append((int(p[0]),int(p[1]),int(p[3])))
    if not rows: return None
    after=[r for r in rows if forced_at is None or r[0]>forced_at]
    before=[r for r in rows if forced_at is not None and r[0]<=forced_at]
    pers=0; clean=0
    for _,e,_ in after:
        if e>0: pers+=1; clean=0
        else:
            clean+=1
            if clean>=5: break
    last=after[-30:] if len(after)>=30 else after
    steady=sum(e for _,e,_ in last)/len(last) if last else float('nan')
    tot=sum(e for _,e,_ in after); rst=(rows[-1][2]-rows[0][2])
    return dict(frames=len(rows), forced_at=forced_at, pre_err=sum(e for _,e,_ in before), after_frames=len(after),
                persist=pers, steady=steady, total_after=tot, rstcs=rst, **hdr)
for f in sorted(glob.glob(sys.argv[1] if len(sys.argv)>1 else 'e5fix_runs/*_frames.txt')):
    s=score(f); n=os.path.basename(f).replace('_frames.txt','')
    if s: print(f"{n:14s} frames={s['frames']:3d} after={s['after_frames']:3d} pre_err={s['pre_err']} persist_frames={s['persist']} steady_err/frame={s['steady']:.1f} total_after={s['total_after']} rstcs_delta={s['rstcs']} {('off='+s.get('offset_before','')+' shift='+s.get('shift','')) if 'shift' in s else ''}")
