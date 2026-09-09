#!/usr/bin/env python3
"""[sim] Task 7 scorer for the NON-REPEATING (TGEN v2) SRO legs.

Task 6's scorer defined OK as "hashes to the modal frame of the s = 0 run"; with a
PN(seq) payload there is no modal frame, so OK here is the byte-exact check the RTL
driver already did against the reconstructed TGEN frame (<p>_seq.txt, col ok).

Reports, per leg:
  * delivered / OK / CORRUPT / MISSING and loss %, with MISSING derived from the
    seq numbers (every air slot carries exactly one seq, verified at capture time),
    so lost frames are in the denominator;
  * the lost-frame pattern per hole cycle: which delivered frames die relative to
    the rhPopEmpty (kind 0) events in <p>_ep.txt;
  * RXFIX_R3 steered events (kind 4 = skipped pop, kind 5 = extra pop) with the
    tref at which each fired -- the measured guard alignment.
"""
import sys, os, collections

def leg(pfx, warm=3, nair=None):
    sq = []
    with open(pfx + '_seq.txt') as f:
        for ln in f:
            if ln.startswith('#'): continue
            a = ln.strip().split(',')
            sq.append((int(a[0]), int(a[1]), int(a[2]), int(a[3]), int(a[4]), int(a[5])))
    # drop warm-up: the first `warm` delivered frames and any pre-lock no-magic run
    good = [r for r in sq if r[2]]
    if not good:
        print(f'{pfx}: NO framed delivery ({len(sq)} raw frames)'); return
    seqs = [r[3] for r in good]
    lo, hi = min(seqs[warm:] or seqs), max(seqs)
    span = [r for r in good if lo <= r[3] <= hi]
    okset = set(r[3] for r in span if r[5])
    corrupt = sorted(set(r[3] for r in span if not r[5]))
    expect = hi - lo + 1
    # A corruption landing in header bytes 4..7 leaves the magic intact but yields a
    # garbage seq, which would silently inflate the denominator.  Bound it.
    if nair is not None and not (0.5 * nair <= expect <= nair + 4):
        print(f'{pfx}: SEQ RANGE IMPLAUSIBLE expect={expect} vs air frames fed {nair} '
              f'-- a corrupt seq field has widened the range; refusing to score')
        return
    missing = sorted(set(range(lo, hi + 1)) - set(r[3] for r in span))
    nomagic = sum(1 for r in sq if not r[2])
    lost = expect - len(okset)
    print(f'{pfx}: seq {lo}..{hi} expect={expect} OK={len(okset)} '
          f'CORRUPT={len(corrupt)} MISSING={len(missing)} nomagic_frames={nomagic} '
          f'LOSS={100.0*lost/expect:.2f}%')
    bad = sorted(set(corrupt) | set(missing))
    if bad:
        print('  lost seq: ' + ','.join(str(b) for b in bad[:60]) +
              (' ...' if len(bad) > 60 else ''))
        d = [bad[i+1]-bad[i] for i in range(len(bad)-1)]
        if d:
            c = collections.Counter(d).most_common(6)
            print('  lost-seq spacings (value:count): ' +
                  ' '.join(f'{k}:{v}' for k, v in c))
    ep = pfx + '_ep.txt'
    if os.path.exists(ep):
        kinds = collections.Counter(); pe = []; st = []
        for ln in open(ep):
            a = ln.strip().split(',')
            if len(a) < 8: continue
            k = int(a[0]); kinds[k] += 1
            if k == 0: pe.append((int(a[2]), int(a[7])))
            if k in (4, 5): st.append((k, int(a[2]), int(a[7]), int(a[6])))
        print(f'  ep kinds: {dict(sorted(kinds.items()))}')
        if pe:
            print(f'  rhPopEmpty events: {len(pe)} at frames ' +
                  ','.join(str(f) for f, _ in pe[:20]) + (' ...' if len(pe) > 20 else ''))
        if st:
            trefs = collections.Counter(t for _, _, t, _ in st)
            print(f'  R3 steered: skips={sum(1 for k,_,_,_ in st if k==4)} '
                  f'extras={sum(1 for k,_,_,_ in st if k==5)}; '
                  f'tref at event (top): ' +
                  ' '.join(f'{t}:{n}' for t, n in trefs.most_common(8)))
    res = pfx + '_res.txt'
    if os.path.exists(res):
        for ln in open(res):
            if ln.startswith(('rh_pop_on_empty', 't7_ok', 'r3_skips', 'packets')):
                print('  ' + ln.rstrip())

nair = int(os.environ.get('T7_NAIR', '0')) or None
for p in sys.argv[1:]:
    leg(p, nair=nair)
