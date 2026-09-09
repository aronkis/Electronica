#!/usr/bin/env python3
"""Classify every silicon burst word as displacement-explainable, or not.

The simulator reproduces each instrument's capture byte-for-byte (positive
control: tap 3 -> 0xBCF94856, cap_in -> 0x5216F3E2, both at frame anchor).
Sweeping the capture window across a whole frame therefore enumerates EVERY
word the instrument can produce from correct data at a wrong position. Those
maps are precomputed in offsetmap/.

A word in the map is explainable by displacement alone. A word NOT in the map
cannot be produced by any displacement of correct data -- it is the residue
that position does not explain, and it is the number worth watching.

Specificity: each map is injective (one word per offset, no collisions), and
covers 12,320 of 2^32 words for tap 3 (2.9e-6 of the space) and 24,640 for
cap_in (5.7e-6). A chance match is negligible, so a hit is real.

Usage: classify_burst_words.py <csv> [tap-label]
  CSV: "tap t frames err capTAP capIn capDeint capOut"
"""
import collections, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BURST = 200

def load_map(name):
    m = {}
    p = os.path.join(HERE, 'offsetmap', name)
    for l in open(p):
        if l.startswith('#'):
            continue
        w, o = l.split()
        m[int(w, 16)] = int(o)
    return m

MAPS = {'tap3': ('tap3_word_to_offset.tsv', 4, 'symbols'),
        'cap_in': ('capin_word_to_offset.tsv', 5, 'bits')}

rows = []
for l in open(sys.argv[1]):
    q = l.split()
    if len(q) >= 8:
        try: int(q[1])
        except ValueError: continue
        rows.append((q[0], int(q[3]), int(q[4], 16), int(q[5], 16)))
want_tap = sys.argv[2] if len(sys.argv) > 2 else '3'

for label, (fname, col, unit) in MAPS.items():
    m = load_map(fname)
    sub = [r for r in rows if (r[0] == want_tap or label == 'cap_in')]
    idx = 2 if label == 'tap3' else 3
    quiet = [r for r in sub if r[1] <= BURST]
    if not quiet:
        continue
    gold = collections.Counter(r[idx] for r in quiet).most_common(1)[0][0]
    # §26: a word whose top byte is zero is the register read mid-fill, not signal.
    burst = collections.Counter(r[idx] for r in sub if r[idx] != gold and (r[idx] >> 24))
    partial = sum(1 for r in sub if r[idx] != gold and not (r[idx] >> 24))
    hit = {w: m[w] for w in burst if w in m}
    miss = [w for w in burst if w not in m]
    nb = sum(burst.values())
    nh = sum(c for w, c in burst.items() if w in m)
    print(f"\n=== {label}: golden 0x{gold:08X}, {len(burst)} distinct burst words "
          f"({nb} occurrences), {partial} partial-fill excluded")
    if nb:
        print(f"    displacement-explainable: {len(hit)}/{len(burst)} distinct, "
              f"{nh}/{nb} occurrences ({100.0*nh/nb:.1f} %)")
    span = max(m.values()) + 1
    for w, o in sorted(hit.items(), key=lambda kv: kv[1]):
        print(f"      0x{w:08X} x{burst[w]:<4d} offset {o:6d} {unit} = {o/span:.4f} of a frame")
    for w in sorted(miss):
        print(f"      0x{w:08X} x{burst[w]:<4d} NOT EXPLAINED by any displacement")
