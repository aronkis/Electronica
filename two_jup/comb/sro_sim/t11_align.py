#!/usr/bin/env python3
"""[sim] Task 11 hole / skip / loss alignment for the seq-scored (non-repeating) legs.

Task 7 established the H-B law on `b_m10` by hand: at a constant seq<->frame offset of
-3, 42 of the 46 lost frames sit within +/-1 of a `rh_pop_on_empty` event (kind 0 in
`<p>_ep.txt`) and the rate is 2.10 lost frames per hole.  This script does that
mechanically, for BOTH event kinds that matter to Task 11:

    kind 0  rh_pop_on_empty   -- the built-in guard's EMPTY edge (a "hole")
    kind 4  r3s_skips         -- an RXFIX_R3S steered SKIP in the guard band
    kind 5  r3s_armed         -- the single arming instant (reported, never aligned)

The gate question (G7) is the SECOND one: if the residual losses on the R3S leg are
aligned to the SKIPS the way the baseline's losses are aligned to its HOLES, then the
position of the skipped slot does not matter and steering is refuted.

The seq axis (delivered frames) and the ep axis (input-sample air frames) are
different frame spaces separated by the receiver pipeline latency, so the constant
offset is SEARCHED and reported, exactly as score_sro2.py does for the tiled legs; it
is a diagnostic, never a threshold.

Usage:  t11_align.py <prefix> [<prefix> ...]     e.g.  t11_align.py b_m10 s_m10
Env:    T11_WARM (default 3) delivered frames dropped from the seq window.
"""
import sys, os, collections

# NB [task 20]: kind 5's LEGEND is lineage-dependent, the ARITHMETIC below is not.
# Task 11 (R3S) and task 12b (R4B) put a lock/arm SENTINEL on the r3Extras port, so
# kind 5 timestamped the arming instant there.  From task 14 (R4D, wrap_byte_sro4d.v
# header) that port carries a real COUNT and kind 5 timestamps every EXTRA POP -- which
# is exactly what the R4D/R4DR1 falsifier has to align.  align() already runs over every
# key of KIND, so only the label needed fixing.
KIND = {0: 'rh_pop_on_empty (hole)', 4: 'r3s_skip / r4d_skip',
        5: 'r3s_armed / r4d_EXTRA POP'}


def read_seq(pfx, warm):
    rows = []
    with open(pfx + '_seq.txt') as f:
        for ln in f:
            if ln.startswith('#'):
                continue
            a = ln.strip().split(',')
            rows.append(tuple(int(x) for x in a[:6]))
    good = [r for r in rows if r[2]]
    if not good:
        return None
    seqs = [r[3] for r in good]
    lo, hi = min(seqs[warm:] or seqs), max(seqs)
    span = [r for r in good if lo <= r[3] <= hi]
    ok = set(r[3] for r in span if r[5])
    seen = set(r[3] for r in span)
    corrupt = sorted(seen - ok)
    # Plausibility guard, the same one score_t7.py carries: a corruption landing in
    # header bytes 4..7 leaves the magic intact but yields a garbage seq, which would
    # both inflate the denominator and make range(lo, hi+1) unbounded.  b_m40 and
    # s_m40 both trip it; those legs are scored by the honest delivered/byte-exact
    # count instead, and only their EVENT census (holes, skips, tref) is used here.
    nair = int(os.environ.get('T7_NAIR', '0') or 0)
    if nair and not (0.5 * nair <= hi - lo + 1 <= nair + 4):
        return dict(refused=True, lo=lo, hi=hi, expect=hi - lo + 1)
    missing = sorted(set(range(lo, hi + 1)) - seen)
    return dict(refused=False, lo=lo, hi=hi, expect=hi - lo + 1, ok=ok,
                lost=sorted(set(corrupt) | set(missing)),
                corrupt=corrupt, missing=missing)


def read_ep(pfx):
    ev = collections.defaultdict(list)
    p = pfx + '_ep.txt'
    if not os.path.exists(p):
        return ev
    for ln in open(p):
        a = ln.strip().split(',')
        if len(a) < 8:
            continue
        k = int(a[0])
        if k in KIND:
            ev[k].append((int(a[2]), int(a[7]), int(a[1])))   # (air frame, tref, sidx)
    return ev


