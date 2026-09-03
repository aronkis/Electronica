#!/usr/bin/env python3
"""Decode PdTelemetry records from a raw rx2 debug-IQ capture (iq_debug_mux 0x10C = 4 -> P1cDtc).

Packing taken verbatim from s1_rtl_beatfix3/hdlsrc/commhdlQPSKTxRxLoopback/PdTelemetry.v:
  telI = w[31:16], telQ = w[15:0]; one 32-bit word `w` per slot, slots 0..6 per preamble event.
  s0 = 0xE0000000 | (tRef&2047)<<17 | (tOff&2047)<<6 | flags
       flags bit0 done, bit1 newPk, bit2 succ, bit3 thrEx, bit4 sync, bit5 armed
  s1 = dI<<16 | dQ
  s2 = (taRef&2047)<<21 | (accOff&2047)<<10 | (fifoEnt&511)<<1 | vPop
  s3 = tRefLong   s4 = runMax   s5 = heldTs
  s6 = 0xA5000000 | (beatCnt&7)<<21 | (symCtr & 0x1FFFFF)
NOTE the instrument masks: fifoEnt is 9 bits (occupancy 12333 -> 12333 & 511 = 45),
tRef/tOff/taRef/accOff 11 bits, symCtr 21 bits. Excursions of +-1 are still visible.
usage: pdtelemetry_decode.py <capture.bin> [--max N] [--csv out.csv]
"""
import sys, struct, collections

def words(path):
    with open(path,'rb') as f: raw=f.read()
    n=len(raw)//4
    for (i,q) in struct.iter_unpack('<hh', raw[:4*n]):
        yield ((i & 0xFFFF)<<16) | (q & 0xFFFF)

def dedupe(ws):
    prev=None
    for w in ws:
        if w!=prev: yield w
        prev=w

def decode(path, maxrec=None):
    seq=list(dedupe(words(path)))
    recs=[]; i=0
    while i+6 < len(seq):
        s0=seq[i]
        if (s0>>29)==0b111 and (seq[i+6]>>24)==0xA5:
            s1,s2,s3,s4,s5,s6=seq[i+1:i+7]
            recs.append(dict(
                tRef=(s0>>17)&2047, tOff=(s0>>6)&2047,
                done=s0&1, newPk=(s0>>1)&1, succ=(s0>>2)&1, thrEx=(s0>>3)&1, sync=(s0>>4)&1, armed=(s0>>5)&1,
                dI=struct.unpack('<h',struct.pack('<H',(s1>>16)&0xFFFF))[0],
                dQ=struct.unpack('<h',struct.pack('<H',s1&0xFFFF))[0],
                taRef=(s2>>21)&2047, accOff=(s2>>10)&2047, fifoEnt=(s2>>1)&511, vPop=s2&1,
                tRefLong=s3, runMax=s4, heldTs=s5,
                beatCnt=(s6>>21)&7, symCtr=s6&0x1FFFFF))
            i+=7
            if maxrec and len(recs)>=maxrec: break
        else: i+=1
    return recs, len(seq)

def summarise(name, recs, nuniq):
    if not recs:
        print(f"{name}: NO RECORDS (unique words {nuniq}) -- capture is not PdTelemetry (check 0x10C=4)"); return
    f=collections.Counter(r['fifoEnt'] for r in recs)
    t=collections.Counter(r['tOff'] for r in recs)
    ch=[(k,recs[k-1]['tOff'],recs[k]['tOff']) for k in range(1,len(recs)) if recs[k]['tOff']!=recs[k-1]['tOff']]
    fch=[(k,recs[k-1]['fifoEnt'],recs[k]['fifoEnt']) for k in range(1,len(recs)) if recs[k]['fifoEnt']!=recs[k-1]['fifoEnt']]
    print(f"{name}: records={len(recs)} uniq_words={nuniq}")
    print(f"  fifoEnt: {dict(f.most_common(6))}   (12333 & 511 = 45 expected if the delay FIFO is exactly full)")
    print(f"  tOff   : {dict(t.most_common(6))}   changes={len(ch)} {ch[:6]}")
    print(f"  fifoEnt changes={len(fch)} {fch[:6]}")
    print(f"  flags  : done={sum(r['done'] for r in recs)} newPk={sum(r['newPk'] for r in recs)} succ={sum(r['succ'] for r in recs)} "
          f"thrEx={sum(r['thrEx'] for r in recs)} sync={sum(r['sync'] for r in recs)} armed={sum(r['armed'] for r in recs)} vPop={sum(r['vPop'] for r in recs)}")
    print(f"  runMax : min={min(r['runMax'] for r in recs)} max={max(r['runMax'] for r in recs)}  "
          f"symCtr span={min(r['symCtr'] for r in recs)}..{max(r['symCtr'] for r in recs)}  beatCnt={sorted(set(r['beatCnt'] for r in recs))}")

if __name__=='__main__':
    args=[a for a in sys.argv[1:] if not a.startswith('--')]
    mx=None
    if '--max' in sys.argv: mx=int(sys.argv[sys.argv.index('--max')+1])
    for p in args:
        recs,n=decode(p,mx); summarise(p.split('/')[-1], recs, n)
        if '--csv' in sys.argv:
            import csv; out=sys.argv[sys.argv.index('--csv')+1]
            with open(out,'w',newline='') as fh:
                w=csv.DictWriter(fh, fieldnames=list(recs[0].keys())); w.writeheader(); w.writerows(recs)
            print(f"  wrote {out} ({len(recs)} rows)")
