#!/usr/bin/env python3
"""comb_autocorr.py FILE.bin [--live-window] -- FFT autocorrelation of the
lost-frame train over the live window (settle 15s, live-window end rule
copied from accept_analyze.py), indexed by the reconstructed TX-slot
(host_seq) axis -- ONE ARRAY SLOT PER TRANSMITTED-FRAME SEQUENCE NUMBER,
built from crc_ok==1 frames' host_seq deltas only (see
two_jup/comb/common.py:loss_slot_trains). This is accept_analyze.py's axis,
NOT frame_taxonomy.py's record-position axis (the position of a logged
record, good or bad, within frames.bin) -- see two_jup/comb/comb_lagcheck.md
for the distinction and why magic-bad frames' garbage host_seq is never used
to place a slot (only crc_ok==1 host_seq values are trusted).

Reports two variants of the fail train, both over the same slot axis:
  all-loss  -- every lost slot (any loss-run length) is a 1
  singles   -- only isolated (run-length==1) losses are a 1; this is the
               exact construction accept_analyze.py's ac33 uses, so its
               lag-33 value should match here for the same capture.

For each variant: FFT autocorrelation (zero-mean, >=4x zero-pad) for lags
1..128, a 200-shuffle permutation null (95th percentile of the per-shuffle
max over lags 1..128), the top 8 lags by value, and the lag-16/32/33/64
values called out explicitly.

Usage: comb_autocorr.py FILE.bin [--live-window]
  --live-window   also print the live-window bounds (dur, live_end, wedged)
                   used to select the window; analysis is always confined to
                   the live window regardless of this flag.
"""
import argparse
import json
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from common import fft_autocorr, live_window, loss_slot_trains, permutation_null, read_frames

MAX_LAG = 128
CALLOUT_LAGS = (16, 32, 33, 64)


def harmonic_family(lag):
    """Task-2-review finding 4: label a lag by its nearest k x 32 and
    k x 33 multiple (round-to-nearest k>=1), with the signed slip from each.
    fwd/rev2 top lags sit exactly on k x 32 (slip 0); fwd_after's sit at
    k x 32 + 1 (33, 65, 97) -- a *systematic* +1 slip off the 32-family, not
    a k x 33 family (33 matches k=1 x 33 exactly, but 65 and 97 do not: 2x33
    =66, 3x33=99). Both families are reported so a reader can see this
    directly rather than trusting one label."""
    if lag <= 0:
        return dict(k32=0, slip32=lag, k33=0, slip33=lag)
    k32 = max(1, round(lag / 32))
    k33 = max(1, round(lag / 33))
    return dict(k32=k32, slip32=lag - k32 * 32, k33=k33, slip33=lag - k33 * 33)


def analyze_one(path, n_shuffle=200, seed=0):
    fr = read_frames(path)
    lt = loss_slot_trains(fr)
    if not lt["usable"]:
        return dict(path=path, usable=False, dur=lt["dur"], live_end=lt["live_end"],
                    wedged=lt["wedged"])
    out = dict(path=path, usable=True, dur=lt["dur"], live_end=lt["live_end"],
               wedged=lt["wedged"], lo=lt["lo"], hi=lt["hi"], n_slots=lt["n_slots"],
               validity_frac=lt["validity_frac"], run_bins=lt["run_bins"], variants={})
    for name in ("all_loss", "singles"):
        x = lt[name]
        if x.sum() < 4 or len(x) <= 40:
            out["variants"][name] = dict(usable=False, n_events=int(x.sum()))
            continue
        ac = fft_autocorr(x, max_lag=MAX_LAG)
        null = permutation_null(x, max_lag=MAX_LAG, n_shuffle=n_shuffle, seed=seed)
        order = np.argsort(-ac[1:]) + 1  # lags, best first
        top8 = [(int(lag), float(ac[lag])) for lag in order[:8]]
        callouts = {lag: float(ac[lag]) if lag < len(ac) else float("nan")
                    for lag in CALLOUT_LAGS}
        out["variants"][name] = dict(
            usable=True, n_events=int(x.sum()), null_threshold=null,
            top8=top8, callouts=callouts,
        )
    return out


def print_report(r):
    tag = r["path"].split("/")[-2] if "/" in r["path"] else r["path"]
    if not r["usable"]:
        print(f"{tag}: UNUSABLE (live window {r['live_end']:.0f}s of {r['dur']:.0f}s"
              f"{', WEDGED' if r['wedged'] else ''})")
        return
    print(f"=== {tag}  live {r['live_end']:.0f}s/{r['dur']:.0f}s"
          f"{' [WEDGE]' if r['wedged'] else ''}  "
          f"slot axis [{r['lo']}, {r['hi']}] ({r['n_slots']} slots)  "
          f"validity_frac={r['validity_frac']:.4f}  run_bins={r['run_bins']} ===")
    for name in ("all_loss", "singles"):
        v = r["variants"][name]
        label = "ALL-LOSS" if name == "all_loss" else "SINGLES-ONLY"
        if not v["usable"]:
            print(f"  [{label}] not usable ({v['n_events']} events, too few/short)")
            continue
        print(f"  [{label}] events={v['n_events']}  null(p95, max over lags 1-128, "
              f"a sampling floor -- shuffling destroys run structure, so it is NOT a "
              f"burst-structure null)={v['null_threshold']:.4f}")
        print(f"    top8 lags: " + ", ".join(f"{lag}:{val:+.4f}" for lag, val in v["top8"]))
        print("    top5 with harmonic family (nearest k x 32 vs k x 33, signed slip):")
        for lag, val in v["top8"][:5]:
            hf = harmonic_family(lag)
            print(f"      {lag:3d}: {val:+.4f}   "
                  f"{hf['k32']}x32={hf['k32']*32} (slip {hf['slip32']:+d})   "
                  f"{hf['k33']}x33={hf['k33']*33} (slip {hf['slip33']:+d})")
        cal = v["callouts"]
        print(f"    lag16={cal[16]:+.4f}  lag32={cal[32]:+.4f}  "
              f"lag33={cal[33]:+.4f}  lag64={cal[64]:+.4f}")


def _json_clean(o):
    if isinstance(o, dict):
        return {str(k): _json_clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_json_clean(v) for v in o]
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating,)):
        return float(o)
    if isinstance(o, np.ndarray):
        return _json_clean(o.tolist())
    return o


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("file", help="frames.bin")
    ap.add_argument("--live-window", action="store_true",
                     help="also print the live-window bounds used")
    ap.add_argument("--out", help="write the full result as JSON to this path")
    args = ap.parse_args(argv)
    r = analyze_one(args.file)
    if args.live_window and r["usable"]:
        print(f"live-window: dur={r['dur']:.1f}s live_end={r['live_end']:.1f}s "
              f"wedged={r['wedged']}")
    elif args.live_window:
        print(f"live-window: dur={r['dur']:.1f}s live_end={r['live_end']:.1f}s "
              f"wedged={r['wedged']} (UNUSABLE)")
    print_report(r)
    if args.out:
        with open(args.out, "w") as f:
            json.dump(_json_clean(r), f, indent=2)


if __name__ == "__main__":
    main(sys.argv[1:])
