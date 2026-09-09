#!/usr/bin/env python3
"""Per-frame displacement for LARGE captures (numpy). Tests §51's pre-registration.

New script, not a revision: t6_score.py's struct-based loader cannot hold 67 M
beats. Same method -- 16 hard decisions at each demod marker, looked up in the
injective offset map (§31/§42), with the §36 skew as a parameter.

§51 predicts JUMP: zero frames at offsets strictly between 0 and 6176.
Any such frame falsifies it. A capture with no 0<->rung transition is
UNINFORMATIVE and is reported as such, never as support.
"""
import os, sys, collections
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = 0x7FFF
RUNGS = {6176, 6240, 6299, 6363, 6432, 6489, 6548}

def load_map(name):
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', name)):
        if l.startswith('#'):
            continue
        w, o = l.split()
        m[int(w, 16)] = int(o)
    return m

def main():
    path = sys.argv[1]; skew = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    a = np.fromfile(path, dtype='<i2')
    a = a[:(len(a)//4)*4].reshape(-1, 4)
    m = load_map('tap3_word_to_offset.tsv'); span = max(m.values()) + 1
    mk = np.flatnonzero(a[:, 2] == MARK)
    print(f"{len(a):,} beats, {len(mk):,} demod markers, skew {skew:+d}, frame {span} symbols")
    if len(mk) < 2:
        print("TOO FEW MARKERS -- no result"); return 2
    sign = ((a[:, 0] < 0).astype(np.uint32) << 1) | (a[:, 1] < 0).astype(np.uint32)
    seq = []
    for i in mk:
        s = i + skew
        if s + 16 > len(a):
            break
        w = 0
        for k in range(16):
            w |= int(sign[s+k]) << (30 - 2*k)
        seq.append(m.get(w, None))
    n = len(seq)
    placed = [o for o in seq if o is not None]
    unex = n - len(placed)
    aligned = sum(1 for o in placed if o == 0)
    onrung = sum(1 for o in placed if o in RUNGS)
    inter = [o for o in placed if o is not None and 0 < o < 6176]
    print(f"scored {n} frames: {len(placed)} placed, {unex} displacement-inexplicable")
    print(f"  aligned at 0      : {aligned}")
    print(f"  on a known rung   : {onrung}  {sorted(collections.Counter(o for o in placed if o in RUNGS).items())}")
    print(f"  INTERMEDIATE (0,6176): {len(inter)}   <-- §51 falsifier: any of these kills 'jump'")
    # transitions
    trans = []
    for i in range(1, n):
        a0, a1 = seq[i-1], seq[i]
        if a0 is None or a1 is None:
            continue
        if (a0 == 0) != (a1 == 0):
            trans.append((i, a0, a1))
    print(f"  0<->rung transitions observed: {len(trans)}")
    for i, x, y in trans[:6]:
        print(f"     frame {i}: {x} -> {y}   (step {abs(y-x)})")
    if not trans:
        print("  *** UNINFORMATIVE: this capture contains no 0<->rung transition.")
        print("  *** Per §51 it does NOT count as support for 'jump'.")
    elif inter:
        print("  *** FALSIFIED: intermediate offsets present -- §43's jump claim must be reopened.")
    else:
        print("  *** CONSISTENT WITH JUMP: a transition is present and no intermediate offset appears.")
    return 0

sys.exit(main())