def align(lost, frames, lo_bound=-8, hi_bound=8):
    """Best constant offset o such that lost seq L matches an event frame F+o."""
    if not lost or not frames:
        return None
    best = None
    for o in range(lo_bound, hi_bound + 1):
        shifted = [f + o for f in frames]
        n = sum(1 for L in lost if min(abs(L - s) for s in shifted) <= 1)
        if best is None or n > best[1]:
            best = (o, n)
    o, n = best
    shifted = [f + o for f in frames]
    # reciprocal: events that have a loss within +/-1
    rn = sum(1 for s in shifted if min(abs(L - s) for L in lost) <= 1)
    return dict(offset=o, within=n, of=len(lost), frac=n / len(lost),
                recip=rn, nev=len(shifted), per_event=n / max(1, rn))


def leg(pfx, warm):
    s = read_seq(pfx, warm)
    if s is None:
        print(f'{pfx}: NO framed delivery'); return
    ev = read_ep(pfx)
    if s.get('refused'):
        print(f"{pfx}: SEQ RANGE IMPLAUSIBLE (seq {s['lo']}..{s['hi']}, range "
              f"{s['expect']}) -- corrupt header seq fields; refusing to score by seq. "
              f"Event census only; use the honest delivered/byte-exact count for LOSS.")
        for k in sorted(KIND):
            f = [e[0] for e in ev.get(k, [])]
            acq = [x for x in f if x < 5]; sc = [x for x in f if x >= 5]
            tr = collections.Counter(e[1] for e in ev[k] if e[0] >= 5)
            print(f'  {KIND[k]:24s}: {len(f)} events = {len(acq)} acquisition + '
                  f'{len(sc)} in the scored window')
            if sc:
                d = [sc[i+1]-sc[i] for i in range(len(sc)-1)]
                if d:
                    print(f'      spacing: mean={sum(d)/len(d):.2f} frames  '
                          f'{dict(collections.Counter(d).most_common(4))}')
                print(f'      first/last frame: {sc[0]}/{sc[-1]}')
                print(f'      tref at event (top): ' +
                      ' '.join(f'{t}:{n}' for t, n in tr.most_common(6)) +
                      f'   [tref range {min(tr)}..{max(tr)}]')
        return
    lost = s['lost']
    loss = 100.0 * (s['expect'] - len(s['ok'])) / s['expect']
    print(f"{pfx}: seq {s['lo']}..{s['hi']} expect={s['expect']} OK={len(s['ok'])} "
          f"CORRUPT={len(s['corrupt'])} MISSING={len(s['missing'])} LOSS={loss:.2f}%")
    if not lost:
        print('  no lost frames -- alignment is vacuous')
    for k in sorted(KIND):
        f = [e[0] for e in ev.get(k, [])]
        if not f:
            print(f'  {KIND[k]:24s}: 0 events')
            continue
        # the scored window starts at the first delivered seq; acquisition-phase
        # events (air frame < 5) are listed separately, they are never scored
        acq = [x for x in f if x < 5]
        sc = [x for x in f if x >= 5]
        trefs = collections.Counter(e[1] for e in ev[k] if e[0] >= 5)
        print(f'  {KIND[k]:24s}: {len(f)} events = {len(acq)} acquisition (air frame < 5) '
              f'+ {len(sc)} in the scored window')
        if sc:
            print(f'      scored-window frames: ' +
                  ','.join(str(x) for x in sc[:24]) + (' ...' if len(sc) > 24 else ''))
            if len(sc) > 1:
                d = [sc[i + 1] - sc[i] for i in range(len(sc) - 1)]
                print(f'      spacing: mean={sum(d)/len(d):.2f} frames  '
                      f'{dict(collections.Counter(d).most_common(4))}')
            print(f'      tref at event (top): ' +
                  ' '.join(f'{t}:{n}' for t, n in trefs.most_common(6)))
        if lost and sc and k != 5:
            a = align(lost, sc)
            print(f'      ALIGNMENT vs losses: best constant offset {a["offset"]:+d} -> '
                  f'{a["within"]}/{a["of"]} losses within +/-1 ({100*a["frac"]:.1f}%); '
                  f'{a["recip"]}/{a["nev"]} events have a loss within +/-1; '
                  f'{a["per_event"]:.2f} lost frames per aligned event')


if __name__ == '__main__':
    w = int(os.environ.get('T11_WARM', '3'))
    for p in sys.argv[1:]:
        leg(p, w)
        print()
