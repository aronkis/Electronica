#!/usr/bin/env python3
"""Value-repertoire test: position shift vs value corruption.

Golden-constancy only asks "did this second match the modal quiet value".
That question is answered identically by (a) correct data arriving at the
wrong phase and (b) corrupted data -- so it cannot discriminate them.

This asks a different question of the SAME captures: when a burst second is
not golden, is the value one the tap already produces during quiet seconds,
or a value never seen when the link is healthy?

The quiet repertoire turns out to be 1-5 values (the capture is a fixed word
latched at a fixed phase), so "is the burst value in the quiet set" is
degenerate: a phase shift lands on a sample position quiet never captured, so
it scores NOVEL exactly like corruption would. The repertoire question cannot
discriminate on this instrument.

What DOES discriminate is determinism. Random corruption cannot reproduce an
identical 32-bit word; recurrence at a fixed interval is not something noise
does. So the reported discriminator is the recurrence structure:

  few distinct values, each recurring at a fixed period -> deterministic state
  many distinct values, each seen once                  -> stochastic corruption

CSV: tap t frames err capTAP capIn capDeint capOut
"""
import sys, collections

BURST = 200
NAME = {0: "0 AGC out", 1: "1 postSymbolSync", 2: "2 postCarrierSync",
        3: "3 QPSKConstellation (demod IN)"}
COLS = [(4, None), (5, "cap_in (demod OUT / FEC in)"),
        (6, "cap_deint"), (7, "cap_out (post-Viterbi)")]

rows = []
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) >= 8:
        rows.append((int(p[0]), int(p[1]), int(p[2]), int(p[3]),
                     int(p[4], 16), int(p[5], 16), int(p[6], 16), int(p[7], 16)))

print(f"=== {sys.argv[1]}: {len(rows)} rows ===\n")
hdr = f"{'witness':34s} {'nb':>4s} {'nongold':>7s} {'in-rep':>7s} {'novel':>6s} {'%novel':>7s}  verdict"
print(hdr); print("-" * len(hdr))

def report(label, sub, idx):
    q = [r for r in sub if r[3] <= BURST]
    b = [r for r in sub if r[3] > BURST]
    if not q or not b:
        return
    gold = collections.Counter(r[idx] for r in q).most_common(1)[0][0]
    rep = set(r[idx] for r in q)                  # everything seen while healthy
    ng = [r[idx] for r in b if r[idx] != gold]    # burst seconds that deviated
    if not ng:
        print(f"{label:34s} {len(b):4d} {0:7d} {'-':>7s} {'-':>6s} {'-':>7s}  no deviation")
        return
    inrep = sum(1 for v in ng if v in rep)
    novel = len(ng) - inrep
    pn = 100.0 * novel / len(ng)
    # A tap whose quiet repertoire is a single value cannot support this test:
    # every deviation is trivially "novel" because nothing else was ever seen.
    distinct = collections.Counter(ng)
    recurring = sum(c for c in distinct.values() if c > 1)
    frac_rec = 100.0 * recurring / len(ng)
    if frac_rec >= 60:
        verdict = f"DETERMINISTIC ({len(distinct)} distinct, {frac_rec:.0f}% recur)"
    elif frac_rec <= 10:
        verdict = f"STOCHASTIC ({len(distinct)} distinct, {frac_rec:.0f}% recur)"
    else:
        verdict = f"MIXED ({len(distinct)} distinct, {frac_rec:.0f}% recur)"
    print(f"{label:34s} {len(b):4d} {len(ng):7d} {inrep:7d} {novel:6d} {pn:6.1f}%  {verdict}")
    top = collections.Counter(ng).most_common(4)
    print(f"{'':34s}   top burst values: " +
          ", ".join(f"0x{v:08X}(x{c},{'seen' if v in rep else 'NEW'})" for v, c in top))
    print(f"{'':34s}   quiet repertoire size: {len(rep)}  golden 0x{gold:08X}")
    # Gaps are only meaningful WITHIN one tap dwell -- the dwell's second
    # counter restarts at each tap change, so pooling across dwells fabricates
    # negative "gaps". Group by dwell before differencing.
    gaps = []
    for dwell in sorted(set(r[0] for r in b)):
        pos = collections.defaultdict(list)
        for r in b:
            if r[0] == dwell and r[idx] != gold:
                pos[r[idx]].append(r[1])
        gaps += [ts[i+1] - ts[i] for ts in pos.values() for i in range(len(ts) - 1)]
    gaps = sorted(gaps)
    if gaps:
        print(f"{'':34s}   recurrence gaps (s): {gaps}")

for t in sorted(set(r[0] for r in rows)):
    report(NAME.get(t, str(t)), [r for r in rows if r[0] == t], 4)
print()
for idx, lab in COLS[1:]:
    report(lab, rows, idx)
