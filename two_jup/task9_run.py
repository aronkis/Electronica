#!/usr/bin/env python3
"""task9_run.py -- committed driver that reproduces the Task 9 sel13/sel14/sel15 *_analysis.json
files from the raw .bin captures with the exact parameters used (final-fix brief item D: the
detector modules had no `main`, and the committed JSON came from uncommitted, un-reproducible
invocations -- countReg extraction `I & 0x7FF`, quiet-stretch selection, injection points).

Parameters below were reverse-derived from TASK9_PREREG.md's addenda (the pre-registered formulas
and the specific pair-index/record ranges quoted for the positive/negative controls) and from the
committed JSON files themselves; see each subcommand for the citation. Run `--check` to diff a
fresh run's output against the already-committed JSON in the same directory.

Usage:
    task9_run.py sel13 <capdir> [--check]
    task9_run.py sel14 <capdir> [--check]
    task9_run.py sel15 <capdir> [--check]
    task9_run.py all <beatcap_root> [--check]
"""
import argparse, json, os, sys
import numpy as np
from ddrcap2_decode import load, decode
import task9_sel13_detector as sel13d
import task9_sel14_detector as sel14d
import task9_sel15_detector as sel15d

# expected_onset_record ~= (LEAD / window_seconds) * total_records, LEAD=0.5, window_seconds~=1.1
# (TASK9_PREREG.md line 43-45); total_records is file-size/4 records (each record = 4 int16 = 8 B).
LEAD = 0.5
WINDOW_SECONDS = 1.1


def expected_onset_record(total_records):
    return int((LEAD / WINDOW_SECONDS) * total_records)


def countreg_of(a):
    """sel13 I[10:0] = Interpolation_Control.countReg[10:0] (TASK9_PREREG.md line 14)."""
    return a[:, 0].astype(np.uint16) & 0x7FF


def _write(obj, path, check):
    fresh = json.dumps(obj, indent=1, sort_keys=True)
    if check and os.path.exists(path):
        old = json.dumps(json.load(open(path)), indent=1, sort_keys=True)
        if old == fresh:
            print(f"  {os.path.basename(path)}: byte-identical to committed JSON")
        else:
            print(f"  {os.path.basename(path)}: DIFFERS from committed JSON")
            print(f"    committed: {old[:300]}")
            print(f"    fresh    : {fresh[:300]}")
        return old == fresh
    json.dump(obj, open(path, 'w'), indent=1)
    print(f"  wrote {path}")
    return None


# ---------------------------------------------------------------------------
# sel13: interpolator phase-accumulator windowed-mean-shift detector.
# Controls per TASK9_PREREG.md Addendum 1: negative control real onset.bin pair-index range
# [1.34M, 4.70M) unmodified (0 events, n_pairs=837222); positive control disjoint pair-index range
# [0.33M, 1.75M), synthetic sustained +40-count step injected at the stretch midpoint (fires
# immediately, stays flagged for the remainder of the stretch).
# ---------------------------------------------------------------------------

