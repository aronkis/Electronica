#!/usr/bin/env python3
"""comb_period_ms.py FRAMES.BIN [--pmin 24 --pmax 44] [--singles-only] [--json]

THE FRACTIONAL-PERIOD instrument for a HOST-ONLY leg (no DDRCAP capture).

WHY IT EXISTS. T3 measured the residual comb's period as 32.44301 frames =
26.0489 ms from sel9 DDRCAP demod frame-marker anomalies, and the whole point
of that number is that it is NOT 32.000 (295 sigma out): a deterministic mod-32
fabric beat is excluded, and 26.042 ms = 1e6 cycles of the ADRV9002 38.4 MHz
device clock is the surviving lead. None of the committed host-side tools can
make that distinction:
  * comb_autocorr.py  -- integer lags only (32 vs 33, never 32.44)
  * comb_phase.py     -- needs the period handed to it
  * loss_period.py    -- scans a fixed integer candidate list by mod-consistency
So a probe that runs no capture had no way to test "did the 26 ms line vanish".
This tool measures the period from frames.bin alone.

METHOD.
  * Axis = the reconstructed TX-slot axis from common.loss_slot_trains (one
    entry per transmitted host_seq, settle-15 s + live-window rule), NOT the
    record axis and NOT t_mono. Host timestamps are sampled at DMA-batch decode
    time and smear a 26 ms structure; the slot axis is exact.
  * Events = loss-RUN ONSETS (the first lost slot of each run), not every lost
    slot: a run of 2 contributes two slots one apart and smears the phase. This
    matches T3's sel9 event definition (one event per short-frame anomaly).
  * Score = Rayleigh concentration R(P) = |mean_k exp(2*pi*i*n_k/P)| over the
    event slot indices n_k. R = 1 means every event sits at one phase of P.
    Evaluated by a zero-padded FFT of the sparse event indicator (so the whole
    band is scanned at once) then refined on a fine local grid.
  * Null = the 95th percentile of max-over-band R for uniformly random event
    sets of the same size (a family-wise threshold across the scanned band).
  * ms conversion uses the fabric frame period, not a fitted rate:
    12333 symbols / 15.36 Msym/s = 802.9297 us.  32.44301 * that = 26.0488 ms.

Reported: best period (frames and ms) with its R, R at exactly P=32.000, the
best period restricted to the 25-27 ms band the 38.4 MHz hypothesis predicts,
and the permutation null. Verdict line COMB_LINE=present/absent.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import loss_slot_trains, read_frames  # noqa: E402

# 12333 symbols per fabric frame at 15.36 Msym/s (capture_r3.sh: ksym=15360,
# spf=49332 = 12333 sym x 4 sps). One slot = one transmitted frame = this long.
FRAME_S = 12333.0 / 15.36e6          # 802.9297 us
BAND_MS = (25.0, 27.0)               # the 38.4 MHz / 1e6-cycle prediction window
# CALIBRATION [silicon, desk, 2026-09-03]. Run on the T3 credited forward leg
# a1r2 (two_jup/comb/runs/20260903_191410_legA_a1r2/cap/frames.bin) this tool
# recovers P = 32.4497 frames = 26.0548 ms with R = 0.1737, against the wholly
# independent DDRCAP sel9 demod-marker value 32.44301 frames = 26.0489 ms --
# agreement to 0.02 %, from a different instrument on the same leg. R at exactly
# P = 32.000 is 0.0008 (at the random null). That is the validation of this tool.
# R here is lower than sel9's 0.872 because the host loss train mixes the 26 ms
# process with everything else that loses a frame (T3: the demod short frames
# account for ~52 % of host loss events), so 0.174 IS the "line fully present"
# baseline for a host-only forward leg -- not 0.87.
R_A1R2 = 0.1737                      # the baseline the probes are compared against
R_ABSENT = 0.05                      # pre-registered "line has vanished": < 0.05
                                     # (a >3x reduction from 0.174, still ~3x the
                                     # random-event null ~0.015)


def _R_at(idx, periods):
    """Rayleigh concentration of event slot indices at each trial period."""
    idx = np.asarray(idx, dtype=np.float64)
    periods = np.atleast_1d(np.asarray(periods, dtype=np.float64))
    out = np.empty(periods.shape, dtype=np.float64)
    for i, P in enumerate(periods):
        ph = 2.0 * np.pi * (idx / P)
        out[i] = abs(np.exp(1j * ph).mean())
    return out


def _scan(idx, n_slots, pmin, pmax, pad=8):
    """Coarse FFT scan over the [pmin,pmax] band, then a fine local refine.
    Returns (best_period, best_R, coarse_periods, coarse_R)."""
    x = np.zeros(int(n_slots), dtype=np.float64)
    x[idx] = 1.0
    M = int(pad * n_slots)
    X = np.fft.rfft(x, n=M)
    f = np.arange(X.size, dtype=np.float64) / M           # cycles per slot
    K = float(len(idx))
    with np.errstate(divide="ignore"):
        P = np.where(f > 0, 1.0 / np.maximum(f, 1e-30), np.inf)
    band = (P >= pmin) & (P <= pmax)
    R = np.abs(X[band]) / K
    Pb = P[band]
    j = int(np.argmax(R))
    # fine refine around the coarse peak (+/- 3 coarse bins), direct evaluation
    lo = max(j - 3, 0)
    hi = min(j + 3, len(Pb) - 1)
    fine = np.linspace(min(Pb[hi], Pb[lo]), max(Pb[hi], Pb[lo]), 601)
    Rf = _R_at(idx, fine)
    k = int(np.argmax(Rf))
    return float(fine[k]), float(Rf[k]), Pb, R


def _null(K, n_slots, pmin, pmax, n_shuffle, rng, pad=8):
    """95th pct of max-over-band R for uniformly random event sets of size K."""
    peaks = []
    for _ in range(n_shuffle):
        idx = rng.choice(int(n_slots), size=int(K), replace=False)
        _, r, _, _ = _scan(np.sort(idx), n_slots, pmin, pmax, pad=pad)
        peaks.append(r)
    return float(np.percentile(peaks, 95)), peaks


def analyze(path, pmin=24.0, pmax=44.0, singles_only=False, n_shuffle=8, seed=1234, pad=8):
    fr = read_frames(path)
    lt = loss_slot_trains(fr)
    out = {"file": path, "usable": bool(lt.get("usable"))}
    if not lt.get("usable"):
        out["reason"] = "loss_slot_trains UNUSABLE (live window too short / wedged)"
        out.update(dur=lt.get("dur"), live_end=lt.get("live_end"), wedged=lt.get("wedged"))
        return out
    train = lt["singles"] if singles_only else lt["all_loss"]
    n_slots = int(lt["n_slots"])
    lost = np.flatnonzero(train)
    if lost.size < 200:
        out["usable"] = False
        out["reason"] = "fewer than 200 loss slots -- no period can be resolved"
        return out
    # loss-run onsets: a lost slot whose predecessor was not lost
    if singles_only:
        onsets = lost
    else:
        prev_lost = np.zeros_like(train)
        prev_lost[1:] = train[:-1]
        onsets = np.flatnonzero((train == 1) & (prev_lost == 0))
    K = int(onsets.size)
    bestP, bestR, Pb, Rb = _scan(onsets, n_slots, pmin, pmax, pad=pad)
    # band-restricted best (the 38.4 MHz prediction window)
    bp_lo, bp_hi = BAND_MS[0] / 1e3 / FRAME_S, BAND_MS[1] / 1e3 / FRAME_S
    inband = (Pb >= bp_lo) & (Pb <= bp_hi)
    if inband.any():
        jb = int(np.argmax(Rb[inband]))
        Pcand = Pb[inband][jb]
        fine = np.linspace(Pcand * (1 - 3e-4), Pcand * (1 + 3e-4), 401)
        Rf = _R_at(onsets, fine)
        kb = int(np.argmax(Rf))
        bandP, bandR = float(fine[kb]), float(Rf[kb])
    else:
        bandP, bandR = float("nan"), float("nan")
    null95, peaks = _null(K, n_slots, pmin, pmax, n_shuffle, np.random.default_rng(seed), pad=pad)
    R32 = float(_R_at(onsets, [32.0])[0])
    out.update(
        n_slots=n_slots, n_lost=int(lost.size), n_events=K,
        live_end=float(lt["live_end"]), dur=float(lt["dur"]), wedged=bool(lt["wedged"]),
        per_pct=100.0 * lost.size / n_slots,
        frame_us=FRAME_S * 1e6,
        best_period_frames=bestP, best_R=bestR, best_period_ms=bestP * FRAME_S * 1e3,
        band_period_frames=bandP, band_R=bandR, band_period_ms=bandP * FRAME_S * 1e3,
        R_at_32=R32,
        null95=null95, null_peaks=[round(p, 5) for p in peaks],
        # PRE-REGISTERED verdict: the 26 ms line is ABSENT when its Rayleigh
        # concentration in the 25-27 ms band falls below R_ABSENT and is not
        # above the random-event null.
        comb_line=("absent" if (bandR < R_ABSENT or bandR <= null95)
                   else ("present" if bandR >= 0.7 * R_A1R2 else "reduced")),
        r_absent_threshold=R_ABSENT, r_a1r2_baseline=R_A1R2, band_ms=list(BAND_MS),
        band_R_over_a1r2=bandR / R_A1R2 if bandR == bandR else float("nan"),
    )
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames", nargs="+")
    ap.add_argument("--pmin", type=float, default=24.0)
    ap.add_argument("--pmax", type=float, default=44.0)
    ap.add_argument("--singles-only", action="store_true")
    ap.add_argument("--shuffle", type=int, default=8)
    ap.add_argument("--pad", type=int, default=8)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    res = [analyze(p, a.pmin, a.pmax, a.singles_only, a.shuffle, pad=a.pad) for p in a.frames]
    if a.json:
        print(json.dumps(res, indent=2))
        return
    for r in res:
        print(f"=== {r['file']}")
        if not r["usable"]:
            print(f"  UNUSABLE: {r.get('reason')}")
            continue
        print(f"  slots={r['n_slots']} lost={r['n_lost']} ({r['per_pct']:.3f} %) "
              f"loss-run onsets={r['n_events']}  live={r['live_end']:.0f}/{r['dur']:.0f}s"
              f"{' [WEDGE truncated]' if r['wedged'] else ''}")
        print(f"  frame period {r['frame_us']:.4f} us")
        print(f"  BEST  P = {r['best_period_frames']:.5f} frames = {r['best_period_ms']:.4f} ms   R = {r['best_R']:.4f}")
        print(f"  BAND  P = {r['band_period_frames']:.5f} frames = {r['band_period_ms']:.4f} ms   R = {r['band_R']:.4f}   (25-27 ms)")
        print(f"  R at exactly P=32.000 : {r['R_at_32']:.4f}")
        print(f"  random-event null (95th pct of band max, n={len(r['null_peaks'])}): {r['null95']:.4f}")
        print(f"  band R / a1r2 baseline ({r['r_a1r2_baseline']}) = {r['band_R_over_a1r2']:.3f}")
        print(f"  COMB_LINE={r['comb_line']}  (absent iff band R < {r['r_absent_threshold']} or <= null; "
              f"present iff >= 0.7x the a1r2 baseline; else reduced)")


if __name__ == "__main__":
    main()
