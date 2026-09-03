#!/usr/bin/env python3
"""analyze_mu.py <golden_rxw.txt> <run_prefix> [...]

H-1 conviction instrument (2026-08-26). Consumes the `_mu.txt` telemetry dump
from sim_byte_taps_mu (Vwrap_byte_taps_mu, Jul-25 gen): change-compressed
lines `clk,mu,countReg,underflow` decoded from Interpolation_Control's T8.7
stateWord. Correlates Interpolation_Control saturation behaviour with the
per-frame corruption verdicts of score_rxw.py logic (inlined here).

For each run prefix it reports:
  - mu/countReg range + histogram extremes
  - saturation events: beats where countReg sits at a rail (>= +1020 or
    <= -1021; sfix11 rails are +1023/-1024) -- the "saturate instead of
    wrap" defect signature
  - per-frame alignment: which rxw frames are corrupt (vs golden modal
    frame), and whether a saturation event falls inside / within one frame
    of each corrupt frame
Verdict line: MU_CONVICTION <prefix> sat_events=N corrupt=K overlap=M
"""
import sys
from collections import Counter


def read_rxw(path):
    frames, cur = [], []
    for ln in open(path):
        h, last, user = ln.strip().split(',')
        cur.append(h)
        if last == '1':
            frames.append(cur)
            cur = []
    return frames


def frame_verdicts(golden_frames, run_frames):
    """Return list of (idx, corrupt_bool, biterrs). Mirrors score_rxw.py:
    golden = modal 191-word frame of the 0 Hz run; frame 0 warm-up and the
    final truncated frame are excluded from scoring."""
    modal = Counter(tuple(f) for f in golden_frames if len(f) == 191).most_common(1)[0][0]
    out = []
    for i, f in enumerate(run_frames):
        if i == 0 or i >= len(run_frames) - 1:
            continue
        if len(f) != 191:
            out.append((i, True, 64 * abs(len(f) - 191)))
            continue
        be = 0
        for a, b in zip(f, modal):
            be += bin(int(a, 16) ^ int(b, 16)).count('1')
        out.append((i, be > 0, be))
    return out


def frame_clk_bounds(path):
    """clk of each frame's last word from the rxw dump is not logged; instead
    approximate frame boundaries in clk space from the mu file's span and the
    fixed geometry: cadence 4 clk/sample, SPF=49332 samples/frame, 100-clk
    reset preamble."""
    SPF, CAD, T0 = 49332, 4, 100
    return lambda k: (T0 + k * SPF * CAD, T0 + (k + 1) * SPF * CAD)


def main():
    golden = read_rxw(sys.argv[1])
    for pfx in sys.argv[2:]:
        mu_path, rxw_path = pfx + '_mu.txt', pfx + '_rxw.txt'
        sats, n, mumin, mumax, cmin, cmax = [], 0, 9999, -9999, 9999, -9999
        for ln in open(mu_path):
            clk, mu, cnt, und = ln.split(',')
            clk, mu, cnt = int(clk), int(mu), int(cnt)
            n += 1
            mumin, mumax = min(mumin, mu), max(mumax, mu)
            cmin, cmax = min(cmin, cnt), max(cmax, cnt)
            if cnt >= 1020 or cnt <= -1021 or mu >= 1020 or mu <= -1021:
                sats.append((clk, mu, cnt))
        verd = frame_verdicts(golden, read_rxw(rxw_path))
        corrupt = [v for v in verd if v[1]]
        bounds = frame_clk_bounds(rxw_path)
        overlap = 0
        detail = []
        for (k, _, be) in corrupt:
            lo, hi = bounds(k - 1)          # widen one frame early
            hi = bounds(k)[1]
            hit = [s for s in sats if lo <= s[0] <= hi]
            overlap += bool(hit)
            detail.append((k, be, len(hit), hit[0][0] if hit else -1))
        print(f"MU_CONVICTION {pfx.split('/')[-1]} updates={n} "
              f"mu=[{mumin},{mumax}] count=[{cmin},{cmax}] "
              f"sat_events={len(sats)} corrupt_frames={len(corrupt)} "
              f"corrupt_with_sat_overlap={overlap}")
        for k, be, nh, c0 in detail:
            print(f"  frame {k}: biterr={be} sat_hits={nh} first_sat_clk={c0}")
        if sats:
            first = sats[0]
            print(f"  first sat event: clk={first[0]} mu={first[1]} count={first[2]}")


if __name__ == '__main__':
    main()
