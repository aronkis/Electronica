#!/usr/bin/env python3
"""ops/comb/common.py -- shared plumbing for the T0b comb analysis tools.

Reuses frame_taxonomy.read_frames (the same reader accept_analyze.py imports)
so frame_rec parsing has exactly one implementation. Adds:

  * live_window()      -- the settle-15s / live-window-end rule, copied
                           verbatim from accept_analyze.analyze() so every
                           tool in this package windows a capture identically.
  * loss_slot_trains()  -- the "record position" reconstruction described in
                           the T0b brief: magic-bad (and any other
                           non-decoded) records log a raw header-byte seq
                           that can be garbage, so lost-frame *slots* are
                           reconstructed from GOOD (crc_ok=1) frames' host_seq
                           only (their seq is CRC-verified, hence trustworthy
                           by construction). Consecutive good frames whose
                           host_seq delta is 1 contribute no loss; a delta > 1
                           means (delta-1) genuinely lost slots between them.
                           This is exactly the reconstruction
                           accept_analyze.analyze() performs (its `pres`
                           array) -- doing it here as reusable, FFT-friendly
                           arrays lets comb_autocorr/comb_phase reproduce its
                           lag-33 numbers exactly (see comb_lagcheck.md for
                           the units discussion). A `validity` mask flags the
                           good-good pairs actually used (delta sane, i.e.
                           1 <= delta < SANITY_CAP) so a caller can tell where
                           the reconstruction is trustworthy.
  * fft_autocorr()      -- zero-mean, >=4x zero-padded FFT autocorrelation,
                           numerically equivalent to
                           np.correlate(x - x.mean(), x - x.mean(), 'full')
                           for lags < len(x), but O(n log n).
  * permutation_null()  -- shuffles the fail train `n_shuffle` times and
                           returns the 95th percentile of the per-shuffle max
                           |autocorr| over the requested lag range (a
                           family-wise threshold across all reported lags).
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from frame_taxonomy import read_frames as _read_frames_raw  # noqa: E402
from recovery_windows import (keep_mask, load_recovery,  # noqa: E402
                              notice_for_unaware_tool, segments_from_mask)

SETTLE_S = 15.0
SANITY_CAP = 100_000  # a good-good host_seq delta this large is corruption, not loss


def read_frames(path, honours_recovery=False):
    """frame_taxonomy.read_frames, plus the RXFIX Task 44 NOTICE.

    Every comb tool imports read_frames from here, so a capture that
    capture_r3.sh has marked as PERTURBED (a recovered mid-window collapse:
    `recovery.txt` next to frames.bin) announces itself on stderr in ALL of
    them -- including the ones that do not exclude it, which would otherwise
    score the collapse gap as ordinary loss without saying so. Silent, and a
    no-op, when there is no recovery.txt: that is every leg to date.

    honours_recovery=True says the CALLER excludes the perturbed interval
    itself (comb_period_ms.py does, via loss_slot_trains(path=...)), so the
    "this tool is scoring it as loss" notice is suppressed -- that tool prints
    its own, accurate, line instead.
    """
    fr = _read_frames_raw(path)
    if not honours_recovery:
        notice_for_unaware_tool(path, tool=os.path.basename(sys.argv[0] or "comb tool"))
    return fr


def live_window(fr):
    """Reproduce accept_analyze.analyze()'s live-window-end rule exactly.

    Returns (dur, live_end, wedged). `fr` is the full structured array from
    read_frames (not yet time-windowed).
    """
    clean = fr["crc_ok"] != 0
    tm = fr["t_mono_ns"].astype(np.int64)
    t0 = tm[0]
    ts = (tm - t0) / 1e9
    dur = float(ts[-1])
    nb = max(int(dur) + 1, 1)
    cps = np.zeros(nb)
    for b in range(nb):
        cps[b] = ((clean) & (ts >= b) & (ts < b + 1)).sum()
    peak = cps.max() if cps.size else 0
    live_end = dur
    if peak > 0:
        good = np.flatnonzero(cps >= 0.25 * peak)
        live_end = float(good[-1] + 1) if good.size else 0.0
        wedged = live_end < dur - 3.0
        if wedged:
            live_end = max(live_end - 2.0, 0.0)
    else:
        wedged = True
        live_end = 0.0
    return ts, dur, live_end, wedged


def _runs(idx):
    """Group a sorted int array of positions into (start, length) runs of
    consecutive integers."""
    runs = []
    i = 0
    n = len(idx)
    while i < n:
        j = i
        while j + 1 < n and idx[j + 1] == idx[j] + 1:
            j += 1
        runs.append((int(idx[i]), j - i + 1))
        i = j + 1
    return runs


def loss_slot_trains(fr, settle_s=SETTLE_S, path=None):
    """Build the reconstructed TX-slot (host_seq) fail trains -- ONE ARRAY
    SLOT PER TRANSMITTED-FRAME SEQUENCE NUMBER, the same axis
    accept_analyze.py's `pres`/`sp` arrays use. This is NOT
    frame_taxonomy.py's record-position axis (the position of a logged
    record, good or bad, in frames.bin) -- see comb_lagcheck.md. Only
    crc_ok==1 frames' host_seq is trusted to place a slot (a magic-bad
    frame's host_seq is raw, possibly-garbage header bytes and is never used
    as an index).

    Returns a dict:
      usable         bool
      live_end, dur, wedged
      lo, hi         host_seq bounds of the reconstructed slot axis
      n_slots        hi - lo + 1
      all_loss       int8[n_slots], 1 at every lost slot (any run length)
      singles        int8[n_slots], 1 only at isolated (run-length==1) losses
                      -- identical construction to accept_analyze's `sp`
      validity_frac  fraction of good-good adjacent pairs whose delta was
                      inside the sanity cap (diagnostic, not used to drop data
                      -- a delta outside the cap most likely means a wedge or
                      capture artefact, not a real single-run loss, so it is
                      *not* folded into the loss trains as ordinary loss)
      run_bins       run-length census (1/2/3-4/5-20/21-100/>100)

    RECOVERED LEGS (RXFIX Task 44). Pass `path` (the frames.bin this array came
    from) and, if capture_r3.sh recovered a mid-window collapse on that leg
    (MID_RECOVER=1, default off), the perturbed interval named in the sibling
    `recovery.txt` is EXCLUDED: its slots are zeroed in all_loss/singles and
    dropped from n_slots_scored, and no loss run is ever built across a segment
    boundary. Three extra keys then appear:

      n_slots_scored  slots actually scored = n_slots - excluded slots.  ANY
                      RATE MUST DIVIDE BY THIS, NOT BY n_slots -- n_slots stays
                      the full [lo,hi] axis length because the phase axis must
                      not shift (comb_period_ms.py FFTs over it).
      scored          int8[n_slots], 1 where the slot is inside a scored segment
      recovery        the loaded record (events, excluded_s, warnings)

    Without `path`, or with no recovery.txt, nothing is excluded and every
    returned array is exactly what this function returned before Task 44.
    """
    ts, dur, live_end, wedged = live_window(fr)
    rec = load_recovery(path) if path else dict(events=[], excluded_s=0.0,
                                                warnings=[], present=False, path=None)
    clean = fr["crc_ok"] != 0
    ci = np.flatnonzero(clean)
    ct = ts[ci]
    cseq = fr["host_seq"][ci].astype(np.int64)
    ct_mono_ns = fr["t_mono_ns"][ci].astype(np.int64)
    ct_real_ns = fr["t_real_ns"][ci].astype(np.int64)
    w = (ct >= settle_s) & (ct < live_end)
    out = dict(usable=False, dur=dur, live_end=live_end, wedged=wedged,
               recovery=rec)
    if w.sum() < 100:
        return out
    wi = np.flatnonzero(w)
    cw = cseq[wi]
    cw_t_mono_ns = ct_mono_ns[wi]
    # Perturbed-interval mask on the RX board's CLOCK_REALTIME -- the clock
    # capture_r3.sh writes recovery.txt on. All-True (one segment) whenever
    # there is no recovery record.
    keep = keep_mask(ct_real_ns[wi], rec["events"])
    segs = segments_from_mask(keep)
    if int(keep.sum()) < 100:
        out["reason_recovery"] = (
            f"only {int(keep.sum())} clean in-window frames survive the "
            f"{len(rec['events'])} perturbed interval(s)")
        return out

    deltas = np.diff(cw)
    sane = (deltas > 0) & (deltas < SANITY_CAP)
    validity_frac = float(sane.mean()) if sane.size else 1.0

    cw_kept = cw[keep]
    lo_ = int(cw_kept[0])
    hi_ = int(cw_kept[-1])
    n_slots = hi_ - lo_ + 1
    pres = np.zeros(n_slots, dtype=np.int8)
    pres[cw_kept - lo_] = 1
    # `scored` = the slots inside a clean segment. With no recovery record
    # there is one segment and this is all-ones, so every array below is
    # identical to the pre-Task-44 result.
    scored = np.zeros(n_slots, dtype=np.int8)
    seg_bounds = []
    for a, b in segs:
        cs = cw[a:b]
        if cs.size < 2:
            continue
        seg_bounds.append((int(cs[0]), int(cs[-1])))
        scored[int(cs[0]) - lo_: int(cs[-1]) - lo_ + 1] = 1
    # A good-good pair whose delta is insane (>= SANITY_CAP) IS still folded
    # into all_loss/singles below (all_loss = 1-pres over the full [lo_,hi_]
    # span; nothing here clamps or special-cases it) -- `sane`/`validity_frac`
    # is a DIAGNOSTIC ONLY (Task-2-review finding 5: an earlier version of
    # this comment claimed such deltas were excluded from the loss trains;
    # they are not). Empirically harmless on today's data (all anomalous
    # deltas seen so far are <= 0, i.e. duplicate/out-of-order host_seq, not
    # a giant forward jump), but a real delta >= SANITY_CAP would currently
    # manufacture a SANITY_CAP-long "loss run" here. If that ever shows up
    # (validity_frac < 1.0 with the anomaly on the >0 side), clamp it rather
    # than trusting run_bins/all_loss blindly.
    # Runs are found INSIDE each scored segment, so the hole a perturbed
    # interval leaves is never itself a loss run and no run ever spans a
    # segment boundary. One segment (the ordinary leg) => this is exactly
    # `_runs(np.flatnonzero(1 - pres))` over the whole axis, as before.
    runs = []
    for s_lo, s_hi in seg_bounds:
        sl = slice(s_lo - lo_, s_hi - lo_ + 1)
        idx = np.flatnonzero(1 - pres[sl])
        runs.extend([(p + (s_lo - lo_), length) for p, length in _runs(idx)])

    all_loss = ((1 - pres) * scored).astype(np.int8)
    singles = np.zeros(n_slots, dtype=np.int8)
    for p, length in runs:
        if length == 1:
            singles[p] = 1

    rl = np.array([length for _, length in runs], dtype=np.int64)
    run_bins = {
        "1": int((rl == 1).sum()),
        "2": int((rl == 2).sum()),
        "3-4": int(((rl >= 3) & (rl <= 4)).sum()),
        "5-20": int(((rl >= 5) & (rl <= 20)).sum()),
        "21-100": int(((rl >= 21) & (rl <= 100)).sum()),
        ">100": int((rl > 100).sum()),
    }

    out.update(
        usable=True,
        lo=lo_,
        hi=hi_,
        n_slots=n_slots,
        all_loss=all_loss,
        singles=singles,
        validity_frac=validity_frac,
        run_bins=run_bins,
        cw=cw,                    # host_seq of each clean (crc_ok=1) frame in-window
        cw_t_mono_ns=cw_t_mono_ns,  # its t_mono_ns, same order as cw (join support)
        # Task 44. n_slots_scored == n_slots on every unperturbed leg.
        n_slots_scored=int(scored.sum()),
        scored=scored,
        n_segments=len(seg_bounds),
        recovery=rec,
    )
    return out


def interp_t_mono_ns(lt, seqs):
    """Estimate t_mono_ns for arbitrary (possibly lost) host_seq values by
    linear interpolation against the known clean-frame anchors (lt['cw'],
    lt['cw_t_mono_ns']). Used to time-clip a TX<->RX join against a TX log's
    t_submit_ns span (README_hostlog.md sec 4) for seqs that were never
    decoded and so have no RX record of their own."""
    seqs = np.asarray(seqs, dtype=np.int64)
    return np.interp(seqs, lt["cw"], lt["cw_t_mono_ns"].astype(np.float64)).astype(np.int64)


def fft_autocorr(x, max_lag=128, zero_pad=4):
    """Zero-mean autocorrelation via FFT, matching
    np.correlate(x-mean, x-mean, 'full')[n-1:n-1+max_lag+1] / ac[0]
    for max_lag < n, but O(n log n) instead of O(n^2).
    """
    x = np.asarray(x, dtype=np.float64)
    n = len(x)
    xc = x - x.mean()
    nfft = 1
    target = zero_pad * n
    while nfft < target:
        nfft *= 2
    X = np.fft.rfft(xc, n=nfft)
    ac_full = np.fft.irfft(X * np.conj(X), n=nfft)
    ac = ac_full[: max_lag + 1].copy()
    if ac[0] != 0:
        ac = ac / ac[0]
    return ac


def permutation_null(x, max_lag=128, n_shuffle=200, seed=0):
    """95th percentile of the per-shuffle max |autocorr(lag)| for
    lag in [1, max_lag], over n_shuffle random permutations of x. A
    family-wise threshold: a real lag's value clearing this bar is
    significant against "no structure, same marginal loss rate" for ANY of
    the reported lags simultaneously.
    """
    rng = np.random.default_rng(seed)
    x = np.asarray(x, dtype=np.float64)
    maxvals = np.empty(n_shuffle)
    for i in range(n_shuffle):
        xs = rng.permutation(x)
        ac = fft_autocorr(xs, max_lag=max_lag)
        maxvals[i] = np.max(np.abs(ac[1:]))
    return float(np.percentile(maxvals, 95))
