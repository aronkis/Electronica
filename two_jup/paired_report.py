#!/usr/bin/env python3
"""paired_report.py <prefix> -- run-level paired analysis for interleaved A/B captures.

WHY THIS EXISTS. On 2026-08-07 I reported an ARQ improvement as "real, non-overlapping
Clopper-Pearson intervals on ~170k frames per arm". That was wrong: CP assumes independent
Bernoulli trials, and this link's losses are BURSTY (measured: 334 of 397 steady-state loss
bursts are a single frame, but the run-to-run PER spread on the treated arm was 1.34 points
against 0.09 on control). Pooling frames across runs hides run-level variance and lets ONE
lucky run carry a conclusion. **The unit of analysis is the RUN, not the frame.**

So this tool refuses to lead with a pooled number. It reports per-run PER, the paired
delta per pair, a sign test over pairs, and -- importantly -- the count of UNUSABLE/wedged
captures PER ARM, because asymmetric drops silently bias whichever runs survive.

usage: paired_report.py r3cap/arqab_n2_20260807   (prefix before _<arm>_r<N>)
       paired_report.py <prefix> --arms arqoff,arqon
"""
import sys, os, glob, re, subprocess, statistics

def analyze(paths, d):
    """Run accept_analyze.py and pull per-capture PER / UNUSABLE verdicts."""
    out = subprocess.run([sys.executable, os.path.join(d, 'accept_analyze.py'), '--arq'] + paths,
                         capture_output=True, text=True).stdout
    res = {}
    for line in out.splitlines():
        m = re.search(r'(\S+_r\d+): .*?PER=([\d.]+)%', line)
        if m: res[m.group(1)] = float(m.group(2)); continue
        m = re.search(r'(\S+_r\d+): UNUSABLE', line)
        if m: res[m.group(1)] = None
    return res

def main():
    prefix = sys.argv[1].rstrip('/')
    arms = ['arqoff', 'arqon']
    if '--arms' in sys.argv: arms = sys.argv[sys.argv.index('--arms') + 1].split(',')
    d = os.path.dirname(os.path.abspath(__file__))
    per = {}
    for arm in arms:
        paths = sorted(glob.glob(f'{prefix}_{arm}_r*/frames.bin'))
        if not paths: print(f'no captures for arm {arm}'); return
        per[arm] = analyze(paths, d)

    def get(arm, i):
        for k, v in per[arm].items():
            if k.endswith(f'_r{i}'): return v
        return 'missing'

    idx = sorted({int(re.search(r'_r(\d+)$', k).group(1)) for a in arms for k in per[a]})
    print(f'\n=== run-level paired report: {len(idx)} pairs, arms {arms[0]} vs {arms[1]} ===')
    print(f'  {"pair":<6}{arms[0]:>12}{arms[1]:>12}{"paired D":>12}')
    deltas = []
    for i in idx:
        a, b = get(arms[0], i), get(arms[1], i)
        if isinstance(a, float) and isinstance(b, float):
            dl = a - b; deltas.append(dl)
            print(f'  {i:<6}{a:>11.3f}%{b:>11.3f}%{dl:>+11.2f}')
        else:
            fa = 'WEDGED' if a is None else ('--' if a == 'missing' else f'{a:.3f}%')
            fb = 'WEDGED' if b is None else ('--' if b == 'missing' else f'{b:.3f}%')
            print(f'  {i:<6}{fa:>12}{fb:>12}{"dropped":>12}')

    print('\n  drops per arm (asymmetric drops bias the survivors):')
    for arm in arms:
        w = sum(1 for v in per[arm].values() if v is None)
        print(f'    {arm:<10} usable {sum(1 for v in per[arm].values() if v is not None):2d}   wedged/UNUSABLE {w}')

    if deltas:
        pos = sum(1 for x in deltas if x > 0)
        print(f'\n  complete pairs: {len(deltas)}')
        print(f'  mean paired delta : {statistics.mean(deltas):+.2f} points'
              f'   (positive = {arms[1]} better)')
        print(f'  median            : {statistics.median(deltas):+.2f} points')
        print(f'  sign test         : {pos}/{len(deltas)} pairs favour {arms[1]}')
        if len(deltas) >= 2:
            sd = statistics.stdev(deltas)
            print(f'  sd of paired delta: {sd:.2f} points')
            if sd > 0:
                t = statistics.mean(deltas) / (sd / len(deltas) ** 0.5)
                print(f'  paired t          : {t:+.2f} on {len(deltas)-1} df'
                      f'   ({"suggestive" if abs(t) > 2.5 else "NOT significant"})')
        mx = max(deltas, key=abs)
        rest = [x for x in deltas if x is not mx]
        if rest:
            print(f'  drop the largest-magnitude pair ({mx:+.2f}) -> mean {statistics.mean(rest):+.2f}'
                  f'  <- if this collapses, one run was carrying the result')
    print('\n  NOTE: no pooled-frame CP interval is reported here, deliberately. Losses are')
    print('        bursty, so frames are not independent trials and pooling overstates n.')

if __name__ == '__main__':
    main()