def sel13_controls(a, tref):
    """TASK9_PREREG.md Addendum 1 quotes 'pair-index range' but the values (1.34M, 4.70M, 0.33M,
    1.75M) are RECORD-index bounds on the `pos` array's VALUES (raw record positions), not indices
    into the (much sparser) `pos` array itself -- confirmed by n_pairs=837222 for the negative
    control, which only comes out of a record-index filter (tref is ~1-in-4 records sparse, and
    (4.70M-1.34M)/4 ~= 840000, matching)."""
    countreg = countreg_of(a)
    pos, prev_pos, modal = sel13d.clean_pairs(tref)
    out = {}
    # negative control: record-index range [1.34M, 4.70M)
    neg_lo, neg_hi = 1_340_000, 4_700_000
    m = (pos >= neg_lo) & (pos < neg_hi)
    np_, npp = pos[m], prev_pos[m]
    d = sel13d.raw_delta(countreg, np_, npp)
    med, mad, thresh = sel13d.mean_shift_baseline(d, sel13d.W_DEFAULT)
    ev, _ = sel13d.mean_shift_events(d, med, mad, thresh, sel13d.W_DEFAULT)
    out['negative_control'] = {'record_lo': neg_lo, 'record_hi': neg_hi, 'n_pairs': len(d), 'n_events': int(len(ev))}

    # positive control: disjoint record-index range [0.33M, 1.75M), inject a SUSTAINED +40-count
    # PER-SYMBOL offset (a rate change, not a one-time level step -- item C's "sustained
    # +40-count-per-symbol offset"; a single one-time step would only perturb the one pair
    # straddling it and never move the windowed mean) starting at the stretch midpoint: every
    # clean-pair position from the midpoint onward gets successively larger cumulative offset, so
    # every post-injection raw_delta is elevated by +40 relative to baseline.
    pos_lo, pos_hi = 330_000, 1_750_000
    mid = pos_lo + (pos_hi - pos_lo) // 2
    m2 = (pos >= pos_lo) & (pos < pos_hi)
    win_pos, win_prev = pos[m2], prev_pos[m2]
    countreg_inj = countreg.copy().astype(np.int64)
    inject_idx = np.flatnonzero(win_pos >= mid)  # pairs whose LATER end is at/after the midpoint
    ramp = np.zeros(len(win_pos), dtype=np.int64)
    if len(inject_idx):
        ramp[inject_idx[0]:] = 40 * (np.arange(len(win_pos) - inject_idx[0]) + 1)
    countreg_inj[win_pos] = (countreg[win_pos].astype(np.int64) + ramp) % 2048
    d_inj = sel13d.raw_delta(countreg_inj, win_pos, win_prev)
    # own baseline recomputed on the pre-injection half only (TASK9_PREREG.md line 98)
    pre_n = int((win_pos < mid).sum())
    med2, mad2, thresh2 = sel13d.mean_shift_baseline(d_inj[:pre_n], sel13d.W_DEFAULT)
    ev2, _ = sel13d.mean_shift_events(d_inj, med2, mad2, thresh2, sel13d.W_DEFAULT)
    closest = int(np.min(np.abs(ev2 - pre_n))) if len(ev2) else None
    out['positive_control'] = {'record_lo': pos_lo, 'record_hi': pos_hi, 'inject_at_record': int(mid),
                                'n_pairs': len(d_inj), 'n_events': int(len(ev2)),
                                'closest_event_to_injection_windows': closest}
    return out


def run_sel13(capdir, check):
    print(f"sel13: {capdir}")
    for name in ('onset', 'mid'):
        binp = os.path.join(capdir, f'{name}.bin')
        if not os.path.exists(binp):
            print(f"  {name}.bin missing, skip"); continue
        a = load(binp); d = decode(a); tref = d['tref']
        total_records = len(a)
        eor = expected_onset_record(total_records)
        r = sel13d.score_onset_window(countreg_of(a), tref, eor, total_records)
        r['total_records'] = total_records
        r['expected_onset_record'] = eor
        r['file'] = os.path.join(capdir, f'{name}.bin')
        out = os.path.join(capdir, f'sel13_{name}_analysis.json')
        _write(r, out, check)
        if name == 'onset':
            ctrl = sel13_controls(a, tref)
            print(f"    controls: {json.dumps(ctrl)}")


# ---------------------------------------------------------------------------
# sel14: frame-to-frame self-similarity. Two variants are committed: the deprecated raw-record-index
# framing (sel14_<name>_analysis.json) and the tref-indexed drop-aware framing (revision 2,
# sel14_<name>_tref_analysis.json).
# ---------------------------------------------------------------------------

