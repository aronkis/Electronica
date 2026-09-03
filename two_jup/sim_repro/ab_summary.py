#!/usr/bin/env python3
"""ab_summary.py -- A/B table for the FIFO image: PER/CP95UL per leg (accept_analyze),
comb cadence + bins from framelogs, 0x1B0 dropped-words-per-transfer from the polls.
Usage: ab_summary.py <r3cap glob prefix>... e.g. fifobase_ fiforxq1full_ fifofifo4k_rxq0_ fifofifo4k_rxq1_"""
import sys, glob, re, subprocess, numpy as np
sys.path.insert(0,'/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup')
from frame_taxonomy import read_frames
from collections import Counter
S='/tmp/claude-1000/-mnt-onetb-scratch-qpsk-jupiter-modem/4cb08d3f-5c30-4165-8bec-058b8fd4daa6/scratchpad/'
polls={}
for f in glob.glob(S+'ab_*.txt')+glob.glob(S+'modeleg_polls.txt'):
    for l in open(f):
        m=re.match(r'POLL2 (\S+) 0x104=0x([0-9A-Fa-f]+) 0x1B0=0x([0-9A-Fa-f]+)',l)
        if m: polls.setdefault(f.split('/')[-1],[]).append((int(m.group(2),16),int(m.group(3),16)))
for pre in sys.argv[1:]:
    for d in sorted(glob.glob('/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/r3cap/'+pre+'*')):
        out=subprocess.run(['python3','/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/accept_analyze.py',d+'/frames.bin'],capture_output=True,text=True).stdout
        m=re.search(r'PER=([\d.]+)% \((\d+)/(\d+)\)\s+CP95UL=([\d.]+)%.*bins=(\{[^}]*\})',out)
        if not m:
            print(f"{d.split('/')[-1]:36s} UNUSABLE"); continue
        fr=read_frames(d+'/frames.bin'); c=fr['crc_ok']; t=fr['t_mono_ns'].astype(np.int64); live=(t-t[0])>20e9
        i=np.where((c==0)&live)[0]; ev=[]
        for j in i:
            if ev and j-ev[-1][1]<=2: ev[-1][1]=j
            else: ev.append([j,j])
        et=np.array([t[a] for a,b in ev]); dt=np.diff(et)/1e6 if len(ev)>2 else np.array([0.])
        span=(t[live][-1]-t[live][0])/1e9
        mode=subprocess.run(['grep','-a','-c','queued-request',d+'/qpsk_tun.log'],capture_output=True,text=True).stdout.strip()
        print(f"{d.split('/')[-1]:36s} RXQ={'1' if mode!='0' else '0'} PER={m.group(1)}% ({m.group(2)}/{m.group(3)}) CP95UL={m.group(4)}% events/s={len(ev)/span:.1f} inter-event median={np.median(dt):.2f}ms bins={m.group(5)}")
for k,v in polls.items(): print(k, "0x1B0 words per transfer at POLL2:", [round(o/max(p/16,1),2) for p,o in v])
