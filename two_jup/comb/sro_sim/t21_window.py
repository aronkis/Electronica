#!/usr/bin/env python3
"""[sim] Task 21: the R4E event histogram -- skip positions AND drop LANDING SLOTS.

R4B's claim was about where a skip fires.  R4E's claim is about something the RTL cannot
observe when it acts: the drop is taken 12-31 validated pops BEFORE the pcEnd it is aimed
at, and what has to be true is that the symbol it deletes WOULD HAVE BEEN POPPED inside
slots [pcEnd+1, pcEnd+13].  From the pre-registration's Fact 4,

    k = O(t) + 1 - m        m = validated pops in [drop tick, pcEnd tick]

so the landing slot is only knowable at the next pcEnd.  Both the RTL (r4e_land_last) and
this harness (from the ring POINTERS, fifoVPop and pcE -- nets that share nothing with the
steering) compute it there, and this script requires them to agree.

<p>_win.txt columns:
    n,sidx,beat,slot_rtl,slot_harness,dt_enb,occ,tref,locked,opens,kind,
    land_rtl,land_harness,m,occ_ptr,land_out
kind 0 = a steered SKIP (the EMPTY side, R4B's), kind 1 = a DROPPED PUSH (the FULL side).

<p>_period.txt columns:  n,sidx,vpops_in_interval,rtl_period,locked
That file exists because the whole schedule rests on the pcEnd-to-pcEnd interval in
VALIDATED POPS being stable, which had never been measured before this task.

Usage:  t21_window.py <prefix> [<prefix> ...]
        t21_window.py --frames <prefix> <lo> <hi>
"""
import sys, os, collections

FRSAMP = 49332
EPOCH = 12333           # symbols per air frame (Peak_Search.timing_Reference modulus)
LO, HI = 1, 13          # the pre-registered structural window
TREF_TOL = 60
PERIOD_SPREAD_MAX = 6   # the pre-registered precondition (section 3.2)


def tref_dist(t):
    t %= EPOCH
    return min(t, EPOCH - t)


def hist(vals):
    c = collections.Counter(vals)
    return ' '.join(f'{k}:{c[k]}' for k in sorted(c))


def rows_of(pfx):
    fn = pfx + '_win.txt'
    if not os.path.exists(fn):
        return None
    out = []
    for ln in open(fn):
        if ln.startswith('#') or not ln.strip():
            continue
        a = ln.strip().split(',')
        if len(a) < 11:
            continue
        r = [int(x) for x in a]
        while len(r) < 16:
            r.append(0)
        out.append(r)
    return out


