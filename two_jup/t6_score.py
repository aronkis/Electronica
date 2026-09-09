#!/usr/bin/env python3
"""Task 6: per-frame displacement from a raw DDR capture.

The existing instrument samples ONE frame per second out of ~1272 (§32), so
every burst figure in this campaign is a lower bound rather than a duty cycle.
A raw capture carries every frame, so this measures displacement per frame --
~1272x the time resolution -- and can watch the slip evolve inside a burst
instead of catching 3 samples of it.

Method: for each demod marker, take the 16 hard decisions at marker+skew and
look the word up in offsetmap/tap3_word_to_offset.tsv, which enumerates the
word produced at EVERY offset in a frame. The map is injective, so a hit is an
unambiguous displacement in symbols. A word absent from the map is displacement-
inexplicable and is reported separately -- never silently dropped.

§36 skew: the DDR path is combinational at selector 6 while DBGCAP is registered
one enb tick later, so the default skew is +1 and is a parameter, not a guess.

Usage: t6_score.py <capture.bin> [skew]
"""
import collections, os, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = 0x7FFF

def load_map():
    m = {}
    for l in open(os.path.join(HERE, 'offsetmap', 'tap3_word_to_offset.tsv')):
        if l.startswith('#'):
            continue
        w, o = l.split()
        m[int(w, 16)] = int(o)
    return m

def load_cap(p):
    b = open(p, 'rb').read()
    n = len(b) // 8
    w = struct.unpack('<%dh' % (n * 4), b[:n * 8])
    return [(w[i*4], w[i*4+1], w[i*4+2]) for i in range(n)]

def main():
    cap = load_cap(sys.argv[1])
    skew = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    m = load_map()
    span = max(m.values()) + 1
    marks = [i for i, r in enumerate(cap) if r[2] == MARK]
    print(f"{len(cap)} words, {len(marks)} demod markers, skew {skew:+d}, "
          f"frame {span} symbols, map {len(m)} offsets")
    if len(marks) < 2:
        print("TOO FEW MARKERS -- cannot anchor. No result.")
        return 2

    rows, unexplained = [], []
    for mi in marks:
        a = mi + skew
        if a + 16 > len(cap):
            continue
        w = 0
        for k in range(16):
            I, Q = cap[a+k][0], cap[a+k][1]
            w |= (((1 if I < 0 else 0) << 1) | (1 if Q < 0 else 0)) << (30 - 2*k)
        if w in m:
            rows.append((mi, m[w]))
        else:
            unexplained.append((mi, w))

    n = len(rows) + len(unexplained)
    if not n:
        print("no scorable frames")
        return 2
    print(f"scored {n} frames: {len(rows)} placed, {len(unexplained)} displacement-inexplicable "
          f"({100.0*len(unexplained)/n:.1f} %)")

    at0 = sum(1 for _, o in rows if o == 0)
    print(f"  aligned (offset 0): {at0}/{len(rows)} ({100.0*at0/max(1,len(rows)):.1f} %)")
    disp = [(i, o) for i, o in rows if o != 0]
    if disp:
        offs = [o for _, o in disp]
        print(f"  displaced frames: {len(disp)}, offsets {min(offs)}..{max(offs)} symbols "
              f"= {min(offs)/span:.4f}..{max(offs)/span:.4f} of a frame")
        c = collections.Counter(offs)
        print("  most common displacements:")
        for o, k in c.most_common(8):
            print(f"    {o:6d} symbols ({o/span:.4f} of a frame)  x{k}")
        # a slip shows as offset advancing with frame index; a static mis-lock does not
        seq = sorted(disp)
        if len(seq) > 2:
            inc = sum(1 for i in range(len(seq)-1) if seq[i+1][1] > seq[i][1])
            print(f"  monotonicity: {inc}/{len(seq)-1} consecutive displaced frames increase "
                  f"({100.0*inc/(len(seq)-1):.0f} %) -- a progressive slip advances, a static "
                  f"mis-lock does not")
    else:
        print("  no displaced frames in this capture (all aligned)")
    for mi, w in unexplained[:6]:
        print(f"  UNEXPLAINED at word {mi}: 0x{w:08X}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
