#!/usr/bin/env python3
"""ddrcap2_txmark_scan.py -- independent re-derivation of the reviewer's TX-marker-coincidence
observation (final-fix brief item B4): every d_data transition found in the two sel6 beat captures
is preceded, by exactly one record, by an anomalous EXTRA `Transmitter_txFrameStart` pulse (ch2
bit14, `mark_fec`) breaking the regular TX cadence -- while the regular cadence itself (one pulse
every `period` records, 48 records ahead of the next `mark_demod`) continues undisturbed.

ch2/ch3 (mark_demod, mark_fec, toff, slot/side/tref) are the universal anchor present on every
selector (ddrcap2_decode.py), so this scan also runs on the full-rate sel13/14/15 captures, which
carry ch2 even though their I/Q payload is selector-specific.

Method: walk the sorted `mark_fec` record positions; a position continues the "regular chain" if it
is `period` (+/- `tol`) records after the previous regular position; otherwise, if the position AFTER
it continues the chain instead, the current position is flagged EXTRA and skipped (this is exactly
what a lone anomalous pulse inserted between two regular ones produces: two short gaps, `g1+g2 ==
period`, instead of one `period` gap). d_data transitions are computed exactly as in
ddrcap2_beat_analysis.analyse (0 / rung / None / other classes, RUNGS list), sel6 only (d_data has no
analog on sel13/14/15 -- see TASK9_PREREG.md).

Positive control: the regular cadence must be found at the capture's own period with the expected
count (>= 99% of the modal chain length; verified below on every real capture scanned).
Negative control: a synthetic stream with no extra pulses reports zero extras.
"""
import argparse, json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
from ddrcap2_beat_analysis import per_frame_offsets, load_map, RUNGS

SEL6_PERIOD = 12320
FULLRATE_PERIOD = 4 * 12333  # 49332 -- full-rate (enb-domain) taps: sel12-15 (spec sec 3)


def find_regular_and_extra(fec, period, tol=5):
    """Split sorted mark_fec record positions into (regular_chain, extra_positions).
    See module docstring for the algorithm."""
    fec = np.asarray(fec, dtype=np.int64)
    if len(fec) == 0:
        return [], []
    regular = [int(fec[0])]
    extra = []
    i = 1
    n = len(fec)
    while i < n:
        cand = int(fec[i])
        gap = cand - regular[-1]
        if abs(gap - period) <= tol:
            regular.append(cand); i += 1
        elif i + 1 < n and abs((int(fec[i + 1]) - regular[-1]) - period) <= tol:
            extra.append(cand); i += 1
        else:
            # cadence broken by more than a single inserted pulse -- best effort: resync here
            regular.append(cand); i += 1
    return regular, extra


def d_data_transitions(a, d):
    """Every d_data class transition (0 / rung / None / other) AFTER the capture's opening frame,
    record index + (from,to) class, exactly the classification ddrcap2_beat_analysis.analyse uses
    for onset/verdict scoring. The opening frame's own class is reported separately as
    `initial_class` (it is a capture-boundary fact, not a transition -- there is no prior frame in
    this file to transition from; note it can itself be 'rung', i.e. the capture can open mid-burst
    -- see 'None' used both as the sentinel-free initial-class value and as a real class name, kept
    distinct here via a private sentinel object, not Python's `None`)."""
    m = load_map()
    fr = per_frame_offsets(a, d, m)

    def cls(o):
        if o is None: return 'None'
        if o == 0: return '0'
        if o in RUNGS: return 'rung'
        return 'other'
    out = []
    _UNSET = object()
    prev = _UNSET
    initial_class = None
    initial_record = None
    for rec, o in fr:
        c = cls(o)
        if prev is _UNSET:
            initial_class = c; initial_record = int(rec); prev = c
            continue
        if c != prev:
            out.append({'record': int(rec), 'from': prev, 'to': c})
            prev = c
    return {'initial_record': initial_record, 'initial_class': initial_class, 'transitions': out}


def nearest_extra(record, extra):
    if not len(extra):
        return None, None
    extra = np.asarray(extra, dtype=np.int64)
    idx = int(np.argmin(np.abs(extra - record)))
    return int(extra[idx]), int(record - extra[idx])