def period(pfx, lock_frame=0):
    """The measured pcEnd interval in VALIDATED POPS -- precondition, not a nicety."""
    fn = pfx + '_period.txt'
    if not os.path.exists(fn):
        print(f'  NO PERIOD TRACE {fn}')
        return None
    v = []
    for ln in open(fn):
        if ln.startswith('#') or not ln.strip():
            continue
        a = ln.strip().split(',')
        if len(a) < 5:
            continue
        n, sidx, vp, rtlp, locked = (int(x) for x in a[:5])
        v.append((n, sidx // FRSAMP, vp, rtlp, locked))
    post = [x for x in v if x[4] == 1][1:]      # after lock, dropping the lock frame
    if not post:
        print(f'  period: {len(v)} pcEnd intervals, NONE post-lock')
        return None
    vp = [x[2] for x in post]
    c = collections.Counter(vp)
    spread = max(vp) - min(vp)
    mode = c.most_common(1)[0]
    ok = 'OK' if spread <= PERIOD_SPREAD_MAX else '*** PRECONDITION FAILED'
    print(f'  pcEnd period (validated pops), post-lock n={len(vp)}: '
          f'min={min(vp)} mode={mode[0]}({mode[1]}) max={max(vp)} spread={spread}  {ok}')
    if spread > PERIOD_SPREAD_MAX:
        print(f'    the schedule predicts the next pcEnd from this period; a spread > '
              f'{PERIOD_SPREAD_MAX} walks the landing slot out of [{LO},{HI}] for reasons '
              f'unrelated to the mechanism')
        print('    full histogram: ' + hist(vp))
    # the RTL's own latched period must track the harness's, one interval behind
    lag = sum(1 for i in range(1, len(post)) if post[i][3] == post[i - 1][2])
    print(f'  RTL r4e_period == the previous harness interval: {lag}/{len(post)-1}')
    return spread


def one(pfx):
    print(f'\n=== {pfx} ===')
    rows = rows_of(pfx)
    if rows is None:
        print(f'  NO TRACE {pfx}_win.txt -- the leg did not run against a '
              f'wrap_byte_sro4e build')
        return 2
    skips = [r for r in rows if r[10] == 0]
    drops = [r for r in rows if r[10] == 1]
    print(f'  trace lines: {len(rows)}   skips(kind 0) = {len(skips)}   '
          f'drops(kind 1) = {len(drops)}')

    # ---- cross-checks against the driver's own outputs (three-way count, K7) ----
    res = pfx + '_res.txt'
    rs = ex = None
    if os.path.exists(res):
        for l in open(res):
            if l.startswith('r3_skips='):
                rs = int(l.split()[0].split('=')[1])
                ex = int(l.split()[1].split('=')[1])
        if rs is not None:
            print(f'  <p>_res.txt r3_skips  = {rs} '
                  f'{"OK" if rs == len(skips) else "*** MISMATCH"}')
            print(f'  <p>_res.txt r3_extras = {ex} (= r4e_drops) '
                  f'{"OK" if ex == len(drops) else "*** MISMATCH"}')
    ep = pfx + '_ep.txt'
    if os.path.exists(ep):
        n4 = sum(1 for l in open(ep) if l.startswith('4,'))
        n5 = sum(1 for l in open(ep) if l.startswith('5,'))
        print(f'  <p>_ep.txt kind-4 (skip) = {n4} '
              f'{"OK" if n4 == len(skips) else "*** MISMATCH"}')
        print(f'  <p>_ep.txt kind-5 (drop) = {n5} '
              f'{"OK" if n5 == len(drops) else "*** MISMATCH (see the kind-priority caveat)"}')

    period(pfx)

    rc = 0
    # ---------------------------------------------------------------- the skips
    if skips:
        sr = [r[3] for r in skips]
        sh = [r[4] for r in skips]
        print(f'  SKIPS  slot_rtl: {hist(sr)}')
        print(f'         slot_harness: {hist(sh)}')
        print(f'         dt_enb: {hist([r[5] for r in skips])}')
        print(f'         occ: {hist([r[6] for r in skips])}')
        print(f'         air frames {min(r[1]//FRSAMP for r in skips)}..'
              f'{max(r[1]//FRSAMP for r in skips)}')
        ag = sum(1 for a, b in zip(sr, sh) if a == b)
        print(f'         RTL vs INDEPENDENT recount: {ag}/{len(skips)}')
        bad = [r for r in skips if not (LO <= r[3] <= HI and LO <= r[4] <= HI)]
        if bad:
            print(f'  *** {len(bad)} SKIP(S) OUTSIDE [{LO},{HI}]'); rc = 1
        else:
            print(f'         WINDOW OK: all {len(skips)} inside [{LO},{HI}] on both counters')

    # ---------------------------------------------------------------- the drops
    if drops:
        lr = [r[11] for r in drops]
        lh = [r[12] for r in drops]
        m = [r[13] for r in drops]
        oc = [r[6] for r in drops]          # occTrue (Delay_out1) at the drop
        op = [r[14] for r in drops]         # (fifoPush - fifoPop) mod 32 at the drop
        fr = [r[1] // FRSAMP for r in drops]
        print(f'  DROPS  LANDING SLOT (RTL)      : {hist(lr)}')
        print(f'         LANDING SLOT (harness)  : {hist(lh)}')
        print(f'         m = validated pops to pcEnd: {hist(m)}')
        print(f'         occupancy at the drop, Delay_out1: {hist(oc)}')
        print(f'         occupancy at the drop, POINTERS  : {hist(op)}')
        alias = sum(1 for a, b in zip(oc, op) if a != b and not (a == 32 and b == 0))
        print(f'         the two occupancy sources disagree on {alias}/{len(drops)} '
              f'(a true 32 aliases to 0 on the pointers and is not counted)')
        print(f'         air frames {min(fr)}..{max(fr)}, spacing: '
              f'{hist([fr[i]-fr[i-1] for i in range(1, len(fr))]) if len(fr) > 1 else "-"}')
        print(f'         drop position in the window it was scheduled FROM '
              f'(slot_harness): {hist([r[4] for r in drops])}')
        print(f'         tref at the drop: {hist([r[7] for r in drops])}')
        print(f'         RTL r4e_land_out (saturating, outside [{LO},{HI}]): '
              f'{drops[-1][15]}')
        ag = sum(1 for a, b in zip(lr, lh) if a == b)
        print(f'         RTL vs INDEPENDENT landing recount: {ag}/{len(drops)} identical'
              + ('' if ag == len(drops) else '   *** the two measurements disagree'))
        # the identity that has to hold if the formula is the RTL's: k = occ + 1 - m
        idn = sum(1 for r in drops if r[12] == r[6] + 1 - r[13])
        print(f'         k == occ + 1 - m (Fact 4, on the harness numbers): '
              f'{idn}/{len(drops)}')
        bad = [r for r in drops if not (LO <= r[11] <= HI)]
        badh = [r for r in drops if not (LO <= r[12] <= HI)]
        if bad or badh:
            print(f'  *** FALSIFIER FIRED: {len(bad)} drop(s) outside slots [{LO},{HI}] by '
                  f'the RTL witness, {len(badh)} by the independent recount')
            for r in (bad or badh)[:10]:
                print(f'      n={r[0]} frame={r[1]//FRSAMP} land_rtl={r[11]} '
                      f'land_harness={r[12]} m={r[13]} occ={r[6]} occ_ptr={r[14]} '
                      f'tref={r[7]}')
            rc = 1
        else:
            print(f'         LANDING OK: every one of {len(drops)} dropped pushes would '
                  f'have been popped inside slots [{LO},{HI}], on BOTH measurements')
        td = [tref_dist(r[7]) for r in drops]
        mode_t = collections.Counter(r[7] for r in drops).most_common(1)[0][0]
        dev = [min(abs(r[7] - mode_t), EPOCH - abs(r[7] - mode_t)) for r in drops]
        print(f'         modal tref = {mode_t}; deviation from it: {hist(dev)}')
        print(f'         |tref - epoch boundary|: {hist(td)}')

    # ---------------------------------------------------------------- K10
    fs = set(r[1] // FRSAMP for r in skips)
    fd = set(r[1] // FRSAMP for r in drops)
    both = sorted(fs & fd)
    print(f'  K10 both edges in one air frame: {len(both)} frame(s)'
          + (f' *** {both[:10]}' if both else '  (none -- the period counter is clean)'))
    if both:
        rc = 1
    return rc


def frange(pfx, lo, hi):
    rows = rows_of(pfx) or []
    sel = [r for r in rows if lo <= r[1] // FRSAMP <= hi]
    print(f'\n=== {pfx} events in air frames [{lo},{hi}]: {len(sel)}')
    for r in sel:
        k = 'DROP' if r[10] == 1 else 'skip'
        print(f'   {k} frame={r[1]//FRSAMP} slot_rtl={r[3]} land_rtl={r[11]} '
              f'land_h={r[12]} m={r[13]} occ={r[6]} tref={r[7]} '
              + ('*** MID-PAYLOAD' if tref_dist(r[7]) > TREF_TOL else 'in guard'))


if __name__ == '__main__':
    if sys.argv[1:2] == ['--frames']:
        frange(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])); sys.exit(0)
    rc = 0
    for p in sys.argv[1:]:
        rc |= one(p)
    sys.exit(rc)
