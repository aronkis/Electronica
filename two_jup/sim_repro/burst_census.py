#!/usr/bin/env python3
"""burst_census.py -- H-4: every >200-frame hole in today's framelogs with timestamp, size,
seconds since daemon start, and whether the surrounding frames were delivered (startup vs
steady-state). Usage: burst_census.py r3cap/<dir>..."""
import sys, glob, numpy as np
sys.path.insert(0,'/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup')
from frame_taxonomy import read_frames
rows=[]
for d in sys.argv[1:]:
    try: fr=read_frames(d+'/frames.bin')
    except Exception as e: continue
    c=fr['crc_ok']; t=(fr['t_mono_ns']-fr['t_mono_ns'][0])/1e9; s=fr['host_seq'].astype(np.int64)
    good=np.where(c==1)[0]
    if good.size<2: continue
    gs=s[good]; d_seq=np.diff(gs); big=np.where(d_seq>200)[0]
    for i in big:
        rows.append((d.split('/')[-1], round(float(t[good[i]]),2), int(d_seq[i]-1), 'startup' if t[good[i]]<20 else 'steady'))
    # runs of consecutive crc=0 records > 200 (delivered-corrupt bursts)
    i=0
    while i<len(c):
        if c[i]==0:
            j=i
            while j<len(c)-1 and c[j+1]==0: j+=1
            if j-i+1>200: rows.append((d.split('/')[-1], round(float(t[i]),2), j-i+1, ('startup' if t[i]<20 else 'steady')+'-corruptrun'))
            i=j+1
        else: i+=1
print(f"{'run':38s} {'t(s)':>8s} {'frames':>7s} class")
for r in sorted(rows): print(f"{r[0]:38s} {r[1]:8.2f} {r[2]:7d} {r[3]}")
from collections import Counter
print("summary:", Counter(r[3] for r in rows))