def demod_offset_sample(regular, demod, k=20):
    """Sample record-distance from each regular TX pulse to the NEXT demod mark (sanity: should be
    a small constant, e.g. 48 records on sel6, per §82's sidecar table)."""
    offs = []
    demod = np.asarray(demod, dtype=np.int64)
    for r in regular[:k]:
        idx = np.searchsorted(demod, r)
        if idx < len(demod):
            offs.append(int(demod[idx] - r))
    return offs


def demod_offset_control(regular, demod):
    """POSITIVE CONTROL (real, not tautological): for EVERY regular TX pulse, the record distance to
    the next demod mark. If the assumed period is right and the marker channel is intact, this is a
    constant (48 records on sel6). PASS iff the modal offset covers >= 99 % of regular pulses.
    A ragged distribution (as on the full-rate taps, where DMA drops delete records) FAILS the control
    and the capture's extra-pulse count is then UNINFORMATIVE, not a null."""
    demod = np.asarray(demod, dtype=np.int64)
    if len(regular) == 0 or len(demod) == 0:
        return {'modal_offset': None, 'modal_fraction': 0.0, 'n': 0, 'pass': False}
    r = np.asarray(regular, dtype=np.int64)
    idx = np.searchsorted(demod, r); ok = idx < len(demod)
    offs = demod[idx[ok]] - r[ok]
    if len(offs) == 0:
        return {'modal_offset': None, 'modal_fraction': 0.0, 'n': 0, 'pass': False}
    v, c = np.unique(offs, return_counts=True); m = int(c.argmax())
    frac = float(c[m] / len(offs))
    return {'modal_offset': int(v[m]), 'modal_fraction': round(frac, 4), 'n': int(len(offs)), 'pass': bool(frac >= 0.99)}


def scan_capture(path, period, has_d_data):
    a = load(path); d = decode(a)
    fec = np.flatnonzero(d['mark_fec'])
    demod = np.flatnonzero(d['mark_demod'])
    regular, extra = find_regular_and_extra(fec, period)
    pc = demod_offset_control(regular, demod)
    result = {
        'file': path, 'period': period,
        'n_mark_fec_total': int(len(fec)),
        'n_regular': len(regular), 'n_extra': len(extra),
        'extra_positions': extra,
        'regular_cadence_offset_to_next_demod_mark_sample': demod_offset_sample(regular, demod),
        'positive_control': pc,
        'positive_control_pass': pc['pass'],
        'extra_pulse_count_status': ('VALID' if pc['pass'] else 'UNINFORMATIVE (positive control failed)'),
    }
    if has_d_data:
        dd = d_data_transitions(a, d)
        trans = dd['transitions']
        for t in trans:
            ex, dist = nearest_extra(t['record'], extra)
            t['nearest_extra_pulse'] = ex
            t['distance_to_nearest_extra'] = dist
            t['extra_pulse_immediately_precedes'] = (dist == 1)
        result['initial_record'] = dd['initial_record']
        result['initial_class'] = dd['initial_class']
        result['d_data_transitions'] = trans
        n_match = sum(1 for t in trans if t['extra_pulse_immediately_precedes'])
        result['transitions_immediately_preceded_by_extra_pulse'] = f"{n_match}/{len(trans)}"
    return result


def negative_control():
    """Synthetic stream, regular cadence only, no extra pulses -- must report zero extras."""
    period = 12320
    n_regular = 50
    fec = np.arange(n_regular) * period + 100
    regular, extra = find_regular_and_extra(fec, period)
    return {'n_regular': len(regular), 'n_extra': len(extra), 'pass': len(extra) == 0 and len(regular) == n_regular}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('capture', nargs='?', help='path to a .bin capture')
    ap.add_argument('--period', type=int, default=None, help='override cadence period (default: 12320 sel6, 49332 full-rate)')
    ap.add_argument('--fullrate', action='store_true', help='this capture is a full-rate (sel12-15) tap: period=49332, no d_data')
    ap.add_argument('--out', help='write JSON result to this path')
    ap.add_argument('--negctl', action='store_true', help='run only the negative control and exit')
    x = ap.parse_args()

    if x.negctl or x.capture is None:
        r = negative_control()
        print(json.dumps(r, indent=1))
        return 0 if r['pass'] else 1

    period = x.period or (FULLRATE_PERIOD if x.fullrate else SEL6_PERIOD)
    r = scan_capture(x.capture, period, has_d_data=not x.fullrate)
    print(json.dumps(r, indent=1))
    if x.out:
        json.dump(r, open(x.out, 'w'), indent=1)
        print(f"wrote {x.out}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
