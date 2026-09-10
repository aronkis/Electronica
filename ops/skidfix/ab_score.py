#!/usr/bin/env python3
"""ab_score.py <run_dir> <fwd|rev> -- per-run loss scoreboard for the overnight
A/Bs, using loss_ledger.analyze_run so classes match LOSS_LEDGER.md exactly.
Prints delivered PER over the steady window (t>=15s) and the class counts that
matter tonight: 633-tick, 8-comb, totals."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import numpy as np
from loss_ledger import analyze_run
from frame_taxonomy import read_frames


def main():
    dirp, direction = sys.argv[1], sys.argv[2]
    r = analyze_run(os.path.basename(dirp), dirp, direction)
    fr = read_frames(os.path.join(dirp, "frames.bin"))
    tm = fr["t_mono_ns"].astype(np.int64)
    ts = (tm - tm[0]) / 1e9
    steady = ts >= 15.0
    clean = (fr["crc_ok"] != 0) & steady
    ci = np.flatnonzero(clean)
    cs = fr["host_seq"][ci].astype(np.int64)
    d = np.diff(cs)
    lost = int(np.sum(d[d > 1] - 1))
    span = int(cs[-1] - cs[0] + 1) if cs.size > 1 else 0
    per = 100.0 * lost / span if span else float("nan")

    holes = [h for h in r["holes"] if h["t"] >= 15.0]
    n633 = sum(1 for h in holes if h.get("c633"))
    n8 = sum(1 for h in holes if h.get("c8"))
    lost633 = sum(h["k"] for h in holes if h.get("c633"))
    lost8 = sum(h["k"] for h in holes if h.get("c8") and not h.get("c633"))
    big = sum(h["k"] for h in holes if h["k"] > 20)
    print(f"AB_SCORE dir={direction} run={os.path.basename(dirp)}")
    print(f"AB_SCORE steady_span={span} lost={lost} PER={per:.3f}%")
    print(f"AB_SCORE holes={len(holes)} n633={n633} lost633={lost633}"
          f" n8={n8} lost8={lost8} bigburst_lost={big}")


if __name__ == "__main__":
    main()
