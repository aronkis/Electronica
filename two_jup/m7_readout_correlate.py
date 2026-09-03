#!/usr/bin/env python3
"""m7_readout_correlate.py -- READOUT A vs COHERENT-SHIFT discriminator.

Golden coded-bit cycle from the bit-true BEATOBS sim (dbg1I per-clk dump:
bit0=dataOut, bit1=startOut, bit2=validOut), captured segments from the banked
on-silicon ILA CSVs (probe8 same packing). Bits sampled at validOut RISING
edges (valid holds 2 clk per enb beat). Cyclic correlation of each capture
segment against the golden frame cycle over all offsets; plus soft-symbol
(probe10/11) vs decision (probe8[4:3]) demap check over 8 mappings x lags.
"""
import sys, csv

def bits_from_dump(path):
    seq=[]; starts=[]; pv=0
    for ln in open(path):
        v=int(ln.strip(),16)
        val=(v>>2)&1
        if val and not pv:
            seq.append(v&1)
            if (v>>1)&1: starts.append(len(seq)-1)
        pv=val
    return seq,starts

def parse_run(path):
    rows=[]
    with open(path) as f:
        r=csv.reader(f)
        for i,row in enumerate(r):
            if i<2: continue
            rows.append(row)
    p8=[int(r[11],16) for r in rows]
    p10=[int(r[13],16) for r in rows]
    p11=[int(r[14],16) for r in rows]
    return p8,p10,p11

def seg_from_p8(p8):
    seq=[]; starts=[]; pv=0
    for v in p8:
        val=(v>>2)&1
        if val and not pv:
            seq.append(v&1)
            if (v>>1)&1: starts.append(len(seq)-1)
        pv=val
    return seq,starts

def best_cyclic(seg,cyc):
    L=len(cyc); n=len(seg); best=(0.0,-1)
    for off in range(L):
        m=0
        for i in range(n):
            if seg[i]==cyc[(off+i)%L]: m+=1
        f=m/n
        if f>best[0]: best=(f,off)
    return best

def sx16(v):
    return v-65536 if v>=32768 else v

def demap_check(p8,p10,p11):
    # decision-change instants at validOut rising edges
    events=[]  # (decision2bit, softI, softQ)
    pv=0
    for k,v in enumerate(p8):
        val=(v>>2)&1
        if val and not pv:
            dec=(v>>3)&3
            events.append((dec,sx16(p10[k]),sx16(p11[k])))
        pv=val
    best=(0.0,None,0)
    for lag in range(0,4):
        for m in range(8):
            swap=m&1; invI=(m>>1)&1; invQ=(m>>2)&1
            match=0; tot=0
            for i in range(len(events)-lag):
                dec,si,sq=events[i+lag][0],events[i][1],events[i][2]
                bi=1 if si<0 else 0; bq=1 if sq<0 else 0
                if invI: bi^=1
                if invQ: bq^=1
                b0,b1=(bq,bi) if swap else (bi,bq)
                d=(b1<<1)|b0
                tot+=1
                if d==dec: match+=1
            if tot and match/tot>best[0]: best=(match/tot,(swap,invI,invQ),lag)
    return best,len(events)

gold,gstarts=bits_from_dump('/tmp/m7_dbg1.txt')
print(f"golden dump: {len(gold)} bits, starts at {gstarts}")
if len(gstarts)>=2:
    L=gstarts[1]-gstarts[0]
    cyc=gold[gstarts[0]:gstarts[1]]
else:
    sys.exit("need 2 frame starts in golden dump")
print(f"golden frame cycle: {L} bits")

base='/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/r3cap/beatcap_20260820_221515/'
for name,fn in [('GAP(run1)','run1_raw.csv'),('INWIN(run2)','run2_qualified.csv')]:
    p8,p10,p11=parse_run(base+fn)
    seg,sstarts=seg_from_p8(p8)
    print(f"\n{name}: {len(seg)} bits extracted, startOut pulses at bit idx {sstarts}")
    frac,off=best_cyclic(seg,cyc)
    print(f"  best cyclic match: {100*frac:.2f}% at offset {off}")
    # second-best sanity: chance floor
    if sstarts:
        # absolute anchor: segment bit sstarts[0] is frame-start -> golden offset 0
        anchored_off=(0 - sstarts[0]) % L
        m=sum(1 for i in range(len(seg)) if seg[i]==cyc[(anchored_off+i)%L])
        print(f"  anchored (startOut) offset {anchored_off}: match {100*m/len(seg):.2f}%")
    (bfrac,bmap,blag),nev=demap_check(p8,p10,p11)
    print(f"  soft-vs-decision demap: best {100*bfrac:.2f}% (map swap/invI/invQ={bmap}, lag={blag}, events={nev})")
