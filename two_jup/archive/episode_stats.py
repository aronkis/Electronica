#!/usr/bin/env python3
"""episode_stats.py <census_or_hunt_dir> -- error-episode statistics from -S
event logs: clusters errored seqs into episodes (gap > 50 frames starts a new
one) and reports the inter-episode spacing distribution. The ~1.57 s (333
frame) period is the signature of the periodic disturbance under
investigation; a flat/absent spacing mode after a lever change means the
lever worked."""
import re
import sys
import glob
import os
import statistics


def analyze(path, name):
    seqs = []
    for line in open(path):
        m = re.search(r'seq=(\d+) type=(biterr|lost)', line)
        if m:
            seqs.append(int(m.group(1)))
    seqs = sorted(set(seqs))
    if not seqs:
        print(f'--- {name}: no errored seqs')
        return
    starts = [seqs[0]]
    for a, b in zip(seqs, seqs[1:]):
        if b - a > 50:
            starts.append(b)
    iv = [b - a for a, b in zip(starts, starts[1:])]
    sizes = [sum(1 for q in seqs if s <= q < s + 50) for s in starts]
    print(f'--- {name}: {len(seqs)} errored seqs, {len(starts)} episodes')
    if iv:
        med = statistics.median(iv)
        print(f'    spacing frames: median={med:.0f} mean={statistics.mean(iv):.0f} '
              f'min={min(iv)} max={max(iv)}  (median {med*4.72e-3:.3f}s)')
        hist = {}
        for v in iv:
            hist[round(v / 10) * 10] = hist.get(round(v / 10) * 10, 0) + 1
        top = sorted(hist.items(), key=lambda kv: -kv[1])[:6]
        print(f'    spacing histogram (10-frame bins): {top}')
    print(f'    episode sizes: median={statistics.median(sizes):.0f} max={max(sizes)}')


def main(d):
    logs = sorted(glob.glob(os.path.join(d, '*_events.log')))
    if not logs:
        print(f'no *_events.log in {d}')
        return 1
    for p in logs:
        analyze(p, os.path.basename(p).replace('_events.log', ''))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
