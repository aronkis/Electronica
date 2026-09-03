#!/usr/bin/env python3
"""score_mm2s.py -- score sim_byte_mm2s rxw output.

Each RX word is either a tag 0xB000_nnnn_????_jjjj (transfer n, word j),
zero (host pad), or unknown. Packets are delimited by the 'user' flag (first)
and 'last' flag. For every packet print:
  pkt#  nwords  w0=(n,j)  dup(w0)  contiguity-verdict
Contiguity: after dedup of leading w0 repeats, words must be (n, j0), (n, j0+1)...
crossing into zero-pad after j=190. Verdict flags: OFFSET(j0!=0), DUP(k>1),
REPLAY(n repeats across packets with same content), NOISE(untagged nonzero).
"""
import sys, re
gate = '--gate' in sys.argv
allow_zero = '--allow-zero-pkts' in sys.argv
args=[a for a in sys.argv[1:] if not a.startswith('--')]
fn = args[0]
NDW = int(args[1]) if len(args)>1 else 191
words=[]
for ln in open(fn):
    h,l,u = ln.strip().split(',')
    words.append((int(h,16), int(l), int(u)))
# split packets on user flag / last flag
pkts=[]; cur=[]
for w,l,u in words:
    if u and cur: pkts.append(cur); cur=[]
    cur.append((w,l))
    if l: pkts.append(cur); cur=[]
if cur: pkts.append(cur)
def dec(w):
    if w==0: return ('Z',0)
    if (w>>60)==0xB: return ((w>>32)&0xFFFF, w&0xFFFF)
    return ('X',w)
print(f"packets={len(pkts)} totwords={len(words)}")
results=[]
for i,p in enumerate(pkts):
    ws=[dec(w) for w,_ in p]
    w0=ws[0]; d=1
    while d<len(ws) and ws[d]==w0: d+=1
    tail=ws[d-1:]  # from the last copy of w0
    # contiguity from the last dup copy
    ok=True; noise=0; zerons=0
    if isinstance(w0[0],int):
        n0,j0=w0
        expj=j0
        for k,(n,j) in enumerate(tail):
            if n=='Z': zerons+=1; continue
            if n=='X': noise+=1; ok=False; continue
            if j!=expj+k or (n-n0) not in (0,1): ok=False
    else:
        n0,j0=w0,None
    flags=[]
    if isinstance(w0[0],int) and w0[1]!=0: flags.append(f"OFFSET(j0={w0[1]})")
    if d>1: flags.append(f"DUP(x{d})")
    if not ok: flags.append("NONCONTIG")
    if noise: flags.append(f"NOISE({noise})")
    print(f"pkt{i:3d} n={len(p):4d} w0={w0} dup={d} zeros={zerons} {' '.join(flags) or 'CLEAN'}")
    results.append((w0,d,ok,noise,zerons,len(p)))

if gate:
    # GATE MODE: every tagged packet (INCLUDING the first = frame-1 scoring)
    # must be clean: dup==1, j0==0, contiguous, no untagged noise, and no
    # embedded zero words (zeros==0 for full packets: a phase offset always
    # manifests as trailing zero-pad words). All-zero packets allowed only
    # with --allow-zero-pkts (gap-induced realign frames).
    fails=[]
    tagged=0
    for i,(w0,d,ok,noise,zerons,n) in enumerate(results):
        if w0[0]=='Z' and d==n:
            if not allow_zero and tagged>0: fails.append(f"pkt{i}: unexpected all-zero packet")
            continue
        if not isinstance(w0[0],int):
            fails.append(f"pkt{i}: untagged w0 {w0}"); continue
        tagged+=1
        if d!=1: fails.append(f"pkt{i}: w0 dup x{d}")
        if w0[1]!=0: fails.append(f"pkt{i}: OFFSET j0={w0[1]}")
        if not ok: fails.append(f"pkt{i}: non-contiguous")
        if noise: fails.append(f"pkt{i}: {noise} untagged words")
        if zerons and not allow_zero: fails.append(f"pkt{i}: {zerons} embedded zero words")
        # with --allow-zero-pkts trailing zeros = gap-induced partial frame (allowed; contiguity still enforced)
    if tagged < 3: fails.append(f"only {tagged} tagged packets (need >=3)")
    if fails:
        print("MM2S_GATE FAIL:"); [print(" ",f) for f in fails]; sys.exit(1)
    print(f"MM2S_GATE PASS ({tagged} tagged packets, frame-1 scored)")
