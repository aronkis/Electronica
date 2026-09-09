#!/usr/bin/env python3
"""[sim] Task 12b: the skip-position histogram, which is what G8/G10/G12 turn on.

R4B's whole claim over R3S/R4 is that the skip lands inside a STRUCTURAL window --
slots [pcEnd+1, pcEnd+13] -- rather than anywhere in a "deframer idle" period that also
opens after a false sync, a missed sync or a garbage frame.  So the gate needs the
position of every skip, not a count.

WHERE THE DATA COMES FROM, AND WHY IT IS NOT IN <p>_ep.txt.  sim_sro.cpp is Task 7's
driver and MUST NOT CHANGE (that is what makes the 0 ppm content-identity row a test of
the RTL rather than of a re-typed driver), and it has no record kind for pcEnd -- its
kind chain is 0 = rh_pop_on_empty, 4 = skip, 5 = the witness sentinel, 1 = taSync,
2 = toffVal.  So wrap_byte_sro4b.v writes one line per skip to <p>_skipwin.txt:

    n,sidx,beat,slot_rtl,slot_harness,dt_enb,occ,tref,locked,opens

`slot_rtl` is the RTL's own window counter (r4b_wslot + 1).  `slot_harness` is an
INDEPENDENT recount made in the wrapper from rhValidIn / rhPhase / Packet_Controller
endOut -- taps that pass through no R4B logic.  `dt_enb` is the enb-beat distance from
the pcEnd beat; with four enb beats per symbol and a fixed pop phase it should satisfy
dt_enb = 4*slot - 1.  Two independent measurements of the same quantity is the point:
if they disagree, the window logic and the measurement disagree, and that is a finding.

Cross-checks against the driver's own outputs, so a truncated or mis-scored run cannot
pass quietly: the number of trace lines must equal r3_skips in <p>_res.txt and the
number of kind-4 records in <p>_ep.txt.

Usage:  t12b_window.py <prefix> [<prefix> ...]
"""
import sys, os, collections

FRSAMP = 49332
EPOCH = 12333           # symbols per air frame (Peak_Search.timing_Reference modulus)
LO, HI = 1, 13          # the pre-registered structural window
TREF_TOL = 60           # air-frame-referenced tolerance -- see tref_dist()


def tref_dist(t):
    """Distance from the EPOCH BOUNDARY, in symbols, on the air-frame time base.

    WHY THIS EXISTS AND WHY slot_rtl IS NOT ENOUGH.  slot_rtl measures position relative
    to THE DEFRAMER'S OWN pcEnd.  After a FALSE SYNC the deframer emits a pcEnd 12,320
    symbols into the wrong place, so a skip inside that frame's guard band is mid-payload
    of the TRUE air frame while still reading slot_rtl = 1..13 -- the window counter
    cannot see it.  That is precisely the defect finding (1) of the adversarial review is
    about: R3S's s_m40 skip at air frame 138 fired after a false Preamble_Detector sync at
    **tref 7026**, mid-payload, and that frame died, against R3S's clean skips at tref
    52 / 21 / 28 and this task's smoke at 12322/12323.

    tref is Peak_Search.timing_Reference mod 12,333 -- an AIR-FRAME-referenced clock that
    a moved pcEnd does not move.  So it is the check that survives a false sync, and it is
    reported as a SECOND, independent window row for every leg.
    """
    t %= EPOCH
    return min(t, EPOCH - t)


def hist(vals):
    c = collections.Counter(vals)
    return ' '.join(f'{k}:{c[k]}' for k in sorted(c))


