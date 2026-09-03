#!/usr/bin/env python3
"""§31 across the anchor boundary: sweep FEC-anchored capture offsets.

§25's anchor-boundary rule forbids carrying the tap-3 displacement result over
to the FEC-anchored witnesses. This repeats the §31 test on their own anchor.

FecCapture builds cap_in/cap_deint/cap_out as the FIRST 32 BITS of a stream
after the FEC startIn, packed LSB-first (`w |= 1 << n`). So the window is 32
consecutive bit-domain beats from the FEC frame mark.

Usage: score_fec_offset.py <dump.txt> <golden_hex> <csv> <col>
  dump: "<idx> <I> <Q> <markDemod> <markFec>" per valid beat, bit in I's LSB.
"""
import sys, collections

dump, golden_s, csv, col = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
GOLD = int(golden_s, 16)

rows = []
for l in open(dump):
    p = l.split()
    if len(p) >= 5:
        rows.append((int(p[1]), int(p[4])))
# Bit-domain selectors pack 16 BITS PER BEAT (ddrcap_bitword), so a beat is a
# word, not a bit: 1540 beats/frame x 16 = 24,640 bits = 12,320 symbols x 2. The
# first attempt read one bit per beat and its positive control correctly refused.
# Bit order within the word is unknown, so it is a parameter the control fixes.
ORDER = sys.argv[5] if len(sys.argv) > 5 else "msb"
bits = []
beat_of_bit = []
for i, (v, _) in enumerate(rows):
    w = v & 0xFFFF
    rng = range(15, -1, -1) if ORDER == "msb" else range(16)
    for b in rng:
        bits.append((w >> b) & 1)
        beat_of_bit.append(i)
marks = [beat_of_bit.index(i) for i, (_, m) in enumerate(rows)
         if m == 32767 and i in beat_of_bit]
print(f"order={ORDER}: {len(rows)} beats -> {len(bits)} bits, {len(marks)} FEC marks, spacing "
      f"{[marks[i+1]-marks[i] for i in range(min(3, len(marks)-1))]}")

def word(a):
    w = 0
    for k in range(32):
        if bits[a + k]:
            w |= 1 << k
    return w

# POSITIVE CONTROL: the golden word must appear at the frame anchor.
hits = [(mi, off) for mi, m in enumerate(marks) for off in range(-48, 49)
        if 0 <= m + off <= len(bits) - 32 and word(m + off) == GOLD]
if not hits:
    print(f"POSITIVE CONTROL FAILED: 0x{GOLD:08X} not reproduced at any frame anchor "
          f"(offsets -48..+48). Per §0 the sweep is NOT run and no null is reported.")
    sys.exit(2)
offs = collections.Counter(o for _, o in hits)
print(f"POSITIVE CONTROL PASS: 0x{GOLD:08X} at {len(hits)} anchors, offsets {dict(offs)}")

rowsC = []
for l in open(csv):
    q = l.split()
    if len(q) >= 8:
        try: int(q[1])
        except ValueError: continue
        rowsC.append((int(q[3]), int(q[col], 16)))
g = collections.Counter(w for e, w in rowsC if e <= 200).most_common(1)[0][0]
burst = sorted({w for e, w in rowsC if w != g and (w >> 24)})
print(f"silicon golden 0x{g:08X} (dump golden 0x{GOLD:08X}); {len(burst)} burst words sought")

n = len(bits) - 32
seen = {}
for a in range(n):
    w = word(a)
    if w in burst:
        seen.setdefault(w, []).append(a)
span = marks[1] - marks[0] if len(marks) > 1 else 0
print(f"swept {n} anchors; null {len(burst)}*{n}*2^-32 = {len(burst)*n*2.0**-32:.2e}\n")
for w in burst:
    if w in seen:
        rel = [(a - marks[0]) % span for a in seen[w][:3]] if span else seen[w][:3]
        print(f"  0x{w:08X} FOUND at {len(seen[w])} anchors; offset in frame {rel}"
              f" = {[round(r/span, 4) for r in rel] if span else ''} of a frame")
    else:
        print(f"  0x{w:08X} not found")
