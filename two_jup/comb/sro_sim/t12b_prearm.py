#!/usr/bin/env python3
"""[sim] Task 12b: PRE-ARM STRUCTURAL IDENTITY against the baseline, on every paired leg.

WHY THIS IS FREE, AND WHY IT IS STRONGER THAN A CONTENT-IDENTITY ROW.  R4B's pop is
`r4b_pop_nom & ~r4b_skip_en` and `r4b_skip_en` is 0 until the first arm, so before the
first skip R4B's pop expression IS the baseline expression, character for character.
That is a claim about the TEXT, so it predicts something much stronger than "the content
matches": every frame delivered before the first skip must be identical to the baseline
INCLUDING its sidx annotation -- same bytes, delivered on the same input sample.

R4 could not make this claim at all (it gated the pop on r4_prefilled, so its expression
was never the baseline expression and even its acquisition differed).  R3S could, and
this is R3S's property recovered.

On n_p000 the first skip is at air frame ~13, so this covers the acquisition transient.
On n_m10 the first skip is predicted at frame ~199, so it covers ~190 delivered frames --
i.e. four legs become structural identity tests at no extra cost.

Reports, per pair: the first skip's air frame, how many common seq precede it, and how
many of those are identical on (nwords, FNV hash, user) AND on sidx.  A single mismatch
before the first skip is a REAL failure -- the steering cannot have acted yet.

Usage:  t12b_prearm.py <new_prefix> <baseline_prefix> [<new> <base> ...]
"""
import sys, os

FRSAMP = 49332


def load(pfx):
    """seq -> (sidx, nwords, hash, user), joined from <p>_deliv.txt and <p>_seq.txt."""
    dl = [l.strip().split(',') for l in open(pfx + '_deliv.txt') if l.strip()]
    sq = [l.strip().split(',') for l in open(pfx + '_seq.txt')
          if l.strip() and not l.startswith('#')]
    if len(dl) != len(sq):
        print(f'  {pfx}: WARNING deliv/seq row counts differ ({len(dl)} vs {len(sq)})')
    out = {}
    for d, s in zip(dl, sq):
        assert d[0] == s[0], f'{pfx}: deliv/seq sidx disagree ({d[0]} vs {s[0]})'
        if int(s[2]) != 1:          # no TGEN magic: not a framed delivery
            continue
        out[int(s[3])] = (int(d[0]), int(d[1]), d[2], int(d[3]))
    return out


def first_skip_frame(pfx):
    fn = pfx + '_skipwin.txt'
    if not os.path.exists(fn):
        return None
    for l in open(fn):
        if l.startswith('#') or not l.strip():
            continue
        return int(l.split(',')[1]) // FRSAMP
    return None            # the trace exists but is empty: no skip ever fired


def pair(new, base):
    print(f'\n=== {new} vs {base} : PRE-ARM STRUCTURAL IDENTITY ===')
    for p in (new, base):
        if not os.path.exists(p + '_deliv.txt'):
            print(f'  MISSING {p}_deliv.txt'); return 2
    a, b = load(new), load(base)
    fs = first_skip_frame(new)
    print(f'  first skip: {"air frame " + str(fs) if fs is not None else "NONE (no skip fired)"}')
    common = sorted(set(a) & set(b))
    if fs is None:
        pre = common                      # no skip at all: the WHOLE leg is pre-arm
    else:
        pre = [s for s in common if a[s][0] // FRSAMP < fs]
    same_content = [s for s in pre if a[s][1:] == b[s][1:]]
    same_sidx = [s for s in pre if a[s] == b[s]]
    print(f'  common seq delivered before the first skip: {len(pre)}')
    print(f'    identical content (nwords,hash,user): {len(same_content)}/{len(pre)}')
    print(f'    identical INCLUDING sidx            : {len(same_sidx)}/{len(pre)}')
    bad = [s for s in pre if a[s] != b[s]]
    if bad:
        print(f'  *** {len(bad)} pre-arm frame(s) differ -- the steering cannot have acted '
              f'yet, so this is a real failure.  First few:')
        for s in bad[:6]:
            print(f'      seq {s}: new={a[s]}  base={b[s]}')
        return 1
    if pre:
        print(f'  PRE-ARM IDENTITY HOLDS on all {len(pre)} frames, sidx included')
    return 0


if __name__ == '__main__':
    args = sys.argv[1:]
    rc = 0
    for i in range(0, len(args) - 1, 2):
        rc |= pair(args[i], args[i + 1])
    sys.exit(rc)