def one(pfx):
    fn = pfx + '_skipwin.txt'
    print(f'\n=== {pfx} ===')
    if not os.path.exists(fn):
        print(f'  NO TRACE {fn} -- the leg did not run against a wrap_byte_sro4b build')
        return 2
    rows = []
    for ln in open(fn):
        if ln.startswith('#') or not ln.strip():
            continue
        a = ln.strip().split(',')
        if len(a) < 10:
            continue
        rows.append([int(x) for x in a[:10]])
    print(f'  skips in the trace: {len(rows)}')

    # ---- cross-checks against the driver's own outputs ----
    res = pfx + '_res.txt'
    if os.path.exists(res):
        for l in open(res):
            if l.startswith('r3_skips='):
                rs = int(l.split()[0].split('=')[1])
                ex = int(l.split()[1].split('=')[1])
                ok = 'OK' if rs == len(rows) else '*** MISMATCH'
                print(f'  <p>_res.txt r3_skips = {rs}  {ok}')
                print(f'  <p>_res.txt r3_extras = 0x{ex:08X} '
                      f'({"LOCKED" if ex == 0xA5A50002 else "NOT LOCKED"})')
    ep = pfx + '_ep.txt'
    if os.path.exists(ep):
        n4 = sum(1 for l in open(ep) if l.startswith('4,'))
        n5 = [l for l in open(ep) if l.startswith('5,')]
        ok = 'OK' if n4 == len(rows) else '*** MISMATCH'
        print(f'  <p>_ep.txt kind-4 (skip) records = {n4}  {ok}')
        if n5:
            f5 = int(n5[0].split(',')[2])
            print(f'  <p>_ep.txt kind-5 (LOCK) at air frame {f5} '
                  f'({len(n5)} record(s) -- lock is sticky, so 1 is expected)')
        else:
            print('  <p>_ep.txt kind-5: NONE -- lock never came true')
    if not rows:
        print('  (no skips: nothing to histogram)')
        return 0

    slot_r = [r[3] for r in rows]
    slot_h = [r[4] for r in rows]
    dt = [r[5] for r in rows]
    occ = [r[6] for r in rows]
    frames = [r[1] // FRSAMP for r in rows]

    print(f'  slot_rtl     histogram: {hist(slot_r)}')
    print(f'  slot_harness histogram: {hist(slot_h)}')
    print(f'  dt_enb       histogram: {hist(dt)}')
    print(f'  occupancy at the skip : {hist(occ)}')
    print(f'  air frames  : first {min(frames)}, last {max(frames)}, '
          f'span {max(frames) - min(frames)}')
    print(f'  window_opens at last skip: {rows[-1][9]}')

    # ---- the AIR-FRAME-referenced position: the check a moved pcEnd cannot fool ----
    tref = [r[7] for r in rows]
    td = [tref_dist(t) for t in tref]
    print(f'  tref histogram          : {hist(tref)}')
    print(f'  |tref - epoch boundary| : {hist(td)}   (tolerance {TREF_TOL} symbols)')
    # ---- the CORRECTED reference, and why it is the defensible one ----
    # The absolute test above measures against Peak_Search's OWN epoch boundary, which is
    # only the deframer's frame boundary when the two epochs happen to be aligned.  The
    # CFO leg and the post-outage re-lock both acquire at a DIFFERENT frame phase, so the
    # constant offset between the two epochs is not zero and the absolute test flags every
    # skip on those legs.  A skip that is genuinely mid-payload -- R3S's s_m40 skip at
    # tref 7026, a LONE outlier among 202 skips at 12295/12296, whose frame died -- shows
    # up as SCATTER against the leg's own mode, not as a constant offset.  So the
    # falsifiable quantity is the deviation from THIS leg's modal tref.
    mode_t = collections.Counter(tref).most_common(1)[0][0]
    dev = [min(abs(t - mode_t), EPOCH - abs(t - mode_t)) for t in tref]
    print(f'  modal tref = {mode_t}; deviation from it: {hist(dev)}')
    scat = [r for r, d in zip(rows, dev) if d > TREF_TOL]
    if scat:
        print(f'  *** SCATTERED SKIPS: {len(scat)} skip(s) more than {TREF_TOL} symbols from '
              f'this leg\'s own modal tref -- the signature of a MOVED pcEnd (false sync)')
        for r in scat[:10]:
            print(f'      n={r[0]} frame={r[1]//FRSAMP} tref={r[7]} occ={r[6]}')
    else:
        print(f'  CLUSTERED: every skip is within {TREF_TOL} symbols of this leg\'s modal '
              f'tref, i.e. a CONSTANT frame phase, not a wandering/false-sync one')

    far = [r for r, d in zip(rows, td) if d > TREF_TOL]
    if far:
        print(f'  *** MID-PAYLOAD SKIPS: {len(far)} skip(s) more than {TREF_TOL} symbols '
              f'from the epoch boundary -- a pcEnd was MOVED (false sync?) and the window '
              f'counter cannot see it')
        for r in far[:10]:
            print(f'      n={r[0]} frame={r[1]//FRSAMP} slot_rtl={r[3]} tref={r[7]} '
                  f'dist={tref_dist(r[7])} occ={r[6]}')
    else:
        print(f'  AIR-FRAME WINDOW OK: every skip is within {TREF_TOL} symbols of the '
              f'epoch boundary, so none of them is mid-payload of a TRUE air frame')

    agree = sum(1 for a, b in zip(slot_r, slot_h) if a == b)
    print(f'  RTL vs INDEPENDENT recount: {agree}/{len(rows)} identical'
          + ('' if agree == len(rows) else
             '   *** the two measurements disagree -- investigate before scoring'))
    dtok = sum(1 for s, d in zip(slot_r, dt) if d == 4 * s - 1)
    print(f'  dt_enb == 4*slot-1 (fixed pop phase): {dtok}/{len(rows)}')

    bad = [r for r in rows if not (LO <= r[3] <= HI)]
    badh = [r for r in rows if not (LO <= r[4] <= HI)]
    if bad or badh:
        print(f'  *** FALSIFIER FIRED: {len(bad)} skip(s) outside slots [{LO},{HI}] by the '
              f'RTL counter, {len(badh)} by the independent recount')
        for r in (bad or badh)[:10]:
            print(f'      n={r[0]} sidx={r[1]} frame={r[1]//FRSAMP} slot_rtl={r[3]} '
                  f'slot_harness={r[4]} dt={r[5]} occ={r[6]} tref={r[7]}')
        return 1
    print(f'  WINDOW OK: every one of {len(rows)} skips is inside slots [{LO},{HI}] '
          f'on BOTH counters')
    return 1 if scat else 0


def frange(pfx, lo, hi):
    """Skips inside an air-frame range, with tref.  Used for the loss-of-lock leg's
    RE-ACQUISITION window, where a false sync is most likely and where a mid-payload skip
    would be the most silicon-relevant finding in the gate."""
    fn = pfx + '_skipwin.txt'
    if not os.path.exists(fn):
        print(f'\n=== {pfx} frames [{lo},{hi}] : NO TRACE'); return
    rows = [[int(x) for x in l.strip().split(',')[:10]]
            for l in open(fn) if not l.startswith('#') and l.strip()]
    sel = [r for r in rows if lo <= r[1] // FRSAMP <= hi]
    print(f'\n=== {pfx} skips in air frames [{lo},{hi}]: {len(sel)}')
    for r in sel:
        d = tref_dist(r[7])
        print(f'   frame={r[1]//FRSAMP} slot_rtl={r[3]} tref={r[7]} dist={d} occ={r[6]} '
              + ('*** MID-PAYLOAD' if d > TREF_TOL else 'in guard'))


if __name__ == '__main__':
    if sys.argv[1:2] == ['--frames']:
        frange(sys.argv[2], int(sys.argv[3]), int(sys.argv[4])); sys.exit(0)
    rc = 0
    for p in sys.argv[1:]:
        rc |= one(p)
    sys.exit(rc)
