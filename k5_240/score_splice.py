#!/usr/bin/env python3
"""Score a splice-sim rxw output against the unspliced reference (out_ref).

Packets: 16x64-bit words; seq = word0 >> 32.  Verdict per ref seq:
OK / DAMAGED (word+bit mismatch counts, +-64-bit shift classification) / LOST.
Usage: score_d2.py TARGET_PREFIX [REF_PREFIX]   (files <prefix>_rxw.txt)
"""
import sys

def packets(fn):
    pk, cur = [], []
    for l in open(fn):
        l = l.strip()
        if not l:
            continue
        h, last, user = l.split(',')
        cur.append(int(h, 16))
        if int(last):
            pk.append(cur)
            cur = []
    return [p for p in pk if len(p) == 16]

def bits(words):
    return ''.join(f'{w:064b}' for w in words)

def shiftmatch(tb, rb, shifts=(64, -64, 32, -32)):
    # fraction of overlapping bits equal when target is shifted by s vs ref
    best = None
    for s in shifts:
        if s >= 0:
            a, b = tb[s:], rb[:len(rb)-s]
        else:
            a, b = tb[:len(tb)+s], rb[-s:]
        eq = sum(1 for x, y in zip(a, b) if x == y) / len(a)
        if best is None or eq > best[1]:
            best = (s, eq)
    return best

tgt = sys.argv[1]
ref = sys.argv[2] if len(sys.argv) > 2 else 'out_ref'
rp = {p[0] >> 32: p for p in packets(f'{ref}_rxw.txt')}
tp = {}
dup = 0
for p in packets(f'{tgt}_rxw.txt'):
    s = p[0] >> 32
    if s in tp:
        dup += 1
    tp[s] = p

rs = sorted(rp)
lo, hi = rs[0], rs[-1]
ok = lost = dam = 0
damaged = []
for s in rs:
    if s not in tp:
        lost += 1
        damaged.append((s, 'LOST', None))
        continue
    if tp[s] == rp[s]:
        ok += 1
        continue
    dam += 1
    tb, rb = bits(tp[s]), bits(rp[s])
    nbit = sum(1 for x, y in zip(tb, rb) if x != y)
    sh, frac = shiftmatch(tb, rb)
    damaged.append((s, f'DAMAGED bits={nbit}', f'bestshift={sh:+d} match={frac:.3f}'))
extra = sorted(set(tp) - set(rp))
print(f'{tgt}: ref_seqs={len(rs)} [{lo}..{hi}] OK={ok} DAMAGED={dam} LOST={lost} dup={dup} extra={len(extra)}')
for s, v, x in damaged:
    print(f'  seq={s} idx={s-lo} {v}' + (f' {x}' if x else ''))
