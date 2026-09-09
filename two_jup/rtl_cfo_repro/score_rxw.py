#!/usr/bin/env python3
"""Per-frame scorer for Vwrap_byte_taps _rxw.txt dumps (CFO sweep, operator item 2).

Frames delimited by last==1. Golden frame = the modal 191-word content of the
0 Hz (G1) run. Reports delivered frames, golden-exact frames, and per-frame
bit errors (hex-word XOR popcount) for non-warmup frames.
"""
import sys, collections

def frames_of(path):
    out, cur = [], []
    for ln in open(path):
        h, last, user = ln.strip().split(',')
        cur.append(h)
        if last == '1':
            out.append(tuple(cur)); cur = []
    if cur:
        out.append(tuple(cur))  # trailing partial (run-end drain)
    return out

def main():
    golden_path, *paths = sys.argv[1:]
    gf = frames_of(golden_path)
    modal = collections.Counter(f for f in gf if len(f) == 191).most_common(1)[0][0]
    for p in paths:
        fr = frames_of(p)
        warm = sum(1 for f in fr if all(w == '0' * 16 for w in f))
        full = [f for f in fr if len(f) == 191]
        good = sum(1 for f in full if f == modal)
        bev = []
        for f in fr:
            if all(w == '0' * 16 for w in f):
                continue
            be = sum(bin(int(a, 16) ^ int(b, 16)).count('1')
                     for a, b in zip(f, modal))
            be += 64 * abs(len(f) - len(modal))
            bev.append(be)
        print(f"{p}: frames_delivered={len(fr)} warmup_zero={warm} "
              f"full191={len(full)} golden_exact={good} "
              f"nonwarm_biterrs={sorted(bev)[:6]}... max={max(bev) if bev else 0} "
              f"sum={sum(bev)}")

if __name__ == '__main__':
    main()