def run_sel14(capdir, check):
    print(f"sel14: {capdir}")
    for name in ('onset', 'mid'):
        binp = os.path.join(capdir, f'{name}.bin')
        if not os.path.exists(binp):
            print(f"  {name}.bin missing, skip"); continue
        a = load(binp); d = decode(a); tref = d['tref']
        I = a[:, 0]
        total_records = len(a)

        # deprecated raw-record-index variant. Baseline from the first 20% of the corr series
        # (same quiet_frac convention as the tref variant), events searched over the whole series.
        corr = sel14d.frame_corr_series(I)
        quiet_n0 = max(5, int(len(corr) * 0.20))
        med, mad, thresh = sel14d.corr_baseline(corr[:quiet_n0])
        ev = sel14d.dip_events(corr, med, thresh)
        n_frames = len(I) // sel14d.FRAME_RECORDS
        r = {'file': os.path.join(capdir, f'{name}.bin'), 'n_frames': int(n_frames),
             'boundaries_scored': int(len(corr)), 'baseline_median': med, 'baseline_mad': mad,
             'threshold': thresh, 'dip_events': ev.tolist(),
             'corr_min': float(corr.min()) if len(corr) else None,
             'corr_max': float(corr.max()) if len(corr) else None}
        _write(r, os.path.join(capdir, f'sel14_{name}_analysis.json'), check)

        # revision-2 tref-indexed variant, scored over the WHOLE file (not just the search window --
        # this is the full-file event location, matching the committed JSON's dip_events_frame/record)
        frames, n_valid = sel14d.tref_frames(I, tref)
        corr2, overlap = sel14d.tref_frame_corr_series(frames)
        quiet_n = max(5, int(len(corr2) * 0.20))
        med2, mad2, thresh2 = sel14d.tref_corr_baseline(corr2[:quiet_n])
        ev2 = sel14d.tref_dip_events(corr2, med2, thresh2)
        # dip_events_record: the RAW record index (into the original stream, not the tref-valid
        # subset) where each dip-flagged frame boundary's earlier frame begins -- i.e. the true
        # record position of the frame-to-frame transition, not a nominal 4*TREF_MOD*frame_id
        # multiply (which is wrong wherever DMA drops have occurred upstream of that frame).
        valid_pos = np.flatnonzero(tref >= 0)
        trv = tref[valid_pos].astype(np.int64)
        raw_dt = np.diff(trv)
        wrap = raw_dt < -(sel14d.TREF_MOD // 2)
        frame_id = np.concatenate(([0], np.cumsum(wrap)))
        n_frames_ = int(frame_id[-1]) + 1
        first_idx = np.searchsorted(frame_id, np.arange(n_frames_))
        first_record = valid_pos[first_idx]
        ev_records = first_record[ev2]
        r2 = {'n_frames': int(frames.shape[0]), 'n_boundaries': int(len(corr2)),
              'baseline_median': med2, 'baseline_mad': mad2, 'threshold': thresh2,
              'dip_events_frame': ev2.tolist(),
              'dip_events_record': ev_records.tolist(),
              'dip_events_pct_of_file': [round(100.0 * r_ / total_records, 3) for r_ in ev_records.tolist()],
              'dip_events_corr': [round(float(corr2[i]), 4) for i in ev2.tolist()],
              'total_records': total_records}
        _write(r2, os.path.join(capdir, f'sel14_{name}_tref_analysis.json'), check)


# ---------------------------------------------------------------------------
# sel15: Rate_Handle FIFO occupancy LEVEL detector + secondary transition detector.
# level_first20_vs_last20 compares the first 20% vs last 20% of the tref-indexed clean-occupancy
# samples in the file (TASK9_PREREG.md's "first-20%/last-20%" fallback, used because neither
# onset.bin nor mid.bin turned out to be a pure whole-window-quiet reference -- Addendum 7).
# ---------------------------------------------------------------------------

def run_sel15(capdir, check):
    print(f"sel15: {capdir}")
    for name in ('onset', 'mid'):
        binp = os.path.join(capdir, f'{name}.bin')
        if not os.path.exists(binp):
            print(f"  {name}.bin missing, skip"); continue
        a = load(binp); d = decode(a); tref = d['tref']
        total_records = len(a)
        push, pop = sel15d.unpack(a)
        occ, pos, modal = sel15d.clean_occupancy(push, pop, tref)
        n = len(occ)
        quiet = occ[:int(n * 0.2)]; displaced = occ[int(n * 0.8):]
        level = sel15d.level_shift(quiet, displaced)
        eor = expected_onset_record(total_records)
        trans = sel15d.transition_score(push, pop, tref, eor, total_records)
        r = {'file': os.path.join(capdir, f'{name}.bin'), 'n_clean_samples': int(n),
             'occupancy_min': int(occ.min()) if n else None, 'occupancy_max': int(occ.max()) if n else None,
             'occupancy_median': float(np.median(occ)) if n else None,
             'occupancy_distinct': sorted(int(x) for x in np.unique(occ)),
             'level_first20_vs_last20': level, 'transition_score': trans}
        _write(r, os.path.join(capdir, f'sel15_{name}_analysis.json'), check)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('selector', choices=['sel13', 'sel14', 'sel15', 'all'])
    ap.add_argument('capdir', help='capture directory (sel13/sel14/sel15) or beatcap root (all)')
    ap.add_argument('--check', action='store_true', help='diff against already-committed JSON instead of overwriting')
    x = ap.parse_args()
    if x.selector == 'all':
        dirs = {'sel13': None, 'sel14': None, 'sel15': None}
        for name in os.listdir(x.capdir):
            for k in dirs:
                if name.endswith('_' + k):
                    dirs[k] = os.path.join(x.capdir, name)
        if dirs['sel13']: run_sel13(dirs['sel13'], x.check)
        if dirs['sel14']: run_sel14(dirs['sel14'], x.check)
        if dirs['sel15']: run_sel15(dirs['sel15'], x.check)
        return 0
    fn = {'sel13': run_sel13, 'sel14': run_sel14, 'sel15': run_sel15}[x.selector]
    fn(x.capdir, x.check)
    return 0


if __name__ == '__main__':
    sys.exit(main())
