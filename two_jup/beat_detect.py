#!/usr/bin/env python3
"""beat_detect.py -- burst detector shared by the sim leg and the hardware soak.
Sim frame log (sim_beat_long / burst_runs format): columns packet errs clks rstcs ...
  burst = errs >= 20 for >= 200 consecutive frames.
--per-second CSV (beat_soak.sh): t,packets,errs cumulative -> burst = d(errs) >= 5000 for >= 2 s.
"""
import sys

def _runs(flags):
    out, start = [], None
    for i, f in enumerate(flags + [False]):
        if f and start is None: start = i
        if not f and start is not None: out.append((start, i - 1)); start = None
    return out

def detect_frames(rows, thresh=20, minlen=200):
    flags = [r[1] >= thresh for r in rows]
    res = []
    for s, e in _runs(flags):
        if e - s + 1 >= minlen:
            errs = [rows[i][1] for i in range(s, e + 1)]
            res.append({'start': rows[s][0], 'end': rows[e][0], 'frames': e - s + 1,
                        'mean_errs': sum(errs) / len(errs), 'rstcs_delta': rows[e][2] - rows[s][2]})
    return res

def detect_seconds(rows, thresh=5000, minlen=2):
    d = [(rows[i][0], rows[i][2] - rows[i - 1][2]) for i in range(1, len(rows))]
    flags = [x[1] >= thresh for x in d]
    res = []
    for s, e in _runs(flags):
        if e - s + 1 >= minlen:
            errs = [d[i][1] for i in range(s, e + 1)]
            res.append({'start': d[s][0], 'end': d[e][0], 'frames': e - s + 1,
                        'mean_errs': sum(errs) / len(errs), 'rstcs_delta': 0})
    return res

def main():
    path = sys.argv[1]; per_sec = '--per-second' in sys.argv
    rows = []
    for l in open(path):
        if l.startswith('#') or l.startswith('t,') or not l.strip(): continue
        p = l.replace(',', ' ').split()
        rows.append((int(p[0]), int(p[1]), int(p[2])) if per_sec else (int(p[0]), int(p[1]), int(p[3]) if len(p) > 3 else 0))
    b = detect_seconds(rows) if per_sec else detect_frames(rows)
    for x in b:
        print(f"BURST start={x['start']} end={x['end']} frames={x['frames']} mean_errs={x['mean_errs']:.1f} rstcs_delta={x['rstcs_delta']}")
    print(f"BURSTS n={len(b)} rows={len(rows)}")
    return 0

if __name__ == '__main__':
    sys.exit(main())
